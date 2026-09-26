#!/usr/bin/env bash
# Tier 1 — the macOS guest's admin password reaches `sudo -S` on ssh's STDIN, never on an argv
# (runs anywhere; nothing is cloned, booted or SSH'd — `ssh` itself is a recording stub).
#
# Every privileged command augur runs in a macOS guest is `sudo -S -p '' <cmd>` over SSH, fed the
# admin password (macos_admin_password). Embedding it in the remote command string would put it on
# the host's `ssh` command line (readable by any local `ps`) and on the guest's process list. This
# file pins, through the REAL ssh_macos / ssh_macos_provision* wrappers and the REAL callers:
#   • the password is on no `ssh` argv, and arrives as the first line of ssh's stdin;
#   • the stdin-forwarding wrappers really forward (no `-n`), and ssh_macos_provision keeps `-n`
#     (its manifest loop depends on it);
#   • a source guard: every `sudo -S` in augur is fed by macos_admin_password_stdin, and the
#     password is never interpolated into anything but the askpass helper file.
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/lib.sh"
AUGUR="$REPO/augur"

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT
# The recording `ssh` below reads its stdin like real ssh. Detach this script's own stdin so a caller
# that pipes nothing in (the very regression under test) reads EOF instead of blocking on a TTY.
exec </dev/null

# Boot-proofing, as in tests/38: the resolved $VM_CLI can never be a real augur-vm.
export AUGUR_VM_BIN="$TMPD/no-such-augur-vm"
AUGUR_SOURCE_ONLY=1 source "$AUGUR"
set +e                                    # augur enables `set -e`; restore lib.sh assert-and-continue

HOME="$TMPD/home"; mkdir -p "$HOME"
# shellcheck disable=SC2034  # read by the sourced augur functions
AUGUR_DIR="$TMPD/augur"
unset ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN

SECRET='pW9+tEsT/sEcReT=='                # base64-alphabet, like cmd_build_macos's generator
MACOS_ADMIN_PASSWORD_FILE="$TMPD/macos-admin-password"
printf '%s\n' "$SECRET" > "$MACOS_ADMIN_PASSWORD_FILE"
# shellcheck disable=SC2034  # read by the sourced ssh wrappers: no key, so no -i/BatchMode opts
MACOS_SSH_KEY="$TMPD/no-such-key"

macos_ssh_host()      { echo "127.0.0.1"; }
macos_ssh_port()      { echo "22"; }
vm_known_hosts_file() { echo "$TMPD/known_hosts"; }

