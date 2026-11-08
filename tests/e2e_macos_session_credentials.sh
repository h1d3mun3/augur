#!/usr/bin/env bash
# tests/e2e_macos_session_credentials.sh — LOCAL check, on a real Mac, that macOS VM mode delivers
# credentials only per SSH session and never leaves them on the guest's disk. NOT a CI job and not
# an NN_* tier (tests/run.sh never runs it). Prints one ok/FAIL/skip line per check.
#
# Usage, from the augur checkout on the Mac, after `bash install --here` and with a base VM built
# or updated by this augur (`augur update --macos`) and the project VM cloned from it:
#   AUGUR_TEST_LIVE=1 bash tests/e2e_macos_session_credentials.sh
#   AUGUR_TEST_LIVE=1 AUGUR_E2E_DESTRUCTIVE=1 bash tests/e2e_macos_session_credentials.sh
#
# Environment:
#   AUGUR_TEST_LIVE=1        required: it talks to a real VM.
#   AUGUR_E2E_PROJECT=<dir>  the project whose VM is used (default: this checkout). Any other
#                            directory also needs AUGUR_E2E_ANY_PROJECT=1, because the script's
#                            `augur up --macos` auto-approves that project's ./.augur/allowlist.conf.
#   AUGUR_E2E_BOOT=1         allow booting the project VM when it is stopped.
#   AUGUR_E2E_DESTRUCTIVE=1  also run the steps that change the VM: move the sshd drop-in away and
#                            back, and stop gvproxy under the live VM (which stops and reboots it).
#                            Implies AUGUR_E2E_BOOT=1.
#   AUGUR_E2E_SKIP_GVPROXY=1 with AUGUR_E2E_DESTRUCTIVE=1, leave gvproxy alone.
#   AUGUR_E2E_RESTORE=1      only put the drop-in back (after an interrupted run) and exit.
#
# The script's own sessions send only a dummy credential (augur-e2e-dummy-<random>). The real
# `augur up --macos` it runs resolves and validates the operator's own credentials as every `up`
# does (reading their token files and `gh auth token`, which may raise a keychain prompt), and
# sends none of them to the guest. It runs with AUGUR_ACCEPT_PROJECT_CONF=1, which approves the
# project's ./.augur/allowlist.conf and records that approval. No credential value or admin
# password is printed. An interrupted run exits non-zero. The VM is left running and usable at
# the end.
#
# shellcheck disable=SC2016,SC2088  # remote commands are single-quoted on purpose: the guest expands them
# shellcheck disable=SC2034,SC2154  # _creds, MACOS_* and AUGUR_DIR are shared with the sourced augur
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/lib.sh"
AUGUR="$REPO/augur"
PROJECT="${AUGUR_E2E_PROJECT:-$REPO}"
DESTRUCTIVE="${AUGUR_E2E_DESTRUCTIVE:-0}"
BOOT="${AUGUR_E2E_BOOT:-$DESTRUCTIVE}"
SKIP_GVPROXY="${AUGUR_E2E_SKIP_GVPROXY:-0}"
on() { [[ "$1" == 1 ]]; }

section "macOS session credentials — live check (LOCAL only, not CI)"
cat <<EOF
  Project: ${PROJECT}
  Always:   'augur up --macos' on the running VM (reconcile + egress self-test, ~1 min, twice),
            one dummy-credential session per check, a ~/.augur-env push, temp files in the guest's
            home, and removing the host's self-test record once (restored by 'augur up --macos').
  Boot:     $(on "$BOOT" && echo "ENABLED" || echo "off (AUGUR_E2E_BOOT=1)") — boots the project VM if it is stopped (1–3 min).
  Destructive: $(on "$DESTRUCTIVE" && echo "ENABLED" || echo "off (AUGUR_E2E_DESTRUCTIVE=1)")
            — moves /etc/ssh/sshd_config.d/200-augur-session-env.conf away and back (sudo in the
              guest; sessions are refused meanwhile);
            — $(on "$SKIP_GVPROXY" && echo "skipped (AUGUR_E2E_SKIP_GVPROXY=1):" || echo "")stops gvproxy under the live VM: ends every session of this project, and
              recovery stops and reboots the VM (2–4 min).
  Its 'augur up --macos' runs with AUGUR_ACCEPT_PROJECT_CONF=1: it approves this project's
            ./.augur/allowlist.conf, if any, and records the approval. It also resolves and validates
            your own credentials as every 'up' does (token files, 'gh auth token'; this may raise a
            keychain prompt) without sending them anywhere; the script's own sessions send only a dummy.
  If a restore fails, the summary at the end prints the command that finishes it.
