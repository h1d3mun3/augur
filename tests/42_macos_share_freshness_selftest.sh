#!/usr/bin/env bash
# Tier 1 — the tripwire for the shared-file refresh (issues #124 / #135, ADR-0016 §5).
#
# WHY THE TRIPWIRE EXISTS. `refresh_macos_shares` rests on the behaviour of a closed guest-side kext
# (`com.apple.driver.AppleVirtIO`), measured on exactly one guest OS. POSIX specifies MS_INVALIDATE
# closely enough that the behaviour is clearly intended, but Apple's man page is four words and there
# is no published contract for the interaction. If a future guest image changes it, `msync` keeps
# returning 0, the sweep keeps reporting `ok=`, and the guest keeps reading stale bytes — silently.
# So the mechanism has to assert its OUTCOME, not its execution. #131, #136 and #137 each taught that
# same lesson in a different place; this file pins it for this mechanism.
#
# WHAT THIS FILE PINS. All four verdicts, because three of them are the interesting ones:
#
#   after-msync mismatch      → BROKEN. warn, loudly, with the remedy.
#   before-msync already fresh → the mitigation is NO LONGER NEEDED. This is the removal signal
#                                ADR-0016 §5 asks for, and a self-test carrying only the first
#                                control would report a clean pass for it — indistinguishable from
#                                "working". That indistinguishability is the whole point of arm 3.
#   probe unreadable           → UNVERIFIED, and reported as such rather than as either verdict.
#                                #137 is the precedent: a probe that cannot run must not be allowed
#                                to look like a probe that passed.
#   otherwise                  → verified.
#
# …plus the property that separates this from the egress self-test: it is NEVER fatal. That one gates
# a security invariant and tears the VM down. This one gates a freshness mitigation — a stale share
# is degraded, not uncontained, and ending an operator's bring-up over it is the shape #129 removed.
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/lib.sh"
AUGUR="$REPO/augur"

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

export AUGUR_VM_BIN="$TMPD/no-such-augur-vm"
AUGUR_SOURCE_ONLY=1 source "$AUGUR"
set +e

HOME="$TMPD/home"; mkdir -p "$HOME"
AUGUR_DIR="$TMPD/augur"
AUGUR_PROXY_DIR="$TMPD/proxy"; mkdir -p "$AUGUR_PROXY_DIR"
unset ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN
VM=testvm
PROBE_DIR="$AUGUR_DIR/claude-agents/$VM"; mkdir -p "$PROBE_DIR"
PROBE="$PROBE_DIR/.augur-freshness-probe"

SSHLOG="$TMPD/sshlog"; : > "$SSHLOG"
MODEFILE="$TMPD/modes"; CTRFILE="$TMPD/ctr"; CACHEFILE="$TMPD/cache"
: > "$MODEFILE"; echo 0 > "$CTRFILE"; : > "$CACHEFILE"

# A scripted guest. Its state lives in FILES, not shell variables, because the function under test
# pipes every ssh_macos call into `tr` — which runs it in a subshell, where a variable-based counter
# would be discarded and every call would silently replay mode #1. Measured: with shell variables
# this fixture reported "already current" for the BROKEN arm, i.e. it could not fail.
#
# The probe file is REAL on the host, so "fresh" is answered from what the host actually wrote and
# "stale" from what the guest cached earlier — a canned string would let the fixture pass while the
# function read the wrong path entirely.
set_modes() { printf '%s\n' "$@" > "$MODEFILE"; echo 0 > "$CTRFILE"; }
ssh_macos() {
    printf '%s\n' "$*" >> "$SSHLOG"
    local i mode
    i="$(cat "$CTRFILE")"; echo $((i+1)) > "$CTRFILE"
    mode="$(sed -n "$((i+1))p" "$MODEFILE")"; [[ -n "$mode" ]] || mode=fresh
    case "$mode" in
        fresh)  cat "$PROBE" ;;
        stale)  cat "$CACHEFILE" ;;
        unread) return 1 ;;
        noop)   : ;;              # the pre-read invalidate: the function discards its output
    esac
    # After the warm read, freeze what the guest "cached" — this is the value a stale answer serves.
    (( i == 0 )) && [[ "$mode" == fresh ]] && cp "$PROBE" "$CACHEFILE"
    return 0
}
run() { echo 0 > "$CTRFILE"; out="$( verify_macos_share_freshness "$VM" 2>&1 )"; rc=$?; }

section "fixture control — the scripted guest must be able to disagree with the host"

