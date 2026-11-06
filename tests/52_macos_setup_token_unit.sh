#!/usr/bin/env bash
# Tier 1 (offline) — the macOS agent-binary trust chain.
#
#   1. agent_verify_integrity_macos: `codesign --verify --strict` against a Developer ID requirement
#      pinned to the vendor's Team ID, plus an exact TeamIdentifier line. A signature that merely
#      MENTIONS the vendor (an ad-hoc one with "anthropic" in its Identifier) must fail.
#   2. `update --macos` works on a staging copy and replaces the base VM only when every step,
#      the signature check included, passed. A failure leaves the base VM untouched. build and
#      update hold one host-wide base-writer lock, so neither overlaps the other or itself.
#      With provisioning files present, every step after provisioning still reaches a running VM,
#      and the signature check runs last, on the guest as provisioning left it.
#   3. ensure_macos_agent_bin never installs anything into a project VM; a missing binary is an
#      error pointing at `update --macos` / `build --macos`, and `claude --macos` refuses.
#   4. `setup-token --macos` runs in a throwaway clone of the base VM: never the project VM, no
#      credentials, no workspace or state shares, the baseline + global allowlist only, the binary
#      launched by the absolute path the signature check verified, and the clone removed on every
#      exit path (success, failure, Ctrl-C) and on the next run after a crash. augur's own credential
#      files are scrubbed from the clone first, and the clone is never taken while a build or
#      update holds the base-writer lock.
#
# Nothing is cloned, booted or SSH'd: the guest is a scriptable ssh_macos and augur-vm a recorder.
# What only a real Mac can show (codesign's actual verdicts, a real clone booting) is in
# tests/e2e_macos_vm.sh's territory, not here.
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/lib.sh"
AUGUR="$REPO/augur"

TMPD="$(mktemp -d)"
cleanup_pids=()
trap 'for p in "${cleanup_pids[@]}"; do kill "$p" 2>/dev/null; done; rm -rf "$TMPD"' EXIT
# Boot-proofing (see tests/36): $VM_CLI can never resolve to a real augur-vm.
export AUGUR_VM_BIN="$TMPD/no-such-augur-vm"

AUGUR_SOURCE_ONLY=1 source "$AUGUR"
set +e

HOME="$TMPD/home"; mkdir -p "$HOME"
AUGUR_DIR="$TMPD/augur"; mkdir -p "$AUGUR_DIR"
AUGUR_PROXY_DIR="$TMPD/proxy"; mkdir -p "$AUGUR_PROXY_DIR"
WORKSPACE_DIR="$TMPD/proj"; mkdir -p "$WORKSPACE_DIR"
AUGUR_BASELINE_CONF="$AUGUR_DIR/augur.conf.default"; printf 'api.anthropic.com\n' > "$AUGUR_BASELINE_CONF"
AUGUR_GLOBAL_CONF="$AUGUR_DIR/augur.conf";           printf 'global.example\n'    > "$AUGUR_GLOBAL_CONF"
AUGUR_PROJECT_DIR="$WORKSPACE_DIR/.augur"; AUGUR_PROJECT_CONF="$AUGUR_PROJECT_DIR/allowlist.conf"
SWIFT_IMAGE_TAG="latest"; IMAGE_NAME="augur:swift-latest"
CONTAINER_NAME="$(make_container_name)"; WORKSPACE_MOUNT="$(make_workspace_mount)"
MACOS_SHARE="workspace-$(workspace_slug)"
MACOS_MODE=true
PV="$(macos_project_vm)"
TEAM="$(agent_macos_signing_team)"
BIN="/Users/${MACOS_SSH_USER}/.local/bin/claude"

LOG="$TMPD/calls"; : > "$LOG"
logged() { grep -qx "$1" "$LOG" 2>/dev/null; }
line_of() { grep -nx "$1" "$LOG" | head -n1 | cut -d: -f1; }

section "Tier 0 — the seam declares the signer and the install path"
if [[ "$TEAM" =~ ^[A-Z0-9]{10}$ ]]; then ok "agent_macos_signing_team is a 10-character Apple Team ID ($TEAM)"
else fail "agent_macos_signing_team is not a Team ID" "[$TEAM]"; fi
eq "$BIN" "$(macos_agent_bin)" "macos_agent_bin is the absolute install path under the guest user's home"

# ── 1. The signature check ─────────────────────────────────────────────────────────────────────
section "Tier 1 — agent_verify_integrity_macos: only the pinned Developer ID team passes"
# The guest's answer to the check's single remote command: G_RC is what that command exits with
# (codesign --verify -R …'s verdict), G_OUT what `codesign -dvv` printed.
G_RC=0; G_OUT=""
SIGCMD="$TMPD/sigcmd"
ssh_macos() { shift; printf '%s\n' "$*" > "$SIGCMD"; printf '%s\n' "$G_OUT"; return "$G_RC"; }
good_dvv="Executable=$BIN
Identifier=com.anthropic.claude-code
Format=Mach-O thin (arm64)
CodeDirectory v=20500 size=1 flags=0x10000(runtime) hashes=1+7 location=embedded
Signature size=9000
Authority=Developer ID Application: Anthropic PBC ($TEAM)
Authority=Developer ID Certification Authority
Authority=Apple Root CA
Timestamp=Jan 1, 2026 at 00:00:00
TeamIdentifier=$TEAM"
sig() { agent_verify_integrity_macos testvm >/dev/null 2>&1; }

G_RC=0; G_OUT="$good_dvv"
sig && ok "the vendor's Developer ID signature passes" || fail "the vendor's Developer ID signature is refused"
cmd="$(cat "$SIGCMD")"
has "$cmd" "/usr/bin/codesign --verify --strict" "runs codesign --verify --strict by absolute path"
req="anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = \"${TEAM}\""
has "$cmd" "-R=$(printf '%q' "$req")" "pins a Developer ID requirement to exactly the vendor's Team ID"
has "$cmd" "'$BIN'" "checks the absolute install path (not a PATH lookup)"
hasnt "$cmd" 'grep' "the verdict is not a guest-side grep"

G_RC=0; G_OUT="Executable=$BIN
Identifier=com.anthropic.claude-code
Signature=adhoc
TeamIdentifier=not set"
sig && fail "an ad-hoc signature with 'anthropic' in its Identifier PASSES" || ok "an ad-hoc signature naming Anthropic in its Identifier fails"
G_RC=1
sig && fail "ad-hoc (codesign -R refuses it) passes" || ok "ad-hoc, as codesign -R really reports it, fails"

G_RC=0; G_OUT="${good_dvv//TeamIdentifier=$TEAM/TeamIdentifier=ABCDE12345}"
sig && fail "another team's Developer ID signature passes" || ok "another team's Developer ID signature fails"
G_RC=0; G_OUT="${good_dvv//TeamIdentifier=$TEAM/TeamIdentifier=${TEAM}X}"
sig && fail "a TeamIdentifier merely starting with the team passes" || ok "the TeamIdentifier must match exactly"
G_RC=1; G_OUT="$good_dvv"
sig && fail "a binary failing --verify --strict passes on its -dvv text" || ok "a failed --verify --strict fails, whatever -dvv says"
G_RC=255; G_OUT=""
sig && fail "an unreachable guest passes" || ok "no answer from the guest fails"

# ── 3. ensure_macos_agent_bin ────────────────────────────────────────────────────────────────
section "Tier 1 — ensure_macos_agent_bin: a missing binary is an error, never a self-install"
ssh_macos() { shift; printf '%s\n' "$*" > "$SIGCMD"; printf '%s\n' "$G_OUT"; return "$G_RC"; }
G_RC=0; G_OUT="present"
out="$(ensure_macos_agent_bin "$PV" 2>&1)"; rc=$?
eq 0 "$rc" "present: returns 0"
has "$(cat "$SIGCMD")" "'$BIN'" "probes the absolute install path"
G_RC=0; G_OUT="missing"
out="$(ensure_macos_agent_bin "$PV" 2>&1)"; rc=$?
[[ "$rc" -ne 0 ]] && ok "missing: fails" || fail "missing: returned 0"
has "$out" "augur update --macos" "missing: points at update --macos"
has "$out" "augur build --macos"  "missing: and at build --macos"
G_RC=255; G_OUT=""
out="$(ensure_macos_agent_bin "$PV" 2>&1)"; rc=$?
[[ "$rc" -ne 0 ]] && ok "unreachable: fails" || fail "unreachable: returned 0"
has "$out" "Could not check" "unreachable: says it could not check (not 'missing')"
bin_fn="$(declare -f ensure_macos_agent_bin)"
hasnt "$bin_fn" "install.sh" "never runs the installer inside a project VM"
hasnt "$bin_fn" "latest"     "never installs 'latest' inside a project VM"
hasnt "$bin_fn" "codesign"   "no signature check at plain claude launch (a project VM is guest-controlled)"

