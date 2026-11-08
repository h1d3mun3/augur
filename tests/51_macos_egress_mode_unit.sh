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
# self-test passed during the VM's current boot (macos_egress_verified_file, tied to the boot by its
# run id: augur-vm's pid and that process's start time, read in UTC so the id does not depend on
# TZ, and so a recycled pid does not match). `claude` / `shell --macos` on a running egress VM
# without it (an `up` interrupted before its self-test, a record from an earlier boot) refuse with
# no guest step but the refusal's push of ~/.augur-env (no credential), naming `up --macos`;
# `up --macos` on the running VM re-runs the self-test and records it. The boot path drops it before
# `augur-vm run` and writes it only after the self-test; --no-egress has none; down/destroy and a
# failing self-test drop it. An `up` that cannot read the run id after a passed self-test fails and
# stops the VM.
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
ensure_macos_agent_profile() { :; }; ensure_macos_agent_bin() { :; }
push_macos_guest_env() { echo "push $*" >> "$LOG"; }   # the push itself: tests/56
macos_poweroff_before_teardown() { :; }
scp_to_macos() { :; }
ssh_macos() { echo "ssh $*" >> "$LOG"; [[ "$*" == *"cat > "* ]] && cat >/dev/null; [[ "$*" == *" -t "* ]] && echo AGENT_ATTACHED; return 0; }
ssh_macos_session() { ssh_macos "$@"; }
egress_on()  { AUGUR_EGRESS=auto; }
egress_off() { AUGUR_EGRESS=0; }
record() { mkdir -p "$AUGUR_PROXY_DIR"; printf '%s\n' "$1" > "$(macos_egress_mode_file)"; }
# The VM's current boot: run.pid holds a live pid (this shell's; BOOT2 is a second boot's process),
# and its id (macos_vm_run_id) adds that process's start time. A `ps` stand-in answers a fixed
# start time per pid so ids cannot drift mid-file (Linux procps computes start times from the
# kernel's boot time, which moves when the host clock is stepped); the run-id section below uses
# the real ps.
SHIMDIR="$TMPD/shim"; mkdir -p "$SHIMDIR"; REAL_PS="$(command -v ps)"
cat > "$SHIMDIR/ps" <<EOF
#!/usr/bin/env bash
if [[ "\${REAL_LSTART:-0}" != 1 && "\$*" == "-o lstart= -p "* ]]; then
  kill -0 "\$4" 2>/dev/null || exit 1; echo "Sun Nov  8 10:00:\$(( \$4 % 60 )) 2026"; exit 0
fi
exec "$REAL_PS" "\$@"
EOF
chmod +x "$SHIMDIR/ps"; PATH="$SHIMDIR:$PATH"
sleep 600 & BOOT2=$!
trap 'kill "$BOOT2" 2>/dev/null; rm -rf "$TMPD"' EXIT
RUN_ID_FILE="$AUGUR_DIR/vms/$PV/run.pid"
boot_id()  { printf '%s\n' "$1" > "$RUN_ID_FILE"; }
verified() { mkdir -p "$AUGUR_PROXY_DIR"; printf '%s\n' "$1" > "$(macos_egress_verified_file)"; }
# The record of a pass during the boot run.pid currently names.
verified_now() { verified "$(macos_vm_run_id "$PV")"; }
boot_id "$$"
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
  egress_on; record on; verified_now
  run_cmd "$c"
  eq 0 "$rc" "$c on an egress VM: attaches"
  has "$out" "AGENT_ATTACHED" "$c on an egress VM: the session is launched"
  egress_off; record off
  run_cmd "$c"
  eq 0 "$rc" "$c --no-egress on a --no-egress VM: attaches"
done