printf 'HOSTVAL\n' > "$PROBE"; printf 'OLDVAL\n' > "$CACHEFILE"
set_modes fresh
if [[ "$(ssh_macos x cat | tr -d '\r\n')" == "HOSTVAL" ]]; then ok "'fresh' answers from the real probe file"
else fail "'fresh' answers from the real probe file"; fi
printf 'OLDVAL\n' > "$CACHEFILE"
set_modes stale
if [[ "$(ssh_macos x cat | tr -d '\r\n')" == "OLDVAL" ]]; then ok "'stale' answers from the cache"
else fail "'stale' answers from the cache"; fi
# …and the counter must survive being run in a subshell, which is how the function calls it.
set_modes fresh stale
( ssh_macos x cat | cat >/dev/null )   # the pipe is the point: it puts ssh_macos in a subshell
if [[ "$(cat "$CTRFILE")" == "1" ]]; then ok "the call counter survives a subshell (variables would not)"
else fail "the call counter survives a subshell" "counter=$(cat "$CTRFILE")"; fi

section "verified — staleness reproduced, then made current"

# warm read fresh (the guest can see the probe), second read STALE, read after msync FRESH.
set_modes noop fresh stale fresh
run
if [[ $rc -eq 0 ]]; then ok "returns 0"; else fail "returns 0" "rc=$rc"; fi
if [[ "$out" == *"Shared-file refresh verified"* ]]; then ok "reports the mitigation as verified"
else fail "reports the mitigation as verified" "$out"; fi
if [[ "$out" != *"[augur]"*"no longer need"* ]]; then ok "does not claim the platform is fixed"
else fail "does not claim the platform is fixed" "$out"; fi
if [[ "$out" != *SELF-TEST\ FAILED* ]]; then ok "does not warn"; else fail "does not warn" "$out"; fi

section "BROKEN — msync did not make the read current"

set_modes noop fresh stale stale
run
if [[ $rc -eq 0 ]]; then ok "a broken mitigation is still NOT fatal (bring-up continues)"
else fail "a broken mitigation is still not fatal" "rc=$rc"; fi
if [[ "$out" == *"SELF-TEST FAILED"* ]]; then ok "it says the self-test failed"
else fail "it says the self-test failed" "$out"; fi
if [[ "$out" == *"until it reboots"* ]]; then ok "…and what the consequence is for the operator"
else fail "…and what the consequence is" "$out"; fi
if [[ "$out" == *"26.5.2"* ]]; then ok "…and names the guest OS the behaviour was measured against"
else fail "…names the guest OS it was measured against" "$out"; fi
if [[ "$out" == *"down --macos"* ]]; then ok "…and the remedy"
else fail "…and the remedy" "$out"; fi

section "REMOVAL SIGNAL — the guest was already current before any msync"

# This is the arm that a one-control self-test cannot distinguish from "working": both end with the
# guest reading the new value. Only the read taken BEFORE the msync separates them.
set_modes noop fresh fresh fresh
run
if [[ "$out" == *"no longer need"* ]]; then ok "an already-fresh guest is reported as the removal signal (ADR-0016 §5)"
else fail "an already-fresh guest is reported as the removal signal" "$out"; fi
if [[ "$out" != *"Shared-file refresh verified"* ]]; then ok "…and is NOT reported as a normal pass"
else fail "…and is not reported as a normal pass" "$out"; fi
if [[ "$out" != *"SELF-TEST FAILED"* ]]; then ok "…and is not reported as a failure either"
else fail "…and is not a failure" "$out"; fi
if [[ $rc -eq 0 ]]; then ok "returns 0"; else fail "returns 0" "rc=$rc"; fi

section "UNVERIFIED — the guest cannot read the probe at all"

set_modes noop unread
run
if [[ "$out" == *"Could not verify"* ]]; then ok "an unreadable probe is reported as unverified"
else fail "an unreadable probe is reported as unverified" "$out"; fi
if [[ "$out" == *"unverified, not proven broken"* ]]; then ok "…and explicitly not as a failure of msync"
else fail "…and explicitly not as a failure of msync" "$out"; fi
if [[ "$out" != *"SELF-TEST FAILED"* ]]; then ok "…so it cannot be mistaken for the BROKEN verdict"
else fail "…so it cannot be mistaken for BROKEN" "$out"; fi
if [[ "$out" != *"Shared-file refresh verified"* ]]; then ok "…nor for a pass (the #137 failure mode)"
else fail "…nor for a pass" "$out"; fi
# Count CALLS, not lines. The invalidate command carries the whole python program, so one call is
# ~25 lines in the log — a line count reported 32 for what is actually two calls. The fixture's own
# counter is the honest measure.
set_modes noop unread; : > "$SSHLOG"; run
# Two calls: the invalidate that makes the warm read meaningful, then the read that failed. Not
# three or four — an unreadable probe must not go on to run the before/after comparison.
if [[ "$(cat "$CTRFILE")" == "2" ]]; then ok "it stops after the failed read instead of probing on"
else fail "it stops after the failed read" "issued $(cat "$CTRFILE") guest calls, expected 2"; fi

section "the warm read is preceded by an invalidate"

# The direct form of the fix. Without it the tripwire misreports on every run but the first: the
# probe keeps one path, so the guest holds a warm STALE page from the previous run, the first read
# returns that, and the function concludes "cannot read the probe". A permanently-unverified
# self-test looks like a working one, which is the failure mode this whole series removes.
set_modes noop fresh stale fresh; : > "$SSHLOG"; run
if head -1 "$SSHLOG" | grep -q "msync\|python3 -c"; then
    ok "the FIRST guest call is an invalidate, not a bare read"
