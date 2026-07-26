#!/usr/bin/env bash
# Tier 1 — macOS mode's BOOT EGRESS SELF-TEST (runs anywhere; nothing is ever cloned, booted or
# SSH'd — the "guest" is a scriptable stand-in for ssh_macos).
#
# The defect. INVARIANT I1 is "egress fails closed on every engine", and its shell half is the boot
# self-test. But `verify_egress_locked` had exactly ONE call site — `finish_up`, which only container
# mode reaches — so no macOS production path ever probed the guest's network. `augur status --macos`
# does not close the gap either: it reports pidfile liveness, never reachability. The only live proof
# was `tests/e2e_macos_vm.sh`, which is AUGUR_TEST_LIVE-gated and therefore never runs in CI. Each of
# the three gvproxy flags that IS the enforcement could be deleted from start_gvproxy's argv and
# `up --macos` would still print "Egress restricted to allowlisted domains" and then "VM is up."
#
# What this file pins. CI boots no guest, so the probes themselves cannot be exercised here — that
# half stays live-only, exactly as container mode's does. What IS offline-testable, and is what broke
# in the first place, is the WIRING: that the self-test is invoked on both `up --macos` paths, that a
# NOT-locked verdict ends the bring-up non-zero with the VM, gvproxy and the proxy torn down, and
# that a locked verdict lets bring-up finish. The scriptable guest below also lets each gvproxy-argv
# mutation be replayed as a distinct verdict, so the probe SET is asserted rather than assumed:
#
#   deleting --socks-upstream → an IP-literal TCP connect succeeds   (G_IPLIT)
#   deleting --dns-allowlist  → a non-allowlisted NAME resolves      (G_BADDNS)
#   deleting --deny-direct    → raw UDP answers / ICMP replies       (G_UDP / G_ICMP)
#
# …plus the property that makes the whole thing more than a one-way check: a guest with NO network
# at all fails every negative probe too, so it reads as "secure" unless the POSITIVE half (allowlisted
# egress works) is load-bearing. G_OKDNS/G_HTTPCODE replay that outage.
#
# Every default in reset_guest is a MEASURED value from a live gvproxy-backed guest, not a guess:
# curl to an IP literal exits 28 at its deadline, `dscacheutil` prints nothing for a non-allowlisted
# name and an `ip_address:` line for an allowlisted one, `dig @1.1.1.1` times out, `ping` sees 100%
# loss, and `curl https://api.github.com/` returns 200.
#
# NOTE: container mode's `verify_egress_locked` has NO offline test of its own — its only gate is the
# live, locally-run `tests/22_egress_failclosed.sh`. There was nothing to mirror, so this file is the
# first offline coverage of a boot self-test on either engine.
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/lib.sh"
AUGUR="$REPO/augur"

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

# BOOT-PROOFING (the technique tests/30_macos_vm.sh, 34 and 35 use): point AUGUR_VM_BIN at a path
# that cannot exist BEFORE sourcing, so the resolved $VM_CLI can never be a real augur-vm. The
# recorder installed below replaces it for the assertions; if that override were ever lost, the
# fallback is "command not found", never a cloned or booted VM. Set before the source because
# resolve_vm_cli runs at source time.
export AUGUR_VM_BIN="$TMPD/no-such-augur-vm"

# Pull the REAL verify_macos_egress_locked / cmd_up_macos out of augur without running its dispatch
# tail (AUGUR_SOURCE_ONLY seam), so this can never drift from the shipped functions. Stubs are
# installed AFTER the source on purpose: bash resolves function names at CALL time.
AUGUR_SOURCE_ONLY=1 source "$AUGUR"
set +e                                    # augur enables `set -e`; restore lib.sh assert-and-continue

# Sandbox every path this can write. This runner exports CLAUDE_CODE_OAUTH_TOKEN and has a real
# ~/.gitconfig; neither may be reachable from here (tests/34 and 35 do the same).
HOME="$TMPD/home"; mkdir -p "$HOME"
AUGUR_DIR="$TMPD/augur"
AUGUR_PROXY_DIR="$TMPD/proxy"; mkdir -p "$AUGUR_PROXY_DIR"
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

