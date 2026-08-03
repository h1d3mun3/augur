#!/usr/bin/env bash
# tests/e2e_macos_vm.sh — LOCAL pre-release gate for macOS VM mode. NOT a CI job.
#
# Why local-only: this boots a full macOS VM via Virtualization.framework and runs xcodebuild
# test inside it. No GitHub-hosted runner can do that — their arm64 macOS runners are themselves
# VZ guests with no nested virtualization. It's also slow (~75 min cold VM build, 70 GB+) and
# needs Apple-signed IPSW/XIP that can't live in CI. The maintainer dogfoods this datapath daily,
# so a real boot+build already runs by hand every day; this target makes it a repeatable gate to
# run BEFORE tagging a release. The fail-closed *security* guarantee is proven for free on Linux
# in CI (tests/22_egress_failclosed.sh); this is the macOS-VM variant of the same assertions plus
# the build itself.
#
# Usage (from your project directory, or set AUGUR_E2E_PROJECT):
#   make e2e                                              # boot + mount/testmanagerd/egress; xcodebuild self-skips
#   AUGUR_E2E_PROJECT=/path/to/app AUGUR_E2E_SCHEME=App make e2e   # + real xcodebuild test inside the VM
#
# shellcheck disable=SC2088  # `~` in the vssh strings is expanded by the GUEST shell, not the host
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/lib.sh"
section "macOS VM mode — pre-release E2E gate (LOCAL only, not CI)"

AUGUR="$REPO/augur"
PROJECT="${AUGUR_E2E_PROJECT:-$REPO}"     # where xcodebuild test runs; defaults to the augur repo
SCHEME="${AUGUR_E2E_SCHEME:-}"            # set to run the real xcodebuild test; else that step self-skips

# ── Guards: a real VM boot only on a configured macOS host, and only when asked ──────────────
if [[ "$(uname -s)" != "Darwin" ]]; then
  skip "macOS VM e2e" "not a macOS host — this gate is local-only by design"; finish; exit $?
fi
if ! command -v augur-vm >/dev/null 2>&1 && [[ ! -x "$HOME/.augur/augur-vm" ]]; then
  skip "macOS VM e2e" "augur-vm backend not built (run: bash install)"; finish; exit $?
fi
if [[ "${AUGUR_TEST_LIVE:-0}" != "1" ]]; then
  skip "macOS VM e2e" "set AUGUR_TEST_LIVE=1 (or run 'make e2e') — this boots a real VM"; finish; exit $?
fi
if [[ ! -d "$PROJECT" ]]; then
  fail "project dir exists" "AUGUR_E2E_PROJECT='$PROJECT' is not a directory"; finish; exit $?
fi

# Reuse augur's OWN ssh/derivation (AUGUR_SOURCE_ONLY seam) so this gate can never drift from the
# real datapath it is meant to prove. cd into the project FIRST so every per-project value augur
# derives (VM name, gvproxy SSH-forward port, share name) matches the `up` below.
cd "$PROJECT" || { fail "cannot cd into project '$PROJECT'"; finish; exit $?; }
AUGUR_SOURCE_ONLY=1 source "$AUGUR"
set +e                                    # augur enables `set -e`; restore lib.sh assert-and-continue
vm="$(macos_project_vm)"
# augur binds MACOS_SHARE ABOVE the AUGUR_SOURCE_ONLY return, so the `source` above already set it
# — and because the `cd` into $PROJECT happened first, it is already the value `up --macos` will use
# for this PROJECT. Recomputed here anyway, from augur's own workspace_slug: this line is what makes
# that agreement checkable rather than assumed, and it is cheap. It used to be load-bearing — the
# assignment lived in the dispatch tail, sourcing left MACOS_SHARE unset, and under the sourced
# augur's `set -u` an unbound MACOS_SHARE aborted this script before any assertion ran. This gate is
# one of the two sourcing contexts that window covered; the same unset variable silently killed the
# share sweep for anything that reached it from here. See tests/41's first section.
MACOS_SHARE="workspace-$(workspace_slug)"
[[ -n "$vm" && -n "$MACOS_SHARE" ]] || { fail "derive VM + share names from augur" "vm='$vm' share='$MACOS_SHARE'"; finish; exit $?; }
vssh() { ssh_macos "$vm" "$@"; }          # run a command in the VM via augur's real SSH path

