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
# The per-VM user-level subagent-defs share (#113) mirrors history: share name from the seam, and
# the guest ~/.claude/agents symlink wired via ensure_macos_claude_agents.
has "$up_macos" 'agent_state_agents_host_subdir' "macOS agents share dir name comes from agent_state_agents_host_subdir (A3/C7)"
has "$up_macos" 'ensure_macos_claude_agents'     "macOS up wires ~/.claude/agents (ensure_macos_claude_agents)"
# No folder-trust seed (ADR-0012, reverses ADR-0011): augur no longer pre-trusts the mounted
# workspace on macOS either — a regression guard against re-introducing the per-workspace key.
hasnt "$up_macos" 'hasTrustDialogAccepted'       "macOS up does NOT pre-trust the workspace in the .claude.json stub"
has "$up_macos" 'hasCompletedOnboarding'         "macOS up still seeds the onboarding-only stub"
# Write-once, gated on absence (the macOS clobber-bug fix, ADR-0012): `down --macos` keeps the
# clone (ADR-0006/ADR-0010), so an unconditional scp on every `up` would destroy accumulated guest
# state on every restart. The seed must be wrapped in an existence check, not written unconditionally.
has "$up_macos" 'test -f'                        "macOS .claude.json seed is gated on the file's absence (no per-up clobber)"

# Base-VM account-state scrub (ADR-0012 follow-up, found via live testing): the base VM is
# long-lived and mutable, so a human can log into `claude` by hand at any point in its life
# (Setup Assistant testing, manual debugging) and leak a real account (userID/machineID) into
# every future project clone via `up`'s clone step. Both the code paths that legitimately touch
# the base VM as part of normal operation — build (creates it) and update (refreshes it) — must
# scrub ~/.claude.json, not just build: update is the ONLY other path that boots the base VM
# automatically, so it is the natural self-healing checkpoint between builds.
build_macos="$(awk '/^cmd_build_macos\(\)/{f=1} f{print} f&&/^}/{exit}' "$AUGUR")"
update_macos="$(awk '/^cmd_update_macos\(\)/{f=1} f{print} f&&/^}/{exit}' "$AUGUR")"
has "$build_macos"  'rm -f ~/.claude.json' "macOS build scrubs any accumulated ~/.claude.json before saving the base VM"
has "$update_macos" 'rm -f ~/.claude.json' "macOS update scrubs any accumulated ~/.claude.json (self-healing between builds)"

section "Tier 2 — per-project VM naming is path-hash keyed, not basename-only (run anywhere)"
# §6/§9 fix: macos_project_vm() used to key purely on basename(WORKSPACE_DIR), so two
# distinct directories sharing a basename (e.g. ~/work/myapp and ~/archive/myapp) collided
# onto the same VM name — and therefore the same history dir, egress config, and everything
# else keyed by that name. See docs/decisions/0004-no-special-worktree-support.md §6/§9.
project_vm_fns="$(mktemp)"
work="$(mktemp -d)"
trap 'rm -f "$project_vm_fns"; rm -rf "$work"' EXIT
{
  awk '/^workspace_path_hash\(\)/{f=1} f{print} f&&/^}/{exit}' "$AUGUR"
  awk '/^macos_project_vm\(\)/{f=1} f{print} f&&/^}/{exit}' "$AUGUR"
} > "$project_vm_fns"
has "$(cat "$project_vm_fns")" 'workspace_path_hash' "macos_project_vm references workspace_path_hash (not basename-only)"
# shellcheck disable=SC1090
source "$project_vm_fns"

mkdir -p "$work/work/myapp" "$work/archive/myapp"
WORKSPACE_DIR="$work/work/myapp";    name_a="$(macos_project_vm)"
WORKSPACE_DIR="$work/archive/myapp"; name_b="$(macos_project_vm)"
if [[ "$name_a" != "$name_b" ]]; then ok "macos_project_vm: same-basename dirs get distinct VM names ($name_a vs $name_b)"
else fail "macos_project_vm: same-basename dirs collided" "both resolved to $name_a"; fi
WORKSPACE_DIR="$work/work/myapp"; name_a2="$(macos_project_vm)"
eq "$name_a" "$name_a2" "macos_project_vm: same directory is stable across calls"

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

