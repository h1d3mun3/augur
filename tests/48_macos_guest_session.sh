#!/usr/bin/env bash
# Tier 1 — macOS mode must keep the guest's console unlocked for a --gui window (runs anywhere;
# nothing is booted or SSH'd — ssh_macos is a recording stand-in).
#
# Auto-login does log the admin in, but macOS 27's "log in, then lock the screen" and the virtual
# display's sleep put a lock screen (which looks like a login screen) in front of it. The fix is a
# handful of guest settings sent in one privileged round-trip on the fresh-boot path. Pinned here:
#   • every setting that defeats a lock is in the command, fed the admin password via `sudo -S`;
#   • it is best-effort: a failure warns, names the consequence, and never aborts `up` (rc 0);
#   • cmd_up_macos calls it, after the clock correction.
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/lib.sh"
AUGUR="$REPO/augur"

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT
exec </dev/null
export AUGUR_VM_BIN="$TMPD/no-such-augur-vm"
AUGUR_SOURCE_ONLY=1 source "$AUGUR"
set +e
HOME="$TMPD/home"; mkdir -p "$HOME"

SSHLOG="$TMPD/sshlog"; : > "$SSHLOG"
G_RC=0; G_MSG=""
ssh_macos() {
    shift
    printf '%s\n' "$*" >> "$SSHLOG"
    cat > "$TMPD/sudo-stdin"
    if [[ "$G_RC" != 0 ]]; then echo "$G_MSG" >&2; return "$G_RC"; fi
    return 0
}
macos_admin_password_stdin() { printf 'pw-for-test\n'; }

section "Tier 1 — the guest session settings are sent in one privileged round-trip"
: > "$SSHLOG"; G_RC=0
out="$( set -e; configure_macos_guest_session testvm 2>&1 )"; rc=$?
eq "0" "$rc" "returns 0 under \`set -e\`"
eq "1" "$(wc -l < "$SSHLOG" | tr -d ' ')" "exactly one ssh round-trip"
cmd="$(cat "$SSHLOG")"
has "$cmd" "sudo -S -p ''" "uses sudo -S"
has "$cmd" "autoLoginUserScreenLocked -bool false" "no lock right after auto-login"
has "$cmd" "pmset -a displaysleep 0 sleep 0" "no display/system sleep"
has "$cmd" "loginWindowIdleTime -int 0" "no screen saver on the login window"
has "$cmd" "askForPassword -int 0" "no password after the screen saver"
has "$cmd" "-currentHost write com.apple.screensaver idleTime -int 0" "no screen saver in the session"
eq "pw-for-test" "$(cat "$TMPD/sudo-stdin")" "the admin password is what sudo -S reads"

section "Tier 1 — best-effort: a failure warns and never aborts the bring-up"
G_RC=1; G_MSG="Sorry, try again."
out="$( set -e; configure_macos_guest_session testvm 2>&1 )"; rc=$?
eq "0" "$rc" "failing guest: still returns 0 under \`set -e\`"
has "$out" "Could not disable the guest's screen lock" "failing guest: warns"
has "$out" "lock screen" "failing guest: names the consequence"
has "$out" "rejected sudo password" "failing guest: a rejected password is diagnosed as such"

section "Tier 1 — cmd_up_macos wires it in after the clock correction"
body="$(declare -f cmd_up_macos)"
clock_at="$(printf '%s\n' "$body" | grep -n 'sync_macos_guest_clock "\$project_vm"' | tail -n1 | cut -d: -f1)"
sess_at="$(printf '%s\n' "$body" | grep -n 'configure_macos_guest_session "\$project_vm"' | head -n1 | cut -d: -f1)"
if [[ -n "$clock_at" && -n "$sess_at" && "$sess_at" -gt "$clock_at" ]]; then
  ok "fresh bring-up: configure_macos_guest_session@$sess_at follows the clock sync@$clock_at"
else
  fail "fresh bring-up does not configure the guest session after the clock sync" "clock@${clock_at:-none} session@${sess_at:-none}"
fi

section "Tier 1 - the base VM build applies it too"
build_body="$(declare -f cmd_build_macos)"
has "$build_body" 'configure_macos_guest_session "$MACOS_BUILD_VM"' "build: the base VM gets the settings, so a clone's first auto-login is unlocked"

hasnt "$cmd" " defaults " "all tools are absolute paths (no bare defaults)"
hasnt "$cmd" " pmset " "all tools are absolute paths (no bare pmset)"

finish
