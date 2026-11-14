#!/usr/bin/env bash
# Tier 1 — custom provisioning's hook.sh runs as root in the macOS guest without ever sitting in a
# file the guest user can write (runs anywhere; nothing is cloned, booted or SSH'd — the "guest" is
# a local shell in a user+mount namespace against a sandboxed home and /var, and its root is a
# stand-in `sudo`).
#
# A copy of the hook in a user-writable file, run by root in a second connection, could be swapped
# by any guest-user process in between, which would get root in the base VM every project VM is
# cloned from. Pinned here, through the REAL run_provision_hook, macos_run_root_script and
# ssh_macos_provision_stdin:
#   • one ssh connection, no scp, nothing written by the guest user: the hook travels inside the
#     root script on that connection's stdin, after the password line and the marker;
#   • the remote command starts at /usr/bin/sudo (no Homebrew code runs first); the root script's
#     tools are absolute (a bash, base64, mktemp, rm or sudo planted early on the guest user's PATH
#     never runs for root), its traps and system PATH are set before its directory exists; the
#     provisioning sudoers grant runs /usr/bin/sudo and /bin/bash;
#   • root decodes it into a fresh mode-0700 directory under /var/root, runs it there with the first
#     `bash` on the hook's PATH (a Homebrew bash when there is one), and removes the directory
#     afterwards, also when the hook fails;
#   • the hook's exit status is the connection's, and a failing hook fails run_provision_hook;
#   • its stdin is /dev/null (it cannot read the rest of the root script), its cwd is the guest
#     user's home, and its stdout and stderr stream to the operator together, in order; what sudo,
#     the root shell or ssh print on stderr is shown afterwards through show_guest_lines, as
#     warnings on success and errors on failure, with no header over blank lines; its environment
#     has Homebrew's PATH (then only the absolute entries of the PATH sudo left) and variables;
#   • no SSH transport precheck consults the VM's own host/port (which the provisioning network
#     does not use), the admin password is checked before any transport is, and a VM with no stored
#     admin password gets no connection;
#   • the password is on no argv, in no output and not in the hook's environment, with or without
#     a NOPASSWD grant, and a wrong password runs nothing;
#   • a hostile hook body (quotes, `$`, backticks, the marker line, heredoc delimiters, CR, NUL and
#     high bytes) arrives byte-exact and runs as written.
# The guest's /bin/sh is `bash --posix` (macOS's /bin/sh is bash in sh mode). The root script's
# bytes on the connection's stdin pass through untouched; its absolute paths reach the guest's own
# tools through the mounts (see in_guest).
# Accepted trade-off: that is bash 5 and GNU tools, not macOS's bash 3.2 and BSD tools; the live
# check on a Mac covers those. Hosts without unprivileged namespaces and overlayfs (macOS itself)
# skip the tiers that run the script.
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
vm_known_hosts_file() { echo "$TMPD/known_hosts"; }
AUGUR_PROVISION_HOOK="$TMPD/provision/hook.sh"; mkdir -p "$TMPD/provision"

GUEST_HOME="$TMPD/guest-home"; mkdir -p "$GUEST_HOME"
GUEST_TMP="$TMPD/guest-tmp"; mkdir -p "$GUEST_TMP"   # the guest's TMPDIR: must stay empty
GUEST_VAR="$TMPD/var"; VARROOT="$GUEST_VAR/root"; mkdir -p "$VARROOT"; chmod 700 "$VARROOT"
EVID="$TMPD/evidence"; mkdir -p "$EVID"
FAKEBIN="$TMPD/fakebin"; PLANT="$TMPD/planted"; OVL="$TMPD/usr-bin-overlay"
mkdir -p "$FAKEBIN" "$PLANT" "$OVL"