LOG="$TMPD/calls"       # teardown / reconcile recorder, one anchor line per call
SSHLOG="$TMPD/sshlog"   # every remote command string the self-test issued, in order
: > "$LOG"; : > "$SSHLOG"

# ── Teardown recorders. Asserting the teardown by RECORDED CALLS, not by exit code: an exit code
#    alone stays green when the teardown is deleted (the function still exits 1). ───────────────
vm_cli_rec() { printf '%s\n' "$*" >> "$LOG"; return 0; }
VM_CLI=vm_cli_rec
stop_gvproxy() { echo "stop_gvproxy" >> "$LOG"; }
stop_proxy()   { echo "stop_proxy"   >> "$LOG"; }
logged() { grep -qx "$1" "$LOG" 2>/dev/null; }
teardown_ran() { logged "stop $1" && logged stop_gvproxy && logged stop_proxy; }

# ── The scriptable guest. Each knob is one gvproxy-argv mutation's observable effect. ───────────
G_REACHABLE=1 G_IPLIT=0 G_BADDNS=0 G_UDP=0 G_ICMP=0 G_OKDNS=1 G_HTTPCODE=200
reset_guest() { G_REACHABLE=1 G_IPLIT=0 G_BADDNS=0 G_UDP=0 G_ICMP=0 G_OKDNS=1 G_HTTPCODE=200; }

ssh_macos() {
    local vm="$1"; shift
    local cmd="$*"
    printf '%s\n' "$cmd" >> "$SSHLOG"
    [[ "$G_REACHABLE" == 1 ]] || return 255            # what ssh exits when it cannot connect
    case "$cmd" in
        *" true")
            return 0 ;;
        *"dscacheutil"*"'example.com'"*)               # the NON-allowlisted name
            [[ "$G_BADDNS" == 1 ]] && printf 'name: example.com\nip_address: 93.184.216.34\n'
            return 0 ;;                                # dscacheutil exits 0 either way
        *"dscacheutil"*"'${_SELFTEST_HOST}'"*)         # the allowlisted name
            [[ "$G_OKDNS" == 1 ]] && printf 'name: %s\nip_address: 140.82.121.6\n' "$_SELFTEST_HOST"
            return 0 ;;
        *"dig "*)
            [[ "$G_UDP" == 1 ]] && echo "93.184.216.34"
            return 0 ;;
        *"ping "*)
            [[ "$G_ICMP" == 1 ]] && return 0
            return 2 ;;
        *"%{http_code}"*)                              # the allowlisted request
            printf '%s' "$G_HTTPCODE"
            [[ -n "$G_HTTPCODE" && "$G_HTTPCODE" != "000" ]] && return 0
            return 7 ;;
        *"curl "*)                                     # everything else curl'd is an IP literal
            [[ "$G_IPLIT" == 1 ]] && return 0
            return 28 ;;
        *".augur-env"*)                                # the credential push (cmd_up_macos sections)
            cat >/dev/null; return 0 ;;
        "/bin/date +%s")                               # the guest-clock sync that now precedes the
            printf '%s\n' "$(date +%s)"; return 0 ;;    # self-test on both up paths (tests/38 owns
                                                       # it). Answering with the host's own clock
                                                       # models an already-correct guest, so no
                                                       # privileged set follows and this fixture
                                                       # stays about egress.
        *)
            echo "UNEXPECTED PROBE: $cmd" >&2; return 1 ;;
    esac
}

# Run the REAL function the way cmd_up_macos runs it: under `set -e`. Without that the `|| true`
# guards on its command substitutions are unobservable, and a missing one would abort `up` on the
# HAPPY path — the opposite of fail-closed.
selftest() {   # sets $out / $rc; truncates both logs first
    : > "$LOG"; : > "$SSHLOG"
    out="$( set -e; verify_macos_egress_locked testvm 2>&1 )"; rc=$?
}
probed() { grep -qF "$1" "$SSHLOG"; }   # was this exact remote command shape actually issued?

section "Tier 1 — fixture controls (a scripted guest that could not fail is no test at all)"

: > "$LOG"; "$VM_CLI" stop self-check >/dev/null 2>&1; stop_gvproxy; stop_proxy
if teardown_ran self-check; then ok "the teardown recorders capture stop/stop_gvproxy/stop_proxy (control)"
else fail "the teardown recorders do not capture a teardown" "every teardown assertion below would be vacuous"; fi