# ── Boot the VM with egress ON (default; --macos is a TRAILING flag) ─────────────────────────
cleanup() { rm -rf "$PROJECT/.refresh-lab"; ( cd "$PROJECT" && bash "$AUGUR" down --macos ) >/dev/null 2>&1; }
trap cleanup EXIT
section "Boot VM (egress on)"
upout="$( cd "$PROJECT" && AUGUR_ACCEPT_PROJECT_CONF=1 bash "$AUGUR" up --macos 2>&1 )"; uprc=$?
if [[ $uprc -ne 0 ]]; then
  fail "augur up --macos (egress on) booted the VM" "augur up exited $uprc — last lines:
$(printf '%s\n' "$upout" | tail -n 12)"
  finish; exit $?
fi
ok "augur up --macos (egress on) booted '$vm'"
if vssh true >/dev/null 2>&1; then ok "VM reachable over SSH"
else fail "VM not reachable over SSH"; finish; exit $?; fi

# ── virtiofs mount + testmanagerd (the two things xcodebuild test needs) ─────────────────────
section "virtiofs mount + testmanagerd reachability"
if vssh "cd ~/${MACOS_SHARE} && test -n \"\$(ls -A ~/${MACOS_SHARE} 2>/dev/null)\""; then
  ok "virtiofs share mounted and populated at ~/${MACOS_SHARE} (host project visible in guest)"
else
  fail "virtiofs share missing/empty at ~/${MACOS_SHARE}" "the workspace mount is not reachable in the guest"
fi
# xcodebuild test needs testmanagerd in a real GUI session — a headless SSH login has none unless
# augur bootstrapped one. Probe the launchd service (two forms, in case the label path differs).
if vssh "launchctl print gui/\$(id -u)/com.apple.testmanagerd >/dev/null 2>&1 || launchctl list 2>/dev/null | grep -q testmanagerd"; then
  ok "testmanagerd reachable in the guest session"
else
  fail "testmanagerd not reachable in the guest" "xcodebuild test will hang/fail (no GUI session bootstrap)"
fi

# ── xcodebuild test inside the VM (the heavy E2E; needs a scheme) ─────────────────────────────
section "xcodebuild test (inside the VM)"
if [[ -z "$SCHEME" ]]; then
  skip "xcodebuild test" "set AUGUR_E2E_SCHEME=<scheme> (+ AUGUR_E2E_PROJECT) to run the real build inside the VM"
else
  if vssh "cd ~/${MACOS_SHARE} && xcodebuild test -scheme '${SCHEME}' -destination 'platform=macOS' -quiet"; then
    ok "xcodebuild test passed for scheme '${SCHEME}' inside the VM"
  else
    fail "xcodebuild test failed for scheme '${SCHEME}' inside the VM"
  fi
fi

# ── VM-mode egress fail-closed (the macOS-VM variant of verify_egress_locked) ────────────────
# In VM mode egress is transparent: gvproxy is the guest's only NIC and forwards all guest TCP to
# augur-proxy's SOCKS5 (the allowlist decision point). The guest uses plain curl (no HTTP_PROXY);
# the proxy decides. A non-allowlisted/IP-literal connection is denied by closing the socket, so
# curl simply fails (unlike the container CONNECT path, which returns a clean 403).
section "VM-mode egress fail-closed"
acode="$(vssh "curl -s -o /dev/null -w '%{http_code}' --max-time 30 https://api.github.com/" 2>/dev/null)"
if [[ "$acode" =~ ^[23][0-9][0-9]$ ]]; then
  ok "allowlisted domain reachable in the VM (api.github.com → HTTP $acode)"
