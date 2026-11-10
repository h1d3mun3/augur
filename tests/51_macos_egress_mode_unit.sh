#!/usr/bin/env bash
# Tier 1 (offline) — macOS mode refuses to attach to a running VM booted with a different egress mode.
#
# The hazard. `claude --macos` and `shell --macos` skip `up` when the VM is already running. Without a
# check, `augur up --macos --no-egress` followed by a plain `augur claude --macos` would run the agent
# on an unfiltered NAT network with no word said; and a plain `augur up --macos` on that VM would run
# the boot self-test against a NAT guest, "detect a leak" and stop the VM under the operator. The
# fix: the egress mode a VM is booted with is recorded host-side at boot (macos_boot_record_file),
# and up/claude/shell on a running VM refuse — without stopping it, after the credential-free push
# of ~/.augur-env every refusal of a running VM makes — when the requested mode differs or the
# record is missing (as does `up` on a running VM with no stored admin password). down/destroy drop
# the record.
#
# The same file pins the record's second field, which a running VM is attached by: that the egress
# self-test passed during the VM's current boot (the record's pass, tied to the boot by its
# run id: the random id augur-vm's `run` writes to run.id for each boot). `claude` / `shell --macos`
# on a running egress VM
# without it (an `up` interrupted before its self-test, a record from an earlier boot) refuse with
# no guest step but the refusal's push of ~/.augur-env (no credential), naming `up --macos`;
# `up --macos` on the running VM re-runs the self-test and records it. The boot path drops it before
# `augur-vm run` and writes it only after the self-test; --no-egress has none; down/destroy and a
# failing self-test drop it. An `up` that cannot read the run id after a passed self-test fails and
# leaves no record; on a boot it stops the VM, on a running VM it leaves the VM running. The record
# is renamed into place, never written in place.
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
# The boot record (macos_boot_record_file), one line `<mode> <pass>`, read and set one field at a
# time: record <mode> keeps the pass, verified <run id> keeps the mode; `-` is no pass.
mode_of() { local l; l="$(cat "$(macos_boot_record_file)" 2>/dev/null)" || return 0; printf '%s' "${l%% *}"; }
pass_of() { local l; l="$(cat "$(macos_boot_record_file)" 2>/dev/null)" || { printf -- -; return 0; }; printf '%s' "${l#* }"; }
has_pass() { [[ "$(pass_of)" != - ]]; }
record() { local p; p="$(pass_of)"; mkdir -p "$AUGUR_PROXY_DIR"; printf '%s %s\n' "$1" "$p" > "$(macos_boot_record_file)"; }
no_pass() { verified -; }
# The VM's current boot: the UUID augur-vm's `run` writes to run.id, without a trailing newline
# (BOOT1; BOOT2 is another boot's), and the pid it writes to run.pid (this shell's by default, so
# the process is alive; BOOT2_PID is another live process). Its run id (macos_vm_run_id) adds that
# process's start time. A `ps` stand-in answers a fixed start time per pid so ids cannot drift
# mid-file (Linux procps computes start times from the kernel's boot time, which moves when the
# host clock is stepped); the run-id section below uses the real ps.
BOOT1=1A2B3C4D-5E6F-4A1B-8C2D-3E4F5A6B7C01; BOOT2=1A2B3C4D-5E6F-4A1B-8C2D-3E4F5A6B7C02
SHIMDIR="$TMPD/shim"; mkdir -p "$SHIMDIR"; REAL_PS="$(command -v ps)"
cat > "$SHIMDIR/ps" <<EOS
#!/usr/bin/env bash
if [[ "\${REAL_LSTART:-0}" != 1 && "\$*" == "-o lstart= -p "* ]]; then
  kill -0 "\$4" 2>/dev/null || exit 1; echo "Sun Nov  8 10:00:\$(( \$4 % 60 )) 2026"; exit 0
fi
exec "$REAL_PS" "\$@"
EOS
chmod +x "$SHIMDIR/ps"; PATH="$SHIMDIR:$PATH"
sleep 600 & BOOT2_PID=$!
trap 'kill "$BOOT2_PID" 2>/dev/null; rm -rf "$TMPD"' EXIT
RUN_ID_FILE="$AUGUR_DIR/vms/$PV/run.id"; RUN_PID_FILE="$AUGUR_DIR/vms/$PV/run.pid"
boot_id()  { printf '%s' "$1" > "$RUN_ID_FILE"; printf '%s' "${2:-$$}" > "$RUN_PID_FILE"; }
# The run id boot_id "$@" would give, leaving the current boot as it is.
id_for() {
  local a b; a="$(command cat "$RUN_ID_FILE" 2>/dev/null)"; b="$(command cat "$RUN_PID_FILE" 2>/dev/null)"
  boot_id "$@"; macos_vm_run_id "$PV"; printf '%s' "$a" > "$RUN_ID_FILE"; printf '%s' "$b" > "$RUN_PID_FILE"
}
verified() { local m; m="$(mode_of)"; mkdir -p "$AUGUR_PROXY_DIR"; printf '%s %s\n' "${m:-on}" "$1" > "$(macos_boot_record_file)"; }
# The record of a pass during the boot run.id currently names.
verified_now() { verified "$(macos_vm_run_id "$PV")"; }
boot_id "$BOOT1"
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
  # Like every refusal of a running VM: one push of ~/.augur-env (no credential), which rewrites a
  # file an older augur may have left credentials in, and no other guest command.
  eq "push $PV --refusing" "$(grep '^push ' "$LOG")" "$1: pushes ~/.augur-env once, as a refusal"
  grep -q '^ssh ' "$LOG" && fail "$1: the guest got another command" "$(cat "$LOG")" || ok "$1: no other guest command"
}

