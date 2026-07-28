#!/usr/bin/env bash
# Tier 1 — the continuous share refresher (issues #124 / #135, ADR-0016). Runs anywhere; nothing is
# cloned, booted or really SSH'd. It DOES spawn the real background loop, with the interval turned
# down and every wait bounded, because the loop's lifecycle is the whole subject.
#
# WHY THE LOOP EXISTS. The sweep at the four attach points buys "fresh as of the last attach" — and
# that does NOT fix what #124 reports. That symptom is a host-side edit made WHILE the agent is
# running: nothing runs between two attaches, so nothing invalidates anything, and the agent reads
# the old bytes with no error.
#
# WHAT THIS FILE PINS:
#   • the pidfile is keyed by workspace_path_hash. Not decoration — a same-basename sibling sharing
#     one pidfile is the exact collision class PR #127 removed from the egress state, and here it
#     would point a refresher at the wrong VM's marker.
#   • start is idempotent, stop is complete, and the loop TERMINATES ON ITS OWN when the guest goes
#     away. `down --macos` does stop it, but a crashed augur or a killed VM must not leave a process
#     SSHing at a guest that no longer exists.
#   • the loop sweeps QUIETLY. Left noisy it would print a line every interval into the operator's
#     terminal for the whole session.
#   • the LOCK. This PR introduces the second concurrent sweeper; until now there was exactly one
#     caller at a time. Two sweeps racing each stamp a pending marker, scan against the shared one,
#     and promote — and the loser's promotion can carry a timestamp taken before the winner's scan,
#     silently dropping every file changed in between. Skipped ticks are correct; a wedged lock is
#     not, so a stale one is stolen.
#   • the call sites: started on both `up` paths, stopped by BOTH `down` and `destroy`.
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/lib.sh"
AUGUR="$REPO/augur"

TMPD="$(mktemp -d)"
cleanup() { [[ -n "${_PF:-}" && -f "$_PF" ]] && kill "$(cat "$_PF")" 2>/dev/null; rm -rf "$TMPD"; }
trap cleanup EXIT

export AUGUR_VM_BIN="$TMPD/no-such-augur-vm"
export AUGUR_MACOS_REFRESH_INTERVAL=1        # the loop's period; every wait below is bounded anyway
AUGUR_SOURCE_ONLY=1 source "$AUGUR"
set +e

HOME="$TMPD/home"; mkdir -p "$HOME"
AUGUR_DIR="$TMPD/augur"
AUGUR_PROXY_DIR="$TMPD/proxy"; mkdir -p "$AUGUR_PROXY_DIR"
unset ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN
WORKSPACE_DIR="$TMPD/ws"; mkdir -p "$WORKSPACE_DIR"
MACOS_SHARE="workspace-testslug"
VM=testvm
mkdir -p "$AUGUR_DIR/claude-projects/$VM" "$AUGUR_DIR/claude-agents/$VM" "$AUGUR_DIR/claude-profile"

# Guest liveness and sweep calls are both file-backed: the loop runs in a subshell, so anything it
# recorded in a variable would be invisible here (the mistake tests/42's fixture had to be fixed for).
ALIVE="$TMPD/alive"; echo yes > "$ALIVE"
SWEEPLOG="$TMPD/sweeps"; : > "$SWEEPLOG"
macos_vm_running() { [[ "$(cat "$ALIVE" 2>/dev/null)" == yes ]]; }
# Save the real one before shadowing it. `unset -f` would not restore it — bash keeps ONE definition
# per name, so unsetting the stub deletes augur's function outright and every later call becomes
# "command not found". Measured: that silently turned the entire lock section green while testing
# nothing, because a sweep that cannot run also issues no SSH.
_REAL_REFRESH="$(declare -f refresh_macos_shares)"
refresh_macos_shares() { printf '%s\n' "${2:-loud}" >> "$SWEEPLOG"; return 0; }

wait_until() {   # wait_until <seconds> <shell-condition…> — bounded, never spins forever
    local n="$1"; shift
    while (( n-- > 0 )); do eval "$*" && return 0; sleep 1; done
    return 1
}

section "the pidfile is keyed by workspace PATH, not basename (the #127 lesson)"