# claude --macos refuses when the binary is missing.
(
  require_vz() { :; }; require_fresh_egress_helpers() { :; }; macos_vm_running() { return 0; }
  require_macos_egress_mode_current() { :; }; sync_macos_guest_clock() { :; }; sync_macos_guest_timezone() { :; }
  ensure_macos_workspace() { :; }; ensure_macos_agent_projects() { :; }; ensure_macos_agent_agents() { :; }
  ensure_macos_agent_profile() { :; }; warn_if_macos_egress_pinned() { :; }
  ssh_macos() { [[ "$*" == *" -t "* ]] && { echo AGENT_LAUNCHED; return 0; }; echo missing; }
  out="$( set -e; cmd_claude_macos 2>&1 )"; rc=$?
  [[ "$rc" -ne 0 ]] && ok "claude --macos with no binary: exits non-zero" || fail "claude --macos with no binary: exit 0"
  hasnt "$out" "AGENT_LAUNCHED" "claude --macos with no binary: nothing is launched"
  finish >/dev/null; exit "$_T_FAIL"
); _sub=$?
(( _sub == 0 )) || fail "the claude --macos subtest reported $_sub failure(s)"

# ── 2. update --macos ────────────────────────────────────────────────────────────────────────
section "Tier 1 — update --macos: a staging copy, promoted only when everything passed"
VMS="$TMPD/vms.list"
RUNNING_VMS=""       # space-separated names the recorder reports as running
CLONE_FAIL_TO=""     # a clone into this name fails
ON_DELETE_BASE=""    # evaluated right after the base VM is deleted (to interrupt the swap)
vm_cli_rec() {
    printf 'vm %s\n' "$*" >> "$LOG"
    case "$1" in
        clone)  if [[ "$3" == "$CLONE_FAIL_TO" ]]; then
                    [[ -n "$CLONE_PARTIAL" ]] && echo "$3" >> "$VMS"   # a failed clone that left a partial copy
                    return 1
                fi
                echo "$3" >> "$VMS" ;;
        delete) grep -vx "$2" "$VMS" > "$VMS.t"; mv "$VMS.t" "$VMS"
                if [[ "$2" == "$MACOS_BASE_VM" && -n "$ON_DELETE_BASE" ]]; then eval "$ON_DELETE_BASE"; fi ;;
        list)   echo "ID NAME CPU MEM STATE"
                for _v in $RUNNING_VMS; do echo "x $_v 4 8192 running"; done ;;
    esac
    return 0
}
VM_CLI=vm_cli_rec
reset_vms() { printf '%s\n' "$MACOS_BASE_VM" > "$VMS"; : > "$LOG"; RUNNING_VMS=""; CLONE_FAIL_TO=""; CLONE_PARTIAL=""; ON_DELETE_BASE=""; }
macos_vm_exists()  { grep -qx "$1" "$VMS" 2>/dev/null; }
macos_vm_running() { [[ " $RUNNING_VMS " == *" $1 "* ]]; }
require_vz() { :; }
mkdir -p "$AUGUR_DIR/vms/$MACOS_BASE_VM"; macos_store_admin_password "$MACOS_BASE_VM" admin
wait_for_macos_ssh() { return 0; }
ssh_macos() { echo "ssh $1" >> "$LOG"; return 0; }
prov_real="$(declare -f run_base_provisioning)"
run_base_provisioning()          { echo "provision $1" >> "$LOG"; }
install_macos_managed_settings() { echo "managed $1" >> "$LOG"; }
select_macos_full_xcode()        { echo "xcode $1" >> "$LOG"; }
SIG_OK=1
verify_real="$(declare -f agent_verify_integrity_macos)"
agent_verify_integrity_macos() { echo "verify $1" >> "$LOG"; [[ "$SIG_OK" == 1 ]]; }
run_update() { out="$( exec 2>&1; set -e; cmd_update_macos )"; rc=$?; }   # exec: the EXIT trap's output too

reset_vms; SIG_OK=0
run_update
[[ "$rc" -ne 0 ]] && ok "signature failure: update exits non-zero" || fail "signature failure: update exited 0"
has "$out" "signature check" "signature failure: says so"
logged "verify $MACOS_UPDATE_VM" && ok "the check runs on the staging copy" || fail "the check never ran on the staging copy"
logged "vm clone $MACOS_BASE_VM $MACOS_UPDATE_VM" && ok "the base VM is cloned to a staging copy first" || fail "no staging clone" "$(cat "$LOG")"
logged "vm delete $MACOS_BASE_VM" && fail "signature failure: the base VM was deleted" || ok "signature failure: the base VM is not deleted"
logged "vm clone $MACOS_UPDATE_VM $MACOS_BASE_VM" && fail "signature failure: the update was saved as the base VM" || ok "signature failure: nothing is saved as the base VM"
logged "vm delete $MACOS_UPDATE_VM" && ok "signature failure: the staging copy is discarded" || fail "signature failure: the staging copy is left behind"
grep -q "^ssh $MACOS_BASE_VM$" "$LOG" && fail "update ran a command in the base VM itself" || ok "nothing runs inside the base VM itself"
for s in provision managed xcode; do
  v_at="$(line_of "verify $MACOS_UPDATE_VM")"; s_at="$(line_of "$s $MACOS_UPDATE_VM")"
  [[ -n "$s_at" && -n "$v_at" && "$s_at" -lt "$v_at" ]] && ok "the check runs on the final guest state, after $s" || fail "the check ran before $s" "$(cat "$LOG")"
done

reset_vms; SIG_OK=1
select_macos_full_xcode() { echo "xcode $1" >> "$LOG"; return 1; }
run_update
select_macos_full_xcode() { echo "xcode $1" >> "$LOG"; }
[[ "$rc" -ne 0 ]] && ok "Xcode selection failure: update exits non-zero" || fail "Xcode selection failure: update exited 0"
has "$out" "Could not select the full Xcode install" "Xcode selection failure: says so"
logged "vm delete $MACOS_BASE_VM" && fail "Xcode selection failure: the base VM was deleted" || ok "Xcode selection failure: the base VM is untouched"
logged "vm clone $MACOS_UPDATE_VM $MACOS_BASE_VM" && fail "Xcode selection failure: the update was saved" || ok "Xcode selection failure: nothing is saved as the base VM"

reset_vms; SIG_OK=1
ssh_macos() { echo "ssh $1" >> "$LOG"; [[ "$*" == *install.sh* ]] && return 1; return 0; }
run_update
[[ "$rc" -ne 0 ]] && ok "installer failure: update exits non-zero" || fail "installer failure: exit 0"
logged "vm delete $MACOS_BASE_VM" && fail "installer failure: the base VM was deleted" || ok "installer failure: the base VM is untouched"
ssh_macos() { echo "ssh $1" >> "$LOG"; return 0; }

# The update script upgrades Homebrew formulae (gh included) over the same plain-NAT ssh call as the
# agent installer: after it, bounded by a timeout, formulae only, and no sudo.
reset_vms; SIG_OK=1
ssh_macos() { echo "ssh $1" >> "$LOG"; [[ "$*" == *install.sh* || "$*" == *_agent_url* ]] && printf '%s\n' "$*" > "$TMPD/update-script"; return 0; }
run_update
script="$(cat "$TMPD/update-script")"
has   "$script" "brew update"             "update script: runs brew update"
has   "$script" "brew upgrade --formula"  "update script: upgrades formulae only"
hasnt "$script" "brew upgrade --cask"     "update script: no cask upgrade"
hasnt "$script" "sudo"                    "update script: no sudo"
has   "$script" "_with_timeout 900 brew update" "update script: brew update is time-bounded"
has   "$script" "brew update failed or timed out" "update script: a failed brew update aborts (exit 1)"
has   "$script" "brew upgrade failed or timed out" "update script: a failed brew upgrade aborts (exit 1)"
has   "$script" "Homebrew is missing from the base VM" "update script: a missing Homebrew is reported as such"
i_at="$(grep -bo '_with_timeout 180 bash' <<<"$script" | head -n1 | cut -d: -f1)"; b_at="$(grep -bo 'brew update' <<<"$script" | head -n1 | cut -d: -f1)"
[[ -n "$i_at" && -n "$b_at" && "$i_at" -lt "$b_at" ]] && ok "update script: brew runs after the agent installer, in the same call" || fail "update script: brew is not after the installer" "installer@$i_at brew@$b_at"
ssh_macos() { echo "ssh $1" >> "$LOG"; return 0; }