section "Tier 1 — the record is written on the boot path, before \`augur-vm run\`"
VM_UP=0
egress_on
rm -f "$(macos_boot_record_file)"
wait_for_macos_ssh() { cp "$(macos_boot_record_file)" "$TMPD/at-boot" 2>/dev/null; return 0; }
run_cmd cmd_up_macos
[[ "$rc" == 0 ]] && ok "up --macos (egress on): boots" || fail "up --macos (egress on): boots" "rc=$rc: $(tail -n 3 <<<"$out")"
eq "on" "$(mode_of)" "up --macos records egress 'on'"
eq "on -" "$(cat "$TMPD/at-boot" 2>/dev/null)" "the record exists by the time the VM is booting, with no pass yet"
fn="$(declare -f cmd_up_macos)"
rec_at="$(grep -n 'macos_record_egress_mode' <<<"$fn" | head -n1 | cut -d: -f1)"
run_at="$(grep -n '"\$VM_CLI" run' <<<"$fn" | head -n1 | cut -d: -f1)"
if [[ -n "$rec_at" && -n "$run_at" && "$rec_at" -lt "$run_at" ]]; then ok "the record is written before 'augur-vm run' (no running VM without one)"
else fail "the record is not written before 'augur-vm run'" "record@$rec_at run@$run_at"; fi
egress_off; rm -f "$TMPD/at-boot"
run_cmd cmd_up_macos
eq "off -" "$(cat "$(macos_boot_record_file)" 2>/dev/null)" "up --macos --no-egress records egress 'off', and no pass"

section "Tier 1 — up --macos on a RUNNING VM: mismatch refuses, match reconciles"
VM_UP=1
egress_on; record off
run_cmd cmd_up_macos
refused "up --macos on a --no-egress VM" "augur down --macos && augur up --macos"
hasnt "$out" "reconciling host-side state" "up --macos on a --no-egress VM: the reconcile is not reached"

egress_off; record on
run_cmd cmd_up_macos
refused "up --macos --no-egress on an egress VM" "augur down --macos && augur up --macos --no-egress"

egress_on; rm -f "$(macos_boot_record_file)"
run_cmd cmd_up_macos
refused "up --macos on a VM with no record" "augur down --macos && augur up --macos" "unknown egress mode"
has "$out" "started by an older augur" "no record: names the likely cause"
# One record holds both fields; one that does not parse is no record. An older augur kept the mode
# and the pass in two other files (`.egress-mode`, `.egress-verified`), which are not read.
_rec_dir="$(dirname "$(macos_boot_record_file)")"; _rec_stem="$(basename "$(macos_boot_record_file)" .boot-record)"
for _bad in "on" "maybe -" "on - extra" $'on -\non -' "" "-"; do
  printf '%s\n' "$_bad" > "$(macos_boot_record_file)"
  run_cmd require_macos_egress_mode_current "$PV"
  refused "a boot record that does not parse ($(printf '%q' "$_bad"))" "augur down --macos && augur up --macos" "unknown egress mode"
done
# The pass field: `-`, or a run id (a UUID, a space, then a start time); anything else is no record.
_uuid="0A1B2C3D-4E5F-6789-ABCD-EF0123456789"
read_rec() { local _mode _pass; printf '%s\n' "$1" > "$(macos_boot_record_file)"; macos_read_boot_record; printf '%s|%s' "$_mode" "$_pass"; }
eq "on|" "$(read_rec "on -")" "boot record 'on -': mode on, no pass"
eq "on|${_uuid} Mon Nov 10 09:00:00 2026" "$(read_rec "on ${_uuid} Mon Nov 10 09:00:00 2026")" "boot record with a run id: mode and pass"
eq "off|${_uuid} x" "$(read_rec "off ${_uuid} x")" "boot record 'off' with a run id: both read"
for _bad in "on ${_uuid}" "on ${_uuid} " "on ${_uuid}  x" "on not-a-uuid Mon" "on ${_uuid/0A/0G} Mon" "on x${_uuid} Mon"; do
  eq "|" "$(read_rec "$_bad")" "a pass that is not a run id is no record ($(printf '%q' "$_bad"))"
done
rm -f "$(macos_boot_record_file)"
printf 'on\n' > "$_rec_dir/$_rec_stem.egress-mode"; printf '%s\n' "$BOOT1" > "$_rec_dir/$_rec_stem.egress-verified"
for c in cmd_up_macos cmd_claude_macos cmd_shell_macos; do
  run_cmd "$c"
  refused "$c on a VM an older augur started (its two old records, no boot record)" "augur down --macos && augur up --macos" "unknown egress mode"
  has "$out" "started by an older augur" "$c on a VM an older augur started: names the likely cause"
done
rm -f "$_rec_dir/$_rec_stem.egress-mode" "$_rec_dir/$_rec_stem.egress-verified"