reset_guest
: > "$SSHLOG"
ssh_macos testvm "export PATH=/usr/bin; curl -s --max-time 4 -o /dev/null 'https://1.1.1.1'" >/dev/null 2>&1
_locked_rc=$?
G_IPLIT=1
ssh_macos testvm "export PATH=/usr/bin; curl -s --max-time 4 -o /dev/null 'https://1.1.1.1'" >/dev/null 2>&1
_leaky_rc=$?
reset_guest
if [[ "$_locked_rc" -ne 0 && "$_leaky_rc" -eq 0 ]]; then
  ok "the scripted guest really flips an IP-literal connect from failing to succeeding (control)"
else
  fail "the scripted guest does not model an IP-literal leak" "locked rc=$_locked_rc leaky rc=$_leaky_rc"
fi

section "Tier 1 — a correctly locked guest PASSES, tears nothing down, and probes both directions"

reset_guest
selftest
eq "0" "$rc" "locked guest: the self-test returns 0 under \`set -e\` (\`up\` continues past it)"
has "$out" "Egress self-test passed" "locked guest: says so, in the shape verify_egress_locked does"
if [[ -s "$LOG" ]]; then fail "locked guest: something was torn down anyway" "$(cat "$LOG")"
else ok "locked guest: nothing is stopped (no VM, no gvproxy, no proxy)"; fi
hasnt "$out" "UNEXPECTED PROBE" "locked guest: every probe the function issues is one this test models"

# The probe SET, asserted by what was actually issued into the guest — not by grepping augur's
# source, where an unanchored substring match would pass with the logic deleted.
if probed "'https://1.1.1.1'";    then ok "probes an IPv4 literal on :443 (only --socks-upstream severs it)"
else fail "no IPv4-literal probe" "$(cat "$SSHLOG")"; fi
if probed "'https://8.8.8.8'";    then ok "probes a SECOND IPv4 literal (one blackholed address cannot fake isolation)"
else fail "no second IPv4-literal probe" "$(cat "$SSHLOG")"; fi
if probed "[2606:4700:4700::1111]"; then ok "probes an IPv6 literal (a v6-only leak the v4 probes would miss)"
else fail "no IPv6-literal probe" "$(cat "$SSHLOG")"; fi
if probed "dscacheutil -q host -a name 'example.com'"; then
  ok "probes a REAL non-allowlisted name through the guest's own resolver (only --dns-allowlist severs it)"
else fail "no non-allowlisted DNS probe" "$(cat "$SSHLOG")"; fi
if probed "@1.1.1.1";             then ok "probes direct UDP at a public resolver (only --deny-direct drops it)"
else fail "no direct-UDP probe" "$(cat "$SSHLOG")"; fi
if probed "ping -c 1";            then ok "probes ICMP (the other forwarder --deny-direct refuses to register)"
else fail "no ICMP probe" "$(cat "$SSHLOG")"; fi
if probed "dscacheutil -q host -a name '$_SELFTEST_HOST'"; then
  ok "POSITIVE half: the allowlisted name must resolve (a closed-but-dead resolver is not 'locked')"
else fail "no allowlisted-DNS probe" "$(cat "$SSHLOG")"; fi
if probed "https://$_SELFTEST_HOST/"; then
  ok "POSITIVE half: the allowlisted host must answer with an HTTP status (the SOCKS forward works)"
else fail "no allowlisted-request probe" "$(cat "$SSHLOG")"; fi

# PATH pinning, asserted behaviourally. `down --macos` keeps the clone and ~/.augur-env puts
# $HOME/.local/bin FIRST in every guest shell's PATH, so an unpinned probe could be shadowed by a
# stub a prior guest session planted — and would then report whatever the attacker wanted.
if [[ -s "$SSHLOG" ]]; then ok "the guest was contacted at all (control for the pin check below)"
else fail "no guest commands were issued" "the PATH-pin assertion would be vacuous"; fi
_unpinned="$(grep -cv 'export PATH=/usr/bin:/bin:/usr/sbin:/sbin;' "$SSHLOG")"
eq "0" "$_unpinned" "every guest command pins PATH to system dirs (no ~/.local/bin shadowing)"

