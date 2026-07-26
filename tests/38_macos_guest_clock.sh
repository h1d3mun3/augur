#!/usr/bin/env bash
# Tier 1 — macOS mode must SET THE GUEST'S CLOCK from the host's (runs anywhere; nothing is ever
# cloned, booted or SSH'd, and NO REAL CLOCK IS EVER SET — the "guest" is a scriptable stand-in for
# ssh_macos, and the only `date` calls that actually execute are host-side READS).
#
# The defect. A macOS guest cloned from augur's base VM boots with a CLOCK_REALTIME a fixed offset
# BEHIND the host's, and nothing in augur ever corrected it. Measured from inside a live guest on the
# host this was written on:
#
#   host clock (a file mtime stamped through the virtiofs share) : 1785039613
#   kern.monotonicclock                                          : 1785039613   delta =     0 s
#   guest CLOCK_REALTIME (`date +%s`)                            : 1785033880   delta = -5733 s
#   kern.monotoniclock_offset_usecs = -5733425731   (byte-identical across two different boots,
#                                                    and unchanged across 7h36m of uptime)
#   kern.sleeptime = kern.waketime = 0              (the guest itself never slept)
#
# So the offset is a CONSTANT baked into the base VM's persisted state and inherited by every clone —
# not accumulated suspend time. The guest's monotonic clock tracks the host exactly, which is why the
# skew is invisible to anything measuring a DURATION and lethal to anything comparing an ABSOLUTE
# instant: a JWT minted on the host seconds ago is `nbf`-in-the-future to a guest 95 minutes in the
# past, git commits are stamped 95 minutes early, and TLS validity windows are judged 95 minutes
# early (harmless for a week-old certificate, a false "egress is DOWN" verdict for one rotated in the
# last 95 minutes — which tears the VM down inside verify_macos_egress_locked).
#
# Why NTP is not the fix: NTP is UDP/123, `augur.conf` is a SOCKS5/TCP NAME allowlist, and
# `gvproxy/augur-egress.patch` does not register the UDP or ICMP forwarders at all under
# `--deny-direct` — so UDP has no path out regardless of the allowlist, and opening one would
# regress INVARIANTS.md I9, which tests/36 now self-tests. The last section pins both of those so
# "just allowlist a time server" cannot be quietly attempted later.
#
# What this file pins, all through stubs:
#   • the correction is INVOKED on every path that hands a guest to the agent — the fresh bring-up,
#     the already-running reconcile, `claude --macos` and `shell --macos`;
#   • it runs BEFORE the time-dependent steps, asserted on recorded-call ORDER (the clock read
#     precedes the egress self-test, the ~/.augur-env credential push and the interactive launch);
#   • the command sent is the one intended, down to its shape, AND carries the HOST's current time
#     (the stamp is bracketed by two host readings, so a constant, the guest's own clock, or a
#     mis-ordered format all fail);
#   • it is IDEMPOTENT — an already-correct guest is read and then left alone, with no `sudo` at all;
#   • every failure is BEST-EFFORT: rc 0, a warning that names the consequence, and never a success
#     claim. Each is asserted on recorded calls, not on rc alone: this function returns 0 in every
#     branch on purpose, so rc can never be the signal.
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/lib.sh"
AUGUR="$REPO/augur"

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

# BOOT-PROOFING (the technique tests/30_macos_vm.sh, 34, 35, 36 and 37 use): point AUGUR_VM_BIN at a
# path that cannot exist BEFORE sourcing, so the resolved $VM_CLI can never be a real augur-vm. The
# recorder installed below replaces it for the assertions; if that override were ever lost the
# fallback is "command not found", never a real clone/run against this host's VMs. Set before the
# source because resolve_vm_cli runs at source time.
export AUGUR_VM_BIN="$TMPD/no-such-augur-vm"