# A running VM with no stored admin password (cloned from an older base) is refused like the rest:
# its push uses only the SSH key. A stopped one is refused before anything touches the guest.
egress_on; record on; mv "$(macos_admin_password_file "$PV")" "$TMPD/pw.saved"
run_cmd cmd_up_macos
refused "up --macos on a running VM with no admin password" "augur destroy --macos && augur up --macos" "has no stored admin password"
VM_UP=0
run_cmd cmd_up_macos
[[ "$rc" -ne 0 ]] && ok "up --macos on a stopped VM with no admin password: refused" || fail "stopped VM, no admin password: not refused"
has "$out" "has no stored admin password" "stopped VM, no admin password: says why"
grep -q '^push \|^ssh \|^vm run' "$LOG" && fail "stopped VM, no admin password: the guest was touched or booted" "$(cat "$LOG")" \
  || ok "stopped VM, no admin password: nothing is pushed or booted"
VM_UP=1; mv "$TMPD/pw.saved" "$(macos_admin_password_file "$PV")"

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
  egress_on; rm -f "$(macos_boot_record_file)"
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

section "Tier 1 — a VM's run id is run.id's UUID plus the start time of the process in run.pid"
boot_id "$BOOT1"
sid() { echo "Sun Nov 8 10:00:$(( $1 % 60 )) 2026"; }   # the stand-in's start time for pid $1, padding collapsed
eq "$BOOT1 $(sid $$)" "$(macos_vm_run_id "$PV")" "the id is '<uuid> <start time>' (augur-vm writes no trailing newlines)"
printf '%s\n' "$BOOT1" > "$RUN_ID_FILE"; printf '%s\n' "$$" > "$RUN_PID_FILE"
eq "$BOOT1 $(sid $$)" "$(macos_vm_run_id "$PV")" "…and the same with trailing newlines"
hasnt "$(macos_vm_run_id "$PV")" "  " "the id holds no run of spaces"
boot_id "$BOOT2"
eq "$BOOT2 $(sid $$)" "$(macos_vm_run_id "$PV")" "another boot (another UUID, the same pid) has another id"
boot_id "$BOOT1" "$BOOT2_PID"
eq "$BOOT1 $(sid "$BOOT2_PID")" "$(macos_vm_run_id "$PV")" "the same UUID with another live process (a reused pid) has another id"
for _bad in "not-a-uuid" "$BOOT1 $BOOT2" "$BOOT1"$'\n'"$BOOT2" "${BOOT1}0" "x${BOOT1}" "$BOOT1;rm" ""; do
  boot_id "$_bad"
  eq "" "$(macos_vm_run_id "$PV")" "a run.id that is not one UUID gives no id: $(printf '%q' "$_bad")"
done
boot_id "$BOOT1"; rm -f "$RUN_ID_FILE"
eq "" "$(macos_vm_run_id "$PV")" "no run.id (an augur-vm older than this augur writes none): no id"
if [[ "$(id -u)" != 0 ]]; then
  boot_id "$BOOT1"; chmod 000 "$RUN_ID_FILE"
  eq "" "$(macos_vm_run_id "$PV")" "an unreadable run.id: no id"
  chmod 600 "$RUN_ID_FILE"
else skip "an unreadable run.id: no id" "running as root, which reads any file"; fi
boot_id "$BOOT1"; rm -f "$RUN_PID_FILE"
eq "" "$(macos_vm_run_id "$PV")" "no run.pid: no id"
boot_id "$BOOT1" "not-a-pid"
eq "" "$(macos_vm_run_id "$PV")" "a run.pid that holds no pid: no id"
sleep 0 & _dead=$!; wait "$_dead"; boot_id "$BOOT1" "$_dead"
eq "" "$(macos_vm_run_id "$PV")" "a pid with no process: no id"
# A record from another boot, or for this boot's UUID and pid with another process's start time (a
# pid an unrelated process took after a host crash), is refused; this boot's is accepted.
boot_id "$BOOT1"; egress_on; record on
for _other in "$(id_for "$BOOT2")" "$BOOT1 Thu Jan 1 00:00:00 1970" "$(id_for "$BOOT1" "$BOOT2_PID")"; do
  verified "$_other"
  run_cmd require_macos_egress_verified "$PV"
  [[ "$rc" -ne 0 ]] && ok "a record of another boot or process is refused: $_other" || fail "a record of another boot or process matched: $_other"
done
verified_now
run_cmd require_macos_egress_verified "$PV"
eq 0 "$rc" "the record of this boot is accepted (control)"
rm -f "$RUN_ID_FILE"
run_cmd require_macos_egress_verified "$PV"
[[ "$rc" -ne 0 ]] && ok "a record with no run.id to match it against is refused" || fail "a record matched a missing run.id"
boot_id "$BOOT1"; verified_now; boot_id "$BOOT1" "$_dead"
run_cmd require_macos_egress_verified "$PV"
[[ "$rc" -ne 0 ]] && ok "a record whose run.pid names no live process is refused" || fail "a record matched a dead pid"
boot_id "$BOOT1"

