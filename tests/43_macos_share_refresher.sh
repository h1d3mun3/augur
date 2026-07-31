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
#   • the LAUNCH-TIME dial, `--share-refresh <continuous|attach|off>` and
#     `--share-refresh-interval`. The loop's cost scales with a changed-file count nobody caps, so
#     `attach` (sweep at each attach, no loop) is the mode that answers "this repo is too big for a
#     5 s loop". Three things are pinned beyond "the flag parses": a non-default mode WARNS every
#     time (#148 — a silently disabled freshness mechanism is the defect, not the fix); `attach`
#     STOPS a refresher an earlier `up` left running rather than merely declining to start a second;
#     and the interval is validated in both layers, because `AUGUR_MACOS_REFRESH_INTERVAL=0` used to
#     reach `sleep 0` and spin the loop hot for the lifetime of the VM.
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

section "the mode gate on the loop — --share-refresh attach|off"

# The loop is the UNATTENDED, repeated cost: it sweeps for the whole lifetime of the VM with nobody
# watching, and its price scales with a changed-file count nobody caps (~0.36 ms per changed file,
# host + guest, both paid serially — past ~14,000 one sweep outlasts the default 5 s interval). So it
# is the mechanism an operator turning the refresh down is actually paying for, and both non-default
# modes stop it. The attach-time sweep is tests/41's subject, not this file's.
_saved_mode="$_MACOS_REFRESH_MODE"
echo yes > "$ALIVE"

for _m in attach off; do
    _MACOS_REFRESH_MODE="$_m"
    : > "$SWEEPLOG"
    start_share_refresher "$VM"
    if [[ ! -f "$_PF" ]]; then ok "$_m: start_share_refresher spawns nothing and writes no pidfile"
    else fail "$_m: start_share_refresher spawns nothing" "pid=$(cat "$_PF" 2>/dev/null)"; fi
    if ! share_refresher_running; then ok "…and nothing is running afterwards"
    else fail "…and nothing is running afterwards"; fi
    # The pidfile is bookkeeping; the property is that no TICK happens. Waited out at several times
    # the fixture's 1 s interval, so a loop that had been spawned would have swept by now.
    sleep 3
    if [[ ! -s "$SWEEPLOG" ]]; then ok "…and no sweep happens in 3s at interval ${AUGUR_MACOS_REFRESH_INTERVAL}s"
    else fail "…and no sweep happens" "recorded: $(tr '\n' ' ' < "$SWEEPLOG")"; fi
done

# WHY IT STOPS RATHER THAN MERELY DECLINES. `up --macos --share-refresh attach` against an
# ALREADY-RUNNING VM reaches start_share_refresher on the reconcile path, where a loop from an
# earlier `up` is still sweeping under the OLD mode. A bare "do not start a second one" would leave
# it alive while augur had just told the operator the loop was off — reporting one thing and doing
# another, which is the class #147 and #151 each closed once.
_MACOS_REFRESH_MODE=continuous
: > "$SWEEPLOG"
start_share_refresher "$VM"
_pid3="$(cat "$_PF" 2>/dev/null)"
if wait_until 8 '[[ -s "$SWEEPLOG" ]]'; then ok "a continuous refresher is live to begin with (the precondition)"
else fail "a continuous refresher is live to begin with" "nothing below would prove anything"; fi
_MACOS_REFRESH_MODE=attach
start_share_refresher "$VM"
if wait_until 5 '! kill -0 "$_pid3" 2>/dev/null'; then
    ok "attach: a refresher left over from an earlier \`up\` is STOPPED, not left running"
else
    kill "$_pid3" 2>/dev/null
    fail "attach: an earlier refresher is stopped" "pid $_pid3 survived — augur would report the loop off while it kept sweeping"
fi
if wait_until 5 '[[ ! -f "$_PF" ]]'; then ok "…and its pidfile goes with it"
else fail "…and its pidfile goes with it"; fi

# THE CONTROL. Back to continuous and the loop starts again, so the arms above measure the MODE and
# not a refresher that had simply stopped working.
_MACOS_REFRESH_MODE=continuous
: > "$SWEEPLOG"
start_share_refresher "$VM"
if wait_until 8 '[[ -s "$SWEEPLOG" ]]'; then ok "continuous: the loop starts and sweeps again"
else fail "continuous: the loop starts and sweeps again" "the gate is stopping more than the two modes it should"; fi
stop_share_refresher
_MACOS_REFRESH_MODE="$_saved_mode"

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

section "the outcome statuses stop at the gate"