else
  fail "allowlisted domain NOT reachable in the VM" "api.github.com returned '$acode' (proxy/datapath broken?)"
fi
if vssh "curl -s -o /dev/null --max-time 15 https://example.com/" >/dev/null 2>&1; then
  fail "non-allowlisted domain was reachable in the VM (FAIL-OPEN)" "example.com should be severed by the proxy"
else
  ok "non-allowlisted domain blocked in the VM (example.com severed by the proxy)"
fi
if vssh "curl -s -o /dev/null --max-time 10 https://1.1.1.1" >/dev/null 2>&1; then
  fail "IP-literal direct egress reachable in the VM (routing not severed)" "https://1.1.1.1 should be denied"
else
  ok "IP-literal direct egress severed in the VM (no raw-routing bypass)"
fi

# ── ARM A: reconcile a RUNNING guest (the second `up`) ────────────────────────────────────────
# Until this arm existed, this gate called `up --macos` exactly ONCE, so the already-running
# reconcile branch had ZERO live coverage on this engine — and it is not a minor branch: it is where
# a revoked allowlist reaches a live proxy, where the guest clock is re-corrected, and where the
# boot self-test re-runs against a guest that is already up. Container mode has live evidence for
# its half (`make egress` asserts "boot self-test re-ran on the reused container"); macOS had none.
#
# The branch was in fact only ever entered by ACCIDENT: on 2026-07-26 two consecutive runs of this
# script hit it because a stale running VM happened to be left over, and that is how the silent-exit
# defect fixed in #137 was found. An accident is not coverage. This arm enters it deliberately.
#
# The clock assertion is a NEGATIVE one on purpose. sync_macos_guest_clock is silent when the guest
# is already within tolerance (`return 0`, no output), so "it printed something" cannot be asserted.
# What CAN be asserted is that it did not report the failure it reports when SSH is unusable — which
# is precisely the symptom the observed defect showed on this branch, one line before dying.
section "Reconcile a running guest (second up --macos)"
reout="$( cd "$PROJECT" && AUGUR_ACCEPT_PROJECT_CONF=1 bash "$AUGUR" up --macos 2>&1 )"; rerc=$?
if [[ $rerc -eq 0 ]]; then
  ok "a second augur up --macos against the running VM succeeds"
else
  fail "a second augur up --macos against the running VM succeeds" "exited $rerc — last lines:
$(printf '%s\n' "$reout" | tail -n 12)"
fi
if [[ "$reout" == *"already running — reconciling host-side state only"* ]]; then
  ok "it took the reconcile branch (not a fresh boot)"
else
  fail "it took the reconcile branch" "the reconcile warning is absent — this arm proved nothing:
$(printf '%s\n' "$reout" | tail -n 12)"
fi
if [[ "$reout" == *"Egress self-test passed"* ]]; then
  ok "the boot self-test RE-RAN on the already-running guest (I1 gates reuse on this engine too)"
else
  fail "the boot self-test re-ran on the already-running guest" "no passing self-test verdict:
$(printf '%s\n' "$reout" | tail -n 12)"
fi
if [[ "$reout" != *"Could not read the guest's clock over SSH"* ]]; then
  ok "the guest clock was readable over SSH on the reconcile path"
else
  fail "the guest clock was readable over SSH on the reconcile path" "SSH to the guest is broken on this branch — the exact symptom that preceded #137's silent exit"
fi
if macos_vm_running "$vm"; then ok "the VM is still running after the reconcile (nothing was torn down)"
else fail "the VM is still running after the reconcile" "the reconcile stopped the VM"; fi
if vssh true >/dev/null 2>&1; then ok "the VM is still reachable over SSH after the reconcile"
else fail "the VM is still reachable over SSH after the reconcile"; fi


