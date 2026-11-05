#!/usr/bin/env bash
# Tier 1 (offline) — the macOS agent-binary trust chain.
#
#   1. agent_verify_integrity_macos: `codesign --verify --strict` against a Developer ID requirement
#      pinned to the vendor's Team ID, plus an exact TeamIdentifier line. A signature that merely
#      MENTIONS the vendor (an ad-hoc one with "anthropic" in its Identifier) must fail.
#   2. `update --macos` works on a staging copy and replaces the base VM only when every step,
#      the signature check included, passed. A failure leaves the base VM untouched.
#   3. ensure_macos_claude_bin never installs anything into a project VM; a missing binary is an
#      error pointing at `update --macos` / `build --macos`, and `claude --macos` refuses.
#   4. `setup-token --macos` runs in a throwaway clone of the base VM: never the project VM, no
#      credentials, no workspace or state shares, the baseline + global allowlist only, the binary
#      launched by the absolute path the signature check verified, and the clone removed on every
#      exit path (success, failure, Ctrl-C) and on the next run after a crash.
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

# ── 3. ensure_macos_claude_bin ────────────────────────────────────────────────────────────────
section "Tier 1 — ensure_macos_claude_bin: a missing binary is an error, never a self-install"
ssh_macos() { shift; printf '%s\n' "$*" > "$SIGCMD"; printf '%s\n' "$G_OUT"; return "$G_RC"; }
G_RC=0; G_OUT="present"
out="$(ensure_macos_claude_bin "$PV" 2>&1)"; rc=$?
eq 0 "$rc" "present: returns 0"
has "$(cat "$SIGCMD")" "'$BIN'" "probes the absolute install path"
G_RC=0; G_OUT="missing"
out="$(ensure_macos_claude_bin "$PV" 2>&1)"; rc=$?
[[ "$rc" -ne 0 ]] && ok "missing: fails" || fail "missing: returned 0"
has "$out" "augur update --macos" "missing: points at update --macos"
has "$out" "augur build --macos"  "missing: and at build --macos"
G_RC=255; G_OUT=""
out="$(ensure_macos_claude_bin "$PV" 2>&1)"; rc=$?
[[ "$rc" -ne 0 ]] && ok "unreachable: fails" || fail "unreachable: returned 0"
has "$out" "Could not check" "unreachable: says it could not check (not 'missing')"
bin_fn="$(declare -f ensure_macos_claude_bin)"
hasnt "$bin_fn" "install.sh" "never runs the installer inside a project VM"
hasnt "$bin_fn" "latest"     "never installs 'latest' inside a project VM"
hasnt "$bin_fn" "codesign"   "no signature check at plain claude launch (a project VM is guest-controlled)"

# claude --macos refuses when the binary is missing.
(
  require_vz() { :; }; require_fresh_egress_helpers() { :; }; macos_vm_running() { return 0; }
  require_macos_egress_mode_current() { :; }; sync_macos_guest_clock() { :; }; sync_macos_guest_timezone() { :; }
  ensure_macos_workspace() { :; }; ensure_macos_claude_projects() { :; }; ensure_macos_claude_agents() { :; }
  ensure_macos_claude_profile() { :; }; warn_if_macos_egress_pinned() { :; }
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
        clone)  [[ "$3" == "$CLONE_FAIL_TO" ]] && return 1; echo "$3" >> "$VMS" ;;
        delete) grep -vx "$2" "$VMS" > "$VMS.t"; mv "$VMS.t" "$VMS"
                if [[ "$2" == "$MACOS_BASE_VM" && -n "$ON_DELETE_BASE" ]]; then eval "$ON_DELETE_BASE"; fi ;;
        list)   echo "ID NAME CPU MEM STATE"
                for _v in $RUNNING_VMS; do echo "x $_v 4 8192 running"; done ;;
    esac
    return 0
}
VM_CLI=vm_cli_rec
reset_vms() { printf '%s\n' "$MACOS_BASE_VM" > "$VMS"; : > "$LOG"; RUNNING_VMS=""; CLONE_FAIL_TO=""; ON_DELETE_BASE=""; }
macos_vm_exists()  { grep -qx "$1" "$VMS" 2>/dev/null; }
macos_vm_running() { [[ " $RUNNING_VMS " == *" $1 "* ]]; }
require_vz() { :; }
mkdir -p "$AUGUR_DIR/vms/$MACOS_BASE_VM"; macos_store_admin_password "$MACOS_BASE_VM" admin
wait_for_macos_ssh() { return 0; }
ssh_macos() { echo "ssh $1" >> "$LOG"; return 0; }
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
logged "provision $MACOS_UPDATE_VM" && fail "signature failure: provisioning still ran" || ok "signature failure: stops before provisioning"