# Pull the REAL sync_macos_guest_clock / cmd_up_macos / cmd_claude_macos / cmd_shell_macos out of
# augur without running its dispatch tail (AUGUR_SOURCE_ONLY seam), so this can never drift from the
# shipped functions. Stubs are installed AFTER the source on purpose: bash resolves function names
# at CALL time, so a later definition wins.
AUGUR_SOURCE_ONLY=1 source "$AUGUR"
set +e                                    # augur enables `set -e`; restore lib.sh assert-and-continue

# Sandbox every path this can read or write. This runner exports CLAUDE_CODE_OAUTH_TOKEN and has a
# real ~/.gitconfig; neither may be reachable from here (tests/34–37 do the same).
HOME="$TMPD/home"; mkdir -p "$HOME"
AUGUR_DIR="$TMPD/augur"
AUGUR_PROXY_DIR="$TMPD/proxy"; mkdir -p "$AUGUR_PROXY_DIR"
WORKSPACE_DIR="$TMPD/proj"; mkdir -p "$WORKSPACE_DIR"
unset ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN
gh() { return 1; }                        # no host gh token: keeps the credential-helper wiring a no-op

# Assigned in the dispatch tail the AUGUR_SOURCE_ONLY seam returns before; mint them exactly as it
# does (cmd_up_macos interpolates MACOS_SHARE, and augur runs under `set -u`).
SWIFT_IMAGE_TAG="${SWIFT_VERSION:-latest}"
IMAGE_NAME="augur:swift-${SWIFT_IMAGE_TAG}"
CONTAINER_NAME="$(make_container_name)"
WORKSPACE_MOUNT="$(make_workspace_mount)"
MACOS_SHARE="workspace-$(workspace_slug)"
MACOS_MODE=true

SSHLOG="$TMPD/sshlog"   # every remote command string, in order — the ONLY reliable signal here
: > "$SSHLOG"

# ── The scriptable guest. Its clock offset from the host's, in seconds, lives in a FILE, not a
#    variable: sync_macos_guest_clock reads and sets through command substitutions, so the "set"
#    happens in a subshell and a variable assignment there would be invisible to the read-back that
#    follows — which is exactly the thing under test. A `date` set moves the offset to G_SET_TO, so
#    "the command succeeded and the clock did not move" is expressible. ────────────────────────────
OFFSET_FILE="$TMPD/guest-clock-offset"
G_READ=1        # 1 = the clock is readable over SSH, 0 = ssh itself fails
G_NOISE=0       # 1 = the guest prints a banner line before the epoch (a chatty ~/.zshenv)
G_SET_RC=0      # what the privileged `date` set exits with
G_SET_TO=0      # the offset the guest lands on after a successful set
g_offset()     { printf '%s' "$1" > "$OFFSET_FILE"; }
reset_guest()  { G_READ=1; G_NOISE=0; G_SET_RC=0; G_SET_TO=0; g_offset 0; }
reset_guest

ssh_macos() {
    local vm="$1"; shift
    local cmd="$*"
    printf '%s\n' "$cmd" >> "$SSHLOG"
    case "$cmd" in
        "/bin/date +%s")                                   # the clock READ (and the read-back)
            [[ "$G_READ" == 1 ]] || return 255             # what ssh exits when it cannot connect
            [[ "$G_NOISE" == 1 ]] && echo "Welcome to the guest!"
            printf '%s\n' "$(( $(date +%s) + $(cat "$OFFSET_FILE") ))"
            return 0 ;;
        *"sudo -S -p ''"*)                                 # the privileged SET
            if [[ "$G_SET_RC" != 0 ]]; then
                echo "Sorry, try again." >&2               # what `sudo -S` says to a bad password
                return "$G_SET_RC"
            fi
            g_offset "$G_SET_TO"
            date -u +'%a %b %e %H:%M:%S UTC %Y'            # what `date` prints when it sets
            return 0 ;;
        *".augur-env"*)                                    # the credential push (cmd_up_macos)
            cat >/dev/null; return 0 ;;
        *".zshenv"*)          return 0 ;;
        *"exec zsh -l"*)      return 0 ;;                  # cmd_shell_macos' interactive launch
        *"zsh -l -c"*)        return 0 ;;                  # cmd_claude_macos' interactive launch
        *) echo "UNEXPECTED GUEST COMMAND: $cmd" >&2; return 1 ;;
    esac
}

