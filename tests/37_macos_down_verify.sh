#!/usr/bin/env bash
# Tier 1 — `down --macos` must VERIFY the VM actually stopped (runs anywhere; nothing is ever
# cloned, booted or SSH'd — the augur-vm CLI is a recorder function).
#
# The defect. Container mode's `cmd_down` runs `eng stop … || true` and then re-checks
# `container_running`, warning when the container is still up rather than claiming success. macOS
# mode ran `"$VM_CLI" stop … 2>/dev/null || true` and then printed an UNCONDITIONAL
# `success "VM … stopped"`. `augur-vm stop` swallows its diagnostics into 2>/dev/null and exits 0
# even on its force-kill path, so "the signal never landed" (a `run` process this host user cannot
# signal, or a stop that errored before signalling) was completely invisible: `down --macos`
# reported a clean stop over a VM that was still executing.
#
# Why it is worse here than in container mode: gvproxy and the proxy are stopped at the TOP of
# cmd_down_macos, so the surviving guest keeps running with this workspace shared into it while no
# augur command can reach it any more — ssh_macos uses gvproxy's 127.0.0.1 forward while gvproxy is
# up and otherwise falls back to a DHCP lease a vfkit-networked guest never had. The next
# `up --macos` therefore takes the already-running reconcile branch, revives a proxy the guest has no
# NIC to reach, and dies inside ssh_macos ("Cannot resolve SSH host") from the boot self-test's first
# probe — whose `&>/dev/null` swallows even that. `claude`/`shell --macos` skip `up` entirely on a
# running VM and fail in the first ensure_* for the same unexplained reason.
#
# What this file pins, all through stubs: with the VM still running after the stop, `down --macos`
# must NOT print its success line and must warn with the operator's remedy; with the VM gone it must
# print success; and the stop must be recorded either way (an assertion on exit status alone proves
# nothing — this path returns 0 in both cases, on purpose).
#
# cmd_destroy_macos deliberately has NO such re-check: its `"$VM_CLI" delete` carries no `|| true`,
# `augur-vm delete` refuses a running VM, and `set -e` therefore aborts it before its success line.
# The last section pins that difference, so "make destroy tolerant of a failed delete" cannot quietly
# reintroduce the very defect this commit removes from `down`.
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/lib.sh"
AUGUR="$REPO/augur"

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT
VMLOG="$TMPD/vmcli"     # every augur-vm invocation, so "the stop happened" is assertable
LOG="$TMPD/calls"       # one anchor line per host-side teardown step

# BOOT-PROOFING (the technique tests/30_macos_vm.sh, 34, 35 and 36 use): point AUGUR_VM_BIN at a path
# that cannot exist BEFORE sourcing, so the resolved $VM_CLI can never be a real augur-vm. The
# recorder installed below replaces it for the assertions; if that override were ever lost the
# fallback is "command not found", never a real `augur-vm stop`/`delete` against this host's VMs.
# Set before the source because resolve_vm_cli runs at source time.
export AUGUR_VM_BIN="$TMPD/no-such-augur-vm"

# Pull the REAL cmd_down_macos / cmd_destroy_macos out of augur without running its dispatch tail
# (AUGUR_SOURCE_ONLY seam), so this can never drift from the shipped functions. Stubs are installed
# AFTER the source on purpose: bash resolves function names at CALL time, so a later definition wins.
AUGUR_SOURCE_ONLY=1 source "$AUGUR"
set +e                                    # augur enables `set -e`; restore lib.sh assert-and-continue

# Sandbox every path this can write or read. This runner exports CLAUDE_CODE_OAUTH_TOKEN and has a
# real ~/.gitconfig; neither may be reachable from here (tests/34, 35 and 36 do the same).
HOME="$TMPD/home"; mkdir -p "$HOME"
AUGUR_DIR="$TMPD/augur"                   # known_hosts / vm-state writes stay in the sandbox
AUGUR_PROXY_DIR="$TMPD/proxy"; mkdir -p "$AUGUR_PROXY_DIR"
unset ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN
# A sandbox workspace, so the VM name and the shared-directory the warning names are both this
# test's, not the checkout the suite happens to run from.
WORKSPACE_DIR="$TMPD/proj"; mkdir -p "$WORKSPACE_DIR"
VM="$(macos_project_vm)"