# ── Shared-file cache refresh (#124 / #135) ───────────────────────────────────────────────────
# The defect: a macOS guest's virtiofs client serves STALE FILE DATA after a host-side edit, on every
# share, with no timeout — measured 904.9 s stale, then fresh 10.3 s after a forced vnode reclaim.
# The mitigation (ADR-0016) has a host half and a guest half and only a real host can exercise both:
# offline tests drive the wiring with stubs, and no stub can reproduce a virtiofs cache.
#
# The headline arm is the one that needs NO augur command at all. The continuous refresher is the
# only reason a host edit reaches a running guest, so if it works, an edit made here becomes visible
# in the guest within one interval with nobody attaching to anything.
section "Shared-file refresh — a host edit reaches a RUNNING guest"
LAB="$PROJECT/.refresh-lab"; GLAB="~/${MACOS_SHARE}/.refresh-lab"
mkdir -p "$LAB"
printf 'MARK-A\n' > "$LAB/f1"
if [[ "$(vssh "cat ${GLAB}/f1" 2>/dev/null | tr -d '\r\n')" == "MARK-A" ]]; then
  ok "the guest can see the lab file (precondition)"
else
  fail "the guest can see the lab file" "nothing below can be interpreted without this"
fi
printf 'MARK-B\n' > "$LAB/f1"                       # same length: exactly the shape #124 reported
_iv="${_MACOS_REFRESH_INTERVAL:-5}"
_saw=""
for _try in 1 2 3 4 5 6; do
  sleep "$_iv"
  _saw="$(vssh "cat ${GLAB}/f1" 2>/dev/null | tr -d '\r\n')"
  [[ "$_saw" == "MARK-B" ]] && break
done
if [[ "$_saw" == "MARK-B" ]]; then
  ok "a host edit became visible in the running guest within $((_try * _iv))s, with no augur command"
else
  fail "a host edit became visible in the running guest" "still '$_saw' after $((6 * _iv))s — the refresher is not working, which is the whole point of ADR-0016"
fi

# The silent-truncation guard. A guest whose cached size is the old, smaller one maps too few bytes,
# invalidates only those pages, and the read comes back EOF-clamped — the first N bytes OF THE NEW
# CONTENT. The file then looks valid and is quietly truncated, which is worse than being stale.
# Measured offline; this is the live form. A whole-file hash is the only oracle that sees it.
{ printf 'HEAD-B'; head -c 262144 /dev/zero | tr '\0' 'b'; printf 'TAIL-B'; } > "$LAB/f2"
_hostsha="$(shasum -a 256 "$LAB/f2" | cut -d' ' -f1)"
printf 'x\n' > "$LAB/f2.touch"                       # ensure the sweep has work even if f2 raced
_gsha=""
for _try in 1 2 3 4 5 6; do
  sleep "$_iv"
  _gsha="$(vssh "shasum -a 256 ${GLAB}/f2" 2>/dev/null | cut -d' ' -f1)"
  [[ "$_gsha" == "$_hostsha" ]] && break
done
if [[ "$_gsha" == "$_hostsha" ]]; then
  ok "a 256 KiB file is refreshed WHOLE (no EOF-clamped truncation)"
else
  fail "a 256 KiB file is refreshed whole" "guest sha=$_gsha host sha=$_hostsha — a partial refresh returns valid-looking, truncated content"
fi

# The refresher is a real host-side process with a pidfile, like the proxy and gvproxy.
if [[ -f "$(share_refresher_pidfile)" ]] && share_refresher_running; then
  ok "the share refresher is running (pid $(cat "$(share_refresher_pidfile)"))"
else
  fail "the share refresher is running" "no live pidfile at $(share_refresher_pidfile)"
fi

