#!/usr/bin/env bash
# Tier 1 — the macOS base VM's managed agent policy is installed by ONE root script over ONE ssh
# connection, with nothing staged in the guest user's home (runs anywhere; nothing is cloned,
# booted or SSH'd: the "guest" is a local shell run against a sandboxed directory).
#
# A file staged in the guest user's home and moved into /Library by a second, privileged call
# could be swapped by any process of that user in between, and the build would then save
# attacker-chosen root-owned policy into the base VM every clone inherits. Pinned here, through the
# REAL install_macos_managed_settings, macos_run_root_script and ssh_macos, with only `ssh` stubbed:
#   • one ssh connection, whose remote command stages nothing (no `cat >`, no home path);
#   • the guest user's home is left empty, and the target directory holds only the target file;
#   • the admin password is on no argv, in no output and in no written file, NOPASSWD sudo or not;
#   • the payload arrives byte-exact (it travels base64-encoded), including quotes, `$`,
#     backslashes, NUL and control bytes, the root script's marker line, its heredoc delimiter and
#     its own command text, with or without trailing newlines;
#   • the file is root:wheel (asked of chown, on a temp file in the target directory) and mode 644,
#     and replaces an existing target by rename; the target directory is made root:wheel 755;
#   • in that directory, every entry not owned by root, every symlink (a target that is one
#     included) and every entry writable by group or others is removed and named, a leftover temp
#     file is removed, and root's own entries are kept;
#   • a symlinked target directory, or a target that is a root-owned directory, is tampering: the
#     install returns 1 (build/update stop) and nothing is installed or put inside it;
#   • a wrong password, or a failed chown, warns and continues (rc 0), leaves an existing target
#     untouched and no temp file behind, and prints no password; sudo's message is shown as guest
#     text;
#   • a generator that fails, a VM with no stored password, or one with no SSH transport warns and
#     connects to nothing, with augur's own error not shown as guest text.
#
# How the guest runs: the stub runs the remote command in an unprivileged user + mount namespace
# (`unshare -rm`, or `unshare -c -m --keep-caps` to play files owned by a non-root user), where a
# recording `chown` is bind-mounted over /usr/sbin (the script's chown path) and `bash --posix`
# over /bin/sh, so the script's own absolute tool paths are used and its bytes are never
# rewritten. `sudo` is a stand-in on PATH that reads the password line one byte at
# a time and refuses a wrong one (SUDO_NOPASSWD=1: reads nothing, as with a NOPASSWD grant).
# Accepted trade-off: that is bash 5 in POSIX mode, not macOS's /bin/sh (bash 3.2 in sh mode), and
# GNU base64 --decode, not macOS's; the live check on a Mac covers those. Hosts without
# unprivileged namespaces (macOS itself) skip the tiers that run the script.
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

# The guest: its user's home, and the target under a sandboxed /Library (with a space, as the real
# path has one).
GUEST_HOME="$TMPD/guest-home"; mkdir -p "$GUEST_HOME"
DST="$TMPD/guest/Library/Application Support/ClaudeCode/managed-settings.json"
DSTDIR="$(dirname "$DST")"
agent_macos_managed_settings_path() { printf '%s\n' "$DST"; }
REAL_PAYLOAD="$TMPD/real-payload"; agent_managed_settings_json > "$REAL_PAYLOAD"

# ── The guest's tools ────────────────────────────────────────────────────────────────────────────
FAKEBIN="$TMPD/fakebin"; FAKESBIN="$TMPD/fakesbin"; mkdir -p "$FAKEBIN" "$FAKESBIN"
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
case "$CHOWN_FAILS" in 1) exit 1 ;; tmp) case "$*" in */.managed-settings.*) exit 1 ;; esac ;; esac
EOF
chmod +x "$FAKEBIN/sudo" "$FAKESBIN/chown"
BASH_BIN="$(readlink -f "$(command -v bash)")"
SH_TARGET="$(readlink -f /bin/sh)"; SH_WRAP=""
if [[ "$SH_TARGET" != "$BASH_BIN" ]]; then
    SH_WRAP="$TMPD/sh-as-bash-posix"
    printf '#!%s\nexec -a sh %s --posix "$@"\n' "$BASH_BIN" "$BASH_BIN" > "$SH_WRAP"; chmod +x "$SH_WRAP"