section "Tier 1 — the run id's start time comes from the real ps, pinned to UTC and the C locale"
export REAL_LSTART=1
# This shell's start time from the real ps, as the id must carry it: UTC, the C locale, the column
# padding collapsed.
lst() { LC_ALL=C TZ=UTC0 "$REAL_PS" -o lstart= -p "$1" | tr -s ' ' | sed 's/^ //; s/ $//'; }
# Linux procps derives a start time from the boot time the kernel reports, which moves when the
# host's clock is stepped. steady <check...>: run the check (0 = pass) up to three times, again only
# when this shell's start time changed while it ran, so a step mid-check cannot fail it and a real
# mismatch still does.
steady() { local _sb _si; for _si in 1 2 3; do _sb="$(lst $$)"; "$@" && return 0; [[ "$(lst $$)" == "$_sb" ]] && return 1; done; return 1; }
boot_id "$BOOT1"
c_shape() { id="$(macos_vm_run_id "$PV")"; want="$BOOT1 $(lst $$)"; [[ -n "$(lst $$)" && "$id" == "$want" ]]; }
steady c_shape && ok "the id is '<uuid> <start time>', ps's padding collapsed" || fail "the id is not '<uuid> <start time>'" "expected [$want], got [$id]"
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
c_lc() { a="$(export LC_ALL=de_DE.UTF-8 LANG=de_DE.UTF-8; macos_vm_run_id "$PV")"; [[ -n "$a" && "$a" == "$(macos_vm_run_id "$PV")" ]]; }
steady c_lc && ok "the id is the same under another locale" || fail "the id depends on the locale" "[$a]"
c_accept() { verified "$(macos_vm_run_id "$PV")"; run_cmd require_macos_egress_verified "$PV"; [[ "$rc" == 0 ]]; }
steady c_accept && ok "the record of this boot is accepted (control, the real ps)" || fail "the record of this boot is refused" "$out"
unset REAL_LSTART

section "Tier 1 — a running VM gets a session only if its current boot passed the self-test"
# An `up --macos` interrupted between `augur-vm run` and the self-test leaves a running VM with no
# pass in its boot record (macos_boot_record_file); one booted again has a new run id.
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
  egress_on; record on; no_pass
  run_cmd "$c"
  unverified "$c, no record of a passed self-test"
  egress_on; record on; verified "$(id_for "$BOOT2")"
  run_cmd "$c"
  unverified "$c, a record from an earlier boot (another run id)"
  egress_on; record on; verified_now; rm -f "$RUN_ID_FILE"
  run_cmd "$c"
  unverified "$c, no run id to match the record against"
  boot_id "$BOOT1"
  egress_off; record off; no_pass
  run_cmd "$c"
  eq 0 "$rc" "$c --no-egress: attaches with no record (a --no-egress boot has no self-test)"
done
# `up --macos` on the running VM re-runs the self-test, and its pass is recorded for this boot.
egress_on; record on; no_pass
run_cmd cmd_up_macos
eq 0 "$rc" "up --macos on an unverified running VM: reconciles"
logged selftest && ok "up --macos on an unverified running VM: runs the self-test" || fail "up --macos: no self-test"
eq "$(macos_vm_run_id "$PV")" "$(pass_of)" "up --macos on a running VM: records the pass with this boot's run id"
run_cmd cmd_claude_macos
eq 0 "$rc" "…after which claude --macos attaches"
# A failing self-test on that path records nothing, and drops a record that was there.
verify_real="$(declare -f verify_macos_egress_locked)"
verify_macos_egress_locked() { echo "selftest" >> "$LOG"; stop_unverified_macos_vm "$1"; exit 1; }
egress_on; record on; verified_now
run_cmd cmd_up_macos
[[ "$rc" -ne 0 ]] && ok "self-test fails on a running VM: up exits non-zero" || fail "self-test fails on a running VM: up exited 0"
has_pass && fail "self-test fails on a running VM: the record survives" \
  || ok "self-test fails on a running VM: the record is dropped"