# Full Xcode is selected BEFORE the update script (which includes the Homebrew upgrade) and again after
# provisioning. A failure of the early selection aborts before the script runs.
reset_vms; SIG_OK=1
run_update
x1="$(grep -nx "xcode $MACOS_UPDATE_VM" "$LOG" | head -n1 | cut -d: -f1)"; x2="$(grep -nx "xcode $MACOS_UPDATE_VM" "$LOG" | tail -n1 | cut -d: -f1)"
s1="$(grep -nx "ssh $MACOS_UPDATE_VM" "$LOG" | head -n1 | cut -d: -f1)"; p1="$(line_of "provision $MACOS_UPDATE_VM")"
if [[ -n "$x1" && -n "$s1" && -n "$p1" && "$x1" -lt "$s1" && "$s1" -lt "$p1" && "$p1" -lt "$x2" ]]; then
  ok "update: Xcode is selected before the update script, and again after provisioning (xcode@$x1 script@$s1 provision@$p1 xcode@$x2)"
else fail "update: Xcode selection is misplaced" "xcode@$x1 script@$s1 provision@$p1 xcode@$x2"; fi
reset_vms; SIG_OK=1
select_macos_full_xcode() { echo "xcode $1" >> "$LOG"; return 1; }
run_update
[[ "$rc" -ne 0 ]] && ok "update: a failing early Xcode selection aborts" || fail "update: a failing early Xcode selection was ignored"
logged "ssh $MACOS_UPDATE_VM" && fail "…but the update script still ran" || ok "…before the update script runs"
logged "vm delete $MACOS_BASE_VM" && fail "…and the base VM was deleted" || ok "…and the base VM is untouched"
select_macos_full_xcode() { echo "xcode $1" >> "$LOG"; }

reset_vms; SIG_OK=1
run_update
eq 0 "$rc" "all steps pass: update exits 0"
v_at="$(line_of "verify $MACOS_UPDATE_VM")"; d_at="$(line_of "vm delete $MACOS_BASE_VM")"
c_at="$(line_of "vm clone $MACOS_UPDATE_VM $MACOS_BASE_VM")"; x_at="$(line_of "vm delete $MACOS_UPDATE_VM")"
if [[ -n "$v_at" && -n "$d_at" && -n "$c_at" && -n "$x_at" && "$v_at" -lt "$d_at" && "$d_at" -lt "$c_at" && "$c_at" -lt "$x_at" ]]; then
  ok "the base VM is replaced only after the check (verify@$v_at < delete@$d_at < save@$c_at < drop staging@$x_at)"
else fail "the base VM replacement is out of order" "$(cat "$LOG")"; fi
for s in provision managed xcode; do
  logged "$s $MACOS_UPDATE_VM" && ok "$s runs on the staging copy" || fail "$s did not run on the staging copy"
done
macos_vm_exists "$MACOS_BASE_VM" && ok "the base VM exists afterwards" || fail "the base VM is gone"
macos_vm_exists "$MACOS_UPDATE_VM" && fail "the staging copy is left behind" || ok "the staging copy is gone"

section "Tier 1 — update --macos: never touches the build VM; serialized with build by the base-writer lock"
WLOCK="$(host_lock_path "$MACOS_BASE_WRITER_LOCK")"
reset_vms; echo "$MACOS_BUILD_VM" >> "$VMS"   # a kept (stopped) build VM
run_update
eq 0 "$rc" "a stopped build VM present: update still runs"
grep -q "$MACOS_BUILD_VM" "$LOG" && fail "update touched the build VM" "$(cat "$LOG")" || ok "update never touches '$MACOS_BUILD_VM'"
macos_vm_exists "$MACOS_BUILD_VM" && ok "the kept build VM is still there" || fail "the kept build VM was deleted"
[[ -L "$WLOCK" ]] && fail "a successful update leaves the base-writer lock behind" || ok "a successful update releases the base-writer lock"

sleep 300 & holder=$!; cleanup_pids+=("$holder")
for other in build update setup-token; do
  reset_vms; echo "$MACOS_UPDATE_VM" >> "$VMS"; RUNNING_VMS="$MACOS_UPDATE_VM"
  rm -f "$WLOCK"; ln -s "$holder:$other" "$WLOCK"
  run_update
  [[ "$rc" -ne 0 ]] && ok "a running '$other' holds the lock: update refuses" || fail "a running '$other' holds the lock: update ran"
  if [[ "$other" == update ]]; then has "$out" "Another 'augur update --macos' is running" "…and says another update is running"
  else has "$out" "'augur $other --macos' is running" "…and names the '$other' that is running"; fi
  grep -q "^vm " "$LOG" && fail "…but a VM was cloned, stopped or deleted (the other run's staging VM included)" "$(cat "$LOG")" || ok "…and no VM is cloned, stopped or deleted"
  eq "$holder:$other" "$(readlink "$WLOCK" 2>/dev/null)" "…and the other run's lock is left alone"
done
rm -f "$WLOCK"

reset_vms; ln -s "999999999:update" "$WLOCK"
run_update
eq 0 "$rc" "a lock left by a killed update is taken over"
[[ -L "$WLOCK" ]] && fail "the taken-over lock is left behind" || ok "…and released at the end"

reset_vms; echo "$MACOS_UPDATE_VM" >> "$VMS"   # left stopped by a crashed update
run_update
eq 0 "$rc" "a stale stopped staging VM: update runs"
d_at="$(line_of "vm delete $MACOS_UPDATE_VM")"; c_at="$(line_of "vm clone $MACOS_BASE_VM $MACOS_UPDATE_VM")"
[[ -n "$d_at" && -n "$c_at" && "$d_at" -lt "$c_at" ]] && ok "the stale staging VM is removed before the new clone" || fail "stale staging VM not removed first" "$(cat "$LOG")"

reset_vms; echo "$MACOS_UPDATE_VM" >> "$VMS"; RUNNING_VMS="$MACOS_UPDATE_VM"   # left running by a killed update
run_update
eq 0 "$rc" "a running staging VM with no lock holder (a killed update's): update runs"
s_at="$(line_of "vm stop $MACOS_UPDATE_VM")"; d_at="$(line_of "vm delete $MACOS_UPDATE_VM")"; c_at="$(line_of "vm clone $MACOS_BASE_VM $MACOS_UPDATE_VM")"
[[ -n "$s_at" && -n "$d_at" && -n "$c_at" && "$s_at" -lt "$d_at" && "$d_at" -lt "$c_at" ]] && ok "…it is stopped and removed before the new clone" || fail "…it was not stopped and removed first" "$(cat "$LOG")"

reset_vms; CLONE_FAIL_TO="$MACOS_UPDATE_VM"
run_update
[[ "$rc" -ne 0 ]] && ok "the staging clone fails: update exits non-zero" || fail "failed staging clone: exit 0"
macos_vm_exists "$MACOS_BASE_VM" && ok "failed staging clone: the base VM is untouched" || fail "failed staging clone: the base VM is gone"
[[ -L "$WLOCK" ]] && fail "failed staging clone: the lock is left behind" || ok "failed staging clone: the lock is released"

section "Tier 1 — update --macos: the swap always leaves one copy"
reset_vms; ON_DELETE_BASE='kill -INT "$(sh -c "echo \$PPID")"'
run_update
eq 0 "$rc" "Ctrl-C between deleting the old base and saving the new one is ignored: the swap completes"
macos_vm_exists "$MACOS_BASE_VM" && ok "…and the base VM exists" || fail "…and the base VM is gone" "$(cat "$LOG")"

reset_vms; CLONE_FAIL_TO="$MACOS_BASE_VM"
run_update
[[ "$rc" -ne 0 ]] && ok "the save fails after the old base is deleted: exits non-zero" || fail "failed save: exit 0"
macos_vm_exists "$MACOS_UPDATE_VM" && ok "failed save: the updated staging copy is KEPT (the only copy left)" || fail "failed save: both copies are gone" "$(cat "$LOG")"
has "$out" "augur-vm clone ${MACOS_UPDATE_VM} ${MACOS_BASE_VM}" "failed save: prints the command that finishes the swap"
[[ -L "$WLOCK" ]] && fail "failed save: the base-writer lock is left behind" || ok "failed save: the base-writer lock is released"

reset_vms; CLONE_FAIL_TO="$MACOS_BASE_VM"; CLONE_PARTIAL=1
run_update
[[ "$rc" -ne 0 ]] && ok "the save fails leaving a partial base VM: exits non-zero" || fail "partial save: exit 0"
macos_vm_exists "$MACOS_UPDATE_VM" && ok "partial save: the staging copy is KEPT (a partial clone is not treated as saved)" || fail "partial save: the staging copy was deleted" "$(cat "$LOG")"
has "$out" "augur-vm delete ${MACOS_BASE_VM} && augur-vm clone ${MACOS_UPDATE_VM} ${MACOS_BASE_VM}" "partial save: says to replace the partial base VM"
reset_vms