section "Tier 1 — each gvproxy-argv mutation produces a DISTINCT detected leak, and a teardown"

# One case per flag. Each is anchored on a message ONLY that condition can print — never on a
# string the passing run also prints — and each asserts the teardown by recorded calls.
leak_case() {   # leak_case <label> <needle>
    if [[ "$rc" -ne 0 ]]; then ok "$1: the self-test exits non-zero"
    else fail "$1: the self-test exited 0" "the leak was not detected at all"; fi
    has "$out" "$2" "$1: names the specific leak it observed"
    hasnt "$out" "Egress self-test passed" "$1: does NOT also claim the self-test passed"
    if teardown_ran testvm; then ok "$1: the VM, gvproxy AND the proxy are all torn down"
    else fail "$1: the teardown did not run" "log: [$(tr '\n' ' ' < "$LOG")]"; fi
}

reset_guest; G_IPLIT=1;  selftest; leak_case "--socks-upstream deleted" "reached https://1.1.1.1 directly"
reset_guest; G_BADDNS=1; selftest; leak_case "--dns-allowlist deleted"  "resolved non-allowlisted example.com"
reset_guest; G_UDP=1;    selftest; leak_case "--deny-direct deleted (UDP)"  "resolved via direct UDP to 1.1.1.1"
reset_guest; G_ICMP=1;   selftest; leak_case "--deny-direct deleted (ICMP)" "ICMP reply from 1.1.1.1"

section "Tier 1 — a guest with NO network must NOT read as 'secure' (the positive half is load-bearing)"

# THE property a direct-egress-only probe gets wrong: with the datapath dead, every negative probe
# above "passes". Only the positive half can tell "locked" from "unplugged" apart.
reset_guest; G_OKDNS=0; G_HTTPCODE=""
selftest
leak_case "total network outage" "cannot resolve allowlisted $_SELFTEST_HOST"

# …and the narrower half of the same idea: DNS works, the SOCKS forward does not. Without the
# request probe this would pass on a dead proxy.
reset_guest; G_HTTPCODE="000"
selftest
leak_case "proxy forward dead (DNS still resolves)" "allowlisted egress to $_SELFTEST_HOST does not work"

section "Tier 1 — an UNVERIFIABLE datapath fails closed, and says which"

reset_guest; G_REACHABLE=0
selftest
leak_case "guest unreachable over SSH" "egress cannot be VERIFIED"
# The transport check must short-circuit: probing on regardless would report an isolated guest.
eq "1" "$(wc -l < "$SSHLOG" | tr -d ' ')" "guest unreachable: exactly one attempt (the liveness check), then stop"

section "Tier 1 — call site: the FRESH bring-up path (before the credentials, before the banner)"

require_vz()                    { :; }
macos_vm_running()              { return 1; }                                  # take the bring-up path
macos_vm_exists()               { return 0; }                                  # base VM + a reusable clone
egress_enabled()                { return 0; }
check_project_conf_approved()   { echo "gate" >> "$LOG"; }
start_proxy()                   { echo "start_proxy $1" >> "$LOG"; }
start_gvproxy()                 { echo "start_gvproxy" >> "$LOG"; }
resolve_macos_vm_cpu()          { echo 4; }
resolve_macos_vm_memory_mb()    { echo 8192; }
wait_for_macos_ssh()            { return 0; }
ensure_macos_workspace()        { echo "wire:workspace" >> "$LOG"; }
ensure_macos_claude_projects()  { :; }
ensure_macos_claude_agents()    { :; }
ensure_macos_claude_profile()   { :; }
ensure_macos_claude_bin()       { :; }
scp_to_macos()                  { :; }
PV="$(macos_project_vm)"

up_macos() {   # sets $out / $rc; truncates both logs first
    : > "$LOG"; : > "$SSHLOG"
    out="$( cmd_up_macos 2>&1 )"; rc=$?
}