else fail "the first guest call is an invalidate" "it read straight away: $(head -1 "$SSHLOG")"; fi
if [[ "$(cat "$CTRFILE")" == "4" ]]; then ok "…so a full run is 4 calls: invalidate, warm, before, after"
else fail "a full run is 4 calls" "made $(cat "$CTRFILE")"; fi

section "it exercises the SHIPPED program, not a copy of it"

set_modes noop fresh stale fresh; : > "$SSHLOG"; run
if grep -q "MS_INVALIDATE\|msync" "$SSHLOG"; then ok "the invalidation is performed in the guest, not simulated"
else fail "the invalidation is performed in the guest" "$(head -2 "$SSHLOG")"; fi
_prog="$(_macos_msync_program | head -3)"
if grep -qF "$(printf '%s' "$_prog" | head -1)" "$SSHLOG"; then ok "…using the same program refresh_macos_shares uses"
else fail "…using the same program refresh_macos_shares uses" "a divergent copy would pass while the shipped one was broken"; fi

section "the probe file itself"

if [[ -f "$PROBE" ]]; then ok "the probe lives in the per-VM agents share"
else fail "the probe lives in the per-VM agents share"; fi
if [[ "$(basename "$PROBE")" == .* ]]; then ok "…as a dotfile (Claude Code scans that directory for *.md)"
else fail "…as a dotfile"; fi
if [[ "$(basename "$PROBE")" != *.md ]]; then ok "…with no .md extension, so nothing loads it as an agent"
else fail "…with no .md extension"; fi
_before="$(cat "$PROBE")"; set_modes noop fresh stale fresh; run
if [[ -f "$PROBE" ]]; then ok "the probe is overwritten, never deleted (a delete leaves a phantom — #135)"
else fail "the probe is overwritten, never deleted"; fi
if [[ "$(cat "$PROBE")" != "$_before" ]]; then ok "…with a fresh nonce each run, so a cached answer cannot pass"
else fail "…with a fresh nonce each run" "the same value twice would let a frozen guest look correct"; fi

section "a missing share directory is a no-op, not a failure"

rm -rf "$PROBE_DIR"
set_modes noop fresh; : > "$SSHLOG"; run
if [[ $rc -eq 0 && -z "$out" ]]; then ok "no agents share → silent no-op"
else fail "no agents share → silent no-op" "rc=$rc out='$out'"; fi
if [[ ! -s "$SSHLOG" ]]; then ok "…and no guest round trip is made"
else fail "…and no guest round trip is made" "$(cat "$SSHLOG")"; fi
mkdir -p "$PROBE_DIR"

section "call sites — the two \`up\` paths only"

fn_range() { awk -v f="^$1\\\\(\\\\) \\\\{" 'BEGIN{s=0} $0 ~ f && s==0 {s=NR} s>0 && /^}/ {print s, NR; exit}' "$AUGUR"; }
count_in() { awk -v a="$1" -v b="$2" -v n="$3" 'NR>=a && NR<=b && index($0,n)>0 && $0 !~ /^ *#/ {c++} END{print c+0}' "$AUGUR"; }
read -r _s _e <<<"$(fn_range cmd_up_macos)"
if [[ "$(count_in "$_s" "$_e" 'verify_macos_share_freshness "$project_vm"')" == "2" ]]; then
    ok "cmd_up_macos runs the tripwire on both paths (fresh boot and reconcile)"
else fail "cmd_up_macos runs the tripwire on both paths" "found $(count_in "$_s" "$_e" 'verify_macos_share_freshness "$project_vm"')"; fi
for _fn in cmd_claude_macos cmd_shell_macos; do
    read -r _s _e <<<"$(fn_range "$_fn")"
    if [[ "$(count_in "$_s" "$_e" 'verify_macos_share_freshness')" == "0" ]]; then
        ok "$_fn does NOT run it (three round trips belong on the heavier command)"
    else fail "$_fn does not run it"; fi
done
read -r _s _e <<<"$(fn_range cmd_up_macos)"
_r="$(awk -v a="$_s" -v b="$_e" 'NR>=a && NR<=b && index($0,"refresh_macos_shares \"$project_vm\"")>0 && $0 !~ /^ *#/ {print NR; exit}' "$AUGUR")"
_v="$(awk -v a="$_s" -v b="$_e" 'NR>=a && NR<=b && index($0,"verify_macos_share_freshness \"$project_vm\"")>0 && $0 !~ /^ *#/ {print NR; exit}' "$AUGUR")"
if [[ -n "$_r" && -n "$_v" && "$_r" -lt "$_v" ]]; then ok "the tripwire runs after the refresh it is checking"
else fail "the tripwire runs after the refresh" "refresh=$_r verify=$_v"; fi

finish