build_fn="$(declare -f cmd_build_macos)"
has   "$build_fn" "agent_verify_integrity_macos" "build --macos runs the same strict check"
hasnt "$build_fn" 'grep -qi "Anthropic"'        "build --macos no longer greps for 'Anthropic'"
hasnt "$(declare -f cmd_update_macos)" 'grep -qi "Anthropic"' "update --macos no longer greps for 'Anthropic'"

# ── 4. setup-token --macos ───────────────────────────────────────────────────────────────────
section "Tier 1 — setup-token --macos: a throwaway clone, no credentials, always removed"
eval "$verify_real"   # the REAL check, answered by the scripted guest below
# Credentials that MUST NOT reach the throwaway VM, in every form augur could read them.
export ANTHROPIC_API_KEY="sk-ant-api-SECRET-0123456789"
printf 'sk-ant-oat-FILESECRET-0123456789\n' > "$HOME/.claude_code_oauth_token"
gh() { [[ "$*" == "auth token" ]] && echo "ghp_GHSECRET0123456789"; }
printf '[user]\n  name = host-user\n' > "$HOME/.gitconfig"
# A project allowlist that a normal `up` would honour (approved, snapshot written).
mkdir -p "$AUGUR_PROJECT_DIR"; printf 'project.example\n' > "$AUGUR_PROJECT_CONF"
AUGUR_ACCEPT_PROJECT_CONF=1 check_project_conf_approved >/dev/null 2>&1
mkdir -p "$AUGUR_DIR/vms/$PV"; macos_store_admin_password "$PV" admin

SSHLOG="$TMPD/ssh"; SCPLOG="$TMPD/scp"
TV=""   # the throwaway VM's name, as cmd_setup_token_macos derives it
ssh_macos() {
    local vm="$1"; shift
    printf '%s\t%s\n' "$vm" "$*" >> "$SSHLOG"
    case "$*" in
        *"codesign --verify"*) [[ "$SIG_OK" == 1 ]] || return 1; printf '%s\n' "$good_dvv"; return 0 ;;
        "rm -f ~/.augur-env"*) [[ "$SCRUB_OK" == 1 ]] || return 1 ;;
        "-t "*) echo AGENT_LAUNCHED; return 0 ;;
    esac
    return 0
}
scp_to_macos() { printf '%s\t%s\t%s\n' "$1" "$3" "$(cat "$2")" >> "$SCPLOG"; }
start_proxy() {
    printf 'start_proxy %s socks=%s ssh=%s\n' "$1" "$AUGUR_PROXY_SOCKS_PORT" "$AUGUR_SSH_FWD_PORT" >> "$LOG"
    cp "$(write_merged_allowlist)" "$TMPD/allowlist.used"
}
start_gvproxy() { echo "start_gvproxy $(gvproxy_socket)" >> "$LOG"; }
stop_gvproxy()  { echo "stop_gvproxy" >> "$LOG"; }
stop_proxy()    { echo "stop_proxy" >> "$LOG"; }
sync_macos_guest_clock() { echo "clock $1" >> "$LOG"; }
SELFTEST_OK=1; SCRUB_OK=1
verify_macos_egress_locked() { echo "selftest $1" >> "$LOG"; [[ "$SELFTEST_OK" == 1 ]] || exit 1; }
macos_poweroff_before_teardown() { echo "poweroff $1" >> "$LOG"; }
macos_guest_poweroff()           { echo "poweroff $1" >> "$LOG"; }
# `read … < /dev/tty`: with a terminal this stub supplies the paste; without one (CI) the redirect
# fails first and no token is saved. Both are fine here: every assertion below holds either way.
read() {
    [[ "$1" == "-rp" ]] || { builtin read "$@"; return; }
    printf -v "${*: -1}" '%s' "sk-ant-oat01-pasted_token-0123456789"
}

run_st() {   # run_st — sets $out/$rc; fresh logs; VM_CLI state as left by the previous run
    : > "$LOG"; : > "$SSHLOG"; : > "$SCPLOG"; rm -f "$TMPD/allowlist.used"
    out="$( set -e; cmd_setup_token_macos 2>&1 )"; rc=$?
    sleep 0.3   # the backgrounded `augur-vm run` recorder line
    TV="$( TARGET_SLUG=""; TARGET_HASH=""; adopt_setup_token_identity; macos_project_vm )"
}
all_traffic() { cat "$LOG" "$SSHLOG" "$SCPLOG" "$TMPD/allowlist.used" 2>/dev/null; }
torn_down() {   # torn_down <label>
  logged "vm delete $TV" && ok "$1: the throwaway VM is deleted" || fail "$1: the throwaway VM is left behind" "$(cat "$LOG")"
  macos_vm_exists "$TV" && fail "$1: the throwaway VM still exists" || ok "$1: nothing of it remains"
  logged stop_gvproxy && logged stop_proxy && ok "$1: its gvproxy and proxy are stopped" || fail "$1: its egress helpers are left running"
  [[ -L "$(host_lock_path "$MACOS_SETUP_TOKEN_LOCK")" ]] && fail "$1: the lock is left behind" || ok "$1: the lock is released"
  [[ -L "$(host_lock_path "$MACOS_BASE_WRITER_LOCK")" ]] && fail "$1: the base-writer lock is left behind" || ok "$1: the base-writer lock is released"
  ( adopt_setup_token_identity; [[ -e "$(macos_egress_mode_file)" ]] ) && fail "$1: an egress-mode record was written (nothing reads it)" || ok "$1: no egress-mode record"
  grep -q "^poweroff " "$LOG" && fail "$1: the guest was asked to shut down before its disk is deleted" || ok "$1: stopped directly, no in-guest poweroff"
}

reset_vms; SIG_OK=1; SELFTEST_OK=1
run_st
[[ "$TV" != "$PV" ]] && ok "the throwaway VM ($TV) is not the project VM" || fail "the throwaway VM IS the project VM"
re="$(target_name_re macos)"
[[ "$TV" =~ $re ]] && fail "the throwaway VM name looks like a project VM (destroy <name> would offer it)" || ok "the throwaway VM name is outside the project naming scheme"
logged "vm clone $MACOS_BASE_VM $TV" && ok "clones the BASE VM" || fail "did not clone the base VM" "$(cat "$LOG")"
grep -q "$PV" <(all_traffic) && fail "the project VM was touched" "$(grep "$PV" <(all_traffic))" || ok "the project VM is never touched"
run_line="$(grep "^vm run " "$LOG")"
has   "$run_line" "--net-vfkit=" "boots on the filtered gvproxy datapath"
hasnt "$run_line" "--net-nat"    "never on NAT"
hasnt "$run_line" "--dir"        "no share at all: no workspace, history, agents or profile"
has "$(cat "$LOG")" "socks=${AUGUR_PROXY_SOCKS_PORT_SETUP_TOKEN} ssh=${AUGUR_SSH_FWD_PORT_SETUP_TOKEN}" "uses its own fixed ports, not the project's"
s_at="$(line_of "selftest $TV")"; k_at="$(line_of "clock $TV")"
[[ -n "$s_at" && -n "$k_at" && "$k_at" -lt "$s_at" ]] && ok "clock sync, then the boot self-test, as on up" || fail "no self-test / clock order" "$(cat "$LOG")"
allow="$(cat "$TMPD/allowlist.used" 2>/dev/null)"
has   "$allow" "api.anthropic.com"  "allowlist: the baseline layer"
has   "$allow" "global.example"     "allowlist: the global layer"
hasnt "$allow" "project.example"    "allowlist: NOT the project's .augur/allowlist.conf"
traffic="$(all_traffic; printf '%s\n' "$out")"
for secret in sk-ant-api-SECRET sk-ant-oat-FILESECRET ghp_GHSECRET host-user; do
  hasnt "$traffic" "$secret" "no credential or host config reaches the throwaway VM ($secret)"