# ── The recording `ssh`. Call N leaves its argv (one arg per line) in $LOG/N.argv and its stdin in
#    $LOG/N.stdin. It honours `-n` the way real ssh does (stdin not read), and plays a guest `sudo -S`
#    that reads ONE line from stdin and checks it, so a password that never arrives there fails the
#    command the way a live guest would ("Sorry, try again."). ─────────────────────────────────────
LOG="$TMPD/ssh"; mkdir -p "$LOG"
GUEST_PW="$SECRET"                         # what the guest's sudo accepts
ssh() {
    local n; n=$(( $(find "$LOG" -name '*.argv' | wc -l) + 1 ))
    printf '%s\n' "$@" > "$LOG/$n.argv"
    local a no_stdin=0
    for a in "$@"; do [[ "$a" == "-n" ]] && no_stdin=1; done
    if (( no_stdin )); then : > "$LOG/$n.stdin"; else cat > "$LOG/$n.stdin"; fi
    local cmd="${!#}"
    case "$cmd" in
        *"sudo -S -p ''"*)
            if [[ "$(head -n1 "$LOG/$n.stdin")" == "$GUEST_PW" ]]; then
                [[ "$cmd" == *"/bin/date -u"* ]] && : > "$TMPD/clock-set"
                [[ "$cmd" == *"-settimezone"*  ]] && : > "$TMPD/tz-set"
                return 0
            fi
            echo "Sorry, try again." >&2; return 1 ;;
    esac
    return 0
}
reset_log() { rm -f "$LOG"/* "$TMPD/clock-set" "$TMPD/tz-set"; }
n_calls()   { find "$LOG" -name '*.argv' | wc -l | tr -d ' '; }
# The one recorded call whose remote command runs `sudo -S` (its number), or empty.
sudo_call() { grep -l "sudo -S -p ''" "$LOG"/*.argv 2>/dev/null | head -n1 | sed 's#.*/##; s#\.argv$##'; }

# check_site NAME — the recorded `sudo -S` call carried the password on stdin and on no argv.
check_site() {
    local name="$1" n
    n="$(sudo_call)"
    if [[ -z "$n" ]]; then fail "$name: no \`sudo -S\` call was recorded" "control: nothing below would be tested"; return; fi
    ok "$name: the \`sudo -S\` call reached ssh (control)"
    if grep -rqF -- "$SECRET" "$LOG"/*.argv; then
        fail "$name: the admin password is on an ssh argv" "$(grep -rlF -- "$SECRET" "$LOG"/*.argv)"
    else
        ok "$name: the admin password is on no ssh argv"
    fi
    eq "$SECRET" "$(head -n1 "$LOG/$n.stdin")" "$name: the admin password is the first line of ssh's stdin"
    hasnt "$(cat "$LOG/$n.argv")" "echo '" "$name: the remote command does not echo a password into sudo"
}

section "Tier 1 — sync_macos_guest_clock"
_macos_guest_epoch() { if [[ -f "$TMPD/clock-set" ]]; then date +%s; else echo $(( $(date +%s) - 5733 )); fi; }
reset_log
out="$( set -e; sync_macos_guest_clock testvm 2>&1 )"
has "$out" "Guest clock synchronised with the host" "clock: the set succeeded against a sudo that reads stdin"
check_site "clock"

# A stale password still surfaces as a rejected sudo password (warn_if_stale_admin_password).
GUEST_PW="some-other-password"; reset_log
out="$( set -e; sync_macos_guest_clock testvm 2>&1 )"; rc=$?
GUEST_PW="$SECRET"
eq "0" "$rc" "clock, wrong password: still best-effort (rc 0)"
has "$out" "Sorry, try again." "clock, wrong password: sudo's diagnostic is still captured"
has "$out" "augur destroy && augur up --macos" "clock, wrong password: the stale-password hint still fires"

section "Tier 1 — sync_macos_guest_timezone"
host_timezone()         { printf 'Asia/Tokyo'; }
_macos_guest_timezone() { if [[ -f "$TMPD/tz-set" ]]; then printf 'Asia/Tokyo'; else printf 'UTC'; fi; }
reset_log
out="$( set -e; sync_macos_guest_timezone testvm 2>&1 )"
has "$out" "Guest timezone synchronised with the host" "timezone: the set succeeded against a sudo that reads stdin"
check_site "timezone"

GUEST_PW="some-other-password"; reset_log
out="$( set -e; sync_macos_guest_timezone testvm 2>&1 )"
GUEST_PW="$SECRET"
has "$out" "augur destroy && augur up --macos" "timezone, wrong password: the stale-password hint still fires"

section "Tier 1 — install_macos_managed_settings"
reset_log
out="$( set -e; install_macos_managed_settings testvm 2>&1 )"
hasnt "$out" "Could not install" "managed policy: the install succeeded against a sudo that reads stdin"
eq "2" "$(n_calls)" "managed policy: stage + privileged move (two calls)"
has "$(cat "$LOG/1.stdin")" "DISABLE_AUTOUPDATER" "managed policy: the JSON still travels on the staging call's stdin"
check_site "managed policy"

section "Tier 1 — select_macos_full_xcode"
reset_log
select_macos_full_xcode testvm >/dev/null 2>&1; rc=$?
eq "0" "$rc" "xcode-select: succeeded against a sudo that reads stdin"
has "$(cat "$LOG/1.argv")" "xcode-select -s '/Applications/Xcode.app/Contents/Developer'" \
    "xcode-select: selects the full Xcode install, not the Command Line Tools"
check_site "xcode-select"
GUEST_PW="some-other-password"; reset_log
select_macos_full_xcode testvm >/dev/null 2>&1; rc=$?
GUEST_PW="$SECRET"
if [[ "$rc" -ne 0 ]]; then ok "xcode-select, wrong password: reports failure to the caller"
else fail "xcode-select, wrong password: returned 0" "build would save a base VM with the CLT selected"; fi

section "Tier 1 — the provisioning wrappers"
reset_log
macos_admin_password_stdin | ssh_macos_provision_stdin testvm "sudo -S -p '' true"
check_site "provision grant wrapper"
if grep -qx -- '-n' "$LOG/1.argv"; then fail "ssh_macos_provision_stdin passes -n (stdin would be dropped)"
else ok "ssh_macos_provision_stdin does not pass -n"; fi
reset_log
ssh_macos_provision testvm "true" </dev/null
if grep -qx -- '-n' "$LOG/1.argv"; then ok "ssh_macos_provision still passes -n (the manifest loop's stdin is safe)"
else fail "ssh_macos_provision lost -n" "every remote command would drain run_provision_manifest's loop input"; fi

section "Tier 0 — source guard over augur"
code="$(grep -vE '^[[:space:]]*#' "$AUGUR")"
hasnt "$code" "echo '\$(macos_admin_password)'" "no remote command echoes the admin password into sudo"
# Every line interpolating the password, minus the two sanctioned ones: the stdin helper itself and
# ssh_macos_bootstrap's askpass file (written by printf %q into a 0700 temp file, not an argv).
_interp="$(printf '%s\n' "$code" | grep -F '$(macos_admin_password)' \
    | grep -vF "macos_admin_password_stdin() { printf '%s\n' \"\$(macos_admin_password)\"; }" \
    | grep -vxF '        "$(macos_admin_password)" > "$askpass"')"
eq "" "$_interp" "the admin password is interpolated nowhere else"
# Every `sudo -S` code line is fed by the helper, on the same line or the line before it.
_bad=""; _prev=""
while IFS= read -r _line; do
    if [[ "$_line" == *"sudo -S"* && "$_line$_prev" != *"macos_admin_password_stdin | ssh_macos"* ]]; then
        _bad+="$_line"$'\n'
    fi
    _prev="$_line"
done <<< "$code"
eq "" "$_bad" "every \`sudo -S\` is fed by macos_admin_password_stdin piped into an ssh_macos* wrapper"
hasnt "$code" 'macos_admin_password_stdin | ssh_macos_provision "' \
    "the password is never piped into ssh_macos_provision (its -n would drop it; use ssh_macos_provision_stdin)"
_sites="$(printf '%s\n' "$code" | grep -c 'macos_admin_password_stdin | ssh_macos')"
eq "6" "$_sites" "six sudo -S call sites use the helper (build, provisioning, managed policy, xcode-select, clock, timezone)"

finish