# Run the REAL function the way its call sites run it: under `set -e`. Without that, "best-effort"
# is unobservable — a failing ssh_macos would merely return non-zero and be ignored, whereas the
# abort this must never cause is precisely a `set -e` abort with the VM already booted.
sync() {   # sets $out / $rc; truncates the log first
    : > "$SSHLOG"
    out="$( set -e; sync_macos_guest_clock testvm 2>&1 )"; rc=$?
}
# Recorded-call helpers. Line NUMBERS, because ORDER is half of what this file proves.
at()      { grep -nxF "$1" "$SSHLOG" | head -n1 | cut -d: -f1; }   # exact whole-line match
at_re()   { grep -nE  "$1" "$SSHLOG" | head -n1 | cut -d: -f1; }
n_calls() { wc -l < "$SSHLOG" | tr -d ' '; }
SET_RE="^echo '${MACOS_SSH_USER}' \| sudo -S -p '' /bin/date -u '[0-9]{12}\.[0-9]{2}'$"
did_set() { grep -qE "$SET_RE" "$SSHLOG"; }
READ_CMD='/bin/date +%s'

section "Tier 1 — fixture controls (a scripted guest that could not fail is no test at all)"

reset_guest; : > "$SSHLOG"
_r0="$(ssh_macos testvm "$READ_CMD")"
g_offset -5733
_r1="$(ssh_macos testvm "$READ_CMD")"
reset_guest
if [[ "$_r0" =~ ^[0-9]+$ && "$_r1" =~ ^[0-9]+$ && $(( _r0 - _r1 )) -ge 5730 ]]; then
  ok "the scripted guest really carries a settable clock offset (control: ${_r0} → ${_r1})"
else
  fail "the scripted guest does not model a clock offset" "read0=[$_r0] read1=[$_r1]"
fi
if [[ "$(n_calls)" == "2" ]]; then ok "the ssh recorder captures every remote command in order (control)"
else fail "the ssh recorder captured $(n_calls) of 2 commands" "every recorded-call assertion below would be vacuous"; fi

section "Tier 1 — a 95-minutes-behind guest is CORRECTED, from the host's clock, in the right order"

reset_guest; g_offset -5733
_before="$(date -u +%m%d%H%M%Y)"
sync
_after="$(date -u +%m%d%H%M%Y)"
eq "0" "$rc" "skewed guest: returns 0 under \`set -e\` (the bring-up continues past it)"
# Anchored on the measured drift: only a run that actually READ the guest's clock can print this.
has "$out" "Guest clock is -573" "skewed guest: reports the measured drift, not just 'setting the clock'"
has "$out" "correcting from the host" "skewed guest: says where the authoritative time came from"
has "$out" "Guest clock synchronised with the host" "skewed guest: confirms the correction landed"

# THE recorded-call assertion: read, then set, then read back — exactly three commands, in that
# order. A mutant that drops the pre-read, the set or the read-back changes this count or this order.
_r1_at="$(at "$READ_CMD")"
_set_at="$(at_re "$SET_RE")"
_r2_at="$(grep -nxF "$READ_CMD" "$SSHLOG" | tail -n1 | cut -d: -f1)"
if [[ -n "$_r1_at" && -n "$_set_at" && -n "$_r2_at" && "$_r1_at" -lt "$_set_at" && "$_set_at" -lt "$_r2_at" ]]; then
  ok "skewed guest: read → set → read-back (read@$_r1_at < set@$_set_at < verify@$_r2_at)"
else
  fail "skewed guest: the correction is not read → set → read-back" \
       "read@${_r1_at:-none} set@${_set_at:-none} verify@${_r2_at:-none}; log: [$(tr '\n' ' ' < "$SSHLOG")]"
fi
eq "3" "$(n_calls)" "skewed guest: exactly three round-trips (nothing extra, nothing missing)"

