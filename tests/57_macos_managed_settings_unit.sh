#!/usr/bin/env bash
# Tier 1 — the macOS base VM's managed agent policy is installed by ONE root script over ONE ssh
# connection, with nothing staged in the guest user's home (runs anywhere; nothing is cloned,
# booted or SSH'd: the "guest" is a local shell run against a sandboxed directory).
#
# A file staged in the guest user's home and moved into /Library by a second, privileged call
# could be swapped by any process of that user in between, and the build would then save
# attacker-chosen root-owned policy into the base VM every clone inherits. Pinned here, through the
# REAL install_macos_managed_settings, macos_run_root_script and ssh_macos, with only `ssh` stubbed
# (it runs the remote command under a `sudo -S` stand-in, like the guest would):
#   • one ssh connection, whose remote command stages nothing (no `cat >`, no home path);
#   • the guest user's home is left empty, and the target directory holds only the target file;
#   • the admin password is on no argv, in no output and in no written file, NOPASSWD sudo or not;
#   • the payload arrives byte-exact, including quotes, `$`, backticks, backslashes, the root
#     script's marker line, the heredoc's own delimiter line, and with or without trailing newlines;
#   • the file is root:wheel (asked of chown, on the temp file in the target directory) and mode
#     644, and replaces an existing target by rename;
#   • a wrong password, or a failed chown, warns and continues (rc 0), leaves an existing target
#     untouched and no temp file behind, and prints no password.
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

# The `sudo -S` stand-in: reads the password line one byte at a time (as sudo does) and refuses a
# wrong one; SUDO_NOPASSWD=1 reads nothing, as with a NOPASSWD grant. `chown` records its arguments
# instead of changing an owner (no root here); CHOWN_FAILS=1 makes it fail.
FAKEBIN="$TMPD/fakebin"; mkdir -p "$FAKEBIN"
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
cat > "$FAKEBIN/chown" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$CHOWNLOG"
[ "$CHOWN_FAILS" != 1 ]
EOF
chmod +x "$FAKEBIN/sudo" "$FAKEBIN/chown"
SUDO_NOPASSWD=0; CHOWN_FAILS=0; GUEST_PW="$SECRET"