# ── Stubs ────────────────────────────────────────────────────────────────────
require_vz()   { :; }
stop_gvproxy() { echo "stop_gvproxy" >> "$LOG"; }
stop_proxy()   { echo "stop_proxy"   >> "$LOG"; }
_vm_exists=0                              # 0 = a clone exists for this dir, 1 = none
_vm_running=0                             # 0 = still running after the stop, 1 = stopped
_delete_rc=0                              # exit status the recorder returns for `delete`
macos_vm_exists()  { return $_vm_exists; }
macos_vm_running() { return $_vm_running; }
# Recorder standing in for the augur-vm CLI. $VM_CLI is invoked as "$VM_CLI" <subcmd>, so a function
# name works. `stop` returns 0 exactly like the real bounded stop does even when it force-kills —
# which is why the exit status of the stop can never be the signal being tested.
vm_cli_rec() {
  printf '%s\n' "$*" >> "$VMLOG"
  [[ "${1:-}" == delete ]] && return $_delete_rc
  return 0
}
VM_CLI=vm_cli_rec
logged() { grep -qx "$1" "$LOG" 2>/dev/null; }
run_down() { : > "$LOG"; : > "$VMLOG"; out="$( cmd_down_macos 2>&1 )"; rc=$?; }

# Negative control for the recorder itself: prove it DOES capture a `stop`, so every "the stop was
# recorded" assertion below cannot pass just because the recorder is broken.
: > "$VMLOG"; "$VM_CLI" stop self-check >/dev/null 2>&1
if grep -qx 'stop self-check' "$VMLOG"; then ok "the augur-vm recorder captures a 'stop' (control)"
else fail "the augur-vm recorder does not capture 'stop'" "every recorded-call assertion would be vacuous"; fi

section "Tier 1 — down --macos: the VM is STILL RUNNING after the stop"

_vm_exists=0; _vm_running=0
run_down
# The recorded call, first: without it every assertion below could pass on a run that never even
# tried to stop the VM.
if grep -qx "stop ${VM}" "$VMLOG"; then ok "down --macos: 'augur-vm stop <vm>' is invoked"
else fail "down --macos: no 'stop ${VM}' recorded" "vm log: $(cat "$VMLOG")"; fi
# THE point of the commit. This exact phrase is the success line, so it can only appear on a run
# that claimed the VM stopped.
hasnt "$out" "stopped (clone kept" "down --macos: does NOT claim the VM stopped when it is still running"
hasnt "$out" "restart it (fast, no re-clone)" "down --macos: does not print the restart hints either"
has "$out" "did NOT stop" "down --macos: says the VM did not stop"
# …and the remedy, spelled out. Nothing else in augur can print these.
has "$out" "run.pid"                    "down --macos: the remedy names the VM's run.pid to kill"
has "$out" "kill \$(cat"                "down --macos: the remedy is a runnable kill command"
has "$out" "augur down --macos"         "down --macos: the remedy says to re-run the teardown afterwards"
has "$out" "augur-vm delete' refuses a running VM" "down --macos: warns that destroy --macos is not the remedy"
has "$out" "$WORKSPACE_DIR"             "down --macos: names the directory still shared into the live guest"
has "$out" "egress datapath already torn down" "down --macos: says the surviving guest has no datapath left"
# Order-agnostic on purpose: the host-side egress teardown must happen on this path too (a stranded
# gvproxy/proxy from a crashed VM is why it is unconditional), but WHERE it happens relative to the
# stop is deliberately not pinned here — moving it is a separate, larger change.
if logged stop_gvproxy; then ok "down --macos: gvproxy is still torn down when the VM survives"
else fail "down --macos: gvproxy was not stopped" "log: $(cat "$LOG")"; fi
if logged stop_proxy; then ok "down --macos: the proxy is still torn down when the VM survives"
else fail "down --macos: the proxy was not stopped" "log: $(cat "$LOG")"; fi

section "Tier 1 — down --macos: the VM DID stop (the success path must survive the fix)"

_vm_exists=0; _vm_running=1
run_down
if grep -qx "stop ${VM}" "$VMLOG"; then ok "down --macos: 'augur-vm stop <vm>' is invoked here too"
else fail "down --macos: no 'stop ${VM}' recorded on the success path" "vm log: $(cat "$VMLOG")"; fi
has "$out" "stopped (clone kept"          "down --macos: reports the stop when the VM really stopped"
has "$out" "restart it (fast, no re-clone)" "down --macos: prints the up hint"
has "$out" "remove the clone entirely"      "down --macos: prints the destroy hint"
hasnt "$out" "did NOT stop"  "down --macos: no failure warning on a clean stop"
hasnt "$out" "run.pid"       "down --macos: no kill-it-by-hand remedy on a clean stop"
eq "0" "$rc" "down --macos: exits 0 after a clean stop"
# Nothing is deleted by `down` (ADR-0006 keeps the clone) — the re-check must not have turned into
# an escalation that removes the VM.
if grep -q '^delete ' "$VMLOG"; then fail "down --macos: deleted the VM" "$(cat "$VMLOG")"
else ok "down --macos: never invokes 'delete' (the clone is kept)"; fi