# The command SHAPE, pinned as a literal contract with the guest: the `sudo -S` mechanism
# install_macos_managed_settings established (a project clone has NO passwordless sudo), an absolute
# /bin/date so ~/.local/bin cannot shadow it, and -u so the stamp is read as UTC.
if did_set; then ok "skewed guest: the set is 'echo <user> | sudo -S -p '' /bin/date -u <stamp>'"
else fail "skewed guest: the privileged set does not have the intended shape" "log: [$(tr '\n' ' ' < "$SSHLOG")]"; fi
has "$(cat "$SSHLOG")" "sudo -S -p ''" "skewed guest: uses \`sudo -S\` (a project clone has no NOPASSWD grant)"
has "$(cat "$SSHLOG")" "/bin/date"     "skewed guest: pins date's absolute path (no \$HOME/.local/bin shadowing)"

# …and the VALUE is the HOST's time now. $_before/$_after bracket the run, so this fails for a
# hard-coded stamp, for the guest's own (skewed) clock, and for a mis-ordered format string — while
# tolerating a minute/hour/day/year rollover mid-test.
_stamp="$(sed -nE "s/^.*\/bin\/date -u '([0-9]{12})\.([0-9]{2})'$/\1/p" "$SSHLOG" | head -n1)"
if [[ "$_stamp" == "$_before" || "$_stamp" == "$_after" ]]; then
  ok "skewed guest: the stamp carries the HOST's current time (mmddHHMMccyy = $_stamp)"
else
  fail "skewed guest: the stamp is not the host's current time" \
       "sent [$_stamp], host was [$_before]..[$_after]"
fi
_secs="$(sed -nE "s/^.*\/bin\/date -u '([0-9]{12})\.([0-9]{2})'$/\2/p" "$SSHLOG" | head -n1)"
if [[ "$_secs" =~ ^[0-9]{2}$ ]]; then ok "skewed guest: the stamp carries seconds too (.SS = $_secs)"
else fail "skewed guest: the stamp has no seconds field" "got [$_secs]"; fi

section "Tier 1 — a guest that is AHEAD of the host is corrected too (the drift test is absolute)"

reset_guest; g_offset 5733
sync
has "$out" "Guest clock is 573" "guest ahead: reports a POSITIVE drift"
if did_set; then ok "guest ahead: still corrected (a signed-only comparison would skip this)"
else fail "guest ahead: no correction was sent" "log: [$(tr '\n' ' ' < "$SSHLOG")]"; fi

section "Tier 1 — an already-correct guest is READ and then LEFT ALONE (no needless \`sudo\`)"

# Idempotence is what makes it safe to call from four sites. The load-bearing assertion is the
# ABSENCE of the set plus the exact call count: a mutant that deletes the tolerance test still
# "works", and would `sudo` the guest on every `up`, `claude` and `shell`.
for _off in 0 -5 5; do
  reset_guest; g_offset "$_off"
  sync
  eq "0" "$rc" "in-tolerance guest (${_off}s): returns 0"
  if did_set; then fail "in-tolerance guest (${_off}s): sent a privileged clock set anyway" "log: [$(tr '\n' ' ' < "$SSHLOG")]"
  else ok "in-tolerance guest (${_off}s): no \`sudo\` clock set is sent"; fi
  eq "1" "$(n_calls)" "in-tolerance guest (${_off}s): exactly one round-trip (the read), then stop"
  # It must also stay SILENT — these are strings only a correcting run prints, so their absence is
  # what proves the early return rather than a set that happened to be a no-op.
  hasnt "$out" "correcting from the host" "in-tolerance guest (${_off}s): says nothing about correcting"
  hasnt "$out" "synchronised"             "in-tolerance guest (${_off}s): claims no correction it did not make"
done

reset_guest; g_offset -20
sync
if did_set; then ok "a 20s-behind guest IS corrected (the tolerance is seconds wide, not minutes)"
else fail "a 20s-behind guest was left alone" "the tolerance is far too wide; log: [$(tr '\n' ' ' < "$SSHLOG")]"; fi