# The ungated entry point reports WHAT HAPPENED in its exit status, so `augur refresh --macos` can
# fail when it swept nothing or swept badly. The gated one must not: four of its five callers invoke
# it as a bare command under `set -e`, so a non-zero here would abort `up --macos` between "SSH is
# up" and the egress tripwire — the I1 shape this series spent a PR removing. One held lock, two
# entry points, opposite answers; the manual half is pinned in tests/41, this is the automatic half.
sleep 1; printf 'STATUS\n' > "$WORKSPACE_DIR/f"
mkdir -p "$LOCK"
_rc=0; refresh_macos_shares_now "$VM" >/dev/null 2>&1 || _rc=$?
if [[ "$_rc" == "$_MACOS_SWEEP_BUSY" ]]; then ok "the UNGATED entry hands back _MACOS_SWEEP_BUSY when it cannot take the lock"
else fail "the ungated entry reports a held lock" "rc=$_rc — \`augur refresh --macos\` cannot tell a skipped sweep from a clean one"; fi
_rc=0; refresh_macos_shares "$VM" >/dev/null 2>&1 || _rc=$?
if [[ "$_rc" == "0" ]]; then ok "…and the GATED entry still swallows it to 0 (the bring-up contract)"
else fail "the gated entry swallows a held lock" "rc=$_rc — a lost lock race would abort a bring-up under set -e"; fi
rmdir "$LOCK"
_saved_ssh_status="$(declare -f ssh_macos)"
ssh_macos() { printf '%s\n' "$*" >> "$SSHLOG"; cat >/dev/null; printf 'boom'; return 1; }
_rc=0; refresh_macos_shares_now "$VM" >/dev/null 2>&1 || _rc=$?
if [[ "$_rc" == "$_MACOS_SWEEP_FAILED" ]]; then ok "a dead round trip is _MACOS_SWEEP_FAILED at the ungated entry"
else fail "a dead round trip is reported at the ungated entry" "rc=$_rc"; fi
_rc=0; refresh_macos_shares "$VM" >/dev/null 2>&1 || _rc=$?
if [[ "$_rc" == "0" ]]; then ok "…and 0 at the gated one, warning and all (best effort, unchanged)"
else fail "a dead round trip is 0 at the gated entry" "rc=$_rc — this is exactly the abort #129 removed from the credential path"; fi
eval "$_saved_ssh_status"
# Nothing left to do is its own status too, and it is the one the manual command turns into a line
# of its own rather than silence. It must not be mistaken for a failure by either caller.
refresh_macos_shares "$VM" >/dev/null 2>&1          # consume the pending edit
_rc=0; refresh_macos_shares_now "$VM" >/dev/null 2>&1 || _rc=$?
if [[ "$_rc" == "$_MACOS_SWEEP_NOWORK" ]]; then ok "nothing-to-do is _MACOS_SWEEP_NOWORK, not 0 and not a failure"
else fail "nothing-to-do is reported as its own status" "rc=$_rc"; fi
_rc=0; refresh_macos_shares "$VM" >/dev/null 2>&1 || _rc=$?
if [[ "$_rc" == "0" ]]; then ok "…and 0 at the gate, where every tick of the loop lands on it"
else fail "nothing-to-do is 0 at the gate" "rc=$_rc — the loop would abort on its own quiet ticks"; fi

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

section "the OTHER attaching commands honour the mode too, not just \`up\`"

# THE GAP THIS SECTION EXISTS FOR, and the first cut of this change shipped it. start_share_refresher
# is the only place a live refresher is reconciled with the requested mode, and it is called from
# cmd_up_macos alone. But cmd_claude_macos, cmd_shell_macos and cmd_setup_token_macos all read
# `macos_vm_running … || cmd_up_macos`, so against an ALREADY-RUNNING VM they skip cmd_up_macos
# entirely — while the launch warning in the dispatch tail fires for all FOUR commands. Measured
# before the fix: `claude --macos --share-refresh attach` printed "the every-5s refresh loop is OFF
# for this run" and then left the earlier `up`'s loop sweeping the guest for the whole session, four
# sweeps in the next four seconds. augur reporting one thing and doing another is the class #147 and
# #151 each closed once, and the operator who re-attaches precisely to escape the cost keeps paying
# it. cmd_claude_macos' own comment states the rule: "on an already-running VM this command skips
# cmd_up_macos entirely, so anything an `up` does for the guest has to be done here too."
for _fn in cmd_claude_macos cmd_shell_macos cmd_setup_token_macos; do
    read -r _s _e <<<"$(fn_range "$_fn")"
    _n="$(count_in "$_s" "$_e" 'share_refresh_loop_enabled || stop_share_refresher')"
    if [[ "$_n" == "1" ]]; then ok "$_fn reconciles a live refresher with the requested mode"
    else fail "$_fn reconciles a live refresher with the requested mode" "found $_n in lines $_s-$_e — this command warns about the mode regardless, so without it the warning is false"; fi
done

# …and dynamically, which is the arm that matters: the structural one above cannot tell a line that
# runs from a line that is dead. Everything the three commands touch besides the refresher is stubbed
# out; `ssh_macos` is already a stub from the section above, so nothing leaves this process.
_saved_attach_refresh="$(declare -f refresh_macos_shares)"
refresh_macos_shares()          { printf '%s\n' "${2:-loud}" >> "$SWEEPLOG"; return 0; }
require_vz()                    { :; }
macos_project_vm()              { echo "$VM"; }
sync_macos_guest_clock()        { :; }
ensure_macos_workspace()        { :; }
ensure_macos_claude_projects()  { :; }
ensure_macos_claude_agents()    { :; }
ensure_macos_claude_profile()   { :; }
ensure_macos_claude_bin()       { :; }
warn_if_macos_profile_stale()   { :; }
warn_if_macos_egress_pinned()   { :; }
agent_verify_integrity_macos()  { return 0; }