section "Tier 1 — down --macos: no VM for this directory"

_vm_exists=1; _vm_running=0               # _vm_running would report "running" if it were consulted
run_down
if [[ -s "$VMLOG" ]]; then fail "down --macos: touched the augur-vm CLI with no VM present" "$(cat "$VMLOG")"
else ok "down --macos: never invokes the augur-vm CLI when no VM exists"; fi
has   "$out" "No VM found"          "down --macos: reports that this directory has no VM"
hasnt "$out" "stopped (clone kept"  "down --macos: does not claim a stop when there was nothing to stop"
hasnt "$out" "did NOT stop"         "down --macos: does not warn about a VM that does not exist"
if logged stop_gvproxy && logged stop_proxy
then ok "down --macos: still tears down gvproxy+proxy with no VM (a stranded one must be reaped)"
else fail "down --macos: skipped the egress teardown when no VM exists" "log: $(cat "$LOG")"; fi

section "Tier 1 — destroy --macos fails CLOSED instead (why it needs no re-check)"

# Run under `set -e` in a subshell, the way the dispatch tail runs it — this test file disables
# errexit for assert-and-continue, and errexit is exactly the mechanism being asserted.
run_destroy() { : > "$LOG"; : > "$VMLOG"; dout="$( set -e; cmd_destroy_macos 2>&1 )"; drc=$?; }

_vm_exists=0; _delete_rc=1                # `augur-vm delete` refuses a running VM (ValidationError)
run_destroy
if grep -qx "delete ${VM}" "$VMLOG"; then ok "destroy --macos: the delete is attempted"
else fail "destroy --macos: no 'delete ${VM}' recorded" "vm log: $(cat "$VMLOG")"; fi
hasnt "$dout" "has been removed" "destroy --macos: does NOT claim removal when the delete failed"
if [[ "$drc" -ne 0 ]]; then ok "destroy --macos: exits non-zero when the delete failed (no '|| true' on it)"
else fail "destroy --macos: exited 0 after a failed delete" "the VM is still there and still running"; fi

_delete_rc=0                              # positive control: the whole path must still work
run_destroy
has "$dout" "has been removed" "destroy --macos: reports removal when the delete succeeded"
eq "0" "$drc" "destroy --macos: exits 0 when the delete succeeded"

section "Tier 1 — source guards: the re-check is wired where behaviour cannot see it"

down_body="$(awk '/^cmd_down_macos\(\)/{f=1} f{print} f&&/^}/{exit}' "$AUGUR")"
destroy_body="$(awk '/^cmd_destroy_macos\(\)/{f=1} f{print} f&&/^}/{exit}' "$AUGUR")"

# The re-check must come AFTER the stop. Before it, it would report the state the stop was about to
# change and the warning would fire on every teardown.
s_at="$(printf '%s\n' "$down_body" | grep -n '"\$VM_CLI" stop'  | head -n1 | cut -d: -f1)"
r_at="$(printf '%s\n' "$down_body" | grep -n 'macos_vm_running' | head -n1 | cut -d: -f1)"
if [[ -n "$s_at" && -n "$r_at" && "$s_at" -lt "$r_at" ]]
then ok "down --macos re-checks AFTER the stop (stop@$s_at < recheck@$r_at)"
else fail "down --macos does not re-check after the stop" "stop@${s_at:-none} recheck@${r_at:-none}"; fi
# Reuse, not a second liveness helper to drift from macos_vm_running/`augur status --macos`.
hasnt "$down_body" 'run.pid" ]]' "the re-check does not read the VM pidfile itself"
# The delete's bare exit status IS destroy's re-check. Guard it explicitly: `|| true` here would put
# the false success straight back, in the one function where it also loses the backend's own message.
if printf '%s\n' "$destroy_body" | grep -q '"\$VM_CLI" delete "\$project_vm"$'
then ok "destroy --macos leaves its delete unguarded (a refusal aborts before the success line)"
else fail "destroy --macos guarded or reshaped its delete" "$(printf '%s\n' "$destroy_body" | grep 'delete')"; fi

finish
