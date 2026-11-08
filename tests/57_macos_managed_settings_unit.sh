#!/usr/bin/env bash
# Tier 1 — the macOS base VM's managed agent policy is installed by ONE root script over ONE ssh
# connection, with nothing staged in the guest user's home, and replaces the whole policy directory
# (runs anywhere; nothing is cloned, booted or SSH'd: the "guest" is a local shell run against a
# sandboxed directory).
#
# A file staged in the guest user's home and moved into /Library by a second, privileged call
# could be swapped by any process of that user in between, and an old policy directory edited in
# place keeps whatever a non-root user put in or on it. Either way the build would save that state
# into the base VM every clone inherits. Pinned here, through the REAL
# install_macos_managed_settings, macos_managed_settings_swap_sh, macos_run_root_script and
# ssh_macos, with only `ssh` stubbed:
#   • one ssh connection, whose remote command stages nothing (no `cat >`, no home path); the guest
#     user's home is left empty;
#   • the admin password is on no argv, in no output and in no written file, NOPASSWD sudo or not;
#   • the payload arrives byte-exact (it travels base64-encoded), including quotes, `$`,
#     backslashes, NUL and control bytes, the root script's marker line and its own text, with or
#     without trailing newlines;
#   • the result is a fresh directory, root:wheel (asked of chown) 755, holding only the policy file,
#     root:wheel 644; `chmod -N` (strip any ACL) is run on the fresh directory, the file and the
#     quarantine; nothing is left next to it;
#   • whatever was at the directory's path is replaced and gone: a 777 directory with entries, a
#     hard-linked entry, a root-owned `.managed-settings.backup/`, a directory at the target path, a
#     regular file at the directory's path, a symlink to a directory (whose target is untouched);
#   • the old one is moved into a 700 quarantine under /var/root, which is then removed;
#   • ANY failure (a failing generator, no stored password or SSH transport, a wrong password, a
#     failed chown, `chmod -N` or quarantine) returns 1 with the reason, leaves the old directory as
#     it was and no fresh one behind.
#
# How the guest runs: the stub runs the remote command in an unprivileged user + mount namespace
# (`unshare -rm`, which maps this user to root, so files the test creates are root-owned). In it, a
# recording `chown` is bind-mounted over /usr/sbin (the script's chown path), a recording `chmod` is
# overlaid on /usr/bin (it plays macOS's `chmod -N` and passes every other call to the real one), a
# test directory is mounted over /var (so /var/root is the test's), and `bash --posix` over /bin/sh.
# The script's own absolute tool paths are used and its bytes are never rewritten. `sudo` is a
# stand-in on PATH that reads the password line one byte at a time and refuses a wrong one
# (SUDO_NOPASSWD=1: reads nothing, as with a NOPASSWD grant).
# Accepted trade-off: that is bash 5 in POSIX mode, not macOS's /bin/sh (bash 3.2 in sh mode), GNU
# ls, mv and base64, not macOS's, and no real ACL (the `ls -le` check is skipped by a GNU ls); the
# live check on a Mac covers those. Hosts without unprivileged namespaces and overlayfs (macOS
# itself) skip the tiers that run the script.
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/lib.sh"
AUGUR="$REPO/augur"

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT
exec </dev/null

# Boot-proofing, as in tests/38: the resolved $VM_CLI can never be a real augur-vm.
export AUGUR_VM_BIN="$TMPD/no-such-augur-vm"
AUGUR_SOURCE_ONLY=1 source "$AUGUR"
set +e                                    # augur enables `set -e`; restore lib.sh assert-and-continue

HOME="$TMPD/home"; mkdir -p "$HOME"
# shellcheck disable=SC2034  # read by the sourced augur functions
AUGUR_DIR="$TMPD/augur"
unset ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN

SECRET='pW9+tEsT/sEcReT=='
mkdir -p "$AUGUR_DIR/vms/testvm"
macos_store_admin_password testvm "$SECRET"
# shellcheck disable=SC2034  # read by the sourced ssh wrappers: no key, so no -i/BatchMode opts
MACOS_SSH_KEY="$TMPD/no-such-key"
macos_ssh_host()      { echo "127.0.0.1"; }
macos_ssh_port()      { echo "22"; }
vm_known_hosts_file() { echo "$TMPD/known_hosts"; }

# The guest: its user's home, its /var (holding root's home), and the target under a sandboxed
# /Library (with a space, as the real path has one).
GUEST_HOME="$TMPD/guest-home"; mkdir -p "$GUEST_HOME"
GUEST_VAR="$TMPD/var"; ROOTHOME="$GUEST_VAR/root"
BASE="$TMPD/guest/Library/Application Support"
DSTDIR="$BASE/ClaudeCode"
DST="$DSTDIR/managed-settings.json"
agent_macos_managed_settings_path() { printf '%s\n' "$DST"; }
REAL_PAYLOAD="$TMPD/real-payload"; agent_managed_settings_json > "$REAL_PAYLOAD"
OUTSIDE="$TMPD/outside"                    # a directory outside the guest's policy tree