_saved_mode="$_MACOS_REFRESH_MODE"
echo yes > "$ALIVE"
for _cmd in cmd_claude_macos cmd_shell_macos cmd_setup_token_macos; do
    for _m in attach off; do
        _MACOS_REFRESH_MODE=continuous
        : > "$SWEEPLOG"
        start_share_refresher "$VM"
        _apid="$(cat "$_PF" 2>/dev/null || true)"
        if [[ -n "$_apid" ]] && kill -0 "$_apid" 2>/dev/null; then ok "$_cmd/$_m: a continuous refresher is live to begin with (the precondition)"
        else fail "$_cmd/$_m: a continuous refresher is live to begin with" "the two arms below would prove nothing"; fi
        _MACOS_REFRESH_MODE="$_m"
        "$_cmd" >/dev/null 2>&1
        if [[ -z "$_apid" ]] || wait_until 5 '! kill -0 "$_apid" 2>/dev/null'; then
            ok "…$_cmd under --share-refresh $_m STOPS the loop an earlier \`up\` left running"
        else
            kill "$_apid" 2>/dev/null
            fail "$_cmd under --share-refresh $_m stops the earlier loop" "pid $_apid survived — augur warns on this command that the loop is off while it keeps sweeping the guest"
        fi
        if ! share_refresher_running; then ok "…and nothing claims to be running afterwards"
        else fail "…and nothing claims to be running afterwards" "the pidfile still names a live process, so \`status --macos\` would report a loop the warning said was off"; fi
    done
done

# THE CONTROL. The same three commands under `continuous` must LEAVE the loop alone — otherwise the
# arms above would pass on a reconcile that simply kills the refresher unconditionally.
for _cmd in cmd_claude_macos cmd_shell_macos cmd_setup_token_macos; do
    _MACOS_REFRESH_MODE=continuous
    stop_share_refresher
    start_share_refresher "$VM"
    _apid="$(cat "$_PF" 2>/dev/null || true)"
    "$_cmd" >/dev/null 2>&1
    if [[ -n "$_apid" ]] && kill -0 "$_apid" 2>/dev/null && share_refresher_running; then
        ok "continuous: $_cmd leaves the running loop alone"
    else fail "continuous: $_cmd leaves the running loop alone" "the reconcile is stopping more than the two non-default modes"; fi
done
stop_share_refresher

# `augur refresh --macos` is deliberately NOT one of them, and the absence is worth pinning because
# it looks like an oversight next to the three above. Those three reconcile because they WARN about
# the mode from the dispatch tail while skipping cmd_up_macos, so a surviving loop would make their
# own warning false. cmd_refresh_macos is outside that gate and makes no claim about a loop — its one
# `off` line is run-scoped ("this is a manual sweep; it does not turn the automatic refresh back on")
# and stays true whatever an earlier `up` left running; `status --macos` is where the live half is
# measured. Killing a background refresher as a side effect of a command called `refresh` is the same
# class of surprise as booting a VM would be, which that command refuses to do for the same reason.
_saved_now="$(declare -f refresh_macos_shares_now)"
_saved_running_43="$(declare -f macos_vm_running)"
_saved_host_43="$(declare -f macos_ssh_host)"
refresh_macos_shares_now() { printf '%s\n' "manual" >> "$SWEEPLOG"; return 0; }
macos_vm_running()         { return 0; }
macos_ssh_host()           { echo 127.0.0.1; }
_MACOS_REFRESH_MODE=continuous
: > "$SWEEPLOG"
start_share_refresher "$VM"
_rpid="$(cat "$_PF" 2>/dev/null || true)"
if [[ -n "$_rpid" ]] && kill -0 "$_rpid" 2>/dev/null; then ok "cmd_refresh_macos: a continuous refresher is live to begin with (the precondition)"
else fail "cmd_refresh_macos: a continuous refresher is live to begin with" "the two arms below would prove nothing"; fi
_MACOS_REFRESH_MODE=off
cmd_refresh_macos >/dev/null 2>&1
if grep -qx manual "$SWEEPLOG"; then ok "…and \`refresh --macos\` sweeps under \`off\`, which is why the command exists"
else fail "\`refresh --macos\` sweeps under off" "recorded: $(tr '\n' ' ' < "$SWEEPLOG")"; fi
if [[ -n "$_rpid" ]] && kill -0 "$_rpid" 2>/dev/null && share_refresher_running; then
    ok "…and LEAVES the loop alone: it is not an attach, and it claims nothing about one"