# The tripwire's verdict, from the `up` output already captured above. Three outcomes are possible
# and they mean different things — a BROKEN one is the signal that this guest OS changed under us.
case "$reout" in
  *"SELF-TEST FAILED"*)
    fail "the freshness self-test passed" "it reported BROKEN — msync no longer refreshes on this guest OS; see ADR-0016 §5" ;;
  *"Shared-file refresh verified"*)
    ok "the freshness self-test reproduced staleness and then cleared it" ;;
  *"no longer need"*)
    skip "the freshness self-test" "it reports the guest was ALREADY current before any msync — the platform may be fixed (ADR-0016 §5)" ;;
  *)
    # Three of the four outcomes that land here DO print something — no transport, an unreadable
    # probe and an empty read all emit "Could not verify the shared-file refresh: …". Reporting "no
    # verdict at all" for those sent an investigator looking for silence when the output already
    # contained the answer, and cost a real debugging session. Surface the line; claim silence only
    # when there genuinely is none. Still a `fail` either way — this is a release gate, and a
    # mitigation that could not be verified is not a mitigation that passed.
    _unv="$(printf '%s\n' "$reout" | grep -m1 'Could not verify the shared-file refresh' || true)"
    if [[ -n "$_unv" ]]; then
      fail "the freshness self-test reached a verdict" "it could not measure anything, and said so: ${_unv#*] }"
    else
      fail "the freshness self-test ran" "no verdict of any kind in the up output — not even a \`Could not verify\` line"
    fi ;;
esac

# The gh-config share was removed: mounted, never wired, and carrying the host's real config.
if vssh "test -d '/Volumes/My Shared Files/gh-config'" >/dev/null 2>&1; then
  fail "the gh-config share is gone from the guest" "it is still mounted — the host's config.yml/hosts.yml are readable there for no working feature"
else
  ok "the gh-config share is gone from the guest"
fi

# ── Bounded teardown (the #64 guarantee, end-to-end on a real VM) ─────────────────────────────
# The base/build VM maintenance paths reap their backgrounded `augur-vm run` via
# stop_and_reap_macos_vm (unit-tested against a SIGTERM-ignoring stand-in in 31_macos_teardown.sh).
# Here we assert the real-VM teardown a user actually runs is bounded: a regression that
# reintroduced a raw `kill "$vm_pid"; wait "$vm_pid"` on a VM that masks SIGTERM (never finishing
# its ACPI shutdown mid-boot) would blow this budget instead of returning. `augur-vm stop`
# SIGKILLs after 30s, so a real down (graceful ACPI, then the CLI returns) is well under 90s.
section "Bounded teardown (no hang)"
down_t0=$SECONDS
( cd "$PROJECT" && bash "$AUGUR" down --macos ) >/dev/null 2>&1
down_el=$(( SECONDS - down_t0 ))
if (( down_el < 90 )); then
  ok "augur down --macos completed in ${down_el}s (bounded — no teardown hang)"
else
  fail "augur down --macos took ${down_el}s" "possible unbounded teardown hang (regression in the reap path)"
fi
if ! share_refresher_running; then ok "…and the share refresher is stopped with it (no orphan SSHing at a dead guest)"
else fail "the share refresher is stopped with the VM" "pid $(cat "$(share_refresher_pidfile)" 2>/dev/null) survived \`down --macos\`"; fi

# The EXIT trap runs `down --macos` again — a harmless no-op now the VM is already stopped.