eval "$verify_real"
# No run id after a passed self-test (no run.id; one that holds no UUID; one that cannot be read):
# the pass cannot be recorded, so `up` fails and leaves no record, which every session
# then refuses. On a boot it also stops the VM it just booted; on a running VM, which may be serving
# live sessions and whose run id may be unreadable only for a moment, it leaves the VM running and
# refuses it as every refusal of a running VM does (one push of ~/.augur-env first).
no_run_id() {   # no_run_id <label> running|boot
  [[ "$rc" -ne 0 ]] && ok "$1: up --macos exits non-zero" || fail "$1: up --macos exited 0"
  has "$out" "Could not read VM '$PV''s run id" "$1: says the run id is unreadable"
  has "$out" "cannot be recorded" "$1: says the pass cannot be recorded"
  logged selftest && ok "$1: the self-test ran first (control)" || fail "$1: no self-test ran"
  logged "vm delete $PV" && fail "$1: the clone was deleted" || ok "$1: the clone is kept"
  has_pass && fail "$1: a record is left (sessions would attach)" || ok "$1: no record is left"
  if [[ "$2" == boot ]]; then
    logged "vm stop $PV" && ok "$1: the VM is stopped" || fail "$1: the VM was left running" "$(cat "$LOG")"
    logged stop_gvproxy && logged stop_proxy && ok "$1: its gvproxy and proxy are stopped" || fail "$1: egress helpers left running"
    has "$out" "Stopping VM '$PV' (its clone is kept)" "$1: says it stops the VM"
  else
    if logged "vm stop $PV" || logged stop_gvproxy || logged stop_proxy; then
      fail "$1: the running VM or its egress helpers were stopped" "$(cat "$LOG")"
    else ok "$1: the running VM and its egress helpers are left running"; fi
    has "$out" "is left running, but no new session will attach to it" "$1: says the VM keeps running, without sessions"
    has "$out" "Run ${BOLD}augur up --macos${RESET} again" "$1: names the retry"
    has "$out" "augur down --macos && augur up --macos" "$1: names the restart if it keeps failing"
    eq "push $PV --refusing" "$(grep '^push ' "$LOG")" "$1: pushes ~/.augur-env once, as a refusal, and nothing else"
  fi
}
VM_UP=1; egress_on; record on
boot_id "$BOOT1"; verified_now; rm -f "$RUN_ID_FILE"
run_cmd cmd_up_macos; no_run_id "running VM, no run.id (a record of this boot was there)" running
boot_id "$BOOT1"; verified_now; boot_id "not-a-uuid"
run_cmd cmd_up_macos; no_run_id "running VM, a run.id that holds no UUID (a record of this boot was there)" running
# A read that fails once: a cat stand-in that fails on run.id only.
boot_id "$BOOT1"; verified_now
cat() { [[ "${1:-}" == "$RUN_ID_FILE" ]] && return 1; command cat "$@"; }
run_cmd cmd_up_macos; no_run_id "running VM, the run.id read fails once (a record of this boot was there)" running
unset -f cat
boot_id "$BOOT1"; verified_now; sleep 0 & _dead=$!; wait "$_dead"; boot_id "$BOOT1" "$_dead"
run_cmd cmd_up_macos; no_run_id "running VM, a run.pid with no process (a record of this boot was there)" running
boot_id "$BOOT1"; verified_now; mv "$SHIMDIR/ps" "$SHIMDIR/ps.saved"
printf '#!/bin/sh\nexit 1\n' > "$SHIMDIR/ps"; chmod +x "$SHIMDIR/ps"
run_cmd cmd_up_macos; no_run_id "running VM, ps fails (a record of this boot was there)" running
mv "$SHIMDIR/ps.saved" "$SHIMDIR/ps"
# The run id is read as the self-test starts and again before the pass is recorded. A VM booted
# again in between (here: run.id changes during the self-test) gets no pass, and sessions refuse it.
rid_changes() {   # rid_changes <label> running|boot
  [[ "$rc" -ne 0 ]] && ok "$1: up --macos exits non-zero" || fail "$1: up --macos exited 0"
  has "$out" "run id changed during its egress self-test" "$1: says the run id changed"
  logged selftest && ok "$1: the self-test ran (control)" || fail "$1: no self-test ran"
  has_pass && fail "$1: a pass is recorded" "$(pass_of)" || ok "$1: no pass is recorded"
  if [[ "$2" == boot ]]; then logged "vm stop $PV" && ok "$1: the VM is stopped" || fail "$1: the VM was left running"
  else
    logged "vm stop $PV" && fail "$1: the running VM was stopped" || ok "$1: the running VM is left running"
    eq "push $PV --refusing" "$(grep '^push ' "$LOG")" "$1: pushes ~/.augur-env once, as a refusal"
  fi
}
verify_real="$(declare -f verify_macos_egress_locked)"
verify_macos_egress_locked() { echo "selftest" >> "$LOG"; boot_id "$BOOT2"; }
VM_UP=1; egress_on; record on; boot_id "$BOOT1"; verified_now
run_cmd cmd_up_macos; rid_changes "running VM, booted again during its self-test" running
run_cmd cmd_claude_macos
unverified "after a self-test that spanned two boots: cmd_claude_macos"
# The other way round: no run id as the self-test starts, one after.
verify_macos_egress_locked() { echo "selftest" >> "$LOG"; boot_id "$BOOT1"; }
rm -f "$RUN_ID_FILE"; record on; no_pass
run_cmd cmd_up_macos; no_run_id "running VM, no run id as the self-test starts" running
VM_UP=0; boot_id "$BOOT1"
verify_macos_egress_locked() { echo "selftest" >> "$LOG"; boot_id "$BOOT2"; }
run_cmd cmd_up_macos; rid_changes "boot, booted again during its self-test" boot
eval "$verify_real"; VM_UP=1; boot_id "$BOOT1"
# `set -e` holds inside the self-test: a command in it that fails unguarded ends the run, and no pass
# is recorded, on both paths. (Called under `||` or `if !`, bash would ignore errexit there.)
verify_macos_egress_locked() { echo "selftest" >> "$LOG"; false; echo "PAST_THE_FAILURE" >> "$LOG"; }
for _path in running boot; do
  if [[ "$_path" == running ]]; then VM_UP=1; else VM_UP=0; fi
  egress_on; record on; no_pass; boot_id "$BOOT1"
  run_cmd cmd_up_macos
  [[ "$rc" -ne 0 ]] && ok "$_path: an unguarded failure in the self-test fails up --macos" || fail "$_path: up --macos exited 0 past a failure in the self-test"
  logged PAST_THE_FAILURE && fail "$_path: the self-test went on past its failing command (errexit ignored)" \
    || ok "$_path: the self-test stops at its failing command"
  has_pass && fail "$_path: a pass was recorded after a failing self-test" "$(pass_of)" || ok "$_path: no pass is recorded"