else fail "refresh --macos leaves the loop alone" "it stopped a background refresher as a side effect of a manual sweep — the three commands above stop one because they warn about it; this one does not warn"; fi
stop_share_refresher
eval "$_saved_now"; eval "$_saved_running_43"; eval "$_saved_host_43"

_MACOS_REFRESH_MODE="$_saved_mode"
eval "$_saved_attach_refresh"

section "a non-default mode WARNS, on every run"

# #148 is the precedent: the refresher's own warnings went to /dev/null, so a session whose sweeps
# had been failing for an hour looked exactly like a healthy one. A mode that switches the same
# mechanism off without saying so is that defect with a different cause. It repeats rather than
# firing once because "once" needs host-side state to remember it spoke — the per-project config
# surface this flag exists to avoid — and it would go quiet for the operator who passes the flag
# habitually, who is precisely the one who forgets it is set.
_saved_mode="$_MACOS_REFRESH_MODE"
_MACOS_REFRESH_MODE=continuous
_w="$( warn_macos_refresh_mode 2>&1 )"
if [[ -z "$_w" ]]; then ok "continuous (the default) says nothing"
else fail "continuous says nothing" "a warning on the default path is noise, and noise is what stops warnings being read: $_w"; fi

for _m in attach off; do
    _MACOS_REFRESH_MODE="$_m"
    _w="$( warn_macos_refresh_mode 2>&1 )"
    if [[ -n "$_w" ]]; then ok "$_m: warns"
    else fail "$_m: warns" "a silently disabled freshness mechanism is #148 exactly"; fi
    if [[ "$_w" == *"#124/#135"* ]]; then ok "…names the issues, so the symptom is searchable"
    else fail "…names the issues" "$_w"; fi
    if [[ "$_w" == *"26.6"* ]]; then ok "…says the defect is STILL present on the current guest OS"
    else fail "…says the defect is still present" "without this it reads as a legacy workaround somebody can ignore: $_w"; fi
    if [[ "$_w" == *"--share-refresh continuous"* ]]; then ok "…and how to restore the default"
    else fail "…and how to restore the default" "$_w"; fi
done

# The two warnings must not be interchangeable: `off` stops the attach sweep and the tripwire as
# well, and an operator who read the `attach` text would still believe both were running.
_MACOS_REFRESH_MODE=attach
_w="$( warn_macos_refresh_mode 2>&1 )"
if [[ "$_w" == *"attach still sweeps"* ]]; then ok "attach says the per-attach sweep is still there"
else fail "attach says the per-attach sweep is still there" "$_w"; fi
_MACOS_REFRESH_MODE=off
_w="$( warn_macos_refresh_mode 2>&1 )"
if [[ "$_w" == *"self-test"* ]]; then ok "off says the freshness self-test is off too (that is the difference)"
else fail "off says the self-test is off too" "$_w"; fi
if [[ "$_w" == *"down --macos"* ]]; then ok "…and gives the remedy that still works with everything off"
else fail "…and gives the remedy" "$_w"; fi
_MACOS_REFRESH_MODE="$_saved_mode"

section "the launch-time flags — parsed and validated before anything can run"

# These run the REAL augur as a subprocess, because the global flag loop lives in the dispatch tail
# that AUGUR_SOURCE_ONLY deliberately returns before — there is no way to reach it from a sourced
# fixture. `help` is the cheapest command that still goes through the whole loop: it clones nothing,
# boots nothing, needs no VM backend and writes no state.
FLAGERR="$TMPD/flagerr"
augur_flags() { bash "$AUGUR" help "$@" >/dev/null 2>"$FLAGERR"; }

for _m in continuous attach off; do
    if augur_flags --macos --share-refresh "$_m"; then ok "--share-refresh $_m is accepted"
    else fail "--share-refresh $_m is accepted" "$(cat "$FLAGERR")"; fi
done
if ! augur_flags --macos --share-refresh sometimes; then ok "an unknown mode is REFUSED"
else fail "an unknown mode is refused" "a typo would leave the default running while the operator believed otherwise"; fi
if grep -q 'continuous, attach or off' "$FLAGERR"; then ok "…and the refusal names the three modes"
else fail "…the refusal names the three modes" "$(cat "$FLAGERR")"; fi
if ! augur_flags --macos --share-refresh; then ok "--share-refresh with no argument fails, rather than eating the next word"
else fail "--share-refresh with no argument fails" "$(cat "$FLAGERR")"; fi

if augur_flags --macos --share-refresh-interval 7; then ok "--share-refresh-interval accepts a positive integer"
else fail "--share-refresh-interval accepts a positive integer" "$(cat "$FLAGERR")"; fi
# Everything below reached `sleep` unchecked before this change. `0` made `sleep 0` return instantly
# and the loop spun on one host core for the lifetime of the VM; a non-numeric value made `sleep`
# fail once per tick into the refresher log, forever, which reads as a healthy session.
for _bad in 0 abc -3 5s ''; do
    if ! augur_flags --macos --share-refresh-interval "$_bad"; then ok "--share-refresh-interval '$_bad' is refused before it can reach \`sleep\`"
    else fail "--share-refresh-interval '$_bad' is refused" "it would have been passed straight to \`sleep\` every tick"; fi
