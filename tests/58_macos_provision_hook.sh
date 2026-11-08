#!/usr/bin/env bash
# Tier 1 — custom provisioning's hook.sh runs as root in the macOS guest without ever sitting in a
# file the guest user can write (runs anywhere; nothing is cloned, booted or SSH'd — the "guest" is
# a local shell against a sandboxed home, and its root is a stand-in `sudo`).
#
# A copy of the hook in a user-writable file, run by root in a second connection, could be swapped
# by any guest-user process in between, which would get root in the base VM every project VM is
# cloned from. Pinned here, through the REAL run_provision_hook, macos_run_root_script and
# ssh_macos_provision_stdin:
#   • one ssh connection, no scp, nothing written by the guest user: the hook travels inside the
#     root script on that connection's stdin, after the password line and the marker;
#   • root decodes it into a fresh mode-0700 directory under /var/root, runs it with `bash` from
#     there, and removes the directory afterwards, also when the hook fails;
#   • the hook's exit status is the connection's, and a failing hook fails run_provision_hook;
#   • its stdin is /dev/null (it cannot read the rest of the root script), its cwd is the guest
#     user's home, and its stdout and stderr stream to the operator together, in order; what sudo,
#     the root shell or ssh print on stderr is shown afterwards through show_guest_lines;
#   • the precheck before connecting checks the provisioning transport (its fixed port), never the
#     VM's own host/port, and a VM with no stored admin password or no such port gets no connection;
#   • the password is on no argv, in no output and not in the hook's environment, with or without
#     a NOPASSWD grant, and a wrong password runs nothing;
#   • a hostile hook body (quotes, `$`, backticks, the marker line, heredoc delimiters, CR, NUL and
#     high bytes) arrives byte-exact and runs as written.
# The guest's /bin/sh is played by `bash --posix` (macOS's /bin/sh is bash in sh mode). Commands
# are intercepted through PATH and argv only; the bytes on the connection's stdin are passed
# through untouched.
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

REALBASH="$BASH"
REALMKTEMP="$(command -v mktemp)"
GUEST_HOME="$TMPD/guest-home"; mkdir -p "$GUEST_HOME"
GUEST_TMP="$TMPD/guest-tmp"; mkdir -p "$GUEST_TMP"   # the guest's TMPDIR: must stay empty
VARROOT="$TMPD/var-root"; mkdir -p "$VARROOT"; chmod 700 "$VARROOT"
EVID="$TMPD/evidence"; mkdir -p "$EVID"
GUESTBIN="$TMPD/guestbin"; mkdir -p "$GUESTBIN"

# The guest's /bin/sh: bash in POSIX mode. The `sudo` stand-in maps the absolute /bin/sh of the
# command it runs here (an argv rewrite; stdin is untouched).
cat > "$GUESTBIN/sh" <<EOF
#!$REALBASH
exec "$REALBASH" --posix "\$@"
EOF
# `sudo -S [-k] -p '' <cmd…>`: like sudo -S, reads the password line from stdin one byte at a time
# and refuses a wrong one; SUDO_NOPASSWD=1 reads nothing, as with a NOPASSWD grant. SUDO_WARN=1 prints
# a line on stderr before running the command. TEST_AS_ROOT=1 in the environment marks what runs
# "as root".
cat > "$GUESTBIN/sudo" <<EOF
#!$REALBASH
printf '%s\n' "\$@" > "\$EVID/sudo-argv"
[[ "\$1" == -S ]] || { echo "sudo stand-in: not -S" >&2; exit 1; }
while [[ "\${1:-}" == -* ]]; do case "\$1" in -p) shift 2 ;; *) echo "\$1" >> "\$EVID/sudo-flags"; shift ;; esac; done
if [[ "\${SUDO_NOPASSWD:-0}" != 1 ]]; then
    IFS= read -r pw
    [[ "\$pw" == "\$(cat "\$SUDO_WANT_FILE")" ]] || { echo "Sorry, try again." >&2; exit 1; }
