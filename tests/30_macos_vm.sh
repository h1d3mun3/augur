#!/usr/bin/env bash
# Tier 2 — macOS VM mode. Two parts:
#   (a) source guards (run anywhere): the macOS launch/state paths must consume the
#       agent seam, never re-hardcode "claude" / "claude-projects". This catches the
#       C4 regression the design doc warns about (interpolating into the SSH string).
#   (b) live smoke (gated): only on a macOS host with augur-vm built; opt-in via
#       AUGUR_TEST_LIVE=1. Boots nothing heavy — just exercises `augur --macos status`.
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/lib.sh"
AUGUR="$REPO/augur"

section "Tier 2 — macOS seam wiring (source guards, run anywhere)"
# The interactive macOS launch must interpolate the seam, not a literal command.
claude_macos="$(awk '/^cmd_claude_macos\(\)/{f=1} f{print} f&&/^}/{exit}' "$AUGUR")"
has "$claude_macos" 'agent_launch_argv'  "macOS launch reads agent_launch_argv (not a hardcoded 'claude')"
has "$claude_macos" 'agent_fixed_env'    "macOS launch reads agent_fixed_env"
has "$claude_macos" '${_rargv}'          "macOS launch interpolates the seam launch argv into the SSH command (C4)"
# The per-VM history share name must equal agent_state_host_subdir (A3/C7 contract).
up_macos="$(awk '/^cmd_up_macos\(\)/{f=1} f{print} f&&/^}/{exit}' "$AUGUR")"
has "$up_macos" 'agent_state_host_subdir' "macOS history share dir name comes from agent_state_host_subdir (A3/C7)"

section "Tier 2 — macOS network isolation (entitlements, run anywhere)"
# Invariant I9 (docs/security-reviews/INVARIANTS.md): the guest gets one host-owned NIC
# and no bridged networking. The machine-checkable part is the entitlement set — bridged
# networking would require com.apple.vm.networking, which augur must NOT ship. (NIC count
# and the gvproxy UDP/ICMP drop stay review-only: they need a real VM host.)
ent="$REPO/augur-vm/augur-vm.entitlements"
if [[ -f "$ent" ]]; then
  # Match the granted <key>…</key> ELEMENTS, not any substring — the file mentions
  # com.apple.vm.networking inside an explanatory comment on purpose.
  ent_txt="$(cat "$ent")"
  has   "$ent_txt" '<key>com.apple.security.virtualization</key>' "entitlements grant Virtualization.framework"
  hasnt "$ent_txt" '<key>com.apple.vm.networking</key>'           "entitlements do NOT grant bridged networking (I9)"
else
  fail "augur-vm.entitlements present" "not found at $ent"
fi

section "Tier 2 — augur-vm clone identity regeneration (source guard, run anywhere)"
# Issue #67: `clone` copies the VM bundle via clonefile(2), which duplicates config.json
# byte-for-byte — including machineIdentifier/macAddress. Without regenerating both on
# the destination, running the source and the clone concurrently collides on the shared
# NAT MAC (augur-vm ip resolves by MAC) and on VZMacMachineIdentifier, which
# Virtualization.framework does not support running twice live.
clone_src="$REPO/augur-vm/Sources/augur-vm/Clone.swift"
if [[ -f "$clone_src" ]]; then
  clone_txt="$(cat "$clone_src")"
  has "$clone_txt" 'VZMacMachineIdentifier()' "clone regenerates machineIdentifier on the copy (issue #67)"
  has "$clone_txt" 'VZMACAddress.randomLocallyAdministered()' "clone regenerates macAddress on the copy (issue #67)"
else
  fail "augur-vm/Sources/augur-vm/Clone.swift present" "not found at $clone_src"
fi

section "Tier 2 — macOS live smoke (gated)"
if [[ "$(uname -s)" != "Darwin" ]]; then skip "live macOS checks" "not a macOS host"; finish; exit $?; fi
if ! command -v augur-vm >/dev/null 2>&1; then skip "live macOS checks" "augur-vm not built (run: bash install)"; finish; exit $?; fi
if [[ "${AUGUR_TEST_LIVE:-0}" != 1 ]]; then skip "augur --macos status" "set AUGUR_TEST_LIVE=1 to run the live macOS smoke"; finish; exit $?; fi

# NOTE: --macos is a TRAILING flag — the subcommand comes first (`augur status --macos`).
# `augur --macos status` would be parsed as COMMAND=--macos → "Unknown command".
out="$(bash "$AUGUR" status --macos 2>&1)"; rc=$?
if [[ $rc -eq 0 ]]; then ok "augur status --macos succeeds"
else fail "augur status --macos exited $rc" "$(printf '%s' "$out" | tail -1)"; fi

finish
