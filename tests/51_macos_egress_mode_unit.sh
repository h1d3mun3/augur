#!/usr/bin/env bash
# Tier 1 (offline) — macOS mode refuses to attach to a running VM booted with a different egress mode.
#
# The hazard. `claude --macos` and `shell --macos` skip `up` when the VM is already running. Without a
# check, `augur up --macos --no-egress` followed by a plain `augur claude --macos` would run the agent
# on an unfiltered NAT network with no word said; and a plain `augur up --macos` on that VM would run
# the boot self-test against a NAT guest, "detect a leak" and stop the VM under the operator. The
# fix: the egress mode a VM is booted with is recorded host-side at boot (macos_egress_mode_file),
# and up/claude/shell on a running VM refuse — without stopping it — when the requested mode
# differs or the record is missing. down/destroy drop the record.
#
# The same file pins the second host-side record a running VM is attached by: that the egress
# self-test passed during the VM's current boot (macos_egress_verified_file, tied to the boot by
# augur-vm's run id). `claude` / `shell --macos` on a running egress VM without it (an `up`
# interrupted before its self-test, a record from an earlier boot) refuse before touching the
# guest; `up --macos` on the running VM re-runs the self-test and records it. The boot path drops
# it before `augur-vm run` and writes it only after the self-test; --no-egress has none;
# down/destroy and a failing self-test drop it.
#
# Nothing is cloned, booted or SSH'd: the real cmd_* functions run against recorder stubs.
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/lib.sh"
AUGUR="$REPO/augur"

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT
# Boot-proofing (see tests/36): $VM_CLI can never resolve to a real augur-vm.
export AUGUR_VM_BIN="$TMPD/no-such-augur-vm"

AUGUR_SOURCE_ONLY=1 source "$AUGUR"
set +e

HOME="$TMPD/home"; mkdir -p "$HOME"
AUGUR_DIR="$TMPD/augur"
AUGUR_PROXY_DIR="$TMPD/proxy"; mkdir -p "$AUGUR_PROXY_DIR"
WORKSPACE_DIR="$TMPD/proj"; mkdir -p "$WORKSPACE_DIR"
unset ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN
gh() { return 1; }
SWIFT_IMAGE_TAG="latest"; IMAGE_NAME="augur:swift-latest"
CONTAINER_NAME="$(make_container_name)"; WORKSPACE_MOUNT="$(make_workspace_mount)"
MACOS_SHARE="workspace-$(workspace_slug)"
MACOS_MODE=true
PV="$(macos_project_vm)"
mkdir -p "$AUGUR_DIR/vms/$PV"; macos_store_admin_password "$PV" admin

LOG="$TMPD/calls"; : > "$LOG"
logged() { grep -qx "$1" "$LOG" 2>/dev/null; }
vm_cli_rec() { printf 'vm %s\n' "$*" >> "$LOG"; return 0; }
VM_CLI=vm_cli_rec
require_vz() { :; }
require_fresh_egress_helpers() { :; }
macos_vm_exists() { return 0; }
VM_UP=1
macos_vm_running() { [[ "$VM_UP" == 1 ]]; }
check_project_conf_approved() { echo gate >> "$LOG"; }
start_proxy()   { echo "start_proxy" >> "$LOG"; }
start_gvproxy() { echo "start_gvproxy" >> "$LOG"; }
stop_gvproxy()  { echo "stop_gvproxy" >> "$LOG"; }
stop_proxy()    { echo "stop_proxy" >> "$LOG"; }
verify_macos_egress_locked() { echo "selftest" >> "$LOG"; }
warn_if_macos_egress_pinned() { :; }
sync_macos_guest_clock() { :; }; sync_macos_guest_timezone() { :; }; configure_macos_guest_session() { :; }
ensure_macos_workspace() { :; }; ensure_macos_agent_projects() { :; }; ensure_macos_agent_agents() { :; }
ensure_macos_agent_profile() { :; }; ensure_macos_agent_bin() { :; }; push_macos_guest_env() { :; }
macos_poweroff_before_teardown() { :; }
scp_to_macos() { :; }
ssh_macos() { echo "ssh $*" >> "$LOG"; [[ "$*" == *"cat > "* ]] && cat >/dev/null; [[ "$*" == *" -t "* ]] && echo AGENT_ATTACHED; return 0; }
ssh_macos_session() { ssh_macos "$@"; }
egress_on()  { AUGUR_EGRESS=auto; }
egress_off() { AUGUR_EGRESS=0; }
record() { mkdir -p "$AUGUR_PROXY_DIR"; printf '%s\n' "$1" > "$(macos_egress_mode_file)"; }
# The VM's current boot (run.pid), and the record that its self-test passed during it.
RUN_ID_FILE="$AUGUR_DIR/vms/$PV/run.pid"
boot_id()  { printf '%s\n' "$1" > "$RUN_ID_FILE"; }
verified() { mkdir -p "$AUGUR_PROXY_DIR"; printf '%s\n' "$1" > "$(macos_egress_verified_file)"; }
boot_id 4242
run_cmd() { : > "$LOG"; out="$( set -e; "$@" 2>&1 )"; rc=$?; }