done
hasnt "$(cat "$SSHLOG")" "cat > /Users/${MACOS_SSH_USER}/.augur-env" "no ~/.augur-env is written"
sc_at="$(grep -n 'rm -f ~/.augur-env ~/.gitconfig' "$SSHLOG" | head -n1 | cut -d: -f1)"
v_at="$(grep -n "codesign --verify" "$SSHLOG" | cut -d: -f1)"
[[ -n "$sc_at" && -n "$v_at" && "$sc_at" -lt "$v_at" ]] && ok "augur's credential files are scrubbed from the clone before the check and the launch" || fail "no credential scrub before the check" "scrub@$sc_at verify@$v_at"
hasnt "$(cat "$SCPLOG")" ".gitconfig" "no ~/.gitconfig is copied"
has "$(cat "$SCPLOG")" "hasCompletedOnboarding" "the onboarding-only ~/.claude.json stub is seeded"
launch="$(grep $'\t-t ' "$SSHLOG")"
has "$launch" "$BIN setup-token" "launches the verified binary by absolute path"
has "$launch" "DISABLE_AUTOUPDATER=1" "with the agent's fixed env"
hasnt "$launch" "zsh -l" "not through a login shell's PATH lookup"
v_at="$(grep -n "codesign --verify" "$SSHLOG" | cut -d: -f1)"; l_at="$(grep -n $'\t-t ' "$SSHLOG" | cut -d: -f1)"
[[ -n "$v_at" && -n "$l_at" && "$v_at" -lt "$l_at" ]] && ok "the signature check runs before the launch" || fail "launch without a prior signature check" "verify@$v_at launch@$l_at"
has "$out" "Only paste it if the sign-in you completed" "the operator warning is shown"
torn_down "success"

reset_vms; SIG_OK=0
run_st
[[ "$rc" -ne 0 ]] && ok "signature failure: exits non-zero" || fail "signature failure: exit 0"
grep -q $'\t-t ' "$SSHLOG" && fail "signature failure: setup-token was launched anyway" || ok "signature failure: nothing is attached to the TTY"
has "$out" "augur update --macos" "signature failure: points at update --macos"
torn_down "signature failure"
SIG_OK=1

reset_vms; SELFTEST_OK=0
run_st
[[ "$rc" -ne 0 ]] && ok "self-test failure: exits non-zero" || fail "self-test failure: exit 0"
grep -q $'\t-t ' "$SSHLOG" && fail "self-test failure: setup-token was launched" || ok "self-test failure: nothing launched"
torn_down "self-test failure (its own exit 1)"
SELFTEST_OK=1

reset_vms; SCRUB_OK=0
run_st
[[ "$rc" -ne 0 ]] && ok "credential scrub failure: exits non-zero" || fail "credential scrub failure: exit 0"
grep -q $'\t-t ' "$SSHLOG" && fail "credential scrub failure: setup-token was launched" || ok "credential scrub failure: nothing launched"
has "$out" "Could not remove augur's credential files" "credential scrub failure: says so"
torn_down "credential scrub failure"
SCRUB_OK=1

reset_vms
sync_macos_guest_clock() { echo "clock $1" >> "$LOG"; kill -INT "$(sh -c 'echo $PPID')"; }
run_st
sync_macos_guest_clock() { echo "clock $1" >> "$LOG"; }
eq 130 "$rc" "Ctrl-C: exits 130"
torn_down "Ctrl-C"

section "Tier 1 — setup-token --macos: a crash's leftovers are removed; a live run is not disturbed"
TV="$( adopt_setup_token_identity; macos_project_vm )"
reset_vms; echo "$TV" >> "$VMS"
run_st
d_at="$(line_of "vm delete $TV")"; c_at="$(line_of "vm clone $MACOS_BASE_VM $TV")"
[[ -n "$d_at" && -n "$c_at" && "$d_at" -lt "$c_at" ]] && ok "a stale throwaway VM is deleted before the new clone" || fail "stale clone not removed first" "$(cat "$LOG")"

LOCK="$(host_lock_path "$MACOS_SETUP_TOKEN_LOCK")"
reset_vms; ln -s 999999999 "$LOCK"
run_st
logged "vm clone $MACOS_BASE_VM $TV" && ok "a lock left by a dead process is taken over" || fail "a dead lock blocks setup-token"
[[ -L "$LOCK" ]] && fail "the taken-over lock is left behind" || ok "the taken-over lock is released at the end"

reset_vms; sleep 300 & live=$!; cleanup_pids+=("$live")
ln -s "$live:setup-token" "$LOCK"
run_st
[[ "$rc" -ne 0 ]] && ok "a concurrent run: refused" || fail "a concurrent run was not refused"
has "$out" "Another 'augur setup-token --macos' is running" "a concurrent run: says why"
grep -q "^vm " "$LOG" && fail "a concurrent run touched a VM" "$(cat "$LOG")" || ok "a concurrent run touches no VM (the live one is not torn down)"
eq "$live:setup-token" "$(readlink "$LOCK" 2>/dev/null)" "a concurrent run leaves the live lock alone"
rm -f "$LOCK"

section "Tier 1 — setup-token --macos never clones the base VM while a build or update holds it"
WLOCK="$(host_lock_path "$MACOS_BASE_WRITER_LOCK")"
for other in build update; do
  reset_vms; rm -f "$WLOCK"; ln -s "$live:$other" "$WLOCK"
  run_st
  [[ "$rc" -ne 0 ]] && ok "'$other' in progress: setup-token refuses" || fail "'$other' in progress: setup-token ran"
  has "$out" "'augur $other --macos' is running" "'$other' in progress: names it"
  logged "vm clone $MACOS_BASE_VM $TV" && fail "'$other' in progress: the base VM was cloned anyway" || ok "'$other' in progress: the base VM is not cloned"
  eq "$live:$other" "$(readlink "$WLOCK" 2>/dev/null)" "'$other' in progress: its lock is left alone"
  [[ -L "$LOCK" ]] && fail "'$other' in progress: setup-token's own lock is left behind" || ok "'$other' in progress: setup-token's own lock is released"
done
rm -f "$WLOCK"
# The base-writer lock is held exactly around the clone: a build or update started during the clone
# is refused, and one started once the throwaway VM is booting is not.
reset_vms
vm_cli_rec_plain="$(declare -f vm_cli_rec)"
eval "$(declare -f vm_cli_rec | sed '1s/^vm_cli_rec/vm_cli_rec_inner/')"
vm_cli_rec() { [[ "$1" == clone ]] && printf 'lock-at-clone %s\n' "$(readlink "$WLOCK" 2>/dev/null)" >> "$LOG"; vm_cli_rec_inner "$@"; }
sync_macos_guest_clock() { printf 'lock-at-boot %s\n' "$(readlink "$WLOCK" 2>/dev/null)" >> "$LOG"; }
run_st
eval "$vm_cli_rec_plain"
sync_macos_guest_clock() { echo "clock $1" >> "$LOG"; }
logged "lock-at-clone $$:setup-token" && ok "the clone runs under the base-writer lock" || fail "the clone runs without the base-writer lock" "$(cat "$LOG")"
logged "lock-at-boot " && ok "the base-writer lock is released once the clone is taken" || fail "the base-writer lock is held past the clone" "$(cat "$LOG")"

section "Tier 1 — host locks: atomic, and only a provably stale lock is ever removed"
# Each acquire runs in a subshell, as a separate augur process would: `$$` there is still this test,
# so the "holder" is simulated by the lock's content, never by $$.
acq() { out="$( set -e; host_lock_acquire "$MACOS_SETUP_TOKEN_LOCK" setup-token 2>&1 )"; rc=$?; }
rm -f "$LOCK"
acq
eq 0 "$rc" "no lock: acquired"
eq "$$:setup-token" "$(readlink "$LOCK")" "the lock is created already naming its holder and command (no empty window)"
ln -s "999" "$LOCK" 2>/dev/null && fail "a second create over a held lock succeeded (not atomic)" || ok "creating over an existing lock fails (symlink is the atomic step)"
rm -f "$LOCK"

for bad in "not-a-pid" "12x:update" ":update" "999999999:Update;rm"; do
  ln -s "$bad" "$LOCK"
  acq
  [[ "$rc" -ne 0 ]] && ok "a lock '$bad' that names no pid: refused, not treated as stale" || fail "a lock '$bad' was taken over"
  eq "$bad" "$(readlink "$LOCK")" "…and it is left untouched"
  rm -f "$LOCK"
done

ln -s "" "$LOCK" 2>/dev/null || ln -s " " "$LOCK"
acq
[[ "$rc" -ne 0 ]] && ok "an empty lock: refused, not treated as stale" || fail "an empty lock was taken over"
rm -f "$LOCK"

mkdir -p "$LOCK"
acq
[[ "$rc" -ne 0 ]] && ok "a directory at the lock path: refused (ln -s would 'succeed' inside it)" || fail "a directory at the lock path was accepted"
rmdir "$LOCK"

