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
# augur derives MACOS_SHARE only in its dispatch tail (AFTER the AUGUR_SOURCE_ONLY return), so
# sourcing does NOT set it — recompute it here from augur's own workspace_slug, identical to what
# `up --macos` will use for this PROJECT. (set -u is still active from the sourced augur, so an
# unbound MACOS_SHARE would otherwise abort the script before any assertion runs.)
MACOS_SHARE="workspace-$(workspace_slug)"
[[ -n "$vm" && -n "$MACOS_SHARE" ]] || { fail "derive VM + share names from augur" "vm='$vm' share='$MACOS_SHARE'"; finish; exit $?; }
vssh() { ssh_macos "$vm" "$@"; }          # run a command in the VM via augur's real SSH path

# ── Boot the VM with egress ON (default; --macos is a TRAILING flag) ─────────────────────────
cleanup() { ( cd "$PROJECT" && bash "$AUGUR" down --macos ) >/dev/null 2>&1; }
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
# curl simply fails (unlike the Docker CONNECT path, which returns a clean 403).
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
# The EXIT trap runs `down --macos` again — a harmless no-op now the VM is already stopped.

finish