done
# A leading zero is two different numbers in the two places this value is used: bash `(( 010 ))` is 8
# but `sleep 010` waits ten seconds.
if ! augur_flags --macos --share-refresh-interval 010; then ok "…and so is a leading zero, which bash and \`sleep\` read differently"
else fail "a leading zero is refused" "$(cat "$FLAGERR")"; fi
augur_flags --macos --share-refresh-interval 0
if grep -q "does not mean" "$FLAGERR"; then ok "0 is refused rather than read as 'off', and points at the flag that really does it"
else fail "0 points at the flag that really turns it off" "a number silently becoming a mode is the misreport shape this series removes: $(cat "$FLAGERR")"; fi

# Precedence — flag > AUGUR_MACOS_REFRESH_INTERVAL > 5 — read through the validator, which is the
# only oracle available offline: a bad value that survives to the end of parsing exits non-zero, a
# good one does not, so the arms below distinguish which layer actually won. The env layer is only
# checked on the commands that can reach `sleep` (below), so these run an ATTACHING command; the
# discriminator is the refusal MESSAGE, not the exit status, because `shell --macos` fails later
# anyway in a suite with no VM backend.
#
# AUGUR_VM_BIN points at nothing (fixture), so `shell --macos` dies in require_vz the moment it
# reaches dispatch — it can never boot or touch a VM. The refusal is printed above dispatch.
augur_attach() {   # augur_attach <flags…> — 0 iff the interval refusal was printed
    ( cd "$WORKSPACE_DIR" && bash "$AUGUR" shell --macos "$@" ) >/dev/null 2>"$FLAGERR"
    grep -q "is not a positive whole number" "$FLAGERR"
}
if ( export AUGUR_MACOS_REFRESH_INTERVAL=0; augur_attach ); then ok "a bad AUGUR_MACOS_REFRESH_INTERVAL is refused too, not just a bad flag"
else fail "a bad AUGUR_MACOS_REFRESH_INTERVAL is refused" "the env layer is the one that used to reach \`sleep 0\`: $(cat "$FLAGERR")"; fi
if ! ( export AUGUR_MACOS_REFRESH_INTERVAL=0; augur_attach --share-refresh-interval 7 ); then ok "…and the FLAG wins over it (env 0, flag 7 → accepted)"
else fail "the flag wins over the env" "$(cat "$FLAGERR")"; fi
if ( export AUGUR_MACOS_REFRESH_INTERVAL=7; augur_attach --share-refresh-interval 0 ); then ok "…in both directions (a good env value does not rescue a bad flag)"
else fail "the flag wins in both directions" "the env layer is overriding the operator's own command line"; fi

# THE OTHER HALF OF THE ENV LAYER, and the half a first cut of this change got wrong: the check is
# gated to the attaching commands, so a stale export cannot take TEARDOWN and INSPECTION down with
# it. Ungated it did, and the value that triggered it is `0` — the guess the operator makes first —
# so the population this flag exists for lost `augur down --macos`, i.e. the one command that stops
# the loop the bad value was spinning. augur:5605 already states the rule for require_safe_workspace
# ("down/destroy/list/status must keep working here"); this is the same rule.
#
# `zzz --macos` is the hermetic probe: reaching the macOS dispatch `case` at all is the property, and
# an unknown command needs no VM backend to prove it. The named commands below share that one block.
_zz="$( AUGUR_MACOS_REFRESH_INTERVAL=0 bash "$AUGUR" zzz --macos 2>&1 || true )"
if [[ "$_zz" == *"Unknown command"* ]]; then
    ok "a stale AUGUR_MACOS_REFRESH_INTERVAL still reaches macOS DISPATCH (so down/destroy/status keep working)"
else fail "a stale AUGUR_MACOS_REFRESH_INTERVAL still reaches macOS dispatch" "it aborted above the dispatch case — an operator who exported the obvious guess can no longer stop the VM whose loop it is spinning"; fi
for _c in help version; do
    if ( AUGUR_MACOS_REFRESH_INTERVAL=abc bash "$AUGUR" "$_c" --macos >/dev/null 2>&1 ); then ok "\`$_c --macos\` survives a non-numeric export too"
    else fail "\`$_c --macos\` survives a non-numeric export" "these need no VM backend and start no loop, so nothing about them can reach \`sleep\`"; fi