done
has "$(declare -f cmd_up_macos)" 'macos_selftest_and_record "$project_vm" running' "the running branch calls the self-test as a plain statement"
has "$(declare -f cmd_up_macos)" 'macos_selftest_and_record "$project_vm" boot' "the boot path calls the self-test as a plain statement"
hasnt "$(declare -f cmd_up_macos)" 'macos_selftest_and_record "$project_vm" ||' "…never under ||"
hasnt "$(declare -f cmd_up_macos)" '! macos_selftest_and_record' "…never under if !"
eval "$verify_real"; VM_UP=1; boot_id "$BOOT1"
# A run id read that fails once, as the self-test starts, on a running VM whose record already holds
# a pass for the boot still running: that pass stands, and `up` goes on. Without such a pass, or
# when the read after the self-test is the one that fails, nothing ties the pass to a boot: no pass.
cat_fails_once() { cat() { if [[ "${1:-}" == "$RUN_ID_FILE" && ! -e "$TMPD/cat-failed" ]]; then : > "$TMPD/cat-failed"; return 1; fi; command cat "$@"; }; }
egress_on; record on; boot_id "$BOOT1"; verified_now; rm -f "$TMPD/cat-failed"
: > "$LOG"; out="$( set -e; cat_fails_once; cmd_up_macos 2>&1 )"; rc=$?
eq 0 "$rc" "running VM, the first run id read fails once, a pass for this boot recorded: up --macos completes"
has "$out" "the pass recorded earlier for the same boot, which is still running, stands" "…saying the earlier pass stands"
eq "$(macos_vm_run_id "$PV")" "$(pass_of)" "…and the pass is still recorded"
record on; no_pass; rm -f "$TMPD/cat-failed"
: > "$LOG"; out="$( set -e; cat_fails_once; cmd_up_macos 2>&1 )"; rc=$?
no_run_id "running VM, the first run id read fails once, no pass recorded" running
record on; verified "$(id_for "$BOOT2")"; rm -f "$TMPD/cat-failed"
: > "$LOG"; out="$( set -e; cat_fails_once; cmd_up_macos 2>&1 )"; rc=$?
no_run_id "running VM, the first run id read fails once, a pass for another boot recorded" running
record on; verified_now
verify_macos_egress_locked() { echo "selftest" >> "$LOG"; rm -f "$RUN_ID_FILE"; }
run_cmd cmd_up_macos
no_run_id "running VM, the run id read after the self-test fails (a pass for this boot was there)" running
eval "$verify_real"; boot_id "$BOOT1"; unset -f cat
# A `down` / `destroy` that removes the record while the self-test runs: the pass is not written,
# so no record is re-created for a VM being torn down.
verify_macos_egress_locked() { echo "selftest" >> "$LOG"; rm -f "$(macos_boot_record_file)"; }
record on; no_pass
run_cmd cmd_up_macos
[[ "$rc" -ne 0 ]] && ok "the record removed during the self-test: up --macos fails" || fail "the record removed during the self-test: up --macos exited 0"
has "$out" "has no boot record" "…saying the VM has no boot record"
has "$out" "nothing is written" "…and that nothing is written"
[[ -e "$(macos_boot_record_file)" ]] && fail "…but a record was re-created" "$(cat "$(macos_boot_record_file)")" || ok "…and no record is re-created"
eval "$verify_real"
# The mode comes from the record, not from this command.
record on; no_pass
( egress_off; macos_record_egress_verified "$PV" "$(macos_vm_run_id "$PV")" ) >/dev/null 2>&1
eq "on" "$(mode_of)" "a recorded pass keeps the record's own mode"
# On a boot whose pass cannot be recorded, the record function alone deals with the pass: the
# teardown that follows leaves the record alone.
VM_UP=0; rm -f "$RUN_ID_FILE"
_drops="$TMPD/drops"; : > "$_drops"
eval "_real_drop() $(declare -f macos_drop_egress_pass | tail -n +2)"
macos_drop_egress_pass() { echo drop >> "$_drops"; _real_drop; }
run_cmd cmd_up_macos
no_run_id "boot, no run id (the pass's one owner)" boot
eq 1 "$(wc -l < "$_drops" | tr -d ' ')" "…the pass is dropped once, by macos_record_egress_verified, not again by the teardown"
eval "macos_drop_egress_pass() $(declare -f _real_drop | tail -n +2)"
VM_UP=1; boot_id "$BOOT1"
# The pass is recorded under the run id read before the self-test: cmd_up_macos reads it first.
fn="$(declare -f cmd_up_macos)"
eq 2 "$(grep -c 'macos_selftest_and_record "$project_vm"' <<<"$fn")" "both self-tests in cmd_up_macos go through macos_selftest_and_record"
hasnt "$fn" 'verify_macos_egress_locked' "…and cmd_up_macos runs no self-test outside it"
_sr="$(declare -f macos_selftest_and_record)"
_r_at="$(grep -n 'rid="$(macos_vm_run_id "$vm")"' <<<"$_sr" | head -n1 | cut -d: -f1)"
_v_at="$(grep -n 'verify_macos_egress_locked "$vm"' <<<"$_sr" | head -n1 | cut -d: -f1)"
_p_at="$(grep -n 'macos_record_egress_verified "$vm" "$rid"' <<<"$_sr" | head -n1 | cut -d: -f1)"
if [[ -n "$_r_at" && -n "$_v_at" && -n "$_p_at" && "$_r_at" -lt "$_v_at" && "$_v_at" -lt "$_p_at" ]]; then
  ok "macos_selftest_and_record reads the run id, then runs the self-test, then records against that id"