section "Tier 1 — a VM's run id is its augur-vm pid plus that process's start time (the real ps)"
export REAL_LSTART=1
# This shell's start time from the real ps, as the id must carry it: UTC, the C locale, the column
# padding collapsed.
lst() { LC_ALL=C TZ=UTC0 "$REAL_PS" -o lstart= -p "$1" | tr -s ' ' | sed 's/^ //; s/ $//'; }
# Linux procps derives a start time from the boot time the kernel reports, which moves when the
# host's clock is stepped (a VM's clock resync after its host slept moves every process's start
# time at once). steady <check...>: run the check (0 = pass) up to three times, again only when this
# shell's start time changed while it ran, so a step mid-check cannot fail it and a real mismatch
# still does.
steady() { local _sb _si; for _si in 1 2 3; do _sb="$(lst $$)"; "$@" && return 0; [[ "$(lst $$)" == "$_sb" ]] && return 1; done; return 1; }
boot_id "$$"
c_shape() { id="$(macos_vm_run_id "$PV")"; want="$$ $(lst $$)"; [[ -n "$(lst $$)" && "$id" == "$want" ]]; }
steady c_shape && ok "the id is '<pid> <start time>', ps's padding collapsed" || fail "the id is not '<pid> <start time>'" "expected [$want], got [$id]"
hasnt "$id" "  " "the id holds no run of spaces"
c_same() { [[ "$(macos_vm_run_id "$PV")" == "$(macos_vm_run_id "$PV")" ]]; }
steady c_same && ok "the id is the same on every read" || fail "two reads of the id differ"
# ps prints lstart in local time, so the id is read under a pinned TZ: augur runs that read and
# write the record may have different ones. POSIX TZ strings, so no zoneinfo files are needed.
c_tz() { a="$(export TZ=JST-9; macos_vm_run_id "$PV")"; b="$(export TZ=PST8PDT; macos_vm_run_id "$PV")"; c="$(unset TZ; macos_vm_run_id "$PV")"
         [[ -n "$a" && "$a" == "$b" && "$a" == "$c" ]]; }
steady c_tz && ok "the id is the same under TZ=JST-9, TZ=PST8PDT and no TZ" || fail "the id depends on TZ" "[$a] [$b] [$c]"
c_tz_raw() { [[ "$(TZ=JST-9 LC_ALL=C "$REAL_PS" -o lstart= -p $$)" != "$(TZ=PST8PDT LC_ALL=C "$REAL_PS" -o lstart= -p $$)" ]]; }
steady c_tz_raw && ok "control: ps's own lstart differs between those TZs (the pin is what keeps the id equal)" \
  || fail "control: ps's lstart does not depend on TZ here (the TZ check above is vacuous)"
c_other() { boot_id "$BOOT2"; o="$(macos_vm_run_id "$PV")"; boot_id "$$"; [[ "$o" == "$BOOT2 "?* && "$o" != "$(macos_vm_run_id "$PV")" ]]; }
steady c_other && ok "another process (another boot) has another id" || fail "another boot's id is not its own" "$o"
c_nonl() { printf '%s' "$$" > "$RUN_ID_FILE"; [[ "$(macos_vm_run_id "$PV")" == "$$ $(lst $$)" ]]; }
steady c_nonl && ok "a pidfile without a trailing newline (augur-vm writes none) gives the same id" || fail "a pidfile without a trailing newline gives another id"
sleep 0 & _dead=$!; wait "$_dead"; boot_id "$_dead"
eq "" "$(macos_vm_run_id "$PV")" "a pid with no process: no id"
boot_id "not-a-pid"
eq "" "$(macos_vm_run_id "$PV")" "a pidfile that holds no pid: no id"
rm -f "$RUN_ID_FILE"
eq "" "$(macos_vm_run_id "$PV")" "no pidfile: no id"
# A recycled pid: the record holds this pid with an earlier process's start time.
boot_id "$$"; egress_on; verified "$$ Thu Jan 1 00:00:00 1970"
run_cmd require_macos_egress_verified "$PV"
[[ "$rc" -ne 0 ]] && ok "a record for the same pid with another start time is refused" || fail "a recycled pid matched the record"
c_accept() { verified "$(macos_vm_run_id "$PV")"; run_cmd require_macos_egress_verified "$PV"; [[ "$rc" == 0 ]]; }
steady c_accept && ok "the record of this boot is accepted (control)" || fail "the record of this boot is refused" "$out"
unset REAL_LSTART