refused() {   # refused <label> <remedy> [<reason the message must give>]
  [[ "$rc" -ne 0 ]] && ok "$1: exits non-zero" || fail "$1: was not refused"
  has "$out" "${3:-was started with a different config}" "$1: says why (${3:-different config})"
  has "$out" "$2" "$1: gives the remedy"
  if logged "vm stop $PV" || logged stop_gvproxy || logged stop_proxy; then
    fail "$1: the VM or its egress helpers were stopped" "$(cat "$LOG")"
  else ok "$1: the running VM is left alone (nothing stopped)"; fi
  logged selftest && fail "$1: the self-test ran anyway" || ok "$1: no self-test on a mismatched VM"
  hasnt "$out" "AGENT_ATTACHED" "$1: nothing is attached"
}

section "Tier 1 — the record is written on the boot path, before \`augur-vm run\`"
VM_UP=0
egress_on
rm -f "$(macos_egress_mode_file)"
wait_for_macos_ssh() { cp "$(macos_egress_mode_file)" "$TMPD/at-boot" 2>/dev/null; return 0; }
run_cmd cmd_up_macos
[[ "$rc" == 0 ]] && ok "up --macos (egress on): boots" || fail "up --macos (egress on): boots" "rc=$rc: $(tail -n 3 <<<"$out")"
eq "on" "$(cat "$(macos_egress_mode_file)" 2>/dev/null)" "up --macos records egress 'on'"
eq "on" "$(cat "$TMPD/at-boot" 2>/dev/null)" "the record exists by the time the VM is booting"
fn="$(declare -f cmd_up_macos)"
rec_at="$(grep -n 'macos_record_egress_mode' <<<"$fn" | head -n1 | cut -d: -f1)"
run_at="$(grep -n '"\$VM_CLI" run' <<<"$fn" | head -n1 | cut -d: -f1)"
if [[ -n "$rec_at" && -n "$run_at" && "$rec_at" -lt "$run_at" ]]; then ok "the record is written before 'augur-vm run' (no running VM without one)"
else fail "the record is not written before 'augur-vm run'" "record@$rec_at run@$run_at"; fi
egress_off; rm -f "$TMPD/at-boot"
run_cmd cmd_up_macos
eq "off" "$(cat "$(macos_egress_mode_file)" 2>/dev/null)" "up --macos --no-egress records egress 'off'"

section "Tier 1 — up --macos on a RUNNING VM: mismatch refuses, match reconciles"
VM_UP=1
egress_on; record off
run_cmd cmd_up_macos
refused "up --macos on a --no-egress VM" "augur down --macos && augur up --macos"
hasnt "$out" "reconciling host-side state" "up --macos on a --no-egress VM: the reconcile is not reached"

egress_off; record on
run_cmd cmd_up_macos
refused "up --macos --no-egress on an egress VM" "augur down --macos && augur up --macos --no-egress"