# The reap step itself: a process that saw a dead holder must not remove a lock another process
# took over in the meantime.
sleep 300 & live2=$!; cleanup_pids+=("$live2")
ln -s "$live2:setup-token" "$LOCK"
host_lock_reap "$MACOS_SETUP_TOKEN_LOCK" "999999999:setup-token" && fail "reap removed a lock now held by a live process" || ok "reap refuses when the lock no longer names the dead holder"
eq "$live2:setup-token" "$(readlink "$LOCK" 2>/dev/null)" "…and puts the live lock back untouched"
ls "$LOCK".reap.* >/dev/null 2>&1 && fail "reap left a private copy behind" || ok "…leaving no private copy behind"
rm -f "$LOCK"; ln -s "999999999:setup-token" "$LOCK"
host_lock_reap "$MACOS_SETUP_TOKEN_LOCK" "999999999:setup-token" && ok "reap removes a lock that still names the dead holder" || fail "reap did not remove a stale lock"
[[ -L "$LOCK" ]] && fail "the stale lock survived reap" || ok "…and it is gone"

# release only removes our own lock, taken for the same command.
ln -s "$live2:setup-token" "$LOCK"
host_lock_release "$MACOS_SETUP_TOKEN_LOCK" setup-token
eq "$live2:setup-token" "$(readlink "$LOCK" 2>/dev/null)" "release leaves another process's lock alone"
rm -f "$LOCK"; ln -s "$$:build" "$WLOCK"
host_lock_release "$MACOS_BASE_WRITER_LOCK" setup-token
eq "$$:build" "$(readlink "$WLOCK" 2>/dev/null)" "release for one command leaves this process's lock for another command alone"
rm -f "$WLOCK"

section "Tier 1 — setup-token --macos refuses (never stops) a running base VM, and a full VM slot"
reset_vms; RUNNING_VMS="$MACOS_BASE_VM"
run_st
[[ "$rc" -ne 0 ]] && ok "base VM running: refused" || fail "base VM running: setup-token ran"
has "$out" "is running" "base VM running: says so"
grep -q "^vm clone\|^vm stop\|^vm delete" "$LOG" && fail "base VM running: a VM was cloned/stopped/deleted" "$(cat "$LOG")" || ok "base VM running: nothing is cloned or stopped"

reset_vms; RUNNING_VMS="augur-macos-a-0123456789ab augur-macos-b-0123456789ab"
run_st
[[ "$rc" -ne 0 ]] && ok "two macOS VMs running: refused before cloning" || fail "two macOS VMs running: setup-token ran"
has "$out" "at most two" "two macOS VMs running: names the limit"
has "$out" "augur-macos-a-0123456789ab" "two macOS VMs running: lists the running VMs"
logged "vm clone $MACOS_BASE_VM $TV" && fail "two macOS VMs running: cloned anyway" || ok "two macOS VMs running: nothing is cloned"
grep -q "$PV" "$LOG" && fail "two macOS VMs running: fell back to the project VM" || ok "two macOS VMs running: no fallback to the project VM"
[[ -L "$LOCK" ]] && fail "two macOS VMs running: the lock is left behind" || ok "two macOS VMs running: the lock is released"

reset_vms; RUNNING_VMS="augur-macos-a-0123456789ab"
run_st
logged "vm clone $MACOS_BASE_VM $TV" && ok "one macOS VM running: the throwaway VM still fits" || fail "one macOS VM running: refused" "$out"
reset_vms

section "Tier 1 — setup-token --macos ignores --no-egress, and needs no safe workspace"
reset_vms
out="$( AUGUR_EGRESS=0; set -e; cmd_setup_token_macos 2>&1 )"; rc=$?
has "$out" "always runs with egress filtering on" "--no-egress: says it is ignored"
grep -q "^vm run .*--net-vfkit=" "$LOG" && ok "--no-egress: still the filtered datapath" || { sleep 0.3; grep -q "^vm run .*--net-vfkit=" "$LOG" && ok "--no-egress: still the filtered datapath" || fail "--no-egress: not filtered" "$(cat "$LOG")"; }
tail_case="$(sed -n '/^case "\$COMMAND" in$/,/^esac$/p' "$AUGUR" | head -n 4)"
has "$tail_case" 'setup-token)     $MACOS_MODE || require_safe_workspace' "the workspace gate skips setup-token --macos only"

section "Tier 1 — setup-token --macos: SSH reaches the throwaway VM on its own fixed forward port"
# The real port resolution (macos_ssh_port → the running gvproxy's --ssh-port), with a stand-in
# gvproxy started the way start_gvproxy starts it: with whatever AUGUR_SSH_FWD_PORT holds once the
# throwaway identity is adopted. The current project's port (20111 here) must never be used.
printf 'sleep 60\n' > "$TMPD/fake-gvproxy"
resolved="$(
    AUGUR_SSH_FWD_PORT=20111
    adopt_setup_token_identity
    bash "$TMPD/fake-gvproxy" --listen-vfkit "unixgram://$(gvproxy_socket)" --ssh-port "$AUGUR_SSH_FWD_PORT" >/dev/null 2>&1 &
    echo $! > "$(gvproxy_pidfile)"
    printf '%s %s %s\n' "$(macos_project_vm)" "$(macos_ssh_host "$(macos_project_vm)")" "$(macos_ssh_port "$(macos_project_vm)")"
    kill $! 2>/dev/null; rm -f "$(gvproxy_pidfile)"
)"
eq "$(TARGET_SLUG=""; TARGET_HASH=""; adopt_setup_token_identity; macos_project_vm) 127.0.0.1 ${AUGUR_SSH_FWD_PORT_SETUP_TOKEN}" "$resolved" \
   "the throwaway VM resolves to 127.0.0.1:${AUGUR_SSH_FWD_PORT_SETUP_TOKEN} (its fixed port, read back from its gvproxy)"
eq "20998" "$AUGUR_SSH_FWD_PORT_SETUP_TOKEN" "the throwaway VM's fixed forward port is 20998"

section "Tier 1 — setup-token --macos replaces a stored token that cannot be injected"
# A stored token that the injection check refuses (a quote, a newline) and a gh token that fails it
# too: setup-token must still reach the login and the save, or the operator could never replace it.
# The save is wrapped to supply the paste, so this holds with or without a terminal for /dev/tty.
eval "$(declare -f save_oauth_token | sed '1s/^save_oauth_token/real_save_oauth_token/')"
NEW_TOKEN="sk-ant-oat01-replacement_token-0123456789"
save_oauth_token() { echo "save" >> "$LOG"; real_save_oauth_token "$NEW_TOKEN" "${2:-}"; }
gh() { [[ "$*" == "auth token" ]] && printf '%s\n' $'ghp_bad\nEVIL=1'; }
unset ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN
for bad in "sk-ant-oat01-it's-bad-0123456789" $'sk-ant-oat01-bad\nEVIL=1'; do
  label="stored token with $([[ "$bad" == *\'* ]] && echo "a quote" || echo "a newline")"
  printf '%s\n' "$bad" > "$HOME/.claude_code_oauth_token"
  reset_vms; run_st
  eq 0 "$rc" "$label: setup-token --macos exits 0"
  logged "vm clone $MACOS_BASE_VM $TV" && ok "$label: the throwaway VM is cloned" || fail "$label: never cloned" "$out"
  grep -q $'\t-t ' "$SSHLOG" && ok "$label: the login is launched" || fail "$label: the login never ran" "$out"
  logged "save" && ok "$label: the token is saved" || fail "$label: save_oauth_token never ran" "$out"
  eq "$NEW_TOKEN" "$(cat "$HOME/.claude_code_oauth_token")" "$label: the file now holds the new token"
  hasnt "$out" "Refusing to inject" "$label: no injection check refuses it"
done
section "Tier 1 — setup-token --macos warns when CLAUDE_CODE_OAUTH_TOKEN hides the saved token"
reset_vms; CLAUDE_CODE_OAUTH_TOKEN="sk-ant-oat01-from-the-env-0123456789" run_st
has "$out" "CLAUDE_CODE_OAUTH_TOKEN is set in this shell" "env var set: warns that it takes precedence"
reset_vms; run_st
hasnt "$out" "CLAUDE_CODE_OAUTH_TOKEN is set in this shell" "env var unset: no warning"