# ── The guest's tools ────────────────────────────────────────────────────────────────────────────
FAKEBIN="$TMPD/fakebin"; FAKESBIN="$TMPD/fakesbin"; FAKEUSRBIN="$TMPD/fakeusrbin"
mkdir -p "$FAKEBIN" "$FAKESBIN" "$FAKEUSRBIN"
cat > "$FAKEBIN/sudo" <<'EOF'
#!/bin/sh
[ "$1" = -S ] || { echo "sudo stand-in: not -S" >&2; exit 1; }
while [ $# -gt 0 ]; do case "$1" in -p) shift 2 ;; -*) shift ;; *) break ;; esac; done
if [ "$SUDO_NOPASSWD" != 1 ]; then
    IFS= read -r pw
    [ "$pw" = "$SUDO_WANT" ] || { echo "Sorry, try again." >&2; exit 1; }
fi
exec "$@"
EOF
cat > "$FAKESBIN/chown" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$CHOWNLOG"
[ "$CHOWN_FAILS" != 1 ]
EOF
REAL_CHMOD="$(readlink -f /usr/bin/chmod 2>/dev/null)"
if [[ "$REAL_CHMOD" == /usr/bin/* ]]; then cp "$REAL_CHMOD" "$TMPD/real-chmod"; REAL_CHMOD="$TMPD/real-chmod"; fi
cat > "$FAKEUSRBIN/chmod" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "\$CHMODLOG"
if [ "\$1" = -N ]; then [ "\$CHMOD_N_FAILS" != 1 ]; exit; fi
exec '$REAL_CHMOD' "\$@"
EOF
chmod +x "$FAKEBIN/sudo" "$FAKESBIN/chown" "$FAKEUSRBIN/chmod"
BASH_BIN="$(readlink -f "$(command -v bash)")"
SH_TARGET="$(readlink -f /bin/sh)"; SH_WRAP=""
if [[ "$SH_TARGET" != "$BASH_BIN" ]]; then
    SH_WRAP="$TMPD/sh-as-bash-posix"
    printf '#!%s\nexec -a sh %s --posix "$@"\n' "$BASH_BIN" "$BASH_BIN" > "$SH_WRAP"; chmod +x "$SH_WRAP"
fi
# The mounts that make the guest (see the header), then $1 under /bin/sh.
GUEST_MOUNTS='mount --bind "$1" /usr/sbin && mount -t overlay overlay -o lowerdir="$2":/usr/bin /usr/bin \
    && mount --bind "$3" /var && { [ -z "$4" ] || mount --bind "$4" "$5"; } && exec /bin/sh -c "$6"'
# NS_ARGS: -rm maps this user to root. With -c -m --keep-caps it maps this user to itself, keeping the
# capabilities the mounts need, so what the root script creates is NOT root-owned, as when a chown
# does not take.
NS_ARGS=(-rm)
in_guest() {   # in_guest CMD — run CMD as the guest, with this function's stdin
    unshare "${NS_ARGS[@]}" "$BASH_BIN" -c "$GUEST_MOUNTS" _ "$FAKESBIN" "$FAKEUSRBIN" "$GUEST_VAR" "$SH_WRAP" "$SH_TARGET" "$1"
}
mkdir -p "$ROOTHOME"
CAN_RUN=0
if command -v unshare >/dev/null 2>&1 && [[ -d /usr/sbin && -d /var && -n "$REAL_CHMOD" ]] \
    && in_guest true </dev/null 2>/dev/null; then CAN_RUN=1; fi
SUDO_NOPASSWD=0; CHOWN_FAILS=0; CHMOD_N_FAILS=0; GUEST_PW="$SECRET"

# The recording `ssh`: call N leaves its argv in $LOG/N.argv and its stdin in $LOG/N.stdin, then
# runs the remote command, fed exactly that stdin, as the guest.
LOG="$TMPD/ssh"; mkdir -p "$LOG"
CHOWNLOG="$TMPD/chown-calls"; CHMODLOG="$TMPD/chmod-calls"
ssh() {
    local n; n=$(( $(find "$LOG" -name '*.argv' | wc -l) + 1 ))
    printf '%s\n' "$@" > "$LOG/$n.argv"
    cat > "$LOG/$n.stdin"
    local cmd="${!#}"
    ( cd "$GUEST_HOME" && HOME="$GUEST_HOME" PATH="$FAKEBIN:$PATH" SUDO_WANT="$GUEST_PW" \
          SUDO_NOPASSWD="$SUDO_NOPASSWD" CHOWNLOG="$CHOWNLOG" CHOWN_FAILS="$CHOWN_FAILS" \
          CHMODLOG="$CHMODLOG" CHMOD_N_FAILS="$CHMOD_N_FAILS" in_guest "$cmd" ) < "$LOG/$n.stdin"
}
reset() {
    rm -rf "$LOG"/* "$CHOWNLOG" "$CHMODLOG" "$TMPD/guest" "$OUTSIDE" "$ROOTHOME"
    mkdir -p "$LOG" "$BASE" "$OUTSIDE" "$ROOTHOME"
}
# has_line TEXT GLOB — some line of TEXT matches GLOB as a whole.
has_line() { local _l; while IFS= read -r _l; do [[ "$_l" == $2 ]] && return 0; done <<< "$1"; return 1; }
n_calls() { find "$LOG" -name '*.argv' | wc -l | tr -d ' '; }
file_mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }

# install_with PAYLOAD-FILE — run the real install with agent_managed_settings_json printing that
# file's exact bytes; sets $out and $rc.
install_with() {
    PAYLOAD_FILE="$1"
    agent_managed_settings_json() { cat "$PAYLOAD_FILE"; }
    out="$( set -e; install_macos_managed_settings testvm 2>&1 )"; rc=$?
}

# check_install NAME PAYLOAD-FILE — every property of a successful install.
check_install() {
    local name="$1" pf="$2"
    eq "0" "$rc" "$name: returns 0"
    hasnt "$out" "Could not" "$name: no failure"
    eq "1" "$(n_calls)" "$name: one ssh connection"
    if [[ -f "$DST" && ! -L "$DSTDIR" ]] && cmp -s "$pf" "$DST"; then ok "$name: the payload arrived byte-exact"
    else fail "$name: the installed file differs from the payload" \
              "want [$(od -c "$pf" | head -n5)] got [$(od -c "$DST" 2>/dev/null | head -n5)]"; fi
    eq "644" "$(file_mode "$DST" 2>/dev/null)" "$name: mode 644"
    eq "755" "$(file_mode "$DSTDIR" 2>/dev/null)" "$name: the policy directory is mode 755"
    eq "$(basename "$DST")" "$(ls -A "$DSTDIR" 2>/dev/null)" "$name: the policy directory holds only the policy file"
    eq "$(basename "$DSTDIR")" "$(ls -A "$BASE")" "$name: nothing is left next to the policy directory"
    eq "" "$(ls -A "$ROOTHOME")" "$name: the quarantine under /var/root is removed"
    eq "" "$(ls -A "$GUEST_HOME")" "$name: nothing is staged in the guest user's home"
    local ch cm
    ch="$(cat "$CHOWNLOG" 2>/dev/null)"; cm="$(cat "$CHMODLOG" 2>/dev/null)"
    [[ "$ch" == "root:wheel $BASE/.augur-policy."*$'\n'"root:wheel $BASE/.augur-policy."*"/.managed-settings.json."* ]] \
        && ok "$name: chown root:wheel on the fresh directory, then on the temp file in it" \
        || fail "$name: chown calls" "[$ch]"
    [[ "$cm" == *"-N $BASE/.augur-policy."* ]] && ok "$name: chmod -N on the fresh directory" || fail "$name: no chmod -N on the fresh directory" "[$cm]"
    has_line "$cm" "-N $BASE/.augur-policy.*/.managed-settings.json.*" && ok "$name: chmod -N on the policy file" || fail "$name: no chmod -N on the policy file" "[$cm]"
    [[ "$cm" == *"700 /var/root/.augur-quarantine."* && "$cm" == *"-N /var/root/.augur-quarantine."* ]] \
        && ok "$name: the quarantine is a 700 directory under /var/root, ACL stripped" || fail "$name: quarantine" "[$cm]"
    if grep -rqF -- "$SECRET" "$LOG"/*.argv; then fail "$name: the admin password is on an ssh argv"
    else ok "$name: the admin password is on no ssh argv"; fi
    hasnt "$out" "$SECRET" "$name: the admin password is not in the output"
    if grep -qF -- "$SECRET" "$DST" 2>/dev/null; then fail "$name: the admin password is in the installed file"
    else ok "$name: the admin password is not in the installed file"; fi
    local argv; argv="$(cat "$LOG/1.argv")"
    hasnt "$argv" "cat > " "$name: the remote command writes no file before sudo"
    hasnt "$argv" "/Users/" "$name: the remote command names no home path"
    has "$argv" "sudo -S -k -p ''" "$name: the root script runs under one sudo -S -k"
}

# check_untouched NAME — a failed install: rc 1, the old policy directory as it was, nothing left.
check_untouched() {
    local name="$1"
    eq "1" "$rc" "$name: returns 1 (build/update stop)"
    has "$out" "Could not install the managed" "$name: the error says so"
    hasnt "$out" "$SECRET" "$name: the admin password is not in the output"
    eq "old" "$(cat "$DST" 2>/dev/null)" "$name: the old policy is still in place"
    eq "$(basename "$DSTDIR")" "$(ls -A "$BASE")" "$name: no fresh directory is left next to it"
}

section "Tier 1 — failures before any connection are fatal"
agent_managed_settings_json() { printf '{"env":'; return 1; }
reset; out="$( set -e; install_macos_managed_settings testvm 2>&1 )"; rc=$?
eq "1" "$rc" "failing generator: returns 1"
has "$out" "Could not produce the managed" "failing generator: says so"
eq "0" "$(n_calls)" "failing generator: nothing is sent to the guest"
E="$TMPD/empty"; : > "$E"
reset; install_with "$E"
eq "1" "$rc" "empty payload: returns 1"
eq "0" "$(n_calls)" "empty payload: nothing is sent to the guest"
agent_managed_settings_json() { cat "$REAL_PAYLOAD"; }
reset; out="$( set -e; install_macos_managed_settings nocredvm 2>&1 )"; rc=$?
eq "1" "$rc" "VM without a stored password: returns 1"
eq "0" "$(n_calls)" "VM without a stored password: no ssh connection is made"
has "$out" "no stored admin password" "VM without a stored password: augur's error says why"
hasnt "$out" "| VM 'nocredvm'" "VM without a stored password: augur's error is not shown as guest text"
reset; out="$( set -e; macos_ssh_host() { :; }; install_macos_managed_settings testvm 2>&1 )"; rc=$?
eq "1" "$rc" "no SSH transport: returns 1"
eq "0" "$(n_calls)" "no SSH transport: no ssh connection is made"
has "$out" "does not resolve" "no SSH transport: augur's error says why"
hasnt "$out" "| Cannot reach" "no SSH transport: augur's error is not shown as guest text"

if (( ! CAN_RUN )); then
    skip "the root script, run as the guest" "no unprivileged user+mount namespaces with overlayfs here"
    finish; exit $?
fi

section "Tier 1 — the guest (control)"
_probe="$( in_guest 'echo "$BASH_VERSION"; set -o | grep posix; /bin/chmod -N /nonexistent && echo chmod-N-ok; ls -A /var' 2>&1 )"
if [[ -n "$(sed -n 1p <<< "$_probe")" && "$_probe" =~ posix[[:space:]]+on ]]; then ok "the stub's /bin/sh is bash with POSIX mode on"
else fail "the stub's /bin/sh is not bash in POSIX mode" "[$_probe]"; fi
has "$_probe" "chmod-N-ok" "the stub's /bin/chmod takes -N"
has "$_probe" "root" "the stub's /var is the test's"

section "Tier 1 — a fresh install"
reset; install_with "$REAL_PAYLOAD"
check_install "real payload" "$REAL_PAYLOAD"
eq "$SECRET" "$(head -n1 "$LOG/1.stdin")" "real payload: the admin password is the first line of ssh's stdin"
eq "$MACOS_ROOT_SCRIPT_BEGIN" "$(sed -n 2p "$LOG/1.stdin")" "real payload: the root script's marker follows it"
hasnt "$(cat "$LOG/1.stdin")" "DISABLE_AUTOUPDATER" "real payload: the JSON is not on the wire as text (base64)"
hasnt "$out" "The guest printed" "real payload: the guest printed nothing"

section "Tier 1 — a hostile payload"
H="$TMPD/hostile"
{
    printf '%s\n' "{\"a\":'single' \"double\" \$HOME \${HOME} \$(id) \`id\` \\\\ \\n \\\$ \\"
    printf '%s\n' "$MACOS_ROOT_SCRIPT_BEGIN" "SCRIPT" "'"
    macos_managed_settings_swap_sh          # the root script's own text
    printf '%s\n' "exit 0" "exit 1" "\"}"
    printf 'ctl:\001\033[31m nul:\000 utf8:\303\251 '
    printf 'no trailing newline: end'
} > "$H"
has "$(tr -d '\000' < "$H")" '/usr/bin/base64 --decode' "hostile payload holds the root script's own text (control)"
reset; install_with "$H"
check_install "hostile payload" "$H"
for nl in 1 3; do
    T="$TMPD/trailing-$nl"; { cat "$H"; for (( i = 0; i < nl; i++ )); do printf '\n'; done; } > "$T"
    reset; install_with "$T"
    check_install "hostile payload + $nl trailing newline(s)" "$T"
done
SUDO_NOPASSWD=1; reset; install_with "$H"; SUDO_NOPASSWD=0
check_install "NOPASSWD sudo (the password line is discarded, never run)" "$H"

section "Tier 1 — whatever was at the policy directory's path is replaced, and gone"
reset; mkdir -p "$DSTDIR/sub"; chmod 777 "$DSTDIR" "$DSTDIR/sub"
printf 'old\n' > "$DST"; printf '{"mcpServers":{"x":{}}}\n' > "$DSTDIR/managed-mcp.json"; printf 'x\n' > "$DSTDIR/sub/deep"
install_with "$REAL_PAYLOAD"
check_install "a 777 directory with entries" "$REAL_PAYLOAD"
reset; mkdir -p "$DSTDIR"; printf 'outside\n' > "$OUTSIDE/file"; ln "$OUTSIDE/file" "$DSTDIR/managed-mcp.json"
install_with "$REAL_PAYLOAD"
check_install "a hard-linked entry" "$REAL_PAYLOAD"
eq "outside" "$(cat "$OUTSIDE/file")" "a hard-linked entry: the file it links to is untouched"
eq "1" "$(stat -c %h "$OUTSIDE/file" 2>/dev/null || stat -f %l "$OUTSIDE/file")" "a hard-linked entry: the link in the policy directory is gone"
reset; mkdir -p "$DSTDIR/.managed-settings.backup"; printf 'b\n' > "$DSTDIR/.managed-settings.backup/x"
install_with "$REAL_PAYLOAD"
check_install "a root-owned .managed-settings.backup/ (discarded with the old directory, by design)" "$REAL_PAYLOAD"
reset; mkdir -p "$DST"; printf 'keep\n' > "$DST/inside"
install_with "$REAL_PAYLOAD"
check_install "a directory at the target path" "$REAL_PAYLOAD"
reset; printf 'a file\n' > "$DSTDIR"
install_with "$REAL_PAYLOAD"
check_install "a regular file at the directory's path" "$REAL_PAYLOAD"
reset; mkdir -p "$OUTSIDE/linked"; printf 'outside\n' > "$OUTSIDE/linked/managed-settings.json"; ln -s "$OUTSIDE/linked" "$DSTDIR"
install_with "$REAL_PAYLOAD"
check_install "a symlink to a directory" "$REAL_PAYLOAD"
eq "outside" "$(cat "$OUTSIDE/linked/managed-settings.json")" "a symlink to a directory: its target is untouched"
eq "managed-settings.json" "$(ls -A "$OUTSIDE/linked")" "a symlink to a directory: nothing is written into its target"
reset; ln -s "$OUTSIDE/missing" "$DSTDIR"
install_with "$REAL_PAYLOAD"
check_install "a dangling symlink" "$REAL_PAYLOAD"
[[ -e "$OUTSIDE/missing" ]] && fail "a dangling symlink: something was created at its target" || ok "a dangling symlink: nothing is created at its target"

section "Tier 1 — any failure in the guest is fatal, and leaves the old directory as it was"
old_policy() { reset; mkdir -p "$DSTDIR"; printf 'old\n' > "$DST"; }
GUEST_PW="some-other-password"; old_policy; install_with "$REAL_PAYLOAD"; GUEST_PW="$SECRET"
check_untouched "wrong password"
has "$out" "| Sorry, try again." "wrong password: sudo's own message is shown as guest text"
CHOWN_FAILS=1; old_policy; install_with "$REAL_PAYLOAD"; CHOWN_FAILS=0
check_untouched "failed chown"
has "$out" "| cannot make" "failed chown: the guest's reason is shown"
CHMOD_N_FAILS=1; old_policy; install_with "$REAL_PAYLOAD"; CHMOD_N_FAILS=0
check_untouched "failed chmod -N"
has "$out" "without an ACL" "failed chmod -N: the guest's reason is shown"
NS_ARGS=(-c -m --keep-caps); old_policy; install_with "$REAL_PAYLOAD"; NS_ARGS=(-rm)
check_untouched "files that do not end up root-owned"
has "$out" "| the new policy is not root:wheel without an ACL" "files that do not end up root-owned: the check catches it"
old_policy; rmdir "$ROOTHOME"; install_with "$REAL_PAYLOAD"
check_untouched "no /var/root for the quarantine"
has "$out" "| cannot create a quarantine directory in /var/root" "no /var/root: the guest's reason is shown"

finish