# The real bash, copied out of /usr/bin, which the overlay below hides.
REALBASH="$TMPD/real-bash"; cp "$(readlink -f "$BASH")" "$REALBASH"
# The guest's /usr/bin/sudo, `sudo -S [-k] -p '' <cmd…>`: like sudo -S, reads the password line
# from stdin one byte at a time and refuses a wrong one; SUDO_NOPASSWD=1 reads nothing, as with a
# NOPASSWD grant. SUDO_WARN=1 prints a line on stderr before running the command, SUDO_WARN=blank
# only blank lines (empty or spaces). TEST_AS_ROOT=1 in the environment marks what runs "as root".
cat > "$OVL/sudo" <<EOF
#!$REALBASH
printf '%s\n' "\$@" > "\$EVID/sudo-argv"
[[ "\$1" == -S ]] || { echo "sudo stand-in: not -S" >&2; exit 1; }
while [[ "\${1:-}" == -* ]]; do case "\$1" in -p) shift 2 ;; *) echo "\$1" >> "\$EVID/sudo-flags"; shift ;; esac; done
if [[ "\${SUDO_NOPASSWD:-0}" != 1 ]]; then
    IFS= read -r pw
    [[ "\$pw" == "\$(cat "\$SUDO_WANT_FILE")" ]] || { echo "Sorry, try again." >&2; exit 1; }
fi
case "\${SUDO_WARN:-0}" in 1) echo "sudo: a warning from the guest" >&2 ;; blank) printf '\\n   \\n \\n' >&2 ;; esac
TEST_AS_ROOT=1 exec "\$@"
EOF
# Tools a guest-user process could plant early on that user's PATH: each logs its use and fails.
for t in bash base64 mktemp rm sudo; do
    printf '#!%s\necho %s >> "$EVID/planted"\nexit 1\n' "$REALBASH" "$t" > "$PLANT/$t"
done
# The hook's interpreters: the guest's /bin/bash and a Homebrew bash. Each records how the hook is
# run (and which of them ran it, in hook-interp), then runs it with the real bash.
write_recorder() {   # write_recorder FILE LABEL
    cat > "$1" <<EOF
#!$REALBASH
case "\${1:-}" in
    /var/root/augur-provision-hook.*/hook.sh)
        echo $2 > "\$EVID/hook-interp"
        printf '%s\n' "\$@" > "\$EVID/hook-argv"
        /usr/bin/cp "\$1" "\$EVID/hook-seen"
        /usr/bin/stat -c %a "\${1%/*}" > "\$EVID/hook-dirmode"
        [ /dev/stdin -ef /dev/null ] && echo devnull > "\$EVID/hook-stdin" || echo other > "\$EVID/hook-stdin"
        pwd > "\$EVID/hook-cwd"
        echo "\${TEST_AS_ROOT:-0}" > "\$EVID/hook-root"
        /usr/bin/env > "\$EVID/hook-env" ;;