# ── 5. The credential scrub, run for real against a stand-in guest home ─────────────────────────
section "Tier 1 — macos_scrub_augur_credentials removes exactly what augur writes into a guest"
GHOME="$TMPD/guest-home"; mkdir -p "$GHOME"
ssh_macos() { shift; HOME="$GHOME" bash -c "$*"; }
printf 'export GH_TOKEN=x\n' > "$GHOME/.augur-env"
printf '[credential "https://github.com"]\n  helper = x\n' > "$GHOME/.gitconfig"
printf 'export DEVELOPER_DIR=/x\n%s\nexport KEEP=1\n' "$MACOS_AUGUR_ENV_SOURCE_LINE" > "$GHOME/.zshenv"
printf 'keep-me\n' > "$GHOME/.zprofile"
macos_scrub_augur_credentials testvm; rc=$?
eq 0 "$rc" "scrub: succeeds"
[[ -e "$GHOME/.augur-env" ]] && fail "scrub: ~/.augur-env survives" || ok "scrub: ~/.augur-env is removed"
[[ -e "$GHOME/.gitconfig" ]] && fail "scrub: ~/.gitconfig (credential helper) survives" || ok "scrub: ~/.gitconfig is removed"
eq $'export DEVELOPER_DIR=/x\nexport KEEP=1' "$(cat "$GHOME/.zshenv")" "scrub: only the line sourcing ~/.augur-env leaves ~/.zshenv"
eq "keep-me" "$(cat "$GHOME/.zprofile")" "scrub: nothing else is touched"
printf '%s\n' "$MACOS_AUGUR_ENV_SOURCE_LINE" > "$GHOME/.zshenv"
macos_scrub_augur_credentials testvm; rc=$?
eq 0 "$rc" "scrub: a ~/.zshenv holding only that line is fine"
eq "" "$(cat "$GHOME/.zshenv")" "…and is left empty"
rm -f "$GHOME/.zshenv"
macos_scrub_augur_credentials testvm; rc=$?
eq 0 "$rc" "scrub: nothing to remove is fine"
has "$(declare -f cmd_up_macos)" 'MACOS_AUGUR_ENV_SOURCE_LINE' "up --macos writes the same ~/.zshenv line the scrub removes"

# ── 6. build / update with provisioning files present ──────────────────────────────────────────
# run_base_provisioning stops the scratch VM's NAT session to boot it on the filtered datapath. Every
# later step (scrub, managed policy, Xcode selection, the signer check) must still reach a RUNNING
# VM, and the signer check must see the guest as provisioning left it. Running state is modelled in
# a file: a boot wait marks the VM up, `augur-vm stop` marks it down, and ssh to a stopped VM fails.
section "Tier 1 — build/update with provisioning files: every later step reaches a running VM"
eval "$prov_real"
RUNF="$TMPD/running"
macos_vm_running() { grep -qx "$1" "$RUNF" 2>/dev/null; }
vm_cli_rec() {
    printf 'vm %s\n' "$*" >> "$LOG"
    case "$1" in
        create) echo "$2" >> "$VMS" ;;
        clone)  [[ "$3" == "$CLONE_FAIL_TO" ]] && return 1; echo "$3" >> "$VMS" ;;
        delete) grep -vx "$2" "$VMS" > "$VMS.t"; mv "$VMS.t" "$VMS" ;;
        stop)   grep -vx "$2" "$RUNF" > "$RUNF.t"; mv "$RUNF.t" "$RUNF" ;;
        list)   echo "ID NAME CPU MEM STATE" ;;
    esac
    return 0
}
wait_for_macos_ssh()     { echo "$1" >> "$RUNF"; echo "boot-nat $1" >> "$LOG"; }
wait_for_provision_ssh() { echo "$1" >> "$RUNF"; echo "boot-filtered $1" >> "$LOG"; }
guest() {   # guest <vm> <what>: one guest step, which fails if the VM is not running
    if grep -qx "$1" "$RUNF" 2>/dev/null; then echo "$2 $1" >> "$LOG"; return 0; fi
    echo "STOPPED $2 $1" >> "$LOG"; return 255
}
# Reads its stdin like ssh does (a `sudo -S` password is piped in); runs below get </dev/null.
ssh_macos()                      { cat >/dev/null; local vm="$1"; shift; guest "$vm" "ssh"; }
run_update() { out="$( exec 2>&1 </dev/null; set -e; cmd_update_macos )"; rc=$?; }
ssh_macos_provision()            { local vm="$1"; shift; guest "$vm" "pssh"; }
ssh_macos_provision_stdin()      { cat >/dev/null; local vm="$1"; shift; guest "$vm" "pssh"; }
macos_admin_password_stdin()     { echo pw; }
install_macos_managed_settings() { guest "$1" managed; }
select_macos_full_xcode()        { guest "$1" xcode; }
agent_verify_integrity_macos()   { guest "$1" verify && [[ "$SIG_OK" == 1 ]]; }
provision_files_present()        { return 0; }
provision_manifest_validate()    { return 0; }
check_provision_approved()       { return 0; }
start_provision_proxy()          { echo "start_provision_proxy" >> "$LOG"; }
start_provision_gvproxy()        { echo "start_provision_gvproxy" >> "$LOG"; }
stop_provision_proxy()           { echo "stop_provision_proxy" >> "$LOG"; }
stop_provision_gvproxy()         { echo "stop_provision_gvproxy" >> "$LOG"; }
run_provision_manifest()         { guest "$1" manifest; }
HOOK_OK=1
run_provision_hook()             { guest "$1" hook && [[ "$HOOK_OK" == 1 ]]; }
no_stopped_steps() {   # no_stopped_steps <label>
  grep -q '^STOPPED ' "$LOG" && fail "$1: a step ran against a stopped VM" "$(grep '^STOPPED ' "$LOG")" || ok "$1: no step ran against a stopped VM"
}
after_hook() {   # after_hook <label> <vm>: managed, xcode, verify all after the hook, verify last
  local h m x v
  h="$(line_of "hook $2")"; m="$(line_of "managed $2")"; x="$(grep -nx "xcode $2" "$LOG" | tail -n1 | cut -d: -f1)"; v="$(line_of "verify $2")"
  if [[ -n "$h" && -n "$m" && -n "$x" && -n "$v" && "$h" -lt "$m" && "$m" -lt "$v" && "$x" -lt "$v" ]]; then
    ok "$1: managed policy, Xcode selection and then the signer check run after the hook (hook@$h verify@$v)"
  else fail "$1: post-provisioning steps out of order" "hook@$h managed@$m xcode@$x verify@$v"; fi
  local b; b="$(grep -n "^boot-nat $2$" "$LOG" | tail -n1 | cut -d: -f1)"
  [[ -n "$b" && "$h" -lt "$b" && "$b" -lt "$m" ]] && ok "$1: the VM is restarted on NAT after provisioning" || fail "$1: no NAT restart after provisioning" "hook@$h nat@$b managed@$m"
}

reset_vms; : > "$RUNF"; SIG_OK=1; HOOK_OK=1
run_update
eq 0 "$rc" "update with provisioning: exits 0"
no_stopped_steps "update with provisioning"
after_hook "update with provisioning" "$MACOS_UPDATE_VM"
v_at="$(line_of "verify $MACOS_UPDATE_VM")"; c_at="$(line_of "vm clone $MACOS_UPDATE_VM $MACOS_BASE_VM")"
[[ -n "$v_at" && -n "$c_at" && "$v_at" -lt "$c_at" ]] && ok "update with provisioning: promoted only after the final check" || fail "update with provisioning: not promoted after the check" "$(cat "$LOG")"
macos_vm_exists "$MACOS_UPDATE_VM" && fail "update with provisioning: the staging copy is left behind" || ok "update with provisioning: the staging copy is gone"

reset_vms; : > "$RUNF"; SIG_OK=0
run_update
[[ "$rc" -ne 0 ]] && ok "update: a binary replaced by provisioning fails the final check" || fail "update: the final check passed a bad binary"
logged "vm delete $MACOS_BASE_VM" && fail "…but the base VM was deleted" || ok "…and the base VM is untouched"
macos_vm_exists "$MACOS_UPDATE_VM" && fail "…but the staging copy is left behind" || ok "…and the staging copy is discarded"
SIG_OK=1

reset_vms; : > "$RUNF"; HOOK_OK=0
run_update
[[ "$rc" -ne 0 ]] && ok "update: a failing hook aborts" || fail "update: a failing hook was ignored"
logged "vm delete $MACOS_BASE_VM" && fail "…but the base VM was deleted" || ok "…and the base VM is untouched"
logged stop_provision_gvproxy && ok "…and the provisioning helpers are stopped" || fail "…but the provisioning helpers are left running"
HOOK_OK=1
[[ -L "$WLOCK" ]] && fail "update: the base-writer lock is left behind" || ok "update: the base-writer lock is released on failure"