section "Tier 1 — a running VM gets a session only if its current boot passed the self-test"
# An `up --macos` interrupted between `augur-vm run` and the self-test leaves a running VM with no
# record of a passed self-test (macos_egress_verified_file); one booted again has a new run id.
unverified() {   # unverified <label>
  [[ "$rc" -ne 0 ]] && ok "$1: exits non-zero" || fail "$1: was not refused"
  has "$out" "no egress self-test has passed since it booted" "$1: says why"
  has "$out" "to re-run the egress self-test on the running VM" "$1: gives the remedy (up --macos)"
  hasnt "$out" "augur down --macos" "$1: does not send the operator through a restart"
  hasnt "$out" "AGENT_ATTACHED" "$1: nothing is attached"
  grep -q '^ssh ' "$LOG" && fail "$1: the guest got a session or another command" "$(cat "$LOG")" || ok "$1: no session and no other guest command"
  # The one guest step a refusal makes: the push of ~/.augur-env, which sends no credential and
  # rewrites one an older augur may have left credentials in.
  eq "push $PV --refusing" "$(grep '^push ' "$LOG")" "$1: pushes ~/.augur-env once, as a refusal, before refusing"
  if logged "vm stop $PV" || logged stop_gvproxy || logged stop_proxy; then
    fail "$1: the VM or its egress helpers were stopped" "$(cat "$LOG")"
  else ok "$1: the running VM is left alone (nothing stopped)"; fi
}
VM_UP=1
for c in cmd_claude_macos cmd_shell_macos; do
  egress_on; record on; rm -f "$(macos_egress_verified_file)"
  run_cmd "$c"
  unverified "$c, no record of a passed self-test"
  egress_on; record on; verified "$(boot_id "$BOOT2"; macos_vm_run_id "$PV")"; boot_id "$$"
  run_cmd "$c"
  unverified "$c, a record from an earlier boot (another run id)"
  egress_on; record on; verified "$$ Thu Jan 1 00:00:00 1970"
  run_cmd "$c"
  unverified "$c, a record for this boot's pid with another start time (a recycled pid)"
  egress_on; record on; verified_now; rm -f "$RUN_ID_FILE"
  run_cmd "$c"
  unverified "$c, no run id to match the record against"
  boot_id "$$"
  egress_off; record off; rm -f "$(macos_egress_verified_file)"
  run_cmd "$c"
  eq 0 "$rc" "$c --no-egress: attaches with no record (a --no-egress boot has no self-test)"
done
# `up --macos` on the running VM re-runs the self-test, and its pass is recorded for this boot.
egress_on; record on; rm -f "$(macos_egress_verified_file)"
run_cmd cmd_up_macos
eq 0 "$rc" "up --macos on an unverified running VM: reconciles"
logged selftest && ok "up --macos on an unverified running VM: runs the self-test" || fail "up --macos: no self-test"
eq "$(macos_vm_run_id "$PV")" "$(cat "$(macos_egress_verified_file)" 2>/dev/null)" "up --macos on a running VM: records the pass with this boot's run id"
run_cmd cmd_claude_macos
eq 0 "$rc" "…after which claude --macos attaches"
# A failing self-test on that path records nothing, and drops a record that was there.
verify_real="$(declare -f verify_macos_egress_locked)"
verify_macos_egress_locked() { echo "selftest" >> "$LOG"; stop_unverified_macos_vm "$1"; exit 1; }
egress_on; record on; verified_now
run_cmd cmd_up_macos
[[ "$rc" -ne 0 ]] && ok "self-test fails on a running VM: up exits non-zero" || fail "self-test fails on a running VM: up exited 0"
[[ -e "$(macos_egress_verified_file)" ]] && fail "self-test fails on a running VM: the record survives" \
  || ok "self-test fails on a running VM: the record is dropped"