_a="$(share_refresher_pidfile)"
_saved="$WORKSPACE_DIR"
WORKSPACE_DIR="$TMPD/other/ws"; mkdir -p "$WORKSPACE_DIR"
_b="$(share_refresher_pidfile)"
WORKSPACE_DIR="$_saved"
if [[ "$_a" != "$_b" ]]; then ok "two workspaces with the same basename get different pidfiles"
else fail "two workspaces with the same basename get different pidfiles" "both resolved to $_a"; fi
if [[ "$_a" == *"$(workspace_path_hash)"* ]]; then ok "the path hash is in the name"
else fail "the path hash is in the name" "$_a"; fi
if [[ "$_a" == "$AUGUR_PROXY_DIR"/* ]]; then ok "it lives beside the other host-side process state"
else fail "it lives beside the other host-side process state" "$_a"; fi

section "start / stop lifecycle"

_PF="$(share_refresher_pidfile)"
if ! share_refresher_running; then ok "nothing is running to begin with"
else fail "nothing is running to begin with"; fi

start_share_refresher "$VM"
if [[ -f "$_PF" ]]; then ok "start writes a pidfile"; else fail "start writes a pidfile"; fi
if share_refresher_running; then ok "…and the process is alive"
else fail "…and the process is alive" "pid=$(cat "$_PF" 2>/dev/null)"; fi

_pid1="$(cat "$_PF")"
start_share_refresher "$VM"
if [[ "$(cat "$_PF")" == "$_pid1" ]]; then ok "starting twice does not spawn a second refresher"
else fail "starting twice does not spawn a second refresher" "$_pid1 -> $(cat "$_PF")"; fi

if wait_until 8 '[[ -s "$SWEEPLOG" ]]'; then ok "the loop actually sweeps"
else fail "the loop actually sweeps" "no sweep in 8s at interval ${AUGUR_MACOS_REFRESH_INTERVAL}s"; fi
if grep -qx quiet "$SWEEPLOG"; then ok "…and sweeps QUIETLY (a line per interval would flood the terminal)"
else fail "…and sweeps quietly" "recorded: $(tr '\n' ' ' < "$SWEEPLOG")"; fi

# A background loop has nowhere to warn TO — the operator is inside `claude`. Its output has to land
# in a file or the "a failing quiet sweep still warns" property below reaches nobody, and an hour of
# failing sweeps looks exactly like a healthy session.
if [[ -f "$(share_refresher_logfile)" ]]; then ok "the loop writes to a logfile, not to /dev/null"
else fail "the loop writes to a logfile" "warnings from a background sweep would be discarded"; fi
if [[ "$(share_refresher_logfile)" == "$AUGUR_PROXY_DIR"/* ]]; then ok "…beside the proxy and gvproxy logs"
else fail "…beside the proxy and gvproxy logs" "$(share_refresher_logfile)"; fi

stop_share_refresher
if ! share_refresher_running; then ok "stop kills the loop"; else fail "stop kills the loop"; fi
if [[ ! -f "$_PF" ]]; then ok "…and removes the pidfile"; else fail "…and removes the pidfile"; fi
stop_share_refresher
if [[ $? -eq 0 ]]; then ok "stopping an already-stopped refresher is a no-op, not an error"
else fail "stopping an already-stopped refresher is a no-op"; fi

section "the loop terminates on its own when the guest goes away"

: > "$SWEEPLOG"; echo yes > "$ALIVE"
start_share_refresher "$VM"
wait_until 8 '[[ -s "$SWEEPLOG" ]]' >/dev/null
_pid2="$(cat "$_PF" 2>/dev/null)"
echo no > "$ALIVE"                      # the VM "stops" — nobody calls stop_share_refresher
if wait_until 10 '! kill -0 "$_pid2" 2>/dev/null'; then
    ok "a refresher whose guest disappeared exits by itself (no orphan SSHing at a dead VM)"
else
    kill "$_pid2" 2>/dev/null
    fail "a refresher whose guest disappeared exits by itself" "pid $_pid2 still alive after 10s"
fi
if wait_until 5 '[[ ! -f "$_PF" ]]'; then ok "…and cleans up its own pidfile on the way out"
else fail "…and cleans up its own pidfile"; fi
echo yes > "$ALIVE"

section "a failing sweep in the loop reaches the log"

# End to end: the warning the quiet mode preserves has to arrive somewhere an operator can read.
: > "$(share_refresher_logfile)"
_saved_refresh="$(declare -f refresh_macos_shares)"
refresh_macos_shares() { warn "SIMULATED sweep failure"; return 0; }
echo yes > "$ALIVE"
start_share_refresher "$VM"
if wait_until 8 'grep -q "SIMULATED sweep failure" "$(share_refresher_logfile)"'; then
    ok "a warning from inside the background loop lands in the log"
else fail "a warning from inside the background loop lands in the log" "an operator has no other way to learn the refresher is failing"; fi
stop_share_refresher
eval "$_saved_refresh"

section "the sweep lock — two concurrent sweepers must not race"

# The real function from here on: the lock is its behaviour, not the loop's.
eval "$_REAL_REFRESH"
if [[ "$(type -t refresh_macos_shares)" == function ]] && ! declare -f refresh_macos_shares | grep -q SWEEPLOG; then
    ok "the real refresh_macos_shares is back in place (not the stub, not missing)"
else fail "the real refresh_macos_shares is back in place" "everything below would pass vacuously"; fi
SSHLOG="$TMPD/sshlog"; : > "$SSHLOG"
ssh_macos() { printf '%s\n' "$*" >> "$SSHLOG"; cat >/dev/null; printf 'ok=1'; return 0; }
printf 'x\n' > "$WORKSPACE_DIR/f"
LOCK="$(macos_share_sweep_marker "$VM").lock"

refresh_macos_shares "$VM" >/dev/null 2>&1          # first sweep: establishes the marker
sleep 1; printf 'y\n' > "$WORKSPACE_DIR/f"
mkdir -p "$LOCK"                                     # …as if another sweeper were mid-scan
: > "$SSHLOG"
refresh_macos_shares "$VM" >/dev/null 2>&1
if [[ ! -s "$SSHLOG" ]]; then ok "a sweep skips its turn while another holds the lock"
else fail "a sweep skips its turn while another holds the lock" "it ran anyway: $(head -1 "$SSHLOG")"; fi
if [[ -d "$LOCK" ]]; then ok "…and does not steal a lock that is fresh"
else fail "…and does not steal a fresh lock"; fi

# A crashed augur leaves the directory behind. Without the steal, every future sweep is wedged.
touch -t 202001010000 "$LOCK"
: > "$SSHLOG"
refresh_macos_shares "$VM" >/dev/null 2>&1
if [[ -s "$SSHLOG" ]]; then ok "a STALE lock is stolen, so a crash cannot wedge the refresh forever"
else fail "a stale lock is stolen" "the sweep stayed blocked behind an abandoned lock"; fi

: > "$SSHLOG"; sleep 1; printf 'z\n' > "$WORKSPACE_DIR/f"
refresh_macos_shares "$VM" >/dev/null 2>&1
if [[ ! -d "$LOCK" ]]; then ok "the lock is released after a normal sweep"
else fail "the lock is released after a normal sweep"; fi
if [[ -s "$SSHLOG" ]]; then ok "…and the sweep that released it did its work"
else fail "…and the sweep that released it did its work"; fi

section "quiet suppresses the report but never the warning"

sleep 1; printf 'w\n' > "$WORKSPACE_DIR/f"
out="$( refresh_macos_shares "$VM" 2>&1 )"
if [[ "$out" == *"Refreshed the guest's view"* ]]; then ok "a loud sweep reports what it did"
else fail "a loud sweep reports what it did" "$out"; fi
sleep 1; printf 'v\n' > "$WORKSPACE_DIR/f"
out="$( refresh_macos_shares "$VM" quiet 2>&1 )"
if [[ -z "$out" ]]; then ok "a quiet sweep says nothing on success"
else fail "a quiet sweep says nothing on success" "$out"; fi
ssh_macos() { printf '%s\n' "$*" >> "$SSHLOG"; cat >/dev/null; printf 'boom'; return 1; }
sleep 1; printf 'u\n' > "$WORKSPACE_DIR/f"
out="$( refresh_macos_shares "$VM" quiet 2>&1 )"
if [[ "$out" == *"Could not refresh"* ]]; then ok "…but a FAILING quiet sweep still warns"
else fail "…but a failing quiet sweep still warns" "silence here would hide a broken session entirely: '$out'"; fi

section "call sites"

fn_range() { awk -v f="^$1\\\\(\\\\) \\\\{" 'BEGIN{s=0} $0 ~ f && s==0 {s=NR} s>0 && /^}/ {print s, NR; exit}' "$AUGUR"; }
count_in() { awk -v a="$1" -v b="$2" -v n="$3" 'NR>=a && NR<=b && index($0,n)>0 && $0 !~ /^ *#/ {c++} END{print c+0}' "$AUGUR"; }
read -r _s _e <<<"$(fn_range cmd_up_macos)"
if [[ "$(count_in "$_s" "$_e" 'start_share_refresher "$project_vm"')" == "2" ]]; then
    ok "cmd_up_macos starts it on both paths (fresh boot and reconcile)"
else fail "cmd_up_macos starts it on both paths" "found $(count_in "$_s" "$_e" 'start_share_refresher "$project_vm"')"; fi
for _fn in cmd_down_macos cmd_destroy_macos; do
    read -r _s _e <<<"$(fn_range "$_fn")"
    if [[ "$(count_in "$_s" "$_e" 'stop_share_refresher')" -ge 1 ]]; then ok "$_fn stops it"
    else fail "$_fn stops it" "a surviving refresher would SSH at a guest this path is tearing down"; fi
    _r="$(awk -v a="$_s" -v b="$_e" 'NR>=a && NR<=b && index($0,"stop_share_refresher")>0 && $0 !~ /^ *#/ {print NR; exit}' "$AUGUR")"
    _v="$(awk -v a="$_s" -v b="$_e" 'NR>=a && NR<=b && index($0,"$VM_CLI\" stop")>0 && $0 !~ /^ *#/ {print NR; exit}' "$AUGUR")"
    if [[ -z "$_v" || ( -n "$_r" && "$_r" -lt "$_v" ) ]]; then ok "$_fn stops it BEFORE stopping the VM"
    else fail "$_fn stops it before stopping the VM" "stop=$_r vm-stop=$_v"; fi
done

finish