done
# …and the same for the commands that DO need the backend, against a stub that owns no state. `down`
# and `destroy` are the ones that matter: they are the escape from a loop a bad export is spinning.
#
# THE ASSERTION IS THE ABSENCE OF THE REFUSAL, NOT A ZERO EXIT, and that is not a weakening — it is
# the only form that means the same thing on both CI platforms. `require_vz` refuses outright when
# `uname` is not Darwin (augur:~1050), so on ubuntu these four can never exit 0 no matter what this
# change does; a first cut asserted exit 0 and failed there for a reason that had nothing to do with
# the env layer. What actually distinguishes "gated correctly" from "gated wrongly" is WHICH refusal
# comes back: the Darwin one (fine — the host has no VM backend) or the interval one (the defect).
# Ungate the check in the dispatch tail and all four print the interval refusal on both platforms.
_VMSTUB="$TMPD/vmstub"; mkdir -p "$_VMSTUB"; printf '#!/bin/bash\nexit 0\n' > "$_VMSTUB/augur-vm"; chmod +x "$_VMSTUB/augur-vm"
for _c in down destroy status list; do
    _sout="$( AUGUR_MACOS_REFRESH_INTERVAL=0 AUGUR_VM_BIN="$_VMSTUB/augur-vm" bash "$AUGUR" "$_c" --macos 2>&1 || true )"
    if [[ "$_sout" != *"is not a positive whole number of seconds"* ]]; then ok "\`$_c --macos\` is not refused over a stale export"
    else fail "\`$_c --macos\` is not refused over a stale export" "teardown and inspection are the wrong things to gate on a period nothing on this path uses: $_sout"; fi
done
if ( AUGUR_MACOS_REFRESH_INTERVAL=0 bash "$AUGUR" help >/dev/null 2>&1 ); then ok "container mode is untouched by it as well"
else fail "container mode is untouched by it" "a macOS-only env var took a container-mode command down with it"; fi

# The refusal's REMEDY has to clear the refusal. `--share-refresh off` does not — it never touches
# the interval — so a message naming only the mode flags sends the operator round the same loop,
# which is the #147/#151 shape with a different subject.
( export AUGUR_MACOS_REFRESH_INTERVAL=0; augur_attach ) >/dev/null 2>&1
if grep -q "unset AUGUR_MACOS_REFRESH_INTERVAL" "$FLAGERR"; then ok "a bad ENV value names the remedy that actually clears it"
else fail "a bad env value names the remedy that clears it" "\`--share-refresh off\` reproduces this error verbatim: $(cat "$FLAGERR")"; fi
augur_flags --macos --share-refresh-interval 0
if grep -q -- "--share-refresh-interval 15" "$FLAGERR"; then ok "…and a bad FLAG value names the flag remedy, not the env one"
else fail "a bad flag value names the flag remedy" "$(cat "$FLAGERR")"; fi