section "Tier 1 — the read-back is load-bearing: a set that did not stick is REPORTED, not claimed"

# The exit status of `echo <pw> | sudo -S date …` covers a rejected password and a malformed stamp.
# It cannot see a guest that accepts the command and stays wrong (`timed` is live in the guest). This
# is that case: the set exits 0 and the clock does not move.
reset_guest; g_offset -5733; G_SET_TO=-5733
sync
eq "0" "$rc" "set did not stick: still returns 0 (a wrong clock is degraded, not uncontained)"
has "$out" "still" "set did not stick: says the clock is STILL off"
has "$out" "after being set" "set did not stick: names the read-back as the thing that noticed"
has "$out" "overriding it" "set did not stick: points at the guest overriding it"
hasnt "$out" "Guest clock synchronised with the host" "set did not stick: never claims success"
if did_set; then ok "set did not stick: the set was genuinely attempted (control)"
else fail "set did not stick: no set was attempted" "the assertions above would be vacuous"; fi
eq "3" "$(n_calls)" "set did not stick: the read-back really ran (three round-trips)"

# …and the read-back's tolerance is the SAME generous one, not an exact-equality test: a set that
# lands 2s out is a success, or every real correction would warn about its own SSH round-trip.
reset_guest; g_offset -5733; G_SET_TO=-2
sync
has "$out" "Guest clock synchronised with the host" "set landed 2s out: accepted (the round-trip is not a failure)"
hasnt "$out" "after being set" "set landed 2s out: no spurious 'still off' warning"

section "Tier 1 — every failure is BEST-EFFORT: warn, name the cost, never claim success, rc 0"

# (a) the privileged set is refused (a base VM whose fixed ADR-0007 password was changed by hand).
reset_guest; g_offset -5733; G_SET_RC=1
sync
eq "0" "$rc" "set refused: returns 0 (\`up\` must not die with the VM already booted)"
has "$out" "Could not set the guest's clock" "set refused: warns that the set failed"
has "$out" "Sorry, try again." "set refused: surfaces sudo's own diagnostic (not swallowed)"
has "$out" "Tokens, TLS validity windows and commit timestamps" "set refused: names what will be wrong"
hasnt "$out" "Guest clock synchronised with the host" "set refused: never claims success"
# The recorded-call proof of the early return: the read-back must NOT be attempted after a failed set.
eq "2" "$(n_calls)" "set refused: stops after the failed set (no pointless read-back)"

# (b) the guest is unreachable. Nothing may be sent — least of all a privileged command whose
# argument would be derived from an unread clock.
reset_guest; G_READ=0
sync
eq "0" "$rc" "guest unreadable: returns 0"
has "$out" "Could not read the guest's clock over SSH" "guest unreadable: says the READ is what failed"
has "$out" "not-yet-valid" "guest unreadable: names the token consequence"
if did_set; then fail "guest unreadable: a privileged clock set was sent anyway" "log: [$(tr '\n' ' ' < "$SSHLOG")]"
else ok "guest unreadable: no clock set is attempted"; fi
eq "1" "$(n_calls)" "guest unreadable: exactly one attempt, then stop"

# (c) a chatty guest shell. `ssh <host> <cmd>` runs under the guest's zsh, which sources ~/.zshenv
# (and augur's own ~/.augur-env), so anything printed there would otherwise be spliced into the
# number. Rejecting the reading beats setting the clock from a mangled one.
reset_guest; g_offset -5733; G_NOISE=1
sync
eq "0" "$rc" "contaminated read: returns 0"
has "$out" "Could not read the guest's clock over SSH" "contaminated read: treated as unreadable, not parsed"
if did_set; then fail "contaminated read: a clock set was derived from contaminated output" "log: [$(tr '\n' ' ' < "$SSHLOG")]"
else ok "contaminated read: no clock set is derived from it"; fi

section "Tier 1 — call site: the FRESH bring-up path, BEFORE the self-test and the credentials"