egress_on; rm -f "$(macos_egress_mode_file)"
run_cmd cmd_up_macos
refused "up --macos on a VM with no record" "augur down --macos && augur up --macos" "unknown egress mode"
has "$out" "started by an older augur" "no record: names the likely cause"

egress_on; record on
run_cmd cmd_up_macos
eq 0 "$rc" "up --macos on an egress VM: reconciles (exit 0)"
logged selftest && ok "egress VM: the self-test runs" || fail "egress VM: the self-test did not run"
logged start_proxy && ok "egress VM: the proxy is revived" || fail "egress VM: start_proxy not called"

egress_off; record off
run_cmd cmd_up_macos
eq 0 "$rc" "up --macos --no-egress on a --no-egress VM: reconciles (exit 0)"
logged selftest && fail "--no-egress VM: the self-test ran (it would 'detect a leak' and stop the VM)" \
                || ok "--no-egress VM: no self-test"
logged start_proxy && fail "--no-egress VM: a proxy was started" || ok "--no-egress VM: no proxy"
logged "vm stop $PV" && fail "--no-egress VM: the VM was stopped" || ok "--no-egress VM: the VM keeps running"

section "Tier 1 — claude / shell --macos on a RUNNING VM"
for c in cmd_claude_macos cmd_shell_macos; do
  egress_on; record off
  run_cmd "$c"
  refused "$c on a --no-egress VM" "augur down --macos && augur up --macos"
  egress_on; rm -f "$(macos_egress_mode_file)"
  run_cmd "$c"
  refused "$c on a VM with no record" "augur down --macos && augur up --macos" "unknown egress mode"
  egress_off; record on
  run_cmd "$c"
  refused "$c --no-egress on an egress VM" "--no-egress"
  egress_on; record on; verified 4242
  run_cmd "$c"
  eq 0 "$rc" "$c on an egress VM: attaches"
  has "$out" "AGENT_ATTACHED" "$c on an egress VM: the session is launched"
  egress_off; record off
  run_cmd "$c"
  eq 0 "$rc" "$c --no-egress on a --no-egress VM: attaches"
done

section "Tier 1 — a running VM gets a session only if its current boot passed the self-test"
# An `up --macos` interrupted between `augur-vm run` and the self-test leaves a running VM with no
# record of a passed self-test (macos_egress_verified_file); one booted again has a new run id.
unverified() {   # unverified <label>
  [[ "$rc" -ne 0 ]] && ok "$1: exits non-zero" || fail "$1: was not refused"
  has "$out" "no egress self-test has passed since it booted" "$1: says why"
  has "$out" "augur down --macos && augur up --macos" "$1: gives the remedy"
  hasnt "$out" "AGENT_ATTACHED" "$1: nothing is attached"
  grep -q '^ssh ' "$LOG" && fail "$1: the guest was contacted" "$(cat "$LOG")" || ok "$1: the guest is not contacted at all"
  if logged "vm stop $PV" || logged stop_gvproxy || logged stop_proxy; then
    fail "$1: the VM or its egress helpers were stopped" "$(cat "$LOG")"
  else ok "$1: the running VM is left alone (nothing stopped)"; fi
}
VM_UP=1
for c in cmd_claude_macos cmd_shell_macos; do
  egress_on; record on; rm -f "$(macos_egress_verified_file)"
  run_cmd "$c"
  unverified "$c, no record of a passed self-test"
  egress_on; record on; verified 4141
  run_cmd "$c"
  unverified "$c, a record from an earlier boot (another run id)"
  egress_on; record on; verified 4242; rm -f "$RUN_ID_FILE"
  run_cmd "$c"
  unverified "$c, no run id to match the record against"
  boot_id 4242
  egress_off; record off; rm -f "$(macos_egress_verified_file)"
  run_cmd "$c"
  eq 0 "$rc" "$c --no-egress: attaches with no record (a --no-egress boot has no self-test)"