fi
if [[ "\${SUDO_WARN:-0}" == 1 ]]; then echo "sudo: a warning from the guest" >&2
fi
args=(); for a in "\$@"; do args+=("\${a//\/bin\/sh/$GUESTBIN/sh}"); done
TEST_AS_ROOT=1 exec "\${args[@]}"
EOF
# `mktemp`: /var/root/ is the sandbox's VARROOT; every template is logged.
cat > "$GUESTBIN/mktemp" <<EOF
#!$REALBASH
printf '%s\n' "\$*" >> "\$EVID/mktemp-args"
args=(); for a in "\$@"; do args+=("\${a/#\/var\/root\//$VARROOT/}"); done
exec "$REALMKTEMP" "\${args[@]}"
EOF
# `bash`, as the root script invokes the hook: records how it is run, then runs it for real.
cat > "$GUESTBIN/bash" <<EOF
#!$REALBASH
printf '%s\n' "\$@" > "\$EVID/hook-argv"
cp "\$1" "\$EVID/hook-seen"
d="\$(dirname "\$1")"
{ stat -c %a "\$d" 2>/dev/null || stat -f %Lp "\$d"; } > "\$EVID/hook-dirmode"
[ /dev/stdin -ef /dev/null ] && echo devnull > "\$EVID/hook-stdin" || echo other > "\$EVID/hook-stdin"
pwd > "\$EVID/hook-cwd"
echo "\${TEST_AS_ROOT:-0}" > "\$EVID/hook-root"
env > "\$EVID/hook-env"
exec "$REALBASH" "\$@"
EOF
chmod +x "$GUESTBIN"/*

# The recording `ssh`: call N leaves its argv in $LOG/N.argv, a copy of its stdin in $LOG/N.stdin
# (tee, so the bytes the guest gets are the bytes augur sent) and its exit status in $LOG/N.rc.
# Like real ssh it honours -n, and it runs the remote command in the guest user's home.
LOG="$TMPD/ssh"; mkdir -p "$LOG"
SUDO_NOPASSWD=0; SUDO_WARN=0; SUDO_WANT_FILE="$TMPD/sudo-want"; printf '%s' "$SECRET" > "$SUDO_WANT_FILE"
ssh() {
    local n a no_stdin=0 rc
    n=$(( $(find "$LOG" -name '*.argv' | wc -l) + 1 ))
    printf '%s\n' "$@" > "$LOG/$n.argv"
    for a in "$@"; do [[ "$a" == "-n" ]] && no_stdin=1; done
    local cmd="${!#}"
    run_guest() {
        ( cd "$GUEST_HOME" && exec env -i HOME="$GUEST_HOME" TMPDIR="$GUEST_TMP" PATH="$GUESTBIN:$PATH" EVID="$EVID" \
              SUDO_NOPASSWD="$SUDO_NOPASSWD" SUDO_WARN="$SUDO_WARN" SUDO_WANT_FILE="$SUDO_WANT_FILE" "$REALBASH" -c "$cmd" )
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

section "Tier 1 — a well-behaved hook"
cat > "$AUGUR_PROVISION_HOOK" <<'EOF'
#!/usr/bin/env bash
echo "hook-says-hi"
rest="$(cat)"
printf '%s' "$rest" > "$EVID/hook-read-stdin"
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
has "$(tail -n1 "$LOG/1.argv")" "sudo -S -k -p '' /bin/sh -c " "the remote command is the root-script protocol"
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
eq "-d /var/root/augur-provision-hook.XXXXXX" "$(cat "$EVID/mktemp-args")" "root makes a fresh directory under /var/root"
hook_path="$(head -n1 "$EVID/hook-argv")"
eq "1" "$(wc -l < "$EVID/hook-argv" | tr -d ' ')" "bash gets just the hook's path"
case "$hook_path" in
    "$VARROOT"/augur-provision-hook.??????/hook.sh) ok "the hook runs from that directory" ;;
    *) fail "the hook runs from somewhere else" "$hook_path" ;;
esac
eq "700" "$(cat "$EVID/hook-dirmode")" "the directory is mode 0700 while the hook runs"
eq "" "$(left_in "$VARROOT")" "the directory is removed afterwards"
eq "" "$(left_in "$GUEST_HOME")" "nothing lands in the guest user's home"
eq "" "$(left_in "$GUEST_TMP")" "nothing lands in the guest's TMPDIR"
eq "devnull" "$(cat "$EVID/hook-stdin")" "the hook's stdin is /dev/null"
eq "" "$(cat "$EVID/hook-read-stdin")" "the hook reads nothing from stdin (not the root script's rest)"
eq "$GUEST_HOME" "$(cat "$EVID/hook-cwd")" "the hook's cwd is the guest user's home, as before"
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
[[ -e "$EVID/hook-ran" || -e "$EVID/mktemp-args" ]] && fail "a wrong password: part of the root script ran" \
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
SUDO_WARN=1; run_hook; SUDO_WARN=0
eq "0" "$rc" "a root shell that writes to stderr but succeeds: the hook succeeds"
has "$out" "reported:" "…its stderr is announced"
has "$out" "  | sudo: a warning from the guest" "…and shown through show_guest_lines"
printf not-the-password > "$SUDO_WANT_FILE"; run_hook; printf '%s' "$SECRET" > "$SUDO_WANT_FILE"
has "$out" "did not complete (exit 1)" "a wrong password: says the hook did not complete"
has "$out" "  | Sorry, try again." "a wrong password: sudo's message is shown through show_guest_lines"
printf '#!/usr/bin/env bash\ntouch "$EVID/hook-ran"\n' > "$AUGUR_PROVISION_HOOK"
run_hook
# The sandbox has no /opt/homebrew/bin/brew, so the provisioning wrapper's shellenv prefix prints
# one "No such file" line (a real base VM has Homebrew there); nothing else may be reported.
eq "" "$(printf '%s\n' "$out" | grep -F '  | ' | grep -vF '/opt/homebrew/bin/brew: No such file')" "a clean run shows no guest error line"
hasnt "$out" "did not complete" "a clean run prints no failure"

section "Tier 1 — the precheck uses the provisioning transport"
# The VM's own host/port (ssh_macos's transport) does not resolve on the provisioning network.
_real_transport="$(declare -f macos_ssh_transport_ok)"
macos_ssh_transport_ok() { echo called >> "$TMPD/transport-calls"; return 1; }
rm -f "$TMPD/transport-calls"; run_hook
eq "0" "$rc" "the hook runs although the VM's own SSH host/port does not resolve"
[[ -f "$EVID/hook-ran" ]] && ok "…it ran" || fail "…it did not run"
[[ -e "$TMPD/transport-calls" ]] && fail "…the precheck consulted ssh_macos's transport" || ok "…the precheck never consults ssh_macos's transport"
reset; macos_run_root_script testvm 'true' >/dev/null 2>&1; rc=$?
if [[ "$rc" -ne 0 && -e "$TMPD/transport-calls" ]]; then ok "control: the default wrapper's precheck does consult it and refuses"
else fail "control: the default wrapper ignored its transport check" "rc=$rc"; fi
eq "0" "$(n_calls)" "control: …without connecting"
eval "$_real_transport"
_port_saved="$AUGUR_SSH_FWD_PORT_PROVISION"; AUGUR_SSH_FWD_PORT_PROVISION=""; run_hook; AUGUR_SSH_FWD_PORT_PROVISION="$_port_saved"
if [[ "$rc" -ne 0 ]]; then ok "no provisioning SSH port: run_provision_hook fails"; else fail "no provisioning SSH port: returned 0"; fi
has "$out" "does not resolve" "no provisioning SSH port: says so"
eq "0" "$(n_calls)" "no provisioning SSH port: nothing connects"
mv "$(macos_admin_password_file testvm)" "$TMPD/pw.saved"; run_hook; mv "$TMPD/pw.saved" "$(macos_admin_password_file testvm)"
if [[ "$rc" -ne 0 ]]; then ok "no stored admin password: run_provision_hook fails"; else fail "no stored admin password: returned 0"; fi
has "$out" "has no stored admin password" "no stored admin password: says so"
eq "0" "$(n_calls)" "no stored admin password: nothing connects"
run_hook
eq "0" "$rc" "the hook runs again once both are back (control)"

section "Tier 0 — source guard"
code="$(declare -f run_provision_hook)"
hasnt "$code" "scp" "run_provision_hook copies nothing with scp"
hasnt "$code" "/tmp" "run_provision_hook names no /tmp path"
has "$code" "ssh_macos_provision_stdin" "run_provision_hook runs over the provisioning network's stdin wrapper"
has "$code" '</dev/null' "the hook's stdin is redirected from /dev/null"
eq "0" "$(grep -c 'scp_to_macos_provision' "$AUGUR")" "no scp helper for the provisioning network is left"

finish