EOF

# ── Guards ─────────────────────────────────────────────────────────────────────────────────────
if [[ "$(uname -s)" != "Darwin" ]]; then
    skip "macOS session credentials e2e" "not a macOS host — this check is local-only by design"; finish; exit $?
fi
if ! command -v augur-vm >/dev/null 2>&1 && [[ ! -x "$HOME/.augur/augur-vm" ]]; then
    skip "macOS session credentials e2e" "augur-vm backend not built (run: bash install)"; finish; exit $?
fi
if [[ "${AUGUR_TEST_LIVE:-0}" != "1" ]]; then
    skip "macOS session credentials e2e" "set AUGUR_TEST_LIVE=1 — this talks to a real VM"; finish; exit $?
fi
cd "$PROJECT" || { fail "cd into project '$PROJECT'"; finish; exit $?; }
if [[ "$(pwd -P)" != "$(cd "$REPO" && pwd -P)" && "${AUGUR_E2E_ANY_PROJECT:-0}" != 1 ]]; then
    fail "run against the augur checkout" "'${PROJECT}' is another project: its ./.augur/allowlist.conf would be auto-approved; set AUGUR_E2E_ANY_PROJECT=1 to allow that"
    finish; exit $?
fi

# augur's own helpers (the AUGUR_SOURCE_ONLY seam), so every name, path, message and ssh option
# here is the one augur uses. cd first: the VM name, gvproxy forward and record path derive from it.
AUGUR_SOURCE_ONLY=1 source "$AUGUR"
set +e
MACOS_MODE=true
MACOS_SHARE="workspace-$(workspace_slug)"
vm="$(macos_project_vm)"
DROPIN="$(macos_session_sshd_dropin)"
SAVED="/etc/ssh/augur-e2e-session-env.saved"      # where the destructive step parks the drop-in
NAMES="$(macos_session_env_names)" || { fail "read augur's credential names"; finish; exit $?; }
LINE="$(macos_session_accept_env_line "$NAMES")"
NAMES_RE="${NAMES// /|}"
DUMMY="augur-e2e-dummy-$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
DUMMY_OLD="augur-e2e-old-$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
DUMMY_SHA="$(printf '%s' "$DUMMY" | shasum -a 256 | cut -c1-64)"
_creds=("GH_TOKEN=${DUMMY}")                       # what ssh_macos_session sends; nothing else
[[ -n "$vm" && ${#DUMMY} -gt 20 ]] || { fail "derive the VM name and a dummy credential"; finish; exit $?; }

# The messages asserted below, each checked against the augur source first so a reworded message
# fails here by name instead of as a silent mismatch.
MSG_OLD_BASE="does not accept augur's session credentials over SSH"
MSG_DELIVERY="which augur's delivery check exits with"
MSG_UNVERIFIED="no egress self-test has passed since it booted"
MSG_NO_TRANSPORT="No SSH transport to VM '"
MSG_RETRY="push to VM '\$1' once more"
for _m in "$MSG_OLD_BASE" "$MSG_DELIVERY" "$MSG_UNVERIFIED" "$MSG_NO_TRANSPORT" "$MSG_RETRY"; do
    grep -qF -- "$_m" "$AUGUR" || fail "augur still prints the message this check expects" "not in $AUGUR: $_m"
done
MSG_RETRY="once more..."

# Never echo a value: every guest output shown in a failure goes through this.
redact() { local s="$1"; s="${s//$DUMMY/<dummy>}"; printf '%s' "${s//$DUMMY_OLD/<dummy>}"; }
# lib.sh's eq/has/hasnt, with what they print on a failure redacted.
eq()    { if [[ "$1" == "$2" ]]; then ok "$3"; else fail "$3" "expected [$(redact "$1")], got [$(redact "$2")]"; fi; }
has()   { case "$1" in *"$2"*) ok "$3" ;; *) fail "$3" "[$(redact "$2")] not found in: $(redact "$1")" ;; esac; }
hasnt() { case "$1" in *"$2"*) fail "$3" "[$(redact "$2")] unexpectedly present in: $(redact "$1")" ;; *) ok "$3" ;; esac; }
# The real CLI, for the steps augur itself must take (boot, reconcile, self-test).
augur_up() { AUGUR_ACCEPT_PROJECT_CONF=1 bash "$AUGUR" up --macos 2>&1; }
# prepare_macos_session (the guest work of `augur claude/shell --macos` before the session) with the
# dummy in place of the operator's credentials. In a subshell: its refusals exit.
prepare_with_dummy() {
    ( resolve_session_credentials() { _creds=("GH_TOKEN=${DUMMY}"); return 0; }
      prepare_macos_session "$vm" ) 2>&1
}
# A guest command for VM $vm, with no stdin, in a subshell: ssh_macos exits when the VM has no SSH
# transport, which must end only this command, not the run.
gssh() { ( ssh_macos "$vm" "$@" </dev/null ); }
# Guest command (both dummies on stdin) printing `value:<file>`, `name:<file>` and `gitcfg:<file>`
# for ~/.augur-env, ~/.zshenv and every ~/.augur-env.tmp.* that holds a dummy, a credential name's
# assignment, or a GIT_CONFIG_ line.
GUEST_DISK_SCAN='IFS= read -r v; IFS= read -r w; find ~ -maxdepth 1 -type f \( -name .augur-env -o -name .zshenv -o -name ".augur-env.tmp.*" \) | while IFS= read -r f; do grep -qF -e "$v" -e "$w" "$f" && echo "value:$f"; grep -qE "^(export )?('"$NAMES_RE"')=" "$f" && echo "name:$f"; grep -q "GIT_CONFIG_" "$f" && echo "gitcfg:$f"; done; true'
disk_scan() { printf '%s\n' "$DUMMY" "$DUMMY_OLD" | ssh_macos "$vm" "$GUEST_DISK_SCAN" 2>/dev/null; }
# A credential-bearing ~/.augur-env, as an older augur wrote it. It holds a second dummy, so a
# session that still sourced it could not pass for one that got the session's own value.
plant_old_env() { printf "export GH_TOKEN='%s'\n" "$DUMMY_OLD" | ssh_macos "$vm" 'umask 077; cat > ~/.augur-env' 2>/dev/null; }
# Pass/fail on whether $1 holds either dummy value, without showing $1.
lacks_dummy() { if [[ "$1" == *"$DUMMY"* || "$1" == *"$DUMMY_OLD"* ]]; then fail "$2" "a dummy value is in it"; else ok "$2"; fi; }
record_ok() { local _mode _pass; macos_read_boot_record; [[ -n "$(macos_vm_run_id "$vm")" && "$_mode" == on && "$_pass" == "$(macos_vm_run_id "$vm")" ]]; }