reset_guest
up_macos
eq "0" "$rc" "locked guest: \`up --macos\` completes"
has "$out" "Egress self-test passed" "locked guest: the self-test fired on the bring-up path"
has "$out" "is up."                  "locked guest: the success banner is still printed"
# Order inside the captured output: the tripwire must precede the banner, or a leak would be
# announced after the operator was told the VM was ready.
_st_at="$(printf '%s\n' "$out" | grep -n "Egress self-test passed" | head -n1 | cut -d: -f1)"
_up_at="$(printf '%s\n' "$out" | grep -n "is up\."                 | head -n1 | cut -d: -f1)"
if [[ -n "$_st_at" && -n "$_up_at" && "$_st_at" -lt "$_up_at" ]]; then
  ok "locked guest: the self-test runs BEFORE the success banner (self-test@$_st_at < banner@$_up_at)"
else
  fail "locked guest: the self-test does not precede the banner" "self-test@${_st_at:-none} banner@${_up_at:-none}"
fi
# …and before the credential injection. Both go through ssh_macos, so their ORDER in SSHLOG is the
# assertion: a guest whose egress is not contained must not be handed an Anthropic or gh token.
_probe_at="$(grep -n "ping -c 1" "$SSHLOG" | head -n1 | cut -d: -f1)"
_cred_at="$( grep -n ".augur-env" "$SSHLOG" | head -n1 | cut -d: -f1)"
if [[ -n "$_probe_at" && -n "$_cred_at" && "$_probe_at" -lt "$_cred_at" ]]; then
  ok "locked guest: every probe precedes the ~/.augur-env push (probe@$_probe_at < credentials@$_cred_at)"
else
  fail "locked guest: the self-test does not precede the credential push" \
       "probe@${_probe_at:-none} credentials@${_cred_at:-none}"
fi

reset_guest; G_BADDNS=1
up_macos
if [[ "$rc" -ne 0 ]]; then ok "leaky guest: \`up --macos\` exits non-zero"
else fail "leaky guest: \`up --macos\` exited 0" "the bring-up continued past a detected leak"; fi
hasnt "$out" "is up." "leaky guest: the success banner is NEVER printed (this is the new failure mode)"
if teardown_ran "$PV"; then ok "leaky guest: the VM, gvproxy AND the proxy are torn down (nothing stranded)"
else fail "leaky guest: the teardown did not run" "log: [$(tr '\n' ' ' < "$LOG")]"; fi
# The security point of running the self-test where it runs: no token ever reaches a leaky guest.
if grep -q ".augur-env" "$SSHLOG"; then
  fail "leaky guest: credentials were pushed anyway" "$(cat "$SSHLOG")"
else
  ok "leaky guest: ~/.augur-env is never written (no token enters an uncontained guest)"
fi

# --no-egress has no allowlist to be locked to, so the self-test must not run — and must not be
# able to fail a bring-up that never started gvproxy or the proxy.
reset_guest; G_IPLIT=1                     # would be a screaming leak if the self-test ran
egress_enabled() { return 1; }
up_macos
egress_enabled() { return 0; }
eq "0" "$rc" "--no-egress: \`up --macos\` completes"
hasnt "$out" "Running egress self-test" "--no-egress: the self-test is skipped entirely"
has "$out" "Egress filtering OFF" "--no-egress: still says what it turned off (control: the branch was taken)"

section "Tier 1 — call site: the ALREADY-RUNNING reconcile path (container's finish_up runs there too)"

macos_vm_running() { return 0; }

reset_guest
up_macos
eq "0" "$rc" "already-running + locked: still returns 0 (no fingerprint ⇒ still no drift refusal)"
has "$out" "reconciling host-side state only" "already-running: the reconcile branch was taken (control)"
has "$out" "Egress self-test passed"          "already-running: I1's tripwire fires on this path too"
if logged "start_proxy 127.0.0.1"; then ok "already-running: the proxy is still revived first (the self-test verifies THAT)"
else fail "already-running: start_proxy was not called" "log: [$(tr '\n' ' ' < "$LOG")]"; fi
# The self-test on this path probes the LIVE guest — asserted on the probes actually issued, not on
# the absence of a boot (tests/34 owns "nothing is booted", and $LOG has an async `vm run` writer).
if probed "dscacheutil -q host -a name '$_SELFTEST_HOST'"; then
  ok "already-running: the probes are issued against the live guest, not a freshly booted one"