reset_vms; SIG_OK=1
ssh_macos() { echo "ssh $1" >> "$LOG"; [[ "$*" == *install.sh* ]] && return 1; return 0; }
run_update
[[ "$rc" -ne 0 ]] && ok "installer failure: update exits non-zero" || fail "installer failure: exit 0"
logged "vm delete $MACOS_BASE_VM" && fail "installer failure: the base VM was deleted" || ok "installer failure: the base VM is untouched"
ssh_macos() { echo "ssh $1" >> "$LOG"; return 0; }

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

section "Tier 1 — update --macos: never touches the build VM; refuses while a build runs"
reset_vms; echo "$MACOS_BUILD_VM" >> "$VMS"   # a kept (stopped) build VM
run_update
eq 0 "$rc" "a stopped build VM present: update still runs"
grep -q "$MACOS_BUILD_VM" "$LOG" && fail "update touched the build VM" "$(cat "$LOG")" || ok "update never touches '$MACOS_BUILD_VM'"
macos_vm_exists "$MACOS_BUILD_VM" && ok "the kept build VM is still there" || fail "the kept build VM was deleted"

reset_vms; echo "$MACOS_BUILD_VM" >> "$VMS"; RUNNING_VMS="$MACOS_BUILD_VM"
run_update
[[ "$rc" -ne 0 ]] && ok "a build in progress: update refuses" || fail "a build in progress: update ran"
has "$out" "build --macos' is in progress" "a build in progress: says so"
grep -q "^vm clone\|^vm delete\|^vm stop" "$LOG" && fail "a build in progress: update changed a VM" "$(cat "$LOG")" || ok "a build in progress: no VM is cloned, stopped or deleted"

reset_vms; echo "$MACOS_UPDATE_VM" >> "$VMS"   # left stopped by a crashed update
run_update
eq 0 "$rc" "a stale stopped staging VM: update runs"
d_at="$(line_of "vm delete $MACOS_UPDATE_VM")"; c_at="$(line_of "vm clone $MACOS_BASE_VM $MACOS_UPDATE_VM")"
[[ -n "$d_at" && -n "$c_at" && "$d_at" -lt "$c_at" ]] && ok "the stale staging VM is removed before the new clone" || fail "stale staging VM not removed first" "$(cat "$LOG")"

reset_vms; echo "$MACOS_UPDATE_VM" >> "$VMS"; RUNNING_VMS="$MACOS_UPDATE_VM"
run_update
[[ "$rc" -ne 0 ]] && ok "a running staging VM (another update): refused" || fail "a running staging VM: update ran"
logged "vm delete $MACOS_UPDATE_VM" && fail "a running staging VM was deleted" || ok "a running staging VM is left alone"

section "Tier 1 — update --macos: the swap always leaves one copy"
reset_vms; ON_DELETE_BASE='kill -INT "$BASHPID"'
run_update
eq 0 "$rc" "Ctrl-C between deleting the old base and saving the new one is ignored: the swap completes"
macos_vm_exists "$MACOS_BASE_VM" && ok "…and the base VM exists" || fail "…and the base VM is gone" "$(cat "$LOG")"