require_vz()                    { :; }
macos_vm_exists()               { return 0; }        # base VM + a reusable clone (no fresh clone)
macos_vm_running()              { return 1; }        # take the bring-up path
egress_enabled()                { return 0; }
check_project_conf_approved()   { :; }
start_proxy()                   { :; }
start_gvproxy()                 { :; }
resolve_macos_vm_cpu()          { echo 4; }
resolve_macos_vm_memory_mb()    { echo 8192; }
wait_for_macos_ssh()            { return 0; }
ensure_macos_workspace()        { :; }
ensure_macos_claude_projects()  { :; }
ensure_macos_claude_agents()    { :; }
ensure_macos_claude_profile()   { :; }
ensure_macos_claude_bin()       { :; }
warn_if_macos_profile_stale()   { :; }
warn_if_macos_egress_pinned()   { :; }
scp_to_macos()                  { :; }
vm_cli_rec()                    { return 0; }
VM_CLI=vm_cli_rec
# A marker IN THE SAME LOG as the guest commands, so the clock correction's position relative to the
# egress self-test is one ordering over one list. (tests/36 owns the self-test's own behaviour.)
verify_macos_egress_locked()    { printf 'MARK:egress-self-test\n' >> "$SSHLOG"; }

up_macos() { : > "$SSHLOG"; out="$( cmd_up_macos 2>&1 )"; rc=$?; }

reset_guest; g_offset -5733
up_macos
eq "0" "$rc" "fresh bring-up: \`up --macos\` completes"
has "$out" "is up." "fresh bring-up: the success banner is still printed (control: the path ran)"
has "$out" "Guest clock synchronised with the host" "fresh bring-up: the clock was corrected"
if did_set; then ok "fresh bring-up: the privileged clock set really reached the guest"
else fail "fresh bring-up: no clock set was sent" "log: [$(tr '\n' ' ' < "$SSHLOG")]"; fi

# THE ordering assertion. Everything after the clock read judges an absolute instant: the
# self-test's TLS handshakes evaluate certificate windows, and ~/.augur-env hands over a JWT whose
# nbf/exp the agent checks against this clock.
_clk_at="$(at "$READ_CMD")"
_st_at="$(at 'MARK:egress-self-test')"
_env_at="$(at_re '\.augur-env')"
if [[ -n "$_clk_at" && -n "$_st_at" && -n "$_env_at" && "$_clk_at" -lt "$_st_at" && "$_st_at" -lt "$_env_at" ]]; then
  ok "fresh bring-up: clock BEFORE the self-test BEFORE the credentials (clock@$_clk_at < self-test@$_st_at < env@$_env_at)"
else
  fail "fresh bring-up: the clock correction is not the first thing done in the guest" \
       "clock@${_clk_at:-none} self-test@${_st_at:-none} env@${_env_at:-none}; log: [$(tr '\n' ' ' < "$SSHLOG")]"
fi
# And the set itself must precede the credential push, not merely the read.
_set_at="$(at_re "$SET_RE")"
if [[ -n "$_set_at" && -n "$_env_at" && "$_set_at" -lt "$_env_at" ]]; then
  ok "fresh bring-up: the clock is already CORRECT when the token arrives (set@$_set_at < env@$_env_at)"
else
  fail "fresh bring-up: the token is pushed before the clock is corrected" \
       "set@${_set_at:-none} env@${_env_at:-none}"
fi

# --no-egress skips the self-test (it has no allowlist to be locked to) but NOT the clock: a wrong
# clock is wrong in either egress mode.
reset_guest; g_offset -5733
egress_enabled() { return 1; }
up_macos
egress_enabled() { return 0; }
eq "0" "$rc" "--no-egress: \`up --macos\` completes"
has "$out" "Egress filtering OFF" "--no-egress: the branch was really taken (control)"
if did_set; then ok "--no-egress: the clock is still corrected"
else fail "--no-egress: the clock correction was skipped with the self-test" "log: [$(tr '\n' ' ' < "$SSHLOG")]"; fi