fi
CAN_RUN=0
CAN_RUN_USER=0
if command -v unshare >/dev/null 2>&1 && [[ -d /usr/sbin ]] \
    && unshare -rm "$BASH_BIN" -c 'mount --bind "$1" /usr/sbin' _ "$FAKESBIN" 2>/dev/null; then CAN_RUN=1; fi
if (( CAN_RUN )) && unshare -c -m --keep-caps "$BASH_BIN" -c 'mount --bind "$1" /usr/sbin' _ "$FAKESBIN" 2>/dev/null; then CAN_RUN_USER=1; fi
SUDO_NOPASSWD=0; CHOWN_FAILS=0; GUEST_PW="$SECRET"

# The recording `ssh`: call N leaves its argv in $LOG/N.argv and its stdin in $LOG/N.stdin, then
# runs the remote command, fed exactly that stdin, as the guest (see the header).
LOG="$TMPD/ssh"; mkdir -p "$LOG"
CHOWNLOG="$TMPD/chown-calls"
ssh() {
    local n; n=$(( $(find "$LOG" -name '*.argv' | wc -l) + 1 ))
    printf '%s\n' "$@" > "$LOG/$n.argv"
    cat > "$LOG/$n.stdin"
    local cmd="${!#}"
    ( cd "$GUEST_HOME" && HOME="$GUEST_HOME" PATH="$FAKEBIN:$PATH" SUDO_WANT="$GUEST_PW" \
          SUDO_NOPASSWD="$SUDO_NOPASSWD" CHOWNLOG="$CHOWNLOG" CHOWN_FAILS="$CHOWN_FAILS" \
          unshare "${NS_ARGS[@]}" "$BASH_BIN" -c \
          'mount --bind "$1" /usr/sbin && { [ -z "$2" ] || mount --bind "$2" "$3"; } && exec /bin/sh -c "$4"' \
          _ "$FAKESBIN" "$SH_WRAP" "$SH_TARGET" "$cmd" ) < "$LOG/$n.stdin"
}
reset() { rm -rf "$LOG"/* "$CHOWNLOG" "$TMPD/guest" "$TMPD/elsewhere"; mkdir -p "$LOG"; }
# Who owns the files this test creates, as the guest sees them. root (the default): the namespace
# maps this user to root, so they are root-owned. user: it maps this user to itself (keeping the
# capabilities the mounts need), so they belong to a non-root user, and nothing is root-owned.
as_owner() { if [[ "$1" == user ]]; then NS_ARGS=(-c -m --keep-caps); else NS_ARGS=(-rm); fi; }
as_owner root
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
    hasnt "$out" "Could not" "$name: no failure warning"
    eq "1" "$(n_calls)" "$name: one ssh connection"
    if [[ -f "$DST" ]] && cmp -s "$pf" "$DST"; then ok "$name: the payload arrived byte-exact"
    else fail "$name: the installed file differs from the payload" \
              "want [$(od -c "$pf" | head -n5)] got [$(od -c "$DST" 2>/dev/null | head -n5)]"; fi
    eq "644" "$(file_mode "$DST" 2>/dev/null)" "$name: mode 644"
    eq "755" "$(file_mode "$DSTDIR" 2>/dev/null)" "$name: the target directory is mode 755"
    eq "$(basename "$DST")" "$(ls -A "$DSTDIR" 2>/dev/null)" "$name: the target directory holds only the target (no temp left)"
    eq "" "$(ls -A "$GUEST_HOME")" "$name: nothing is staged in the guest user's home"
    eq "root:wheel $DSTDIR" "$(sed -n 1p "$CHOWNLOG" 2>/dev/null)" "$name: the target directory is made root:wheel first"
    local c; c="$(sed -n 2p "$CHOWNLOG" 2>/dev/null)"
    if [[ "$c" == "root:wheel $DSTDIR/.managed-settings."* ]]; then
        ok "$name: chown root:wheel on a temp file in the target directory, before the rename"
    else fail "$name: chown was not asked for root:wheel on a temp file in the target directory" "[$c]"; fi
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

section "Tier 1 — refused before any connection"
agent_managed_settings_json() { printf '{"env":'; return 1; }
reset; out="$( set -e; install_macos_managed_settings testvm 2>&1 )"; rc=$?
eq "0" "$rc" "failing generator: returns 0 (best effort)"
has "$out" "Could not produce the managed" "failing generator: says so"
eq "0" "$(n_calls)" "failing generator: nothing is sent to the guest"
E="$TMPD/empty"; : > "$E"
reset; install_with "$E"
eq "0" "$rc" "empty payload: returns 0"
eq "0" "$(n_calls)" "empty payload: nothing is sent to the guest"
has "$out" "Could not produce the managed" "empty payload: says so"
agent_managed_settings_json() { cat "$REAL_PAYLOAD"; }
reset; out="$( set -e; install_macos_managed_settings nocredvm 2>&1 )"; rc=$?
eq "0" "$rc" "VM without a stored password: returns 0 (best effort)"
eq "0" "$(n_calls)" "VM without a stored password: no ssh connection is made"
has "$out" "no stored admin password" "VM without a stored password: augur's error says why"
hasnt "$out" "| VM 'nocredvm'" "VM without a stored password: augur's error is not shown as guest text"
has "$out" "Could not install the managed" "VM without a stored password: the warning is shown"
reset; out="$( set -e; macos_ssh_host() { :; }; install_macos_managed_settings testvm 2>&1 )"; rc=$?
eq "0" "$rc" "no SSH transport: returns 0 (best effort)"
eq "0" "$(n_calls)" "no SSH transport: no ssh connection is made"
has "$out" "does not resolve" "no SSH transport: augur's error says why"
hasnt "$out" "| Cannot reach" "no SSH transport: augur's error is not shown as guest text"

if (( ! CAN_RUN )); then
    skip "the root script, run as the guest" "no unprivileged user+mount namespaces here (unshare -rm)"
    finish; exit $?
fi

section "Tier 1 — the guest shell (control)"
_probe="$( unshare -rm "$BASH_BIN" -c '{ [ -z "$1" ] || mount --bind "$1" "$2"; } && exec /bin/sh -c "echo \"\$BASH_VERSION\"; set -o | grep posix"' \
           _ "$SH_WRAP" "$SH_TARGET" )"
if [[ -n "$(sed -n 1p <<< "$_probe")" && "$_probe" =~ posix[[:space:]]+on ]]; then ok "the stub's /bin/sh is bash with POSIX mode on"
else fail "the stub's /bin/sh is not bash in POSIX mode" "[$_probe]"; fi

section "Tier 1 — the real payload"
reset; install_with "$REAL_PAYLOAD"
check_install "real payload" "$REAL_PAYLOAD"
eq "$SECRET" "$(head -n1 "$LOG/1.stdin")" "real payload: the admin password is the first line of ssh's stdin"
eq "$MACOS_ROOT_SCRIPT_BEGIN" "$(sed -n 2p "$LOG/1.stdin")" "real payload: the root script's marker follows it"
hasnt "$out" "Removed entries" "real payload: nothing is removed from a fresh directory"
hasnt "$(cat "$LOG/1.stdin")" "DISABLE_AUTOUPDATER" "real payload: the JSON is not on the wire as text (base64)"

section "Tier 1 — a hostile payload"
H="$TMPD/hostile"
{
    printf '%s\n' "{\"a\":'single' \"double\" \$HOME \${HOME} \$(id) \`id\` \\\\ \\n \\\$ \\"
    printf '%s\n' "$MACOS_ROOT_SCRIPT_BEGIN" "AUGUR_MANAGED_SETTINGS_B64" "'AUGUR_MANAGED_SETTINGS_B64'"
    # The root script's own command text.
    awk '/^install_macos_managed_settings\(\)/{f=1} f&&/^\[ ! -L/{p=1} p{print} p&&/^\/usr\/sbin\/chown root:wheel/{exit}' "$AUGUR"
    printf '%s\n' "exit 0" "exit 1" "\"}"
    printf 'ctl:\001\033[31m nul:\000 utf8:\303\251 '
    printf 'no trailing newline: end'
} > "$H"
has "$(tr -d '\000' < "$H")" '/usr/bin/base64 --decode' "hostile payload holds the root script's own command text (control)"
reset; install_with "$H"
check_install "hostile payload" "$H"
for nl in 1 3; do
    T="$TMPD/trailing-$nl"; { cat "$H"; for (( i = 0; i < nl; i++ )); do printf '\n'; done; } > "$T"
    reset; install_with "$T"
    check_install "hostile payload + $nl trailing newline(s)" "$T"
done

section "Tier 1 — NOPASSWD sudo (the build's grant): the password line is discarded, never run"
SUDO_NOPASSWD=1; reset; install_with "$H"; SUDO_NOPASSWD=0
check_install "NOPASSWD" "$H"

section "Tier 1 — an existing target, and an existing target directory"
reset; mkdir -p "$DSTDIR"; chmod 777 "$DSTDIR"; printf 'old\n' > "$DST"
install_with "$REAL_PAYLOAD"
check_install "replace (directory was 777)" "$REAL_PAYLOAD"

section "Tier 1 — tampering only root could cause is fatal, and nothing is installed"
reset; mkdir -p "$TMPD/elsewhere" "$(dirname "$DSTDIR")"; ln -s "$TMPD/elsewhere" "$DSTDIR"
install_with "$REAL_PAYLOAD"
eq "1" "$rc" "symlinked target directory: returns 1 (build/update stop)"
has "$out" "has been tampered with" "symlinked target directory: the error says so"
hasnt "$out" "continuing without it" "symlinked target directory: not reported as best effort"
has "$out" "| ${DSTDIR} is a symlink" "symlinked target directory: the guest's reason is shown as guest text"
eq "" "$(ls -A "$TMPD/elsewhere")" "symlinked target directory: nothing is written through it"
eq "" "$(cat "$CHOWNLOG" 2>/dev/null)" "symlinked target directory: nothing is chowned"
reset; mkdir -p "$DST"; printf 'keep\n' > "$DST/inside"
install_with "$REAL_PAYLOAD"
eq "1" "$rc" "target is a root-owned directory: returns 1 (build/update stop)"
has "$out" "has been tampered with" "target is a root-owned directory: the error says so"
has "$out" "| ${DST} is not a regular file" "target is a root-owned directory: the guest's reason is shown as guest text"
eq "inside" "$(ls -A "$DST")" "target is a root-owned directory: nothing is put inside it"
eq "keep" "$(cat "$DST/inside")" "target is a root-owned directory: its content is left alone"
eq "$(basename "$DST")" "$(ls -A "$DSTDIR")" "target is a root-owned directory: no temp file left"

section "Tier 1 — untrusted entries in the policy directory are removed, root's own are kept"
reset; mkdir -p "$DSTDIR" "$TMPD/elsewhere"; ln -s "$TMPD/elsewhere" "$DST"
install_with "$REAL_PAYLOAD"
check_install "target is a symlink to a directory" "$REAL_PAYLOAD"
has "$out" "| removed untrusted ${DST}" "target is a symlink to a directory: the removal is named"
eq "" "$(ls -A "$TMPD/elsewhere")" "target is a symlink to a directory: nothing is written through it"
reset; mkdir -p "$DSTDIR"
printf '{"mcpServers":{}}\n' > "$DSTDIR/managed-mcp.json"; chmod 644 "$DSTDIR/managed-mcp.json"
printf 'x\n' > "$DSTDIR/CLAUDE.md"; chmod 666 "$DSTDIR/CLAUDE.md"
mkdir -p "$DSTDIR/sub"; chmod 777 "$DSTDIR/sub"
ln -s "$TMPD/elsewhere" "$DSTDIR/linked"
printf 'stale\n' > "$DSTDIR/.managed-settings.AbC123"
install_with "$REAL_PAYLOAD"
eq "0" "$rc" "root-owned directory with mixed entries: returns 0"
if cmp -s "$REAL_PAYLOAD" "$DST"; then ok "root-owned directory with mixed entries: the payload is installed"
else fail "root-owned directory with mixed entries: the payload is not installed"; fi
eq $'managed-mcp.json\nmanaged-settings.json' "$(ls -A "$DSTDIR" | LC_ALL=C sort)" \
    "root-owned directory with mixed entries: only root's own 644 file and the target remain"
eq '{"mcpServers":{}}' "$(cat "$DSTDIR/managed-mcp.json")" "root-owned directory with mixed entries: root's own file is untouched"
for _e in CLAUDE.md sub linked; do
    has "$out" "| removed untrusted ${DSTDIR}/${_e}" "root-owned directory: the removal of ${_e} is named"
done
hasnt "$out" "managed-mcp.json" "root-owned directory: root's own file is not named"
hasnt "$out" ".managed-settings.AbC123" "root-owned directory: a leftover temp file is removed without being named"

if (( CAN_RUN_USER )); then
    as_owner user
    reset; mkdir -p "$DSTDIR/sub" "$DST"
    printf '{"mcpServers":{"evil":{}}}\n' > "$DSTDIR/managed-mcp.json"; chmod 644 "$DSTDIR/managed-mcp.json"
    printf 'x\n' > "$DSTDIR/CLAUDE.md"; chmod 644 "$DSTDIR/CLAUDE.md"; chmod 755 "$DSTDIR/sub"
    printf 'x\n' > "$DSTDIR/sub/deep"; printf 'stale\n' > "$DSTDIR/.managed-settings.zz"; printf 'x\n' > "$DST/inside"
    install_with "$REAL_PAYLOAD"
    as_owner root
    check_install "every entry owned by another user" "$REAL_PAYLOAD"
    for _e in managed-mcp.json CLAUDE.md sub .managed-settings.zz managed-settings.json; do
        has "$out" "| removed untrusted ${DSTDIR}/${_e}" "another user's ${_e} is removed and named"
    done
    has "$out" "Removed entries augur does not trust" "another user's entries: the warning is shown"
else
    skip "entries owned by another user" "no user namespace that maps this user to itself with capabilities"
fi

section "Tier 1 — failures warn, continue, and leave the target as it was"
GUEST_PW="some-other-password"
reset; mkdir -p "$DSTDIR"; printf 'old\n' > "$DST"
install_with "$REAL_PAYLOAD"
GUEST_PW="$SECRET"
eq "0" "$rc" "wrong password: still returns 0 (best effort)"
has "$out" "Could not install the managed" "wrong password: the warning is shown"
has "$out" "| Sorry, try again." "wrong password: sudo's own message is shown as guest text"
hasnt "$out" "$SECRET" "wrong password: the admin password is not in the output"
eq "old" "$(cat "$DST")" "wrong password: the existing target is untouched"
eq "$(basename "$DST")" "$(ls -A "$DSTDIR")" "wrong password: no temp file left"
eq "" "$(ls -A "$GUEST_HOME")" "wrong password: nothing staged in the guest user's home"

CHOWN_FAILS=1   # the target directory's chown
reset; mkdir -p "$DSTDIR"; printf 'old\n' > "$DST"
install_with "$H"
CHOWN_FAILS=0
eq "0" "$rc" "failed chown: still returns 0 (best effort)"
has "$out" "Could not install the managed" "failed chown: the warning is shown"
eq "old" "$(cat "$DST")" "failed chown: the existing target is untouched"
eq "$(basename "$DST")" "$(ls -A "$DSTDIR")" "failed chown: no temp file left"

CHOWN_FAILS=tmp
reset; mkdir -p "$DSTDIR"; printf 'old\n' > "$DST"
install_with "$H"
CHOWN_FAILS=0
eq "0" "$rc" "failed chown of the temp file: still returns 0 (best effort)"
has "$out" "Could not install the managed" "failed chown of the temp file: the warning is shown"
has "$(cat "$CHOWNLOG")" "$DSTDIR/.managed-settings." "failed chown of the temp file: the temp file was written (control)"
eq "old" "$(cat "$DST")" "failed chown of the temp file: the existing target is untouched"
eq "$(basename "$DST")" "$(ls -A "$DSTDIR")" "failed chown of the temp file: the temp file is removed"

finish