# Two links the arms above cannot see, because the only commands that would reveal them dynamically
# (`status --macos`, and the launch warning on `up`/`claude`/`shell`) need a VM backend this suite
# must never touch. Asserted structurally instead, inside the flag loop's own line range — the same
# technique this repo uses for call sites, and it is the difference between "the flag validates" and
# "the flag has an effect": a `--share-refresh` arm that checked the mode and assigned nothing would
# pass every dynamic arm above.
_fl_s="$(awk '/^while \[\[ \$# -gt 0 \]\]; do$/{print NR; exit}' "$AUGUR")"
_fl_e="$(awk -v a="${_fl_s:-0}" 'NR>a && /^done$/{print NR; exit}' "$AUGUR")"
in_flag_loop() { awk -v a="${_fl_s:-0}" -v b="${_fl_e:-0}" -v n="$1" 'NR>=a && NR<=b && index($0,n)>0 && $0 !~ /^ *#/ {c++} END{print c+0}' "$AUGUR"; }
if [[ -n "$_fl_s" && -n "$_fl_e" && "$_fl_e" -gt "$_fl_s" ]]; then ok "the global flag loop is where these are parsed (lines ${_fl_s}-${_fl_e})"
else fail "the global flag loop was located" "every arm below would be vacuous"; fi
if [[ "$(in_flag_loop '_MACOS_REFRESH_MODE="${2:')" == "1" ]]; then ok "…and an accepted mode is assigned to _MACOS_REFRESH_MODE there"
else fail "an accepted mode is assigned to _MACOS_REFRESH_MODE" "validation without an assignment leaves all three gates on the default"; fi
if [[ "$(in_flag_loop '_MACOS_REFRESH_INTERVAL="$2"')" == "1" ]]; then ok "…and so is an accepted interval"
else fail "an accepted interval is assigned" "found $(in_flag_loop '_MACOS_REFRESH_INTERVAL="$2"')"; fi

# …and the dispatch-tail block: the warning's call site, the env check that shares its gate, and the
# ORDER of both. Three separate failures, none of which any dynamic arm above can see:
#   • unwired          → the warning never prints, which is #148 again;
#   • ungated          → a stale AUGUR_MACOS_REFRESH_INTERVAL refuses `down --macos` (arms above);
#   • BELOW dispatch   → the warning prints after cmd_up_macos has returned, and a bad env value is
#                        refused only after the VM has booted and the hot loop has started. Measured:
#                        moving the whole block past the dispatch `case` left this suite fully green
#                        before this arm existed.
_wline="$(awk 'index($0,"warn_macos_refresh_mode")>0 && index($0,"()")==0 && $0 !~ /^ *#/ {print NR; exit}' "$AUGUR")"
_vline="$(awk 'index($0,"validate_macos_refresh_interval \"$_MACOS_REFRESH_INTERVAL\"")>0 && $0 !~ /^ *#/ {print NR; exit}' "$AUGUR")"
_dline="$(awk 'index($0,"cmd_up_macos ;;")>0 {print NR; exit}' "$AUGUR")"
_gline="$(awk -v w="${_wline:-0}" 'NR<w && index($0,"up|claude|shell|setup-token)")>0 && $0 !~ /^ *#/ {l=NR} END{print l+0}' "$AUGUR")"
if [[ -n "$_wline" && -n "$_vline" && -n "$_dline" && "$_gline" -gt 0 ]]; then ok "the dispatch-tail refresh block is locatable (gate ${_gline}, env check ${_vline}, warning ${_wline}, dispatch ${_dline})"
else fail "the dispatch-tail refresh block is locatable" "gate=$_gline env=$_vline warn=$_wline dispatch=$_dline — every arm below would be vacuous"; fi
if [[ "$_gline" -lt "$_wline" && $(( _wline - _gline )) -le 5 ]]; then ok "…the launch warning is wired to the commands that attach to a guest"
else fail "the launch warning is wired to the attaching commands" "gate=$_gline warn=$_wline — an unwired or ungated warning is #148 again"; fi
if [[ "$_gline" -lt "$_vline" && "$_vline" -lt "$_wline" ]]; then ok "…the ENV interval check sits inside that same gate, so it cannot refuse \`down --macos\`"
else fail "the env interval check sits inside the attaching-command gate" "gate=$_gline env=$_vline warn=$_wline"; fi
if [[ "$_wline" -lt "$_dline" && "$_vline" -lt "$_dline" ]]; then ok "…and both run BEFORE the macOS dispatch, not after a VM has already been booted"
else fail "both run before the macOS dispatch" "env=$_vline warn=$_wline dispatch=$_dline — a warning printed after cmd_up_macos returned describes a loop it already started"; fi

section "status --macos tells the truth about the refresh"

# "Why is my edit not showing up in the guest?" is answered here or nowhere — and the honest answer
# needs both halves, on separate lines, because their SCOPES differ and neither substitutes for the
# other. The MODE is re-derived from status's OWN command line: nothing persists what a running
# session was launched with, so it says what the next `up` typed the same way would do, and it has to
# be labelled that way. The LIVE half is measured — a host process, and the marker the sweep advances.
# Before this split, `status --macos` in a bare shell reported a GREEN "continuous … 5s loop" for a VM
# launched `--share-refresh off` at interval 30, with every one of those three claims wrong.
require_vz()      { :; }
macos_vm_exists() { return 1; }     # "not created" — the short path; no VM backend is ever called
egress_enabled()  { return 1; }
macos_project_vm() { echo "$VM"; }  # keeps the sweep marker the arms below control on a known path
echo no > "$ALIVE"
stop_share_refresher
_MARK="$(macos_share_sweep_marker "$VM")"
rm -f "$_MARK"

_MACOS_REFRESH_MODE=continuous
_st="$( cmd_status_macos 2>&1 )"
if [[ "$_st" == *"Share refresh:"* ]]; then ok "status prints a Share refresh line"
else fail "status prints a Share refresh line" "$_st"; fi
if [[ "$_st" == *continuous* ]]; then ok "…naming the mode"
else fail "…naming the mode" "$_st"; fi
if [[ "$_st" == *"this run:"* ]]; then ok "…labelled as THIS RUN's setting, not as the running session's state"
else fail "…labelled as this run's setting" "the mode is re-derived from status's own command line; presented unlabelled it is a claim about the VM that nothing measured: $_st"; fi
if [[ "$_st" == *"loop not running"* ]]; then ok "…and that no loop is actually running, which the mode alone cannot say"
else fail "…and that no loop is actually running" "reporting the mode as continuous while nothing sweeps is the misreport this line exists to prevent: $_st"; fi
if [[ "$_st" == *"no sweep recorded"* ]]; then ok "…and that no sweep has been recorded, which is the measured half"
else fail "…and that no sweep has been recorded" "$_st"; fi
# The run-scoped PERIOD must not ride along in the live clause. Nothing records the period a running
# loop was started with, so "loop running" and "5s" in one sentence read as one claim whose second
# half is a guess — measured against a live loop at interval 30, status said 5s.
_liveline="$(printf '%s\n' "$_st" | grep -F 'live:' || true)"
if [[ -n "$_liveline" && "$_liveline" != *"${_MACOS_REFRESH_INTERVAL}s loop"* ]]; then ok "…and the run-scoped interval is NOT attached to the live-loop clause"
else fail "the run-scoped interval is not attached to the live-loop clause" "live='$_liveline' — status cannot know the period the running loop was started with"; fi

touch "$_MARK"
_st="$( cmd_status_macos 2>&1 )"
if [[ "$_st" == *"last sweep"*"s ago"* ]]; then ok "a recorded sweep is reported as a measured age"
else fail "a recorded sweep is reported as a measured age" "the marker mtime is the only thing here that answers \"is my edit through yet\": $_st"; fi

# A `stat` that SUCCEEDS while printing something non-numeric. This is not hypothetical: `stat -f %m`
# is BSD, and on GNU `-f` means --file-system, so the same argv treats `%m` as a second path, **exits
# 0**, and prints a filesystem report. `||` never fires, and `$(( $(date +%s) - rmt ))` then evaluates
# ` File: "…"` as arithmetic — where the bare word `File` is a variable name, so `set -u` (augur:7)
# aborts `status --macos` outright. It took the four teardown/inspection arms above down with it on
# ubuntu CI while passing on macOS. The remedy in cmd_status_macos is GNU-form-first plus a NUMERIC
# test, and the numeric test is the half that closes the class rather than this one platform — so it
# is what this arm pins. `stat` is an external command, not one of augur's own functions, so the
# stub is removed with `unset -f` (the hazard recorded at the top of this file is unsetting a
# function augur itself defines).
stat() { printf '  File: "/somewhere"\n    ID: 0        Namelen: 255     Type: apfs\n'; return 0; }
_st="$( set -e; cmd_status_macos 2>&1; echo SURVIVED )"
unset -f stat
if [[ "$_st" == *SURVIVED* ]]; then ok "a stat that succeeds with non-numeric output does not abort status"
else fail "a stat that succeeds with non-numeric output does not abort status" "under set -u the bare word in ' File: \"…\"' is an unbound variable inside \$(( … )): $_st"; fi
if [[ "$_st" == *"no sweep recorded"* ]]; then ok "…and the age is reported as unknown rather than as a bogus number"
else fail "…and the age is reported as unknown" "a non-numeric mtime must not reach the arithmetic, and must not be dressed up as a measurement: $_st"; fi
rm -f "$_MARK"

echo yes > "$ALIVE"
start_share_refresher "$VM"
_st="$( cmd_status_macos 2>&1 )"
if [[ "$_st" == *"loop running"* && "$_st" != *"loop not running"* ]]; then ok "a live refresher is reported as running"
else fail "a live refresher is reported as running" "$_st"; fi
stop_share_refresher
echo no > "$ALIVE"
rm -f "$_MARK"

for _m in attach off; do
    _MACOS_REFRESH_MODE="$_m"
    _st="$( cmd_status_macos 2>&1 )"
    if [[ "$_st" == *"Share refresh:"*"$_m"* ]]; then ok "$_m is reported as the mode"
    else fail "$_m is reported as the mode" "$_st"; fi
    if [[ "$_st" == *"#124/#135"* ]]; then ok "…with the issues, so the line is actionable where it matters"
    else fail "…with the issues" "$_st"; fi
done
_MACOS_REFRESH_MODE="$_saved_mode"

section "the egress tripwire is still reached, in every mode, under \`set -e\`"

# WHY THIS IS IN THIS FILE AT ALL. augur runs `set -euo pipefail` (augur:7), and all three of the
# functions this change edits run in the window between "SSH is up" and `verify_macos_egress_locked`
# on both `up --macos` paths. A command that merely RETURNS non-zero in that window aborts the
# bring-up and leaves a running VM with a live NIC and no tripwire — the I1 bypass this series closed
# once already, when unguarded probes were added between exactly those two points. The new guards
# return EARLY under attach/off, so strictly fewer commands run there; but "fewer" is an argument,
# and every other arm in this suite runs under `set +e`, where the failure is invisible by
# construction. So: run the real sequence, in a subshell that really has `set -e`, in all three
# modes. The markers are the discriminator — an abort or an exit prints neither.
_saved_mode="$_MACOS_REFRESH_MODE"
verify_macos_egress_locked() { echo "TRIPWIRE-REACHED"; return 0; }
echo yes > "$ALIVE"
for _m in continuous attach off; do
    _MACOS_REFRESH_MODE="$_m"
    stop_share_refresher
    _seq="$( { set -e
               refresh_macos_shares "$VM" quiet
               verify_macos_share_freshness "$VM"
               start_share_refresher "$VM"
               verify_macos_egress_locked "$VM"
               echo SURVIVED; } 2>&1 )"
    if [[ "$_seq" == *TRIPWIRE-REACHED* ]]; then ok "$_m: the up-window sequence still reaches verify_macos_egress_locked"
    else fail "$_m: the up-window sequence still reaches verify_macos_egress_locked" "a VM would be left running with a live NIC and nothing would have checked it: '$_seq'"; fi
    if [[ "$_seq" == *SURVIVED* ]]; then ok "…and the caller survives it (no abort, no exit)"
    else fail "…and the caller survives it" "'$_seq'"; fi
done
stop_share_refresher
_MACOS_REFRESH_MODE="$_saved_mode"

finish