section "Tier 1 — call site: the ALREADY-RUNNING reconcile path"

macos_vm_running() { return 0; }
reset_guest; g_offset -5733
up_macos
eq "0" "$rc" "already-running: still returns 0 (a pure host-side reconcile plus this)"
has "$out" "reconciling host-side state only" "already-running: the reconcile branch was taken (control)"
if did_set; then ok "already-running: a long-lived guest's clock is re-corrected here too"
else fail "already-running: the clock is never corrected on the reconcile path" \
          "a VM kept across \`down --macos\` would never be fixed; log: [$(tr '\n' ' ' < "$SSHLOG")]"; fi
_clk_at="$(at "$READ_CMD")"; _st_at="$(at 'MARK:egress-self-test')"
if [[ -n "$_clk_at" && -n "$_st_at" && "$_clk_at" -lt "$_st_at" ]]; then
  ok "already-running: the clock precedes this path's self-test too (clock@$_clk_at < self-test@$_st_at)"
else
  fail "already-running: the clock does not precede the self-test" "clock@${_clk_at:-none} self-test@${_st_at:-none}"
fi

section "Tier 1 — call sites: \`claude --macos\` and \`shell --macos\` attach WITHOUT going through up"

# Same reason warn_if_macos_profile_stale / warn_if_macos_egress_pinned are called from these two
# sites: on a running VM they skip cmd_up_macos entirely. `claude` is the highest-impact case — the
# launch below hands a JWT to the agent.
macos_vm_running() { return 0; }

reset_guest; g_offset -5733
: > "$SSHLOG"; out="$( cmd_claude_macos 2>&1 )"; rc=$?
eq "0" "$rc" "claude --macos: completes"
if did_set; then ok "claude --macos: corrects the clock on an already-running guest"
else fail "claude --macos: never corrects the clock" "a VM up for days would launch the agent skewed; log: [$(tr '\n' ' ' < "$SSHLOG")]"; fi
_set_at="$(at_re "$SET_RE")"; _launch_at="$(at_re 'zsh -l -c')"
if [[ -n "$_set_at" && -n "$_launch_at" && "$_set_at" -lt "$_launch_at" ]]; then
  ok "claude --macos: the clock is corrected BEFORE the agent launches (set@$_set_at < launch@$_launch_at)"
else
  fail "claude --macos: the agent launches before the clock is corrected" \
       "set@${_set_at:-none} launch@${_launch_at:-none}; log: [$(tr '\n' ' ' < "$SSHLOG")]"
fi

reset_guest; g_offset -5733
: > "$SSHLOG"; out="$( cmd_shell_macos 2>&1 )"; rc=$?
eq "0" "$rc" "shell --macos: completes"
if did_set; then ok "shell --macos: corrects the clock too (git/gh/curl by hand use it)"
else fail "shell --macos: never corrects the clock" "log: [$(tr '\n' ' ' < "$SSHLOG")]"; fi
_set_at="$(at_re "$SET_RE")"; _launch_at="$(at_re 'exec zsh -l')"
if [[ -n "$_set_at" && -n "$_launch_at" && "$_set_at" -lt "$_launch_at" ]]; then
  ok "shell --macos: the clock is corrected BEFORE the shell opens (set@$_set_at < launch@$_launch_at)"
else
  fail "shell --macos: the shell opens before the clock is corrected" \
       "set@${_set_at:-none} launch@${_launch_at:-none}"
fi

section "Tier 1 — source guards: the wiring's POSITION, and the NTP door stays shut"

up_macos_body="$(awk '/^cmd_up_macos\(\)/{f=1} f{print} f&&/^}/{exit}'      "$AUGUR")"
claude_body="$(awk  '/^cmd_claude_macos\(\)/{f=1} f{print} f&&/^}/{exit}'   "$AUGUR")"
shell_body="$(awk   '/^cmd_shell_macos\(\)/{f=1} f{print} f&&/^}/{exit}'    "$AUGUR")"