else fail "macos_selftest_and_record's order is wrong" "read@$_r_at test@$_v_at record@$_p_at"; fi
# …after which a session refuses the VM, and the next `up` records the pass again.
run_cmd cmd_claude_macos
unverified "after the unrecordable pass: cmd_claude_macos"
run_cmd cmd_up_macos
eq 0 "$rc" "…and the next up --macos, with the read working again, reconciles"
eq "$(macos_vm_run_id "$PV")" "$(pass_of)" "…and records the pass"
# The record is written to a temp file beside it and renamed into place, so a session reading it at
# that moment sees the old record or the new one, never an empty or partial file.
rec_body="$(declare -f macos_write_boot_record)"
has "$rec_body" '> "${f}.tmp.$$"' "the record is written to a temp file beside it"
has "$rec_body" 'mv -f "${f}.tmp.$$" "$f"' "…and renamed into place"
hasnt "$rec_body" '> "$f"' "…never written in place"
for _w in macos_record_egress_mode macos_record_egress_verified macos_drop_egress_pass; do
  has "$(declare -f "$_w")" 'macos_write_boot_record' "$_w writes through it"
  hasnt "$(declare -f "$_w")" '> "$(macos_boot_record_file)"' "$_w never writes the record in place"
done
# A concurrent reader polling the record while passes are recorded never sees it empty.
boot_id "$BOOT1"; verified_now
( for _i in $(seq 1 200); do macos_record_egress_verified "$PV" "$(macos_vm_run_id "$PV")" || exit 1; done ) & _wr=$!
_empty=0; while kill -0 "$_wr" 2>/dev/null; do [[ -s "$(macos_boot_record_file)" ]] || _empty=$((_empty + 1)); done; wait "$_wr"
eq 0 "$_empty" "a reader polling during 200 record writes never finds the record empty or missing"
eq "" "$(find "$AUGUR_PROXY_DIR" -name '*.boot-record.tmp.*')" "…and no temp file is left"
# A failed write (the rename fails) leaves no record and no temp file, and fails the record.
( mv() { return 1; }; macos_record_egress_verified "$PV" "$(macos_vm_run_id "$PV")" ) >"$TMPD/rec.out" 2>&1; _rrc=$?
[[ "$_rrc" -ne 0 ]] && ok "a failed record write: returns non-zero" || fail "a failed record write returned 0"
has "$(cat "$TMPD/rec.out")" "cannot be recorded for its sessions" "a failed record write: says the pass cannot be recorded"
[[ -e "$(macos_boot_record_file)" ]] && fail "a failed record write: a record is left" || ok "a failed record write: no record is left"
eq "" "$(find "$AUGUR_PROXY_DIR" -name '*.boot-record.tmp.*')" "a failed record write: no temp file is left"
# The teardown of an unverified VM drops the pass and keeps the mode, so a VM it failed to stop is
# refused as unverified (remedy: up --macos), not as one of unknown mode.
record on; verified_now
( stop_unverified_macos_vm "$PV" ) >/dev/null 2>&1
eq "on -" "$(cat "$(macos_boot_record_file)" 2>/dev/null)" "the unverified-VM teardown drops the pass and keeps the mode"
rm -f "$(macos_boot_record_file)"
( stop_unverified_macos_vm "$PV" ) >/dev/null 2>&1
[[ -e "$(macos_boot_record_file)" ]] && fail "the unverified-VM teardown created a record" || ok "…and creates none where there was none"
# The boot's record cannot be written: the VM is not booted.
VM_UP=0
: > "$LOG"; out="$( set -e; mv() { return 1; }; cmd_up_macos 2>&1 )"; rc=$?
[[ "$rc" -ne 0 ]] && ok "boot record unwritable: up --macos fails" || fail "boot record unwritable: up --macos exited 0"
has "$out" "Could not write $(macos_boot_record_file)" "boot record unwritable: says so"
grep -q '^vm run' "$LOG" && fail "boot record unwritable: the VM was booted" "$(cat "$LOG")" || ok "boot record unwritable: the VM is not booted"
if logged start_proxy || logged start_gvproxy; then fail "boot record unwritable: the proxy or gvproxy was started and left behind" "$(cat "$LOG")"
else ok "boot record unwritable: no proxy or gvproxy is started"; fi
fn="$(declare -f cmd_up_macos)"
rec_at="$(grep -n 'macos_record_egress_mode' <<<"$fn" | head -n1 | cut -d: -f1)"
sp_at="$(grep -n 'start_proxy "127.0.0.1"' <<<"$fn" | tail -n1 | cut -d: -f1)"
sg_at="$(grep -n '^ *start_gvproxy;$' <<<"$fn" | tail -n1 | cut -d: -f1)"
if [[ -n "$rec_at" && -n "$sp_at" && -n "$sg_at" && "$rec_at" -lt "$sp_at" && "$rec_at" -lt "$sg_at" ]]; then
  ok "the boot's record is written before the boot path starts the proxy and gvproxy"