# The recording `ssh`: call N leaves its argv in $LOG/N.argv and its stdin in $LOG/N.stdin, then
# runs the remote command under /bin/sh with that stdin, the guest's home as HOME and cwd, and the
# stand-ins on PATH. The one mapping on the way: the root script's absolute chown points at the
# stand-in. The test payloads below never contain that path, so the payload passes through as sent.
LOG="$TMPD/ssh"; mkdir -p "$LOG"
CHOWNLOG="$TMPD/chown-calls"
ssh() {
    local n; n=$(( $(find "$LOG" -name '*.argv' | wc -l) + 1 ))
    printf '%s\n' "$@" > "$LOG/$n.argv"
    cat > "$LOG/$n.stdin"
    local cmd="${!#}"
    sed "s#/usr/sbin/chown root:wheel#$FAKEBIN/chown root:wheel#" "$LOG/$n.stdin" \
        | ( cd "$GUEST_HOME" && HOME="$GUEST_HOME" PATH="$FAKEBIN:$PATH" SUDO_WANT="$GUEST_PW" \
              SUDO_NOPASSWD="$SUDO_NOPASSWD" CHOWNLOG="$CHOWNLOG" CHOWN_FAILS="$CHOWN_FAILS" \
              /bin/sh -c "$cmd" )
}
reset() { rm -rf "$LOG"/* "$CHOWNLOG" "$TMPD/guest"; mkdir -p "$LOG"; }
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
    hasnt "$out" "Could not install" "$name: no failure warning"
    eq "1" "$(n_calls)" "$name: one ssh connection"
    if [[ -f "$DST" ]] && cmp -s "$pf" "$DST"; then ok "$name: the payload arrived byte-exact"
    else fail "$name: the installed file differs from the payload" \
              "want [$(od -c "$pf" | head -n5)] got [$(od -c "$DST" 2>/dev/null | head -n5)]"; fi
    eq "644" "$(file_mode "$DST" 2>/dev/null)" "$name: mode 644"
    eq "$(basename "$DST")" "$(ls -A "$DSTDIR" 2>/dev/null)" "$name: the target directory holds only the target (no temp left)"
    eq "" "$(ls -A "$GUEST_HOME")" "$name: nothing is staged in the guest user's home"
    local c; c="$(cat "$CHOWNLOG" 2>/dev/null)"
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

section "Tier 1 — the real payload"
P="$TMPD/payload"
agent_managed_settings_json > "$P"         # augur's own definition, before install_with replaces it
reset; install_with "$P"
check_install "real payload" "$P"
eq "$SECRET" "$(head -n1 "$LOG/1.stdin")" "real payload: the admin password is the first line of ssh's stdin"
eq "$MACOS_ROOT_SCRIPT_BEGIN" "$(sed -n 2p "$LOG/1.stdin")" "real payload: the root script's marker follows it"

section "Tier 1 — a hostile payload"
H="$TMPD/hostile"
{
    printf '%s\n' "{\"a\":'single' \"double\" \$HOME \${HOME} \$(id) \`id\` \\\\ \\n \\\$ \\"
    printf '%s\n' "$MACOS_ROOT_SCRIPT_BEGIN"
    printf '%s\n' "AUGUR_MANAGED_SETTINGS_EOF" "AUGUR_MANAGED_SETTINGS_EOF_"
    printf '%s\n' "'AUGUR_MANAGED_SETTINGS_EOF'" "  AUGUR_MANAGED_SETTINGS_EOF"
    printf '%s\n' "exit 0" "\"}"
    printf 'no trailing newline: end'
} > "$H"
reset; install_with "$H"
check_install "hostile payload" "$H"
for nl in 1 3; do
    T="$TMPD/trailing-$nl"; { cat "$H"; for (( i = 0; i < nl; i++ )); do printf '\n'; done; } > "$T"
    reset; install_with "$T"
    check_install "hostile payload + $nl trailing newline(s)" "$T"
done
# A payload that is only the delimiter, with no newline.
D="$TMPD/delim-only"; printf 'AUGUR_MANAGED_SETTINGS_EOF' > "$D"
reset; install_with "$D"
check_install "the delimiter alone" "$D"

section "Tier 1 — NOPASSWD sudo (the build's grant): the password line is discarded, never run"
SUDO_NOPASSWD=1; reset; install_with "$H"; SUDO_NOPASSWD=0
check_install "NOPASSWD" "$H"

section "Tier 1 — an existing target is replaced by rename"
reset; mkdir -p "$DSTDIR"; printf 'old\n' > "$DST"
install_with "$P"
check_install "replace" "$P"

section "Tier 1 — failures warn, continue, and leave the target as it was"
GUEST_PW="some-other-password"
reset; mkdir -p "$DSTDIR"; printf 'old\n' > "$DST"
install_with "$P"
GUEST_PW="$SECRET"
eq "0" "$rc" "wrong password: still returns 0 (best effort)"
has "$out" "Could not install the managed" "wrong password: the warning is shown"
has "$out" "Sorry, try again." "wrong password: sudo's own message is shown"
hasnt "$out" "$SECRET" "wrong password: the admin password is not in the output"
eq "old" "$(cat "$DST")" "wrong password: the existing target is untouched"
eq "$(basename "$DST")" "$(ls -A "$DSTDIR")" "wrong password: no temp file left"
eq "" "$(ls -A "$GUEST_HOME")" "wrong password: nothing staged in the guest user's home"

CHOWN_FAILS=1
reset; mkdir -p "$DSTDIR"; printf 'old\n' > "$DST"
install_with "$H"
CHOWN_FAILS=0
eq "0" "$rc" "failed chown: still returns 0 (best effort)"
has "$out" "Could not install the managed" "failed chown: the warning is shown"
eq "old" "$(cat "$DST")" "failed chown: the existing target is untouched"
eq "$(basename "$DST")" "$(ls -A "$DSTDIR")" "failed chown: the temp file is removed"

E="$TMPD/empty"; : > "$E"
reset; install_with "$E"
eq "0" "$rc" "empty payload: returns 0"
eq "0" "$(n_calls)" "empty payload: nothing is sent to the guest"
has "$out" "is empty; not installing it" "empty payload: says so"

finish