# Position in the source, not just its effect: an edit that moves the call below the self-test, the
# credential writer or the banner must fail here too. (grep -n indexes within the extracted body.)
# The FRESH-path call specifically: cmd_up_macos has two, and the already-running branch's sits one
# indent level deeper, so the 4-space anchor picks the top-level one. Deleting it makes this empty
# (or, if the anchor is ever loosened, resolves to the reconcile call at a line before the SSH wait)
# — either way the comparison below fails.
c_at="$(printf   '%s\n' "$up_macos_body" | grep -n '^    sync_macos_guest_clock '          | head -n1 | cut -d: -f1)"
ssh_at="$(printf '%s\n' "$up_macos_body" | grep -n '^ *wait_for_macos_ssh '                | head -n1 | cut -d: -f1)"
v_at="$(printf   '%s\n' "$up_macos_body" | grep -n 'verify_macos_egress_locked "\$project_vm"' | tail -n1 | cut -d: -f1)"
env_at="$(printf '%s\n' "$up_macos_body" | grep -n 'augur-env && chmod 600'                | head -n1 | cut -d: -f1)"
ban_at="$(printf '%s\n' "$up_macos_body" | grep -n "success \"VM '"                        | head -n1 | cut -d: -f1)"
if [[ -n "$c_at" && -n "$ssh_at" && -n "$v_at" && -n "$env_at" && -n "$ban_at" \
      && "$ssh_at" -lt "$c_at" && "$c_at" -lt "$v_at" && "$c_at" -lt "$env_at" && "$c_at" -lt "$ban_at" ]]; then
  ok "macOS up syncs the clock AFTER the SSH wait and BEFORE the self-test/credentials/banner (ssh@$ssh_at < clock@$c_at < test@$v_at, env@$env_at, banner@$ban_at)"
else
  fail "macOS up does not sync the clock between the SSH wait and the self-test" \
       "ssh@${ssh_at:-none} clock@${c_at:-none} test@${v_at:-none} env@${env_at:-none} banner@${ban_at:-none}"
fi
if printf '%s\n' "$up_macos_body" | sed -n '/already running/,/^    fi$/p' | grep -q '^ *sync_macos_guest_clock '
then ok "the already-running branch syncs the clock (the only place a long-lived guest is re-corrected)"
else fail "the already-running branch skips the clock sync" "a VM kept across \`down --macos\` would drift forever"; fi
printf '%s\n' "$claude_body" | grep -q '^ *sync_macos_guest_clock ' \
  && ok "cmd_claude_macos syncs the clock (it attaches without going through up)" \
  || fail "cmd_claude_macos does not sync the clock"
printf '%s\n' "$shell_body" | grep -q '^ *sync_macos_guest_clock ' \
  && ok "cmd_shell_macos syncs the clock" \
  || fail "cmd_shell_macos does not sync the clock"

# The rejected alternative, pinned so it cannot be quietly attempted. NTP is UDP/123; the allowlist
# is SOCKS5/TCP names, and the patch does not register the UDP forwarder under --deny-direct at all.
if grep -qiE '(^|[^a-z])(ntp|time\.apple\.com|pool\.ntp\.org)' "$REPO/augur.conf"; then
  fail "augur.conf gained a time server" "NTP is UDP/123 — a TCP/SOCKS name allowlist cannot forward it, and I9 drops UDP"
else
  ok "augur.conf has no time server (the fix uses the host's clock, not an NTP hole)"
fi
if grep -qF 'if !configuration.DenyDirectEgress {' "$REPO/gvproxy/augur-egress.patch" \
   && grep -qF '+		udpForwarder := forwarder.UDP(' "$REPO/gvproxy/augur-egress.patch"; then
  ok "the gvproxy patch still registers the UDP forwarder ONLY without --deny-direct (I9 intact)"
else
  fail "the gvproxy patch's UDP-forwarder guard changed" \
       "I9's 'drops UDP/ICMP' clause is what makes NTP-in-the-guest impossible; a clock fix must not touch it"
fi

finish