else fail "the boot's record is not written before the proxy and gvproxy" "record@$rec_at proxy@$sp_at gvproxy@$sg_at"; fi
VM_UP=1

VM_UP=0; rm -f "$RUN_ID_FILE"
run_cmd cmd_up_macos; no_run_id "boot, no run.id" boot
hasnt "$out" "is up." "boot, no run.id: no success banner"
VM_UP=1; boot_id "$BOOT1"

section "Tier 1 — the boot path rewrites the record, with no pass, before \`augur-vm run\`, and records the pass after the self-test"
VM_UP=0
egress_on; verified_now; boot_id "$BOOT2"
wait_for_macos_ssh() { cp "$(macos_boot_record_file)" "$TMPD/verified-at-boot" 2>/dev/null; return 0; }
rm -f "$TMPD/verified-at-boot"
run_cmd cmd_up_macos
eq 0 "$rc" "boot: completes"
eq "on -" "$(cat "$TMPD/verified-at-boot" 2>/dev/null)" "boot: while the VM boots, the record holds no pass (the earlier boot's is gone)"
eq "$(macos_vm_run_id "$PV")" "$(pass_of)" "boot: the pass is recorded with this boot's run id"
fn="$(declare -f cmd_up_macos)"
rm_at="$(grep -n 'macos_record_egress_mode' <<<"$fn" | head -n1 | cut -d: -f1)"
run_at="$(grep -n '"\$VM_CLI" run' <<<"$fn" | head -n1 | cut -d: -f1)"
st_at="$(grep -n 'macos_selftest_and_record' <<<"$fn" | tail -n1 | cut -d: -f1)"
rec_at="$st_at"   # the pass is recorded inside macos_selftest_and_record, after its self-test (checked above)
if [[ -n "$rm_at" && -n "$run_at" && -n "$st_at" && -n "$rec_at" && "$rm_at" -lt "$run_at" && "$run_at" -lt "$st_at" ]]; then
  ok "boot: the record is dropped before 'augur-vm run' and written after the self-test"
else fail "boot: the record's place in cmd_up_macos is wrong" "rm@$rm_at run@$run_at self-test@$st_at record@$rec_at"; fi
# Interrupted before the self-test (here: the SSH wait never ends well): nothing is recorded.
wait_for_macos_ssh() { return 1; }
macos_boot_ssh_failed() { stop_unverified_macos_vm "$1"; exit 1; }
verified_now
run_cmd cmd_up_macos
has_pass && fail "boot fails before its self-test: a record exists" \
  || ok "boot fails before its self-test: no record"
unset -f macos_boot_ssh_failed; eval "$(sed -n '/^macos_boot_ssh_failed() {$/,/^}$/p' "$AUGUR")"
wait_for_macos_ssh() { return 0; }
# --no-egress: no self-test, so no record.
egress_off; verified_now
run_cmd cmd_up_macos
eq 0 "$rc" "boot --no-egress: completes"
has_pass && fail "boot --no-egress: a record exists" || ok "boot --no-egress: no record"
boot_id "$BOOT1"

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
WORKSPACE_DIR="$TMPD/work/app";    rec_a="$(macos_boot_record_file)"
WORKSPACE_DIR="$TMPD/archive/app"; rec_b="$(macos_boot_record_file)"
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
eq "on" "$(mode_of)" "writing one project's record leaves the other's alone"
# `destroy <name>` addresses another project through TARGET_SLUG/TARGET_HASH: the record it drops is
# that project's, whatever the current directory.
want="$rec_b"
slug_b="$(WORKSPACE_DIR="$TMPD/archive/app"; workspace_slug)"; hash_b="$(WORKSPACE_DIR="$TMPD/archive/app"; workspace_path_hash)"
eq "$want" "$(TARGET_SLUG="$slug_b"; TARGET_HASH="$hash_b"; macos_boot_record_file)" "an explicit target resolves to that project's record from anywhere"
WORKSPACE_DIR="$WS_SAVE"

section "Tier 1 — down / destroy drop the record"
egress_on
for c in cmd_down_macos cmd_destroy_macos; do
  record on; verified_now
  _old="${AUGUR_PROXY_DIR}/$(workspace_slug)-$(workspace_path_hash)"
  printf 'on\n' > "$_old.egress-mode"; printf 'x\n' > "$_old.egress-verified"
  run_cmd "$c"
  [[ -e "$(macos_boot_record_file)" ]] && fail "$c leaves the record behind" || ok "$c removes the record"
  [[ -e "$_old.egress-mode" || -e "$_old.egress-verified" ]] && fail "$c leaves an older augur's two record files" \
    || ok "$c removes an older augur's .egress-mode and .egress-verified too"
  has "$(declare -f "$c")" 'macos_remove_old_records' "$c removes them through macos_remove_old_records"
done
macos_vm_exists() { return 1; }
record on; verified_now
run_cmd cmd_down_macos
[[ -e "$(macos_boot_record_file)" ]] && fail "down with no VM leaves the record" || ok "down with no VM still removes the record"

finish