done
# `up --macos` on the running VM re-runs the self-test, and its pass is recorded for this boot.
egress_on; record on; rm -f "$(macos_egress_verified_file)"
run_cmd cmd_up_macos
eq 0 "$rc" "up --macos on an unverified running VM: reconciles"
logged selftest && ok "up --macos on an unverified running VM: runs the self-test" || fail "up --macos: no self-test"
eq "4242" "$(cat "$(macos_egress_verified_file)" 2>/dev/null)" "up --macos on a running VM: records the pass with this boot's run id"
run_cmd cmd_claude_macos
eq 0 "$rc" "…after which claude --macos attaches"
# A failing self-test on that path records nothing, and drops a record that was there.
verify_real="$(declare -f verify_macos_egress_locked)"
verify_macos_egress_locked() { echo "selftest" >> "$LOG"; stop_unverified_macos_vm "$1"; exit 1; }
egress_on; record on; verified 4242
run_cmd cmd_up_macos
[[ "$rc" -ne 0 ]] && ok "self-test fails on a running VM: up exits non-zero" || fail "self-test fails on a running VM: up exited 0"
[[ -e "$(macos_egress_verified_file)" ]] && fail "self-test fails on a running VM: the record survives" \
  || ok "self-test fails on a running VM: the record is dropped"
eval "$verify_real"
# No run id: nothing is recorded, with a warning, so sessions refuse (fail closed).
rm -f "$RUN_ID_FILE" "$(macos_egress_verified_file)"
run_cmd cmd_up_macos
eq 0 "$rc" "no run id: up --macos still reconciles"
has "$out" "its passed self-test is not recorded" "no run id: says the pass is not recorded"
[[ -e "$(macos_egress_verified_file)" ]] && fail "no run id: a record was written" || ok "no run id: nothing is recorded"
boot_id 4242

section "Tier 1 — the boot path drops the record before \`augur-vm run\` and writes it after the self-test"
VM_UP=0
egress_on; verified 4242; boot_id 4343
wait_for_macos_ssh() { cp "$(macos_egress_verified_file)" "$TMPD/verified-at-boot" 2>/dev/null; return 0; }
rm -f "$TMPD/verified-at-boot"
run_cmd cmd_up_macos
eq 0 "$rc" "boot: completes"
[[ -e "$TMPD/verified-at-boot" ]] && fail "boot: a record from an earlier boot is still there while this one boots" \
  || ok "boot: the earlier boot's record is gone before the VM boots"
eq "4343" "$(cat "$(macos_egress_verified_file)" 2>/dev/null)" "boot: the pass is recorded with this boot's run id"
fn="$(declare -f cmd_up_macos)"
rm_at="$(grep -n 'rm -f "$(macos_egress_verified_file)"' <<<"$fn" | head -n1 | cut -d: -f1)"
run_at="$(grep -n '"\$VM_CLI" run' <<<"$fn" | head -n1 | cut -d: -f1)"
st_at="$(grep -n 'verify_macos_egress_locked' <<<"$fn" | tail -n1 | cut -d: -f1)"
rec_at="$(grep -n 'macos_record_egress_verified' <<<"$fn" | tail -n1 | cut -d: -f1)"
if [[ -n "$rm_at" && -n "$run_at" && -n "$st_at" && -n "$rec_at" && "$rm_at" -lt "$run_at" && "$st_at" -lt "$rec_at" ]]; then
  ok "boot: the record is dropped before 'augur-vm run' and written after the self-test"
else fail "boot: the record's place in cmd_up_macos is wrong" "rm@$rm_at run@$run_at self-test@$st_at record@$rec_at"; fi
# Interrupted before the self-test (here: the SSH wait never ends well): nothing is recorded.
wait_for_macos_ssh() { return 1; }
macos_boot_ssh_failed() { stop_unverified_macos_vm "$1"; exit 1; }
verified 4242
run_cmd cmd_up_macos
[[ -e "$(macos_egress_verified_file)" ]] && fail "boot fails before its self-test: a record exists" \
  || ok "boot fails before its self-test: no record"