# ── Restores (also on Ctrl-C) ──────────────────────────────────────────────────────────────────
DROPIN_MOVED=0; RECORD_REMOVED=0; GVPROXY_STOPPED=0; RESTORE_FAILED=(); E2E_SIGNAL=0
RESTORE_DROPIN_HOW="AUGUR_TEST_LIVE=1 AUGUR_E2E_RESTORE=1 bash tests/e2e_macos_session_credentials.sh  (or, in the VM's own Terminal: sudo mv ${SAVED} ${DROPIN})"
RESTORE_VM_HOW="cd '${PROJECT}' && augur up --macos  (run it twice if the first one stops the VM)"
restore_dropin() {
    macos_run_root_script "$vm" "if [ -e '${SAVED}' ]; then mv -f '${SAVED}' '${DROPIN}'; fi; grep -qxF '${LINE}' '${DROPIN}'" >/dev/null 2>&1
}
# The EXIT trap. INT/TERM/HUP are ignored while it runs (augur_up inherits that, so a second Ctrl-C
# cannot cut a restore short), the drop-in goes back first, and each slow step prints its by-hand
# command before it starts. An interrupted run keeps its signal's exit status.
e2e_restore() {
    trap - EXIT; trap '' INT TERM HUP
    if on "$DROPIN_MOVED"; then
        if restore_dropin; then DROPIN_MOVED=0; echo "  restored: ${DROPIN}"
        else RESTORE_FAILED+=("the sshd drop-in: ${RESTORE_DROPIN_HOW}"); fi
    fi
    if on "$GVPROXY_STOPPED" || on "$RECORD_REMOVED"; then
        if ! { macos_vm_running "$vm" && gvproxy_running && record_ok; }; then
            echo "  restoring the VM with augur up --macos (if this is cut short: ${RESTORE_VM_HOW})"
            augur_up >/dev/null; macos_vm_running "$vm" || augur_up >/dev/null
        fi
        if macos_vm_running "$vm" && record_ok; then echo "  restored: VM '${vm}' running with a passed self-test"
        else RESTORE_FAILED+=("the VM and its self-test record: ${RESTORE_VM_HOW}"); fi
    fi
    if (( ${#RESTORE_FAILED[@]} > 0 )); then
        fail "restore everything this run changed"
        for _r in "${RESTORE_FAILED[@]}"; do echo "         ↳ restore by hand: ${_r}"; done
    fi
    (( E2E_SIGNAL == 0 )) || fail "the run finished" "interrupted (exit ${E2E_SIGNAL}); the checks after that point did not run"
    finish; local _rc=$?
    (( E2E_SIGNAL == 0 )) || exit "$E2E_SIGNAL"
    exit "$_rc"
}
trap e2e_restore EXIT
trap 'E2E_SIGNAL=130; exit 130' INT; trap 'E2E_SIGNAL=143; exit 143' TERM; trap 'E2E_SIGNAL=129; exit 129' HUP

if [[ "${AUGUR_E2E_RESTORE:-0}" == 1 ]]; then
    section "Restore only"
    if restore_dropin; then ok "the drop-in is in place with the exact AcceptEnv line"
    else fail "put the drop-in back" "in the VM's own Terminal: sudo mv ${SAVED} ${DROPIN}"; fi
    exit
fi

# ── 1. Boot or reconcile, and the self-test record ─────────────────────────────────────────────
section "up --macos and the per-boot self-test record"
if ! macos_vm_running "$vm"; then
    if ! on "$BOOT"; then
        skip "every check" "VM '${vm}' is not running; start it with 'augur up --macos' or set AUGUR_E2E_BOOT=1"; exit
    fi
    echo "  booting '${vm}'..."
fi
upout="$(augur_up)"; uprc=$?
if (( uprc == 0 )); then ok "augur up --macos completes on '${vm}'"
else fail "augur up --macos completes on '${vm}'" "exit ${uprc}: $(redact "$(printf '%s\n' "$upout" | tail -n 8)")"; exit; fi
has "$upout" "Egress self-test passed" "the egress self-test passed"
if record_ok; then ok "the self-test record matches macos_vm_run_id ($(macos_vm_run_id "$vm"))"
else fail "the self-test record matches macos_vm_run_id" "record [$(cat "$(macos_boot_record_file)" 2>/dev/null)] id [$(macos_vm_run_id "$vm")]"; fi

section "The run id is augur-vm's run.id plus its process's start time, stable for one boot"
id1="$(macos_vm_run_id "$vm")"
uuid="$(tr -d '[:space:]' < "$AUGUR_DIR/vms/$vm/run.id" 2>/dev/null)"
pid="$(tr -d '[:space:]' < "$AUGUR_DIR/vms/$vm/run.pid" 2>/dev/null)"
if [[ -n "$id1" && -n "$uuid" && "$pid" =~ ^[0-9]+$ ]]; then
    ok "augur-vm wrote a run.id ($uuid) and a run.pid for this boot"
    [[ "$id1" == "$uuid "?* ]] && ok "the run id starts with that UUID" || fail "the run id starts with run.id's UUID" "[$id1]"
    l1="$(LC_ALL=C TZ=UTC0 ps -o lstart= -p "$pid")"; sleep 3; l2="$(LC_ALL=C TZ=UTC0 ps -o lstart= -p "$pid")"
    [[ -n "$l1" ]] && eq "$l1" "$l2" "ps -o lstart= of augur-vm's run pid is the same 3 s apart" \
        || fail "ps -o lstart= of augur-vm's run pid answers" "pid ${pid}"
    eq "$id1" "$(macos_vm_run_id "$vm")" "the run id is the same 3 s apart"
    id_jst="$(TZ=JST-9 macos_vm_run_id "$vm")"; id_utc="$(TZ=UTC macos_vm_run_id "$vm")"
    id_unset="$(unset TZ; macos_vm_run_id "$vm")"
    eq "$id_utc" "$id_jst" "macos_vm_run_id is the same under TZ=JST-9 and TZ=UTC"
    eq "$id_utc" "$id_unset" "macos_vm_run_id is the same with TZ unset"
    raw_jst="$(LC_ALL=C TZ=JST-9 ps -o lstart= -p "$pid")"; raw_utc="$(LC_ALL=C TZ=UTC ps -o lstart= -p "$pid")"
    if [[ "$raw_jst" != "$raw_utc" ]]; then ok "control: ps's own lstart differs between TZ=JST-9 and TZ=UTC"
    else skip "control: ps's own lstart differs by TZ" "it does not on this host, so the TZ checks above prove less"; fi
else
    fail "augur-vm wrote a run.id and a run.pid for this boot" "run id [$id1], run.id [$uuid], run.pid [$pid] (an augur-vm older than this augur writes no run.id)"
fi

# ── 2. The base's sshd drop-in, and root over stdin ────────────────────────────────────────────
section "The sshd drop-in"
dout="$(gssh "cat '${DROPIN}'; stat -f 'owner=%Su:%Sg mode=%Lp' '${DROPIN}'" 2>&1)"
dcontent="$(gssh "cat '${DROPIN}'" 2>&1)"
if [[ "$dcontent" == "$LINE" ]]; then ok "${DROPIN} holds exactly the one line, and nothing else: ${LINE}"
else fail "${DROPIN} holds exactly the one line, and nothing else: ${LINE}" "$(redact "$dcontent")"; fi
if gssh "$(macos_session_env_check_cmd "$NAMES")"; then ok "the clones' check (macos_session_env_check_cmd) passes on this guest"
else fail "the clones' check (macos_session_env_check_cmd) passes on this guest"; fi
has "$dout" "owner=root:wheel mode=644" "the drop-in is root:wheel, mode 644"
pwfile="$(macos_admin_password_file "$vm")"
if [[ -f "$pwfile" ]]; then
    PW="$(cat "$pwfile")"
    sout="$(macos_run_root_script "$vm" '/usr/sbin/sshd -T </dev/null 2>/dev/null | awk '"'"'tolower($1) == "acceptenv" { for (i = 2; i <= NF; i++) print $i }'"'"'' 2>&1)"; src=$?
    eq "0" "$src" "sudo sshd -T runs (password on stdin)"
    for _n in $NAMES; do
        if grep -qxF -- "$_n" <<<"$sout"; then ok "sshd -T accepts ${_n}"; else fail "sshd -T accepts ${_n}" "not in its AcceptEnv list (output not shown: it comes from a sudo session)"; fi
    done
    if (( ${#PW} >= 4 )) && [[ "$sout" == *"$PW"* ]]; then fail "the sshd -T output holds no admin password"
    else ok "the sshd -T output holds no admin password"; fi

    section "Root scripts over one ssh stdin (sudo -S -k)"
    rout="$(macos_run_root_script "$vm" 'id -u' 2>&1)"; rrc=$?
    eq "0" "$rrc" "macos_run_root_script runs a script"
    if [[ "$(printf '%s' "$rout" | tr -d '[:space:]')" == 0 ]]; then ok "…as root (id -u prints 0, and nothing else)"
    else fail "…as root (id -u prints 0, and nothing else)" "it printed something else (not shown: it comes from a sudo session)"; fi
    if (( ${#PW} >= 4 )) && [[ "$rout" == *"$PW"* ]]; then fail "…and prints no password"; else ok "…and prints no password"; fi
    if gssh 'sudo -n true' >/dev/null 2>&1; then
        skip "a wrong password runs nothing" "this guest has passwordless sudo, which skips the password read"
    else
        marker="/tmp/augur-e2e-ran-${DUMMY##*-}"
        wout="$( macos_admin_password_stdin() { printf '%s\n' "augur-e2e-wrong-password"; }
                 macos_run_root_script "$vm" "touch '${marker}'; id -u" 2>&1 )"; wrc=$?
        if (( wrc != 0 )); then ok "a wrong password fails"; else fail "a wrong password fails" "exit 0"; fi
        if grep -qx 0 <<<"$wout"; then fail "…without running the script's id -u" "it printed 0"; else ok "…without running the script's id -u"; fi
        if gssh "test ! -e '${marker}'" 2>/dev/null; then ok "…and the script never ran (no marker file)"
        else fail "…and the script never ran" "${marker} exists in the guest"; fi
        if (( ${#PW} >= 4 )) && [[ "$wout" == *"$PW"* ]]; then fail "…and prints no password"; else ok "…and prints no password"; fi
    fi
    unset PW
else
    skip "sshd -T and root-script checks" "no stored admin password at ${pwfile}"
fi

# ── 3. A session gets the credential; the disk does not ────────────────────────────────────────
section "Credential delivery in a session"
SESSION_PROBE='printf "tok=%s\n" "$(printf %s "${GH_TOKEN:-}" | shasum -a 256 | cut -c1-64)"; printf "gcc=%s\n" "${GIT_CONFIG_COUNT:-}"; printf "fill=%s\n" "$(printf %s "$(printf "protocol=https\nhost=github.com\n\n" | GIT_TERMINAL_PROMPT=0 git credential fill 2>/dev/null | sed -n "s/^password=//p")" | shasum -a 256 | cut -c1-64)"'
session_probe() { ( ssh_macos_session "$vm" "$SESSION_PROBE" </dev/null ) 2>&1; }
pout="$(session_probe)"; prc=$?
eq "0" "$prc" "a session with a dummy GH_TOKEN runs"
has "$pout" "tok=${DUMMY_SHA}" "the session sees GH_TOKEN, equal to the value sent (compared by hash)"
if [[ "$pout" =~ gcc=([1-9][0-9]*) ]]; then ok "the session has git's helper set (GIT_CONFIG_COUNT=${BASH_REMATCH[1]})"
else fail "the session has git's helper set (GIT_CONFIG_COUNT)" "$(redact "$pout")"; fi
has "$pout" "fill=${DUMMY_SHA}" "git credential fill in the session answers with that GH_TOKEN"
lacks_dummy "$pout" "the session printed no value"
scan="$(disk_scan)"
eq "" "$(grep '^value:' <<<"$scan")" "no guest ~/.augur-env, ~/.zshenv or ~/.augur-env.tmp.* holds the value"
eq "" "$(grep '^name:' <<<"$scan")" "…none assigns a credential name (${NAMES})"
eq "" "$(grep '^gitcfg:' <<<"$scan")" "…none holds a GIT_CONFIG_ line"

section "A plain ssh (not a session) gets nothing"
qout="$(gssh 'printf "gh=%s\n" "${GH_TOKEN:+set}"; printf "gitenv=%s\n" "$(env | grep -c "^GIT_CONFIG_")"; h="$(git config --get-all credential.helper)"; printf "hrc=%s\n" "$?"; case "$h" in *GH_TOKEN*) echo augurhelper=yes ;; *) echo augurhelper=no ;; esac' 2>&1)"
has "$qout" "gh=" "control: the plain ssh ran"
hasnt "$qout" "gh=set" "a plain ssh_macos has no GH_TOKEN (with a credential resolved in augur's scope)"
has "$qout" "gitenv=0" "…and no GIT_CONFIG_* variable"
if [[ "$qout" == *"hrc=0"* || "$qout" == *"hrc=1"* ]]; then ok "…and git config --get-all credential.helper works normally"
else fail "…and git config --get-all credential.helper works normally" "$(redact "$qout")"; fi
has "$qout" "augurhelper=no" "…and lists no augur helper"

section "The host side of a session"
( ssh_macos_session "$vm" 'sleep 8' </dev/null >/dev/null 2>&1 ) & bg=$!
sshpid=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
    sleep 0.5
    # The session's ssh: a descendant of the background job whose argv carries SendEnv=GH_TOKEN.
    tree="$(ps -axo pid=,ppid=)"; kids=" $bg "; changed=1
    while (( changed )); do
        changed=0
        while read -r _p _pp; do
            [[ "$kids" == *" $_pp "* && "$kids" != *" $_p "* ]] && { kids+="$_p "; changed=1; }
        done <<<"$tree"
    done
    for _p in $kids; do
        [[ "$(ps -ww -o command= -p "$_p" 2>/dev/null)" == ssh*SendEnv=GH_TOKEN* ]] && { sshpid="$_p"; break 2; }
    done
done
if [[ -n "$sshpid" ]]; then
    ok "found the session's ssh (pid ${sshpid})"
    lacks_dummy "$(ps -ww -o command= -p "$sshpid")" "the session ssh's argv does not hold the value"
    if [[ "$(ps -E -ww -o command= -p "$sshpid" 2>/dev/null)" == *"$DUMMY"* ]]; then
        ok "observed: ps -E shows the value in the session ssh's environment to its own user (as documented)"
        others=""; psall="$(ps -E -axww -o pid=,command= 2>/dev/null)"
        while read -r _p _rest; do
            [[ "$_p" != "$sshpid" && "$_rest" == *"$DUMMY"* ]] && others+="$_p "
        done <<<"$psall"; unset psall
        if [[ -z "$others" ]]; then ok "no other host process's environment or argv holds the value"
        else fail "no other host process's environment or argv holds the value" "pids: ${others}(commands: $(for p in $others; do ps -o comm= -p "$p"; done | tr '\n' ' '))"; fi
    else
        skip "other host processes' environments" "ps -E does not show this user's own ssh environment here, so it cannot show the others either"
    fi
    skip "another account reading the ssh's environment" "needs a second account or sudo on the host"
else
    fail "found the session's ssh" "no ssh with SendEnv=GH_TOKEN under the background session"
fi
wait "$bg"; eq "0" "$?" "the background session completed"

# ── 4. The push's temp-file cleanup ────────────────────────────────────────────────────────────
section "Stale ~/.augur-env.tmp.* cleanup in the real guest"
eq "197001010000.00" "$(gssh 'TZ=UTC0 date -r 0 +%Y%m%d%H%M.%S' 2>&1 | tr -d '[:space:]')" \
   "guest date -r <seconds> +%Y%m%d%H%M.%S works"
gssh 'cd ~ && : > .augur-env.tmp.e2eold && touch -t "$(date -r $(( $(date +%s) - 600 )) +%Y%m%d%H%M.%S)" .augur-env.tmp.e2eold && : > .augur-env.tmp.e2efuture && touch -t 209901010000 .augur-env.tmp.e2efuture && : > .augur-env.tmp.e2efresh' >/dev/null 2>&1
eq "e2efresh e2efuture e2eold" "$(gssh 'cd ~ && ls -a | sed -n "s/^\.augur-env\.tmp\.\(e2e.*\)/\1/p" | sort | tr "\n" " "' 2>&1 | sed 's/ $//')" \
   "control: the three temp files exist before the push"
cout="$(push_macos_guest_env "$vm" 2>&1)"; crc=$?
eq "0" "$crc" "the push succeeds"
left="$(gssh 'cd ~ && ls -a | sed -n "s/^\.augur-env\.tmp\.\(e2e.*\)/\1/p" | sort | tr "\n" " "' 2>&1 | sed 's/ $//')"
eq "e2efresh" "$left" "the push removed the 10-minute-old and the far-future temp file and kept the fresh one"
gssh 'rm -f ~/.augur-env.tmp.e2efresh' >/dev/null 2>&1
hasnt "$cout" "grep:" "the push printed no raw grep error"

# ── 5. A running VM with no self-test record for its boot ──────────────────────────────────────
section "Interrupted boot: no self-test record for the running VM"
plant_old_env
RECORD_REMOVED=1; macos_drop_egress_pass
rout="$(prepare_with_dummy)"; rrc=$?
if (( rrc != 0 )); then ok "a session (prepare_macos_session) refuses the VM"; else fail "a session refuses the VM" "exit 0"; fi
has "$rout" "$MSG_UNVERIFIED" "…saying no self-test has passed since the boot"
eq "" "$(grep '^value:' <<<"$(disk_scan)")" "…after a push that removed the credential an older augur wrote"
uout="$(augur_up)"; urc=$?
if (( urc == 0 )); then ok "augur up --macos re-runs the self-test on the running VM"
else fail "augur up --macos re-runs the self-test on the running VM" "exit ${urc}: $(redact "$(printf '%s\n' "$uout" | tail -n 8)")"; fi
if record_ok; then ok "…and writes the record again"; RECORD_REMOVED=0; else fail "…and writes the record again"; fi
pout="$(session_probe)"
has "$pout" "tok=${DUMMY_SHA}" "the next session gets its credential"

# ── 6. Old base and delivery check (destructive) ───────────────────────────────────────────────
section "A guest without the drop-in (destructive)"
if ! on "$DESTRUCTIVE"; then
    skip "old-base refusal and the delivery check" "set AUGUR_E2E_DESTRUCTIVE=1 (moves the sshd drop-in away and back)"
else
    DROPIN_MOVED=1
    if macos_run_root_script "$vm" "mv -f '${DROPIN}' '${SAVED}'" >/dev/null 2>&1; then
        ok "moved the drop-in to ${SAVED}"
        plant_old_env
        bout="$(push_macos_guest_env "$vm" 2>&1)"; brc=$?
        eq "$MACOS_PUSH_REFUSED_RC" "$brc" "the push refuses the guest"
        has "$bout" "$MSG_OLD_BASE" "…with the old-base message"
        hasnt "$bout" "grep:" "…and no raw grep error"
        hasnt "$bout" "No such file" "…and no 'No such file'"
        scan="$(disk_scan)"
        eq "" "$(grep -E '^(value|name):' <<<"$scan")" "…and ~/.augur-env no longer holds the credential an older augur wrote"
        sout="$(prepare_with_dummy)"; src=$?
        if (( src != 0 )); then ok "a session (prepare_macos_session) is refused"; else fail "a session is refused" "exit 0"; fi
        has "$sout" "$MSG_OLD_BASE" "…with the old-base message"
        # The session ssh itself, past the push: the guest's sshd now drops GH_TOKEN.
        dout="$( ( ssh_macos_session "$vm" 'echo AUGUR-E2E-STARTED' </dev/null ) 2>&1 )"; drc=$?
        eq "1" "$drc" "a session whose sshd dropped the credential fails"
        has "$dout" "$MSG_DELIVERY" "…with the delivery check's (exit $MACOS_SESSION_ENV_MISSING_RC) message"
        hasnt "$dout" "AUGUR-E2E-STARTED" "…before its command starts"
        lacks_dummy "$dout" "…printing no value"
    else
        fail "move the drop-in away" "sudo in the guest failed; nothing was changed"
    fi
    if restore_dropin; then DROPIN_MOVED=0; ok "put the drop-in back"
    else fail "put the drop-in back"; fi
    eq "0" "$( (push_macos_guest_env "$vm" >/dev/null 2>&1); echo $?)" "the push accepts the guest again"
    pout="$(session_probe)"
    has "$pout" "tok=${DUMMY_SHA}" "a session gets its credential again"
fi

# ── 7. No SSH transport (destructive, slow) ────────────────────────────────────────────────────
section "No SSH transport: gvproxy stopped under the live VM (destructive, slow)"
if ! on "$DESTRUCTIVE"; then
    skip "no-transport checks" "set AUGUR_E2E_DESTRUCTIVE=1 (stops gvproxy; the VM is stopped and rebooted)"
elif on "$SKIP_GVPROXY"; then
    skip "no-transport checks" "AUGUR_E2E_SKIP_GVPROXY=1"
else
    GVPROXY_STOPPED=1
    stop_gvproxy >/dev/null 2>&1
    if gvproxy_running; then fail "stop gvproxy" "it is still running"
    elif ( macos_ssh_pin "$vm" ); then
        skip "no-transport checks" "the VM still resolves an SSH host and port without gvproxy ('augur-vm ip' answered)"
    else
        ok "gvproxy stopped; the VM has no SSH transport"
        nout="$(push_macos_guest_env "$vm" 2>&1)"; nrc=$?
        eq "1" "$nrc" "a push fails at once"
        has "$nout" "$MSG_NO_TRANSPORT" "…saying there is no SSH transport"
        hasnt "$nout" "Could not write" "…not that the write failed"
        sout="$(prepare_with_dummy)"; src=$?
        if (( src != 0 )); then ok "a session (prepare_macos_session) fails"; else fail "a session fails" "exit 0"; fi
        has "$sout" "$MSG_NO_TRANSPORT" "…saying there is no SSH transport"
        hasnt "$sout" "$MSG_RETRY" "…and does not retry"
    fi
    echo "  recovering: augur up --macos (the self-test stops the stranded VM), then a fresh boot..."
    r1="$(augur_up)"; r1rc=$?
    if (( r1rc != 0 )) && ! macos_vm_running "$vm"; then ok "the first up --macos fails closed and stops the stranded VM"
    elif (( r1rc == 0 )); then skip "the first up --macos fails closed" "it succeeded (gvproxy was not stranded)"
    else fail "the first up --macos stops the stranded VM" "the VM is still running: $(redact "$(printf '%s\n' "$r1" | tail -n 6)")"; fi
    if ! macos_vm_running "$vm"; then augur_up >/dev/null; fi
    if macos_vm_running "$vm" && gvproxy_running && record_ok; then ok "a second up --macos boots it again"; GVPROXY_STOPPED=0
    else fail "a second up --macos boots it again"; fi
fi

# ── 8. Left usable ─────────────────────────────────────────────────────────────────────────────
section "The VM is left running and usable"
if macos_vm_running "$vm" && record_ok; then ok "VM '${vm}' is running with a passed self-test for this boot"
else fail "VM '${vm}' is running with a passed self-test for this boot"; fi
eq "0" "$( (push_macos_guest_env "$vm" >/dev/null 2>&1); echo $?)" "a final push rewrites the guest's ~/.augur-env"
pout="$(session_probe)"
has "$pout" "tok=${DUMMY_SHA}" "a session gets its credential"
eq "" "$(grep -E '^(value|name|gitcfg):' <<<"$(disk_scan)")" "nothing on the guest's disk holds the dummy, a credential name or GIT_CONFIG_"
# e2e_restore (the EXIT trap) prints the summary.