section "Tier 2 — macOS build SSH bootstrap: no human-typed password (source guard, run anywhere)"
# The base-VM build's first SSH calls run before key auth exists. They must NOT fall back to an
# interactive login-password prompt — augur feeds the fixed admin password via OpenSSH's own
# SSH_ASKPASS (SSH_ASKPASS_REQUIRE=force, ssh_macos_bootstrap), so the operator types nothing
# after Setup Assistant. The key is installed FIRST, so the sudo-config and everything after run
# over key auth (a single password-auth connection).
build_macos="$(awk '/^cmd_build_macos\(\)/{f=1} f{print} f&&/^}/{exit}' "$AUGUR")"
boot_fn="$(awk '/^ssh_macos_bootstrap\(\)/{f=1} f{print} f&&/^}/{exit}' "$AUGUR")"
# (1) the build reaches the guest only via the ssh_macos* helpers — never a raw password `ssh`.
has   "$build_macos" 'ssh_macos_bootstrap' "build installs the SSH key via ssh_macos_bootstrap (askpass), not a raw ssh"
hasnt "$build_macos" 'ssh -F /dev/null'    "build has no raw password 'ssh -F /dev/null' left (all via ssh_macos* helpers)"
# (2) the bootstrap helper forces askpass and answers ONLY password prompts.
has "$boot_fn" 'SSH_ASKPASS_REQUIRE=force'        "bootstrap forces askpass even with a TTY / no DISPLAY (OpenSSH >=8.4)"
has "$boot_fn" 'StrictHostKeyChecking=accept-new' "bootstrap pre-accepts the fresh host key (keeps the yes/no prompt off askpass)"
has "$boot_fn" '*[Pp]assword:*'                   "bootstrap askpass replies to password prompts only (never feeds the host-key question)"
# (3) key install must precede the passwordless-sudo config (so sudo config runs over key auth).
key_ln="$(printf '%s\n' "$build_macos"  | grep -n 'Setting up SSH key authentication' | head -1 | cut -d: -f1)"
sudo_ln="$(printf '%s\n' "$build_macos" | grep -n 'Configuring passwordless sudo'      | head -1 | cut -d: -f1)"
if [[ -n "$key_ln" && -n "$sudo_ln" && "$key_ln" -lt "$sudo_ln" ]]; then
  ok "build installs the SSH key before configuring passwordless sudo (single password-auth connection)"
else
  fail "build orders key-install before sudo-config" "key@${key_ln:-?} sudo@${sudo_ln:-?}"
fi
# The helper must clean up explicitly and propagate ssh's status — NOT via a `trap … RETURN`
# (a RETURN trap isn't function-local: it re-fires on the caller's return where $askpass is out
# of scope → fatal under `set -u`, and it doesn't fire when `set -e` aborts on a failed ssh).
has "$boot_fn" 'rm -f "$askpass"' "bootstrap removes the temp askpass helper explicitly (not via RETURN trap)"
has "$boot_fn" 'return $rc'       "bootstrap propagates ssh's exit status to the caller"

section "Tier 2 — macOS build SSH bootstrap: cleanup + status (execution guard, run anywhere)"
# Regression guard for the RETURN-trap bug: extract ssh_macos_bootstrap, stub its deps + ssh, and
# exercise it inside a caller under `set -euo pipefail`. Assert: (success) rc 0, the caller returns
# cleanly with NO unbound-variable crash, temp helper removed; (failure) status propagates so the
# build aborts, temp helper still removed.
boot_src="$(mktemp)"; boot_td="$(mktemp -d)"
awk '/^ssh_macos_bootstrap\(\)/{f=1} f{print} f&&/^}/{exit}' "$AUGUR" > "$boot_src"
_stubs='error(){ :; }; vm_known_hosts_file(){ echo /dev/null; }; MACOS_SSH_USER=admin;'
# success path
out_s="$(TMPDIR="$boot_td" bash -euo pipefail -c '
  source "$1"; '"$_stubs"'
  ssh(){ return 0; }
  outer(){ ssh_macos_bootstrap vm 1.2.3.4 "true"; echo BANNER; }
  outer; echo AFTER_OUTER_OK' _ "$boot_src" 2>&1)"; rc_s=$?
left_s="$(find "$boot_td" -name 'augur-askpass.*' 2>/dev/null | wc -l | tr -d ' ')"
# failure path
out_f="$(TMPDIR="$boot_td" bash -euo pipefail -c '
  source "$1"; '"$_stubs"'
  ssh(){ return 5; }
  outer(){ ssh_macos_bootstrap vm 1.2.3.4 "true"; echo SHOULD_NOT_PRINT; }
  outer; echo SHOULD_NOT_PRINT_MAIN' _ "$boot_src" 2>&1)"; rc_f=$?
left_f="$(find "$boot_td" -name 'augur-askpass.*' 2>/dev/null | wc -l | tr -d ' ')"
rm -rf "$boot_src" "$boot_td"

eq "0" "$rc_s" "bootstrap: successful build path exits 0 (no persistent-RETURN-trap crash)"
has "$out_s" "AFTER_OUTER_OK" "bootstrap: caller returns cleanly after the helper (no unbound-variable abort)"
eq "0" "$left_s" "bootstrap: temp askpass helper removed on the success path"
if [[ "$rc_f" -ne 0 ]]; then ok "bootstrap: a failed ssh propagates non-zero (build aborts under set -e)"
else fail "bootstrap: a failed ssh must propagate non-zero" "got rc=$rc_f"; fi
hasnt "$out_f" "SHOULD_NOT_PRINT" "bootstrap: set -e aborts the caller when the helper fails"
eq "0" "$left_f" "bootstrap: temp askpass helper removed on the failure path too"

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