unset -f macos_boot_ssh_failed; eval "$(sed -n '/^macos_boot_ssh_failed() {$/,/^}$/p' "$AUGUR")"
wait_for_macos_ssh() { return 0; }
# --no-egress: no self-test, so no record.
egress_off; verified 4242
run_cmd cmd_up_macos
eq 0 "$rc" "boot --no-egress: completes"
[[ -e "$(macos_egress_verified_file)" ]] && fail "boot --no-egress: a record exists" || ok "boot --no-egress: no record"
boot_id 4242

section "Tier 1 — a stopped VM goes through up (which writes a fresh record)"
VM_UP=0; egress_on; record off
cmd_up_macos_real="$(declare -f cmd_up_macos)"
cmd_up_macos() { echo "CMD_UP_MACOS" >> "$LOG"; }
run_cmd cmd_claude_macos
eq 0 "$rc" "claude --macos on a stopped VM: not refused over a stale record"
logged CMD_UP_MACOS && ok "claude --macos on a stopped VM: boots it via up" || fail "claude --macos did not call up"
eval "$cmd_up_macos_real"

section "Tier 1 — the record is per project: keyed on the full path, not the directory name"
# Two projects with the same basename (~/work/app vs ~/archive/app): one's record must never answer
# for the other, or a --no-egress VM of one could pass the other's egress check.
WS_SAVE="$WORKSPACE_DIR"
WORKSPACE_DIR="$TMPD/work/app";    rec_a="$(macos_egress_mode_file)"
WORKSPACE_DIR="$TMPD/archive/app"; rec_b="$(macos_egress_mode_file)"
[[ "$rec_a" != "$rec_b" ]] && ok "same basename, different paths: different record files" || fail "two projects share one record file" "$rec_a"
has "$rec_a" "/app-" "the record name carries the project slug"
WORKSPACE_DIR="$TMPD/work/app"; egress_on; record off
WORKSPACE_DIR="$TMPD/archive/app"; rm -f "$rec_b"
run_cmd require_macos_egress_mode_current somevm
[[ "$rc" -ne 0 ]] && ok "another project's record does not satisfy this one (no record here: refused)" || fail "another project's record was read for this one"
has "$out" "unknown egress mode" "…as an unknown egress mode"
WORKSPACE_DIR="$TMPD/work/app"; record on
WORKSPACE_DIR="$TMPD/archive/app"; record off
WORKSPACE_DIR="$TMPD/work/app"
eq "on" "$(cat "$(macos_egress_mode_file)")" "writing one project's record leaves the other's alone"
# `destroy <name>` addresses another project through TARGET_SLUG/TARGET_HASH: the record it drops is
# that project's, whatever the current directory.
want="$rec_b"
slug_b="$(WORKSPACE_DIR="$TMPD/archive/app"; workspace_slug)"; hash_b="$(WORKSPACE_DIR="$TMPD/archive/app"; workspace_path_hash)"
eq "$want" "$(TARGET_SLUG="$slug_b"; TARGET_HASH="$hash_b"; macos_egress_mode_file)" "an explicit target resolves to that project's record from anywhere"
WORKSPACE_DIR="$WS_SAVE"

section "Tier 1 — down / destroy drop the records"
egress_on
for c in cmd_down_macos cmd_destroy_macos; do
  record on; verified 4242
  run_cmd "$c"
  [[ -e "$(macos_egress_mode_file)" ]] && fail "$c leaves the record behind" || ok "$c removes the record"
  [[ -e "$(macos_egress_verified_file)" ]] && fail "$c leaves the self-test record behind" || ok "$c removes the self-test record"
done
macos_vm_exists() { return 1; }
record on; verified 4242
run_cmd cmd_down_macos
[[ -e "$(macos_egress_mode_file)" ]] && fail "down with no VM leaves the record" || ok "down with no VM still removes the record"
[[ -e "$(macos_egress_verified_file)" ]] && fail "down with no VM leaves the self-test record" || ok "down with no VM still removes the self-test record"

finish