# build: everything before Step 6.5 stubbed down to its recorded effect.
IPSW="$TMPD/r.ipsw"; XIP="$TMPD/x.xip"; : > "$IPSW"; : > "$XIP"
MACOS_SSH_KEY="$TMPD/vm_key"; : > "$MACOS_SSH_KEY"; echo "ssh-ed25519 AAAA test" > "$MACOS_SSH_KEY.pub"
macos_setup_flow() { echo automated; }
macos_first_boot_automated() { echo "$MACOS_BUILD_VM" >> "$RUNF"; true & MACOS_BUILD_VM_PID=$!; MACOS_BUILD_VM_IP="192.0.2.1"; }
ssh_macos_bootstrap() { guest "$1" bootstrap; }
configure_macos_guest_session() { :; }
scp_to_macos() { guest "$1" scp; }
run_build() { out="$( exec 2>&1 </dev/null; set -e; cmd_build_macos --ipsw "$IPSW" --xcode-xip "$XIP" )"; rc=$?; }

: > "$VMS"; : > "$LOG"; : > "$RUNF"; SIG_OK=1; HOOK_OK=1
run_build
eq 0 "$rc" "build with provisioning: exits 0"
no_stopped_steps "build with provisioning"
after_hook "build with provisioning" "$MACOS_BUILD_VM"
logged "ssh $MACOS_BUILD_VM" && ok "build with provisioning: the ~/.claude.json scrub reaches the VM" || fail "build: scrub never ran"
v_at="$(line_of "verify $MACOS_BUILD_VM")"; c_at="$(line_of "vm clone $MACOS_BUILD_VM $MACOS_BASE_VM")"
[[ -n "$v_at" && -n "$c_at" && "$v_at" -lt "$c_at" ]] && ok "build with provisioning: saved only after the final check" || fail "build: saved before the final check" "$(cat "$LOG")"
macos_vm_exists "$MACOS_BASE_VM" && ok "build with provisioning: the base VM is saved" || fail "build with provisioning: no base VM"
[[ -L "$WLOCK" ]] && fail "build: the base-writer lock is left behind" || ok "build: the base-writer lock is released"

: > "$VMS"; : > "$LOG"; : > "$RUNF"; SIG_OK=0
run_build
[[ "$rc" -ne 0 ]] && ok "build: a binary failing the final check aborts" || fail "build: the final check passed a bad binary"
logged "vm clone $MACOS_BUILD_VM $MACOS_BASE_VM" && fail "…but it was saved as the base VM" || ok "…and nothing is saved as the base VM"
SIG_OK=1

: > "$VMS"; : > "$LOG"; : > "$RUNF"; CLONE_FAIL_TO="$MACOS_BASE_VM"
run_build
CLONE_FAIL_TO=""
[[ "$rc" -ne 0 ]] && ok "build: a failed save exits non-zero" || fail "build: a failed save exited 0"
macos_vm_exists "$MACOS_BUILD_VM" && ok "build: a failed save KEEPS the build VM (the only copy)" || fail "build: a failed save discarded the only copy" "$(cat "$LOG")"
has "$out" "augur-vm clone ${MACOS_BUILD_VM} ${MACOS_BASE_VM}" "build: a failed save says how to finish it"
[[ -L "$WLOCK" ]] && fail "build: a failed save leaves the lock behind" || ok "build: a failed save releases the lock"

for other in update build setup-token; do
  : > "$VMS"; echo "$MACOS_BASE_VM" >> "$VMS"; : > "$LOG"; : > "$RUNF"
  rm -f "$WLOCK"; ln -s "$live:$other" "$WLOCK"
  run_build
  [[ "$rc" -ne 0 ]] && ok "build while '$other' holds the lock: refused" || fail "build while '$other' holds the lock: ran"
  if [[ "$other" == build ]]; then has "$out" "Another 'augur build --macos' is running" "…and says another build is running"
  else has "$out" "'augur $other --macos' is running" "…and names the '$other'"; fi
  grep -q "^vm " "$LOG" && fail "…but a VM was created, stopped or deleted" "$(cat "$LOG")" || ok "…and no VM is touched (the base VM included)"
  eq "$live:$other" "$(readlink "$WLOCK" 2>/dev/null)" "…and the other run's lock is left alone"
done
rm -f "$WLOCK"
cert_fn="$(declare -f cmd_install_cert_macos)"
has "$cert_fn" 'host_lock_acquire "$MACOS_BASE_WRITER_LOCK" install-cert' "install-cert --macos (which writes into the base VM) takes the base-writer lock"
has "$cert_fn" 'host_lock_release "$MACOS_BASE_WRITER_LOCK" install-cert' "…and releases it"

section "Tier 1 — install-cert --macos skips a certificate that is already in the keychain"
if command -v openssl >/dev/null; then
  CRT="$TMPD/ca.crt"
  openssl req -x509 -newkey rsa:2048 -nodes -keyout /dev/null -out "$CRT" -days 30 -subj "/CN=augur-skip-test" 2>/dev/null
  eval "$(declare -f vm_cli_rec | sed '1s/vm_cli_rec/vm_cli_cert/')"
  VM_CLI=vm_cli_cert
  require_macos_admin_password() { :; }
  confirm_cert_install() { return 0; }
  wait_for_macos_ssh() { echo "$MACOS_BASE_VM" >> "$RUNF"; echo "ssh-up" >> "$LOG"; return 0; }
  scp_to_macos() { echo "scp" >> "$LOG"; return 0; }
  ssh_macos() { cat >/dev/null 2>&1 </dev/null; echo "ssh" >> "$LOG"; return 0; }
  CERT_PRESENT=1
  _cert_present_in_base_vm() { [[ "$CERT_PRESENT" == 1 ]]; }
  run_cert() { out="$( exec 2>&1 </dev/null; set -e; cmd_install_cert_macos "$CRT"; echo "done" )"; rc=$?; }

  reset_vms; : > "$RUNF"; CERT_PRESENT=1
  run_cert
  eq 0 "$rc" "already present: exits 0"
  has "$out" "already in the System keychain" "already present: says so"
  has "$out" "augur-skip-test" "already present: shows the subject"
  has "$out" "Expires:" "already present: shows the expiry"
  has "$out" "TRUST SETTING was NOT verified" "already present: says the trust setting was not verified"
  has "$out" "sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain" "already present: gives the manual trust command"
  hasnt "$out" "Existing project VMs are NOT updated" "already present: no project-VM reminder"
  logged "vm run --no-graphics --net-nat $MACOS_BASE_VM" && ok "already present: the base VM boots headless" || fail "already present: no headless boot" "$(cat "$LOG")"
  logged "vm run --net-nat $MACOS_BASE_VM" && fail "already present: a GUI window was opened" || ok "already present: no GUI window"
  logged scp && fail "already present: the certificate was copied into the VM" || ok "already present: nothing is copied into the VM"
  logged "vm stop $MACOS_BASE_VM" && ok "already present: the base VM is stopped" || fail "already present: the base VM is left running"
  grep -qx "$MACOS_BASE_VM" "$RUNF" && fail "already present: the base VM is still marked running" || ok "already present: the base VM is not running afterwards"
  [[ -L "$WLOCK" ]] && fail "already present: the base-writer lock is left behind" || ok "already present: the base-writer lock is released"

  reset_vms; : > "$RUNF"; CERT_PRESENT=0
  run_cert
  [[ "$rc" -ne 0 ]] && ok "absent: proceeds to the interactive step (refused without a terminal)" || fail "absent: did not reach the interactive step"
  hasnt "$out" "already in the System keychain" "absent: no skip notice"
  logged "vm run --no-graphics --net-nat $MACOS_BASE_VM" && logged "vm run --net-nat $MACOS_BASE_VM" && ok "absent: headless check, then a GUI boot" || fail "absent: boots are wrong" "$(cat "$LOG")"
  b1="$(grep -n '^vm run --no-graphics' "$LOG" | head -n1 | cut -d: -f1)"; s1="$(grep -n "^vm stop $MACOS_BASE_VM" "$LOG" | cut -d: -f1 | awk -v b="$b1" '$1>b{print;exit}')"; g1="$(grep -n '^vm run --net-nat' "$LOG" | head -n1 | cut -d: -f1)"
  [[ -n "$b1" && -n "$s1" && -n "$g1" && "$b1" -lt "$s1" && "$s1" -lt "$g1" ]] && ok "absent: the headless VM is stopped before the GUI boot" || fail "absent: boot order" "headless@$b1 stop@$s1 gui@$g1"
  logged scp && ok "absent: the certificate is staged in the VM" || fail "absent: certificate never staged"
  grep -qx "$MACOS_BASE_VM" "$RUNF" && fail "absent: the base VM is left running after the abort" || ok "absent: the base VM is stopped on the abort path"
  [[ -L "$WLOCK" ]] && fail "absent: the base-writer lock is left behind" || ok "absent: the base-writer lock is released"
else skip "install-cert skip branch" "openssl not available"; fi

finish