else fail "already-running: no probe reached the guest" "sshlog: [$(tr '\n' ' ' < "$SSHLOG")]"; fi

reset_guest; G_UDP=1
up_macos
if [[ "$rc" -ne 0 ]]; then ok "already-running + leaky: exits non-zero (ADR-0010 accepts ending a live session on a DETECTED leak)"
else fail "already-running + leaky: exited 0" "a live leak on the reconcile path went unreported"; fi
if teardown_ran "$PV"; then ok "already-running + leaky: the live VM, gvproxy and proxy are torn down"
else fail "already-running + leaky: the teardown did not run" "log: [$(tr '\n' ' ' < "$LOG")]"; fi

section "Tier 1 — source guards: the wiring is pinned where behaviour cannot see it"

up_macos_body="$(awk '/^cmd_up_macos\(\)/{f=1} f{print} f&&/^}/{exit}' "$AUGUR")"
selftest_fn="$(awk '/^verify_macos_egress_locked\(\)/{f=1} f{print} f&&/^}/{exit}' "$AUGUR")"

# Position in the source, not just its effect: an edit that moves the call below the credential
# writer or the banner must fail here too. (grep -n indexes within the extracted function body.)
v_at="$(printf  '%s\n' "$up_macos_body" | grep -n 'verify_macos_egress_locked "\$project_vm"' | tail -n1 | cut -d: -f1)"
env_at="$(printf '%s\n' "$up_macos_body" | grep -n 'augur-env && chmod 600'   | head -n1 | cut -d: -f1)"
ban_at="$(printf '%s\n' "$up_macos_body" | grep -n "success \"VM '"           | head -n1 | cut -d: -f1)"
ssh_at="$(printf '%s\n' "$up_macos_body" | grep -n '^ *wait_for_macos_ssh '   | head -n1 | cut -d: -f1)"
if [[ -n "$v_at" && -n "$env_at" && -n "$ban_at" && -n "$ssh_at" \
      && "$ssh_at" -lt "$v_at" && "$v_at" -lt "$env_at" && "$v_at" -lt "$ban_at" ]]; then
  ok "macOS up self-tests AFTER the SSH wait and BEFORE the credentials/banner (ssh@$ssh_at < test@$v_at < env@$env_at, banner@$ban_at)"
else
  fail "macOS up does not self-test between the SSH wait and the credential push" \
       "ssh@${ssh_at:-none} test@${v_at:-none} env@${env_at:-none} banner@${ban_at:-none}"
fi
if printf '%s\n' "$up_macos_body" | sed -n '/already running/,/^    fi$/p' | grep -q 'verify_macos_egress_locked'; then
  ok "the already-running branch calls the self-test (I1 says every \`up\`, and container mode does)"
else
  fail "the already-running branch skips the self-test" "I1's tripwire would not fire on that path"
fi
# The teardown must name all three, in the shape the SSH-timeout path above it already uses.
printf '%s\n' "$selftest_fn" | grep -q '"\$VM_CLI" stop "\$vm"' \
  && ok "the self-test's teardown stops the VM"    || fail "the self-test's teardown does not stop the VM"
printf '%s\n' "$selftest_fn" | grep -q '^ *stop_gvproxy$' \
  && ok "the self-test's teardown stops gvproxy"   || fail "the self-test's teardown does not stop gvproxy"
printf '%s\n' "$selftest_fn" | grep -q '^ *stop_proxy$' \
  && ok "the self-test's teardown stops the proxy" || fail "the self-test's teardown does not stop the proxy"
# The positive half must target a MANAGED-BASELINE domain: the already-running path warns that
# gvproxy snapshots its DNS allowlist at boot, so a project-conf domain could be allowlisted
# host-side and still unresolvable in a live guest — a false leak that tears down a working VM.
if grep -qx "$_SELFTEST_HOST" "$REPO/augur.conf"; then
  ok "the positive probe targets '$_SELFTEST_HOST', which augur.conf ships in the managed baseline"
else
  fail "the positive probe's host is not in the managed baseline" \
       "'$_SELFTEST_HOST' is not an exact line in augur.conf — a boot-pinned DNS allowlist could make it a false leak"
fi

finish