eval "$verify_real"
# No run id after a passed self-test (no pidfile; a pid with no process; the process's start time
# unreadable): the pass cannot be recorded, so `up` fails and stops the VM it cannot vouch for, on
# the running VM and on a boot alike, rather than leave one every session refuses.
no_run_id() {   # no_run_id <label>
  [[ "$rc" -ne 0 ]] && ok "$1: up --macos exits non-zero" || fail "$1: up --macos exited 0"
  has "$out" "Could not read VM '$PV''s run id" "$1: says the run id is unreadable"
  has "$out" "cannot be recorded" "$1: says the pass cannot be recorded"
  logged selftest && ok "$1: the self-test ran first (control)" || fail "$1: no self-test ran"
  logged "vm stop $PV" && ok "$1: the VM is stopped" || fail "$1: the VM was left running" "$(cat "$LOG")"
  logged stop_gvproxy && logged stop_proxy && ok "$1: its gvproxy and proxy are stopped" || fail "$1: egress helpers left running"
  logged "vm delete $PV" && fail "$1: the clone was deleted" || ok "$1: the clone is kept"
  [[ -e "$(macos_egress_verified_file)" ]] && fail "$1: a record was written" || ok "$1: nothing is recorded"
}
VM_UP=1; egress_on; record on
rm -f "$RUN_ID_FILE" "$(macos_egress_verified_file)"
run_cmd cmd_up_macos; no_run_id "running VM, no pidfile"
sleep 0 & _dead=$!; wait "$_dead"; boot_id "$_dead"; verified_now
run_cmd cmd_up_macos; no_run_id "running VM, a pid with no process"
boot_id "$$"; mv "$SHIMDIR/ps" "$SHIMDIR/ps.saved"
printf '#!/bin/sh\nexit 1\n' > "$SHIMDIR/ps"; chmod +x "$SHIMDIR/ps"
run_cmd cmd_up_macos; no_run_id "running VM, ps cannot read the start time"
mv "$SHIMDIR/ps.saved" "$SHIMDIR/ps"
VM_UP=0; rm -f "$RUN_ID_FILE"
run_cmd cmd_up_macos; no_run_id "boot, no pidfile"
hasnt "$out" "is up." "boot, no pidfile: no success banner"
VM_UP=1; boot_id "$$"

section "Tier 1 — the boot path drops the record before \`augur-vm run\` and writes it after the self-test"
VM_UP=0
egress_on; verified_now; boot_id "$BOOT2"
wait_for_macos_ssh() { cp "$(macos_egress_verified_file)" "$TMPD/verified-at-boot" 2>/dev/null; return 0; }
rm -f "$TMPD/verified-at-boot"
run_cmd cmd_up_macos
eq 0 "$rc" "boot: completes"
[[ -e "$TMPD/verified-at-boot" ]] && fail "boot: a record from an earlier boot is still there while this one boots" \
  || ok "boot: the earlier boot's record is gone before the VM boots"
eq "$(macos_vm_run_id "$PV")" "$(cat "$(macos_egress_verified_file)" 2>/dev/null)" "boot: the pass is recorded with this boot's run id"
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
verified_now
run_cmd cmd_up_macos
[[ -e "$(macos_egress_verified_file)" ]] && fail "boot fails before its self-test: a record exists" \
  || ok "boot fails before its self-test: no record"
unset -f macos_boot_ssh_failed; eval "$(sed -n '/^macos_boot_ssh_failed() {$/,/^}$/p' "$AUGUR")"
wait_for_macos_ssh() { return 0; }
# --no-egress: no self-test, so no record.
egress_off; verified_now
run_cmd cmd_up_macos
eq 0 "$rc" "boot --no-egress: completes"
[[ -e "$(macos_egress_verified_file)" ]] && fail "boot --no-egress: a record exists" || ok "boot --no-egress: no record"
boot_id "$$"

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
  record on; verified_now
  run_cmd "$c"
  [[ -e "$(macos_egress_mode_file)" ]] && fail "$c leaves the record behind" || ok "$c removes the record"
  [[ -e "$(macos_egress_verified_file)" ]] && fail "$c leaves the self-test record behind" || ok "$c removes the self-test record"
done
macos_vm_exists() { return 1; }
record on; verified_now
run_cmd cmd_down_macos
[[ -e "$(macos_egress_mode_file)" ]] && fail "down with no VM leaves the record" || ok "down with no VM still removes the record"
[[ -e "$(macos_egress_verified_file)" ]] && fail "down with no VM leaves the self-test record" || ok "down with no VM still removes the self-test record"

finish