esac
exec "$REALBASH" "\$@"
EOF
    chmod +x "$1"
}
OPTDIR="$TMPD/opt"; BREWBASH="$OPTDIR/homebrew/bin/bash"; mkdir -p "$OPTDIR/homebrew/bin" "$OPTDIR/homebrew/sbin"
write_recorder "$OVL/bash" system
write_recorder "$BREWBASH" homebrew
# The guest's /bin/sh: bash in POSIX mode, as macOS's /bin/sh is bash in sh mode.
SH_NAME="$(basename "$(readlink -f /bin/sh)")"
[[ "$SH_NAME" == bash ]] || printf '#!%s\nexec -a sh %s --posix "$@"\n' "$REALBASH" "$REALBASH" > "$OVL/$SH_NAME"
chmod +x "$PLANT"/* "$OVL"/*

# The guest: an unprivileged user + mount namespace (`unshare -rm`) where the test's directory is
# mounted over /var (so /var/root is the test's) and the overlay above over /usr/bin (which /bin
# links to), so the root script's absolute paths (/bin/sh, /bin/bash, /usr/bin/mktemp,
# /usr/bin/base64, /bin/rm) are the guest's own and its bytes are never rewritten.
GUEST_MOUNTS='mount --bind "$1" /var && mount --bind "$5" /opt && mount -t overlay overlay -o lowerdir="$2":/usr/bin /usr/bin && exec "$3" -c "$4"'
in_guest() { unshare -rm "$REALBASH" -c "$GUEST_MOUNTS" _ "$GUEST_VAR" "$OVL" "$REALBASH" "$1" "$OPTDIR"; }
CAN_RUN=0
if command -v unshare >/dev/null 2>&1 && [[ /bin -ef /usr/bin ]] && in_guest true </dev/null 2>/dev/null; then CAN_RUN=1; fi

# The recording `ssh`: call N leaves its argv in $LOG/N.argv, a copy of its stdin in $LOG/N.stdin
# (tee, so the bytes the guest gets are the bytes augur sent) and its exit status in $LOG/N.rc.
# Like real ssh it honours -n, and it runs the remote command in the guest user's home, with the
# planted tools first on PATH.
LOG="$TMPD/ssh"; mkdir -p "$LOG"
GUEST_PATH="$PLANT:$FAKEBIN:/usr/bin:/bin"   # the guest user's PATH, which sudo keeps
SUDO_NOPASSWD=0; SUDO_WARN=0; SUDO_WANT_FILE="$TMPD/sudo-want"; printf '%s' "$SECRET" > "$SUDO_WANT_FILE"
ssh() {
    local n a no_stdin=0 rc
    n=$(( $(find "$LOG" -name '*.argv' | wc -l) + 1 ))
    printf '%s\n' "$@" > "$LOG/$n.argv"
    for a in "$@"; do [[ "$a" == "-n" ]] && no_stdin=1; done
    local cmd="${!#}"
    run_guest() {
        ( cd "$GUEST_HOME" && exec env -i HOME="$GUEST_HOME" TMPDIR="$GUEST_TMP" PATH="$GUEST_PATH" EVID="$EVID" \
              SUDO_NOPASSWD="$SUDO_NOPASSWD" SUDO_WARN="$SUDO_WARN" SUDO_WANT_FILE="$SUDO_WANT_FILE" \
              unshare -rm "$REALBASH" -c "$GUEST_MOUNTS" _ "$GUEST_VAR" "$OVL" "$REALBASH" "$cmd" "$OPTDIR" )
    }
    if (( no_stdin )); then : > "$LOG/$n.stdin"; run_guest </dev/null; rc=$?
    else tee "$LOG/$n.stdin" | run_guest; rc=${PIPESTATUS[1]}; fi
    echo "$rc" > "$LOG/$n.rc"
    return "$rc"
}
scp() { printf '%s\n' "$@" > "$LOG/scp-called"; return 0; }

reset() { rm -rf "${LOG:?}"/* "${EVID:?}"/*; }
n_calls() { find "$LOG" -name '*.argv' | wc -l | tr -d ' '; }
left_in() { find "$1" -mindepth 1 2>/dev/null | head -n5; }
run_hook() {   # run_hook — sets $out / $rc
    reset
    out="$(run_provision_hook testvm 2>&1)"; rc=$?
}

guest_tiers() {
section "Tier 1 — a well-behaved hook"
cat > "$AUGUR_PROVISION_HOOK" <<'EOF'
#!/usr/bin/env bash
echo "hook-says-hi"
rest="$(cat)"
printf '%s' "$rest" > "$EVID/hook-read-stdin"
command -v mktemp > "$EVID/hook-which-mktemp"
touch "$EVID/hook-ran"
EOF
run_hook
eq "0" "$rc" "the hook succeeds"
[[ -f "$EVID/hook-ran" ]] && ok "the hook ran" || fail "the hook did not run"
has "$out" "hook-says-hi" "the hook's output reaches the operator"
eq "1" "$(n_calls)" "one ssh connection"
[[ -e "$LOG/scp-called" ]] && fail "scp was used to copy the hook" || ok "no scp"
if grep -qx -- '-n' "$LOG/1.argv"; then fail "the connection passes -n (the root script would be dropped)"
else ok "the connection forwards stdin (no -n)"; fi
has "$(cat "$LOG/1.argv")" "-p
${AUGUR_SSH_FWD_PORT_PROVISION}" "it goes over the provisioning network's SSH port"
_remote="$(tail -n1 "$LOG/1.argv")"
eq "/usr/bin/sudo -S -k -p '' /bin/sh -c " "${_remote:0:37}" "the remote command starts with the root-script sudo: no Homebrew prefix"
hasnt "$_remote" "brew" "no brew runs before sudo on that connection"
hasnt "$(cat "$LOG/1.argv")" "cat >" "nothing is written to a file before sudo runs"
hasnt "$(tail -n1 "$LOG/1.argv")" "/tmp" "no /tmp path on the remote command"
hasnt "$(cat "$LOG/1.argv")" "$SECRET" "the password is on no ssh argv"
hasnt "$(cat "$EVID/sudo-argv")" "$SECRET" "the password is on no sudo argv"
eq "$SECRET" "$(head -n1 "$LOG/1.stdin")" "the password is the first line of the connection's stdin"
eq "$MACOS_ROOT_SCRIPT_BEGIN" "$(sed -n 2p "$LOG/1.stdin")" "the marker follows it"
b64="$(base64 < "$AUGUR_PROVISION_HOOK" | tr -d '\n')"
hasnt "$(cat "$LOG/1.argv")" "$b64" "the hook is not on the ssh argv"
has "$(cat "$LOG/1.stdin")" "$b64" "the hook travels base64-encoded on the connection's stdin"
eq "1" "$(cat "$EVID/hook-root")" "the hook runs as root"
hook_path="$(head -n1 "$EVID/hook-argv")"
eq "1" "$(wc -l < "$EVID/hook-argv" | tr -d ' ')" "bash gets just the hook's path"
case "$hook_path" in
    /var/root/augur-provision-hook.??????/hook.sh) ok "the hook runs from a fresh directory under /var/root" ;;
    *) fail "the hook runs from somewhere else" "$hook_path" ;;
esac
eq "700" "$(cat "$EVID/hook-dirmode")" "the directory is mode 0700 while the hook runs"
eq "" "$(left_in "$VARROOT")" "the directory is removed afterwards"
eq "" "$(left_in "$GUEST_HOME")" "nothing lands in the guest user's home"
eq "" "$(left_in "$GUEST_TMP")" "nothing lands in the guest's TMPDIR"
eq "devnull" "$(cat "$EVID/hook-stdin")" "the hook's stdin is /dev/null"
eq "" "$(cat "$EVID/hook-read-stdin")" "the hook reads nothing from stdin (not the root script's rest)"
eq "$GUEST_HOME" "$(cat "$EVID/hook-cwd")" "the hook's cwd is the guest user's home"
eq "" "$(cat "$EVID/planted" 2>/dev/null)" "no tool planted early on the guest user's PATH runs (bash, base64, mktemp, rm)"
eq "$PLANT/mktemp" "$(cat "$EVID/hook-which-mktemp")" "control: the planted tools are on the PATH the hook inherits"
eq "PATH=/opt/homebrew/bin:/opt/homebrew/sbin:$PLANT:$FAKEBIN:/usr/bin:/bin" "$(grep '^PATH=' "$EVID/hook-env")" "the hook's PATH has Homebrew first, then the PATH sudo left"
for _v in HOMEBREW_PREFIX=/opt/homebrew HOMEBREW_CELLAR=/opt/homebrew/Cellar HOMEBREW_REPOSITORY=/opt/homebrew INFOPATH=/opt/homebrew/share/info:; do
    grep -qxF "$_v" "$EVID/hook-env" && ok "the hook's environment has $_v" || fail "the hook's environment lacks $_v"
done
grep -qF -- "$SECRET" "$EVID/hook-env" && fail "the password is not in the hook's environment" || ok "the password is not in the hook's environment"
hasnt "$out" "$SECRET" "the password is not in the output"
cmp -s "$AUGUR_PROVISION_HOOK" "$EVID/hook-seen" && ok "the hook runs byte-exact" || fail "the hook arrived altered"

section "Tier 1 — a failing hook"
printf '#!/usr/bin/env bash\necho hook-fails >&2\nexit 7\n' > "$AUGUR_PROVISION_HOOK"
run_hook
if [[ "$rc" -ne 0 ]]; then ok "run_provision_hook fails"; else fail "run_provision_hook returned 0 for a failing hook"; fi
eq "7" "$(cat "$LOG/1.rc")" "the hook's exit status is the connection's"
has "$out" "hook-fails" "its stderr reaches the operator"
[[ -f "$EVID/hook-seen" ]] && ok "it ran (control)" || fail "it never ran (control)"
eq "" "$(left_in "$VARROOT")" "the directory is removed after a failing hook too"
printf '#!/usr/bin/env bash\nexit 0\n' > "$AUGUR_PROVISION_HOOK"
run_hook
eq "0" "$(cat "$LOG/1.rc")" "a hook exiting 0 gives status 0 (control)"
# A root shell ended by SIGTERM while the hook runs still removes the directory.
printf '#!/usr/bin/env bash\nkill -TERM "$PPID"\nexit 0\n' > "$AUGUR_PROVISION_HOOK"
run_hook
eq "143" "$(cat "$LOG/1.rc")" "SIGTERM to the root shell: it exits 143"
if [[ "$rc" -ne 0 ]]; then ok "SIGTERM to the root shell: run_provision_hook fails"; else fail "SIGTERM to the root shell: returned 0"; fi
eq "" "$(left_in "$VARROOT")" "SIGTERM to the root shell: the directory is removed"

section "Tier 1 — a hostile hook body"
{
    cat <<'HOSTILE_END'
#!/usr/bin/env bash
: <<'Z'
'
"
`
$
\
SCRIPT
EOF
#augur-root-script
touch "$EVID/pwned"
SCRIPT
EOF
Z
x='it'"'"'s'; y="$HOME `printf bt` $(printf cs) \$x"
printf '%s|%s' "$x" "$y" > "$EVID/hostile-vars"
touch "$EVID/hostile-ran"
exit 0
HOSTILE_END
    printf '%s\n' "$MACOS_ROOT_SCRIPT_BEGIN"
    printf 'trailing bytes \r\t\001\002\033\177\200\376\377 and a NUL:\000 end'
} > "$AUGUR_PROVISION_HOOK"
grep -qx "$MACOS_ROOT_SCRIPT_BEGIN" "$AUGUR_PROVISION_HOOK" && ok "control: the body holds a line equal to the marker" \
    || fail "control: the body lacks the marker line"
run_hook
eq "0" "$rc" "the hostile hook succeeds"
cmp -s "$AUGUR_PROVISION_HOOK" "$EVID/hook-seen" && ok "it arrives byte-exact (NUL and high bytes included)" \
    || fail "it arrived altered"
[[ -f "$EVID/hostile-ran" ]] && ok "it runs to its end" || fail "it did not run to its end"
eq "it's|$GUEST_HOME bt cs \$x" "$(cat "$EVID/hostile-vars")" "its quoting and expansions behave as written"
[[ -e "$EVID/pwned" ]] && fail "a line of its heredoc ran as a command" || ok "no line of it runs outside the hook's own parse"
eq "1" "$(cat "$EVID/hook-root")" "it runs as root"
eq "" "$(left_in "$VARROOT")" "its directory is removed"

section "Tier 1 — NOPASSWD sudo and a wrong password"
printf '#!/usr/bin/env bash\ntouch "$EVID/hook-ran"\n' > "$AUGUR_PROVISION_HOOK"
SUDO_NOPASSWD=1; run_hook; SUDO_NOPASSWD=0
eq "0" "$rc" "NOPASSWD: the hook succeeds"
[[ -f "$EVID/hook-ran" ]] && ok "NOPASSWD: the hook ran" || fail "NOPASSWD: the hook did not run"
hasnt "$out" "$SECRET" "NOPASSWD: the unread password line is not printed (never run as a command)"
grep -qF -- "$SECRET" "$EVID/hook-env" && fail "NOPASSWD: the password is not in the hook's environment" || ok "NOPASSWD: the password is not in the hook's environment"
eq "" "$(left_in "$VARROOT")" "NOPASSWD: the directory is removed"
printf not-the-password > "$SUDO_WANT_FILE"; run_hook; printf '%s' "$SECRET" > "$SUDO_WANT_FILE"
if [[ "$rc" -ne 0 ]]; then ok "a wrong password: run_provision_hook fails"; else fail "a wrong password: returned 0"; fi
[[ -e "$EVID/hook-ran" || -e "$EVID/hook-argv" || -n "$(left_in "$VARROOT")" ]] && fail "a wrong password: part of the root script ran" \
    || ok "a wrong password: nothing of the root script runs"
hasnt "$out" "$SECRET" "a wrong password: the password is not printed"

section "Tier 1 — no hook, and the wrapper guard"
rm -f "$AUGUR_PROVISION_HOOK"; run_hook
eq "0" "$rc" "no hook.sh: nothing to do"
eq "0" "$(n_calls)" "no hook.sh: no connection"
reset
macos_run_root_script testvm 'true' ssh_macos_provision >/dev/null 2>&1; rc=$?
if [[ "$rc" -ne 0 ]]; then ok "macos_run_root_script refuses a wrapper that drops stdin"; else fail "macos_run_root_script took ssh_macos_provision"; fi
eq "0" "$(n_calls)" "…without connecting"

section "Tier 1 — the hook's output, and the root shell's own errors"
printf '#!/usr/bin/env bash\necho out-1\necho err-1 >&2\necho out-2\n' > "$AUGUR_PROVISION_HOOK"
reset; out="$(run_provision_hook testvm 2>/dev/null)"; rc=$?
eq "0" "$rc" "a hook writing to both streams succeeds"
has "$out" $'out-1\nerr-1\nout-2' "its stderr streams to the operator with its stdout, in order (not held back in MACOS_ROOT_SCRIPT_ERR)"
SUDO_WARN=1; reset; out="$(run_provision_hook testvm 2>"$TMPD/stderr")"; rc=$?; SUDO_WARN=0
eq "0" "$rc" "a root shell that writes to stderr but succeeds: the hook succeeds"
has "$out" "reported:" "…its stderr is announced"
has "$out" "  | sudo: a warning from the guest" "…and shown through show_guest_lines as warnings (stdout)"
hasnt "$(cat "$TMPD/stderr")" "sudo: a warning" "…not as error lines (stderr)"
printf not-the-password > "$SUDO_WANT_FILE"; reset; out="$(run_provision_hook testvm 2>"$TMPD/stderr")"; rc=$?
printf '%s' "$SECRET" > "$SUDO_WANT_FILE"
has "$(cat "$TMPD/stderr")" "did not complete (exit 1)" "a wrong password: says the hook did not complete, as an error"
has "$(cat "$TMPD/stderr")" "  | Sorry, try again." "a wrong password: sudo's message is shown as error lines"
hasnt "$out" "Sorry" "a wrong password: …not as warnings"
printf '#!/usr/bin/env bash\ntouch "$EVID/hook-ran"\n' > "$AUGUR_PROVISION_HOOK"
run_hook
hasnt "$out" "  | " "a clean run shows no guest line"
hasnt "$out" "reported:" "a clean run prints no root-shell report"
hasnt "$out" "did not complete" "a clean run prints no failure"

section "Tier 1 — no SSH transport precheck for the provisioning network"
# The VM's own host/port (ssh_macos's transport) does not resolve on the provisioning network.
_real_transport="$(declare -f macos_ssh_build)"
macos_ssh_build() { echo called >> "$TMPD/transport-calls"; return 1; }
rm -f "$TMPD/transport-calls"; run_hook
eq "0" "$rc" "the hook runs although the VM's own SSH host/port does not resolve"
[[ -f "$EVID/hook-ran" ]] && ok "…it ran" || fail "…it did not run"
[[ -e "$TMPD/transport-calls" ]] && fail "…the precheck consulted ssh_macos's transport" || ok "…the precheck never consults ssh_macos's transport"
reset; macos_run_root_script testvm 'true' >/dev/null 2>&1; rc=$?
if [[ "$rc" -ne 0 && -e "$TMPD/transport-calls" ]]; then ok "control: the default wrapper's precheck does consult it and refuses"
else fail "control: the default wrapper ignored its transport check" "rc=$rc"; fi
eq "0" "$(n_calls)" "control: …without connecting"
eval "$_real_transport"
mv "$(macos_admin_password_file testvm)" "$TMPD/pw.saved"; run_hook; mv "$TMPD/pw.saved" "$(macos_admin_password_file testvm)"
if [[ "$rc" -ne 0 ]]; then ok "no stored admin password: run_provision_hook fails"; else fail "no stored admin password: returned 0"; fi
has "$out" "has no stored admin password" "no stored admin password: says so"
eq "0" "$(n_calls)" "no stored admin password: nothing connects"
run_hook
eq "0" "$rc" "the hook runs again once the password is back (control)"

section "Tier 1 — the hook's interpreter and PATH"
printf '#!/usr/bin/env bash\ntouch "$EVID/hook-ran"\n' > "$AUGUR_PROVISION_HOOK"
run_hook
eq "homebrew" "$(cat "$EVID/hook-interp")" "a Homebrew bash on the hook's PATH runs the hook"
mv "$BREWBASH" "$TMPD/brewbash.saved"; mv "$PLANT/bash" "$TMPD/plantbash.saved"; run_hook
eq "system" "$(cat "$EVID/hook-interp")" "control: without one (and without the planted bash), the system bash runs it"
mv "$TMPD/brewbash.saved" "$BREWBASH"; mv "$TMPD/plantbash.saved" "$PLANT/bash"
_gp_saved="$GUEST_PATH"; GUEST_PATH=":$PLANT::.:rel/dir:./x:$FAKEBIN:/usr/bin:/bin:"; run_hook; GUEST_PATH="$_gp_saved"
eq "0" "$rc" "an inherited PATH with empty, '.' and relative entries: the hook succeeds"
eq "PATH=/opt/homebrew/bin:/opt/homebrew/sbin:$PLANT:$FAKEBIN:/usr/bin:/bin" "$(grep '^PATH=' "$EVID/hook-env")" \
    "…and its PATH keeps only the absolute entries"

section "Tier 1 — a root-shell report of only empty lines"
SUDO_WARN=blank; run_hook; SUDO_WARN=0
eq "0" "$rc" "the hook succeeds"
hasnt "$out" "reported:" "no header is printed over nothing"

section "Tier 1 — the password is checked before the SSH transport"
macos_ssh_build() { echo called >> "$TMPD/transport-calls"; return 0; }
rm -f "$TMPD/transport-calls"
mv "$(macos_admin_password_file testvm)" "$TMPD/pw.saved"; reset
out="$(macos_run_root_script testvm 'true' 2>&1)"; rc=$?
mv "$TMPD/pw.saved" "$(macos_admin_password_file testvm)"
if [[ "$rc" -ne 0 ]]; then ok "no stored admin password: macos_run_root_script fails"; else fail "no stored admin password: returned 0"; fi
has "$out" "has no stored admin password" "…with the password error"
[[ -e "$TMPD/transport-calls" ]] && fail "…after probing the SSH transport" || ok "…before probing the SSH transport"
eval "$_real_transport"
}

if (( CAN_RUN )); then guest_tiers
else skip "the tiers that run the root script" "needs unprivileged user+mount namespaces, overlayfs and /bin linked to /usr/bin"; fi

section "Tier 0 — source guard"
code="$(declare -f run_provision_hook; declare -f macos_provision_hook_root_sh)"
hasnt "$code" "scp" "run_provision_hook copies nothing with scp"
hasnt "$code" "/tmp" "run_provision_hook names no /tmp path"
has "$code" "ssh_macos_provision_stdin" "run_provision_hook runs over the provisioning network's stdin wrapper"
has "$code" '</dev/null' "the hook's stdin is redirected from /dev/null"
eq "0" "$(grep -c 'scp_to_macos_provision' "$AUGUR")" "no scp helper for the provisioning network is left"
# The root script itself, as run_provision_hook builds it.
printf 'x' > "$AUGUR_PROVISION_HOOK"
_rs="$( macos_run_root_script() { printf '%s\n' "$2"; }; run_provision_hook testvm 2>/dev/null )"
_line_of() { printf '%s\n' "$_rs" | grep -n -m1 -e "$1" | cut -d: -f1; }
_mk="$(_line_of 'mktemp -d')"
for _t in "trap .* EXIT" "trap 'exit 129' HUP" "trap 'exit 143' TERM" "^PATH=/usr/bin:/bin:/usr/sbin:/sbin$"; do
    _n="$(_line_of "$_t")"
    if [[ -n "$_n" && -n "$_mk" && "$_n" -lt "$_mk" ]]; then ok "root script: '$_t' comes before mktemp -d"
    else fail "root script: '$_t' does not come before mktemp -d" "line [$_n] vs mktemp [$_mk]"; fi
done
has "$_rs" '[ -z "$d" ] || /bin/rm -rf "$d"' "root script: the cleanup runs only once the directory is set"
has "$_rs" "/usr/bin/mktemp -d /var/root/" "root script: mktemp is /usr/bin/mktemp"
has "$_rs" "| /usr/bin/base64 --decode >" "root script: base64 is /usr/bin/base64 --decode"
has "$_rs" '/usr/bin/env PATH="$hook_path" ' "root script: the hook is started by /usr/bin/env with the hook's PATH"
has "$_rs" $'\n    bash "$d/hook.sh" </dev/null 2>&1' "root script: …which looks up the hook's bash on that PATH"
_bare="$(printf '%s\n' "$_rs" | grep -vxF '    bash "$d/hook.sh" </dev/null 2>&1' | grep -nE '(^|[|;&]|\$\()[[:space:]]*(mktemp|base64|bash|rm|sudo|env)[[:space:]]')"
eq "" "$_bare" "root script: no other bare (PATH-resolved) mktemp, base64, bash, rm, sudo or env"
# Every sudo this change runs with the password on stdin is /usr/bin/sudo, and the grant's shell is /bin/bash.
eq "1" "$(grep -cF '| "$ssh_fn" "$vm" "/usr/bin/sudo -S -k -p '"''"' /bin/sh -c ' "$AUGUR")" "macos_run_root_script runs /usr/bin/sudo"
_grant="$(declare -f run_base_provisioning | grep -A3 'ssh_macos_provision_stdin "$vm"')"
has "$_grant" "\"/usr/bin/sudo -S -p '' /bin/bash -c" "the provisioning sudoers grant runs /usr/bin/sudo and /bin/bash"
has "$_grant" "/bin/chmod 440 /etc/sudoers.d/augur" "…and /bin/chmod"
# The provisioning wrapper the root script and the sudo grant use starts the remote command at sudo.
code="$(declare -f ssh_macos_provision_stdin) $(declare -f _ssh_macos_provision)"
_argv="$( ssh() { printf '%s\n' "${!#}"; }; ssh_macos_provision_stdin testvm "sudo -S true" )"
eq "sudo -S true" "$_argv" "ssh_macos_provision_stdin's remote command is exactly the caller's (no Homebrew prefix)"
_argv="$( ssh() { printf '%s\n' "${!#}"; }; ssh_macos_provision testvm "brew list" </dev/null )"
has "$_argv" 'eval "$(/opt/homebrew/bin/brew shellenv)"' "control: ssh_macos_provision keeps its Homebrew prefix"

finish