reset_vms; CLONE_FAIL_TO="$MACOS_BASE_VM"
run_update
[[ "$rc" -ne 0 ]] && ok "the save fails after the old base is deleted: exits non-zero" || fail "failed save: exit 0"
macos_vm_exists "$MACOS_UPDATE_VM" && ok "failed save: the updated staging copy is KEPT (the only copy left)" || fail "failed save: both copies are gone" "$(cat "$LOG")"
has "$out" "augur-vm clone ${MACOS_UPDATE_VM} ${MACOS_BASE_VM}" "failed save: prints the command that finishes the swap"
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
SELFTEST_OK=1
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
  [[ -L "$(setup_token_lock_path)" ]] && fail "$1: the lock is left behind" || ok "$1: the lock is released"
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
hasnt "$(cat "$SSHLOG")" ".augur-env" "no ~/.augur-env is written"
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

reset_vms
sync_macos_guest_clock() { echo "clock $1" >> "$LOG"; kill -INT "$BASHPID"; }
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

LOCK="$(setup_token_lock_path)"
reset_vms; ln -s 999999999 "$LOCK"
run_st
logged "vm clone $MACOS_BASE_VM $TV" && ok "a lock left by a dead process is taken over" || fail "a dead lock blocks setup-token"
[[ -L "$LOCK" ]] && fail "the taken-over lock is left behind" || ok "the taken-over lock is released at the end"

reset_vms; sleep 300 & live=$!; cleanup_pids+=("$live")
ln -s "$live" "$LOCK"
run_st
[[ "$rc" -ne 0 ]] && ok "a concurrent run: refused" || fail "a concurrent run was not refused"
has "$out" "Another 'augur setup-token --macos' is running" "a concurrent run: says why"
grep -q "^vm " "$LOG" && fail "a concurrent run touched a VM" "$(cat "$LOG")" || ok "a concurrent run touches no VM (the live one is not torn down)"
eq "$live" "$(readlink "$LOCK" 2>/dev/null)" "a concurrent run leaves the live lock alone"
rm -f "$LOCK"

section "Tier 1 — setup-token lock: atomic, and only a provably stale lock is ever removed"
# Each acquire runs in a subshell, as a separate augur process would: `$$` there is still this test,
# so the "holder" is simulated by the lock's content, never by $$.
acq() { out="$( set -e; setup_token_lock_acquire 2>&1 )"; rc=$?; }
rm -f "$LOCK"
acq
eq 0 "$rc" "no lock: acquired"
eq "$$" "$(readlink "$LOCK")" "the lock is created already naming its holder (no empty window)"
ln -s "999" "$LOCK" 2>/dev/null && fail "a second create over a held lock succeeded (not atomic)" || ok "creating over an existing lock fails (symlink is the atomic step)"
rm -f "$LOCK"

ln -s "not-a-pid" "$LOCK"
acq
[[ "$rc" -ne 0 ]] && ok "a lock that names no pid: refused, not treated as stale" || fail "a lock that names no pid was taken over"
eq "not-a-pid" "$(readlink "$LOCK")" "…and it is left untouched"
rm -f "$LOCK"

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
ln -s "$live2" "$LOCK"
setup_token_lock_reap 999999999 && fail "reap removed a lock now held by a live process" || ok "reap refuses when the lock no longer names the dead holder"
eq "$live2" "$(readlink "$LOCK" 2>/dev/null)" "…and puts the live lock back untouched"
ls "$LOCK".reap.* >/dev/null 2>&1 && fail "reap left a private copy behind" || ok "…leaving no private copy behind"
rm -f "$LOCK"; ln -s 999999999 "$LOCK"
setup_token_lock_reap 999999999 && ok "reap removes a lock that still names the dead holder" || fail "reap did not remove a stale lock"
[[ -L "$LOCK" ]] && fail "the stale lock survived reap" || ok "…and it is gone"

# release only removes our own lock.
ln -s "$live2" "$LOCK"
setup_token_lock_release
eq "$live2" "$(readlink "$LOCK" 2>/dev/null)" "release leaves another process's lock alone"
rm -f "$LOCK"

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

finish