# ── ARM B: the self-test with NO SSH transport (gvproxy killed under a live VM) ────────────────
# The state #137 fixed, constructed on purpose. It is reachable in the field because
# cmd_down_macos stops gvproxy and the proxy at the TOP: a stop that fails to kill the VM leaves a
# running guest whose NIC is gone. macos_ssh_host then falls back to `augur-vm ip`, which a
# vfkit-networked guest has no DHCP lease to answer, and ssh_macos EXITS the script rather than
# returning — which used to end `up --macos` at rc=1 with no output and, worse, JUMP OVER the
# self-test's own fail-closed teardown, leaving a live VM with a live NIC.
#
# tests/40 pins that offline through the real ssh_macos, but only a live host can prove the pieces
# it has to stub: that a real `stop_gvproxy` really does strand the guest, and that `augur-vm ip`
# really does answer with nothing for this network mode.
#
# This arm runs LAST and boots its own VM, so every assertion above keeps testing exactly what it
# tested before. It ends with the VM STOPPED — by the self-test's teardown, which is the point.
section "Self-test with no SSH transport (gvproxy killed under a live VM)"
btout="$( cd "$PROJECT" && AUGUR_ACCEPT_PROJECT_CONF=1 bash "$AUGUR" up --macos 2>&1 )"; btrc=$?
if [[ $btrc -eq 0 ]] && macos_vm_running "$vm"; then
  ok "precondition: a fresh VM is up again for this arm"

  # augur's OWN teardown function, the one cmd_down_macos calls — not a hand-rolled kill, so this
  # cannot drift from the production path that creates the state.
  stop_gvproxy >/dev/null 2>&1 || true
  if ! gvproxy_running; then ok "precondition: gvproxy stopped under the live VM"
  else fail "precondition: gvproxy stopped under the live VM" "stop_gvproxy left it running"; fi
  if macos_vm_running "$vm"; then ok "precondition: the VM is still running with its NIC gone"
  else fail "precondition: the VM is still running with its NIC gone" "stopping gvproxy also stopped the VM"; fi

  ntout="$( cd "$PROJECT" && AUGUR_ACCEPT_PROJECT_CONF=1 bash "$AUGUR" up --macos 2>&1 )"; ntrc=$?

  # THE two load-bearing assertions, and both are environment-independent: whichever branch the
  # self-test takes, an unverifiable datapath must end `up` non-zero AND must not leave the guest
  # running. The second is the one the defect broke — rc was already 1 before #137.
  if [[ $ntrc -ne 0 ]]; then ok "up --macos against the stranded guest exits non-zero"
  else fail "up --macos against the stranded guest exits non-zero" "it exited 0 — an unverifiable datapath was accepted:
$(printf '%s\n' "$ntout" | tail -n 12)"; fi
  if ! macos_vm_running "$vm"; then
    ok "the fail-closed teardown actually stopped the VM (no live VM with a live NIC left behind)"
  else
    fail "the fail-closed teardown actually stopped the VM" "the VM is STILL RUNNING — this is #137's defect, or a new path around the teardown:
$(printf '%s\n' "$ntout" | tail -n 12)"
  fi
  if [[ "$ntout" == *"Egress self-test FAILED"* ]]; then
    ok "it reported through the normal fail-closed verdict"
  else
    fail "it reported through the normal fail-closed verdict" "no verdict line — did it die silently again?:
$(printf '%s\n' "$ntout" | tail -n 12)"
  fi

  # Which of the two unverifiable-transport branches fired is environment-dependent: the specific one
  # needs `augur-vm ip` to answer with nothing, which is true for a vfkit-networked guest but is not
  # a property this script controls. Reported, never failed on — the assertions above already hold
  # either way, and a silent exit would have failed them.
  if [[ "$ntout" == *"no SSH transport"* ]]; then
    ok "it named the missing transport and the remedy (#137's specific branch)"
  elif [[ "$ntout" == *"cannot run a command in the guest over SSH"* ]]; then
    skip "it named the missing transport (#137's branch)" "took the unreachable-but-resolvable branch instead — 'augur-vm ip' answered for this guest"
  else
    fail "it named the missing transport" "neither transport branch reported:
$(printf '%s\n' "$ntout" | tail -n 12)"
  fi
else
  fail "precondition: a fresh VM is up again for this arm" "exited $btrc — the arm could not be set up, so nothing below it ran:
$(printf '%s\n' "$btout" | tail -n 12)"
fi

finish
