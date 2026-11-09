#!/usr/bin/env bash
# tests/e2e_macos_managed_settings.sh — LOCAL check, on a real Mac, of how the macOS base VM's
# managed Claude Code policy is installed and re-checked (install_macos_managed_settings,
# verify_macos_managed_settings). NOT a CI job and not an NN_* tier (tests/run.sh never runs it).
# Prints one ok/FAIL/skip line per check and exits non-zero on any FAIL.
#
# It covers what tests/57_macos_managed_settings_unit.sh can only emulate on Linux: macOS's own
# /bin/sh, `ls -le` ACL lines, `chmod -N`, `mv`, `cmp`, `base64` and `mktemp`, the stock
# /Library/Application Support, and the policy a real build/update leaves in the base VM.
#
# Usage, from the augur checkout on the Mac, after `bash install --here`:
#   AUGUR_TEST_LIVE=1 bash tests/e2e_macos_managed_settings.sh            # stages 1-3 (~3-6 min)
#   AUGUR_TEST_LIVE=1 bash tests/e2e_macos_managed_settings.sh --update   # update first (+10-30 min)
#   AUGUR_TEST_LIVE=1 bash tests/e2e_macos_managed_settings.sh --hook     # provisioning hook (+35-90 min)
#   AUGUR_TEST_LIVE=1 bash tests/e2e_macos_managed_settings.sh --restore  # after an interrupted --hook
#
# Stages:
#   1-3 (always): a throwaway clone of the base VM (augur-e2e-policy) is booted on NAT, checked and
#       deleted. Nothing else changes: no project VM is touched and the base VM is only read.
#       1. the stock /Library/Application Support (its `ls -lde` is printed) passes augur's own
#          parent check, the exact line of the install script;
#       2. the base's policy directory and file are as installed (owner, mode, no ACL, one link,
#          the bytes augur renders on the host, compared by SHA-256), the real
#          verify_macos_managed_settings passes, and no staging or quarantine file is left;
#       3. the BSD tools the root script relies on behave as it assumes, as root through the real
#          macos_run_root_script, and the real install script swaps a sandbox directory under
#          /var/root (never the clone's real policy) in each case it must handle.
#   --update: `augur update --macos` first, so stages 1-3 check a base this augur just updated.
#   --hook: replaces ~/.augur/provision/ with test hooks for three updates, then puts it back:
#       a hook adding a file beside the policy (update succeeds), a hook overwriting the policy
#       (update fails and saves nothing; a clone then shows the base still holds the added file and
#       the real policy), and a final clean update with your own provisioning, which discards the
#       test file. Your provisioning must be approved already (the script never approves it).
#
# The base VM must be stopped. The script never prints the admin password: it only reaches the
# guest through augur's own macos_run_root_script. An EXIT trap deletes the throwaway clone and puts
# ~/.augur/provision/ back, ignoring a second Ctrl-C meanwhile; an interrupted run exits non-zero.
#
# shellcheck disable=SC2016  # guest commands are single-quoted on purpose: the guest expands them
# shellcheck disable=SC2034,SC2154  # MACOS_*, AUGUR_* and VM_CLI are shared with the sourced augur
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/lib.sh"
AUGUR="$REPO/augur"
ME="tests/e2e_macos_managed_settings.sh"

DO_UPDATE=0; DO_HOOK=0; DO_RESTORE=0
for _a in "$@"; do
    case "$_a" in
        --update)  DO_UPDATE=1 ;;
        --hook)    DO_HOOK=1 ;;
        --restore) DO_RESTORE=1 ;;
        -h|--help) sed -n '2,/^# shellcheck/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown argument: $_a (see --help)" >&2; exit 2 ;;
    esac
done
on() { [[ "$1" == 1 ]]; }

section "macOS managed Claude Code policy — live check (LOCAL only, not CI)"
cat <<EOF
  Always (~3-6 min): clones the base VM to a throwaway VM 'augur-e2e-policy', boots it on NAT
            (1-5 min), runs read-only checks and root-script checks in a sandbox under its
            /var/root, then deletes it. The base VM is only read; no project VM is touched.
  --update: $(on "$DO_UPDATE" && echo "ENABLED" || echo "off") — runs 'augur update --macos' first (10-30 min; replaces the base VM
            as every update does).
  --hook:   $(on "$DO_HOOK" && echo "ENABLED" || echo "off") — SLOW (35-90 min): three 'augur update --macos' runs with
            ~/.augur/provision/ temporarily replaced by test hooks (restored by the EXIT trap, or
            with --restore), one extra throwaway boot, and a final clean update with your own
            provisioning, which leaves the base VM as a normal update would.
EOF

# ── Guards ─────────────────────────────────────────────────────────────────────────────────────
if [[ "$(uname -s)" != "Darwin" ]]; then
    skip "macOS managed-settings e2e" "not a macOS host — this check is local-only by design"; finish; exit $?
fi
if ! command -v augur-vm >/dev/null 2>&1 && [[ ! -x "$HOME/.augur/augur-vm" ]]; then
    skip "macOS managed-settings e2e" "augur-vm backend not built (run: bash install)"; finish; exit $?
fi
if [[ "${AUGUR_TEST_LIVE:-0}" != "1" ]]; then
    skip "macOS managed-settings e2e" "set AUGUR_TEST_LIVE=1 — this boots and changes VMs"; finish; exit $?
fi

# augur's own helpers (the AUGUR_SOURCE_ONLY seam), so every path, script and ssh option here is
# the one augur uses.
AUGUR_SOURCE_ONLY=1 source "$AUGUR"
set +e
MACOS_MODE=true
PROBE="augur-e2e-policy"
PROBE_LOCK="policy-check"
DST="$(agent_macos_managed_settings_path)"; PDIR="$(dirname "$DST")"; PBASE="$(dirname "$PDIR")"
PNAME="$(basename "$DST")"
SANDBOX="/var/root/augur-e2e-swap"                 # stage 3's sandbox in the throwaway clone
MARKER="augur-e2e-hook-marker.txt"                 # the file --hook's first hook adds
BK="$AUGUR_DIR/provision.e2e-managed-settings-backup"
HASHF="$(provision_hash_file)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/augur-e2e-policy.XXXXXX")" || { fail "create a temporary directory"; finish; exit $?; }
POLICY_SHA="$(agent_managed_settings_json | shasum -a 256 | cut -c1-64)"
[[ ${#POLICY_SHA} == 64 ]] || { fail "render augur's policy on the host"; finish; exit $?; }

# ── Throwaway clone ────────────────────────────────────────────────────────────────────────────
PROBE_PID=""; PROBE_LIVE=0; LOCK_HELD=0
probe_delete() {
    if macos_vm_exists "$PROBE"; then
        stop_and_reap_macos_vm "$PROBE" "$PROBE_PID"
        "$VM_CLI" delete "$PROBE" >/dev/null 2>&1
    fi
    PROBE_PID=""; PROBE_LIVE=0
    rm -f "$(vm_known_hosts_file "$PROBE")"
    ! macos_vm_exists "$PROBE"
}
# Clone the base VM to $PROBE and boot it on NAT. The base-writer lock is held only for the clone,
# as setup-token does, so no build or update replaces the base VM halfway through the copy; it is
# released before any `augur update` this script runs, which takes the same lock.
probe_up() {
    probe_delete || { fail "delete a leftover '${PROBE}'"; return 1; }
    if ! macos_vm_exists "$MACOS_BASE_VM"; then fail "base VM '${MACOS_BASE_VM}' exists"; return 1; fi
    if macos_vm_running "$MACOS_BASE_VM"; then
        fail "base VM '${MACOS_BASE_VM}' is stopped" "stop it first: augur-vm stop ${MACOS_BASE_VM}"; return 1
    fi
    LOCK_HELD=1   # release only removes a lock this process holds
    ( host_lock_acquire "$MACOS_BASE_WRITER_LOCK" "$PROBE_LOCK" ) || { fail "take the base-writer lock (another augur build/update is running?)"; return 1; }
    "$VM_CLI" clone "$MACOS_BASE_VM" "$PROBE" >/dev/null 2>&1; local _crc=$?
    host_lock_release "$MACOS_BASE_WRITER_LOCK" "$PROBE_LOCK"; LOCK_HELD=0
    (( _crc == 0 )) || { fail "clone '${MACOS_BASE_VM}' to '${PROBE}'"; return 1; }
    rm -f "$(vm_known_hosts_file "$PROBE")"
    echo "  booting the throwaway clone '${PROBE}' on NAT (1-5 min)..."
    PROBE_LIVE=1
    if macos_boot_scratch_vm_nat "$PROBE" "$WORK/probe.vm.log"; then
        PROBE_PID="$MACOS_SCRATCH_VM_PID"; ok "a throwaway clone of the base VM boots and answers SSH"; return 0
    fi
    PROBE_PID="$MACOS_SCRATCH_VM_PID"
    fail "the throwaway clone answers SSH" "VM log: $WORK/probe.vm.log"
    return 1
}
# A plain (non-root) guest command on the clone, no stdin, in a subshell (ssh_macos exits when the
# VM has no transport).
gssh() { ( ssh_macos "$PROBE" "$@" </dev/null ); }
# The real macos_run_root_script on the clone: RS_OUT is its stdout, RS_RC its status, RS_ERR the
# guest stderr it keeps aside. Not in `$( )`, which would lose MACOS_ROOT_SCRIPT_ERR.
RS_OUT=""; RS_RC=0; RS_ERR=""
rs() {
    RS_RC=0
    macos_run_root_script "$PROBE" "$1" > "$WORK/rs.out" || RS_RC=$?
    RS_OUT="$(cat "$WORK/rs.out")"; RS_ERR="$MACOS_ROOT_SCRIPT_ERR"
}
last_line() { printf '%s' "${1##*$'\n'}"; }
guest_tail() { printf '%s\n' "$1" | tail -n "${2:-6}" | tr '\n' '|'; }

# ── ~/.augur/provision/ swap for --hook ────────────────────────────────────────────────────────
# What was there is recorded in $BK before anything moves, so a restore after any interruption
# knows what to put back: BK/provision (the moved directory) or BK/no-provision, and
# BK/macos.sha256 (the approval record) or BK/no-hash.
HOOK_SWAPPED=0
provision_backup() {
    if [[ -e "$BK" || -L "$BK" ]]; then
        fail "no backup from an earlier run is pending" "run: AUGUR_TEST_LIVE=1 bash ${ME} --restore"; return 1
    fi
    mkdir -m 700 "$BK" || { fail "create ${BK}"; return 1; }
    HOOK_SWAPPED=1
    if [[ -f "$HASHF" ]]; then cp -p "$HASHF" "$BK/macos.sha256" || return 1; else : > "$BK/no-hash"; fi
    if [[ -e "$AUGUR_PROVISION_DIR" || -L "$AUGUR_PROVISION_DIR" ]]; then
        mv "$AUGUR_PROVISION_DIR" "$BK/provision" || return 1
    else
        : > "$BK/no-provision"
    fi
    mkdir -m 700 "$AUGUR_PROVISION_DIR"
}
provision_restore() {
    [[ -d "$BK" ]] || return 0
    if [[ -e "$BK/provision" || -L "$BK/provision" || -e "$BK/no-provision" ]]; then
        rm -f "$AUGUR_PROVISION_DIR/hook.sh"
        if [[ -d "$AUGUR_PROVISION_DIR" ]]; then rmdir "$AUGUR_PROVISION_DIR" || return 1; fi
        if [[ -e "$BK/provision" || -L "$BK/provision" ]]; then mv "$BK/provision" "$AUGUR_PROVISION_DIR" || return 1; fi
    fi
    if [[ -f "$BK/macos.sha256" ]]; then cp -p "$BK/macos.sha256" "$HASHF" || return 1
    elif [[ -e "$BK/no-hash" ]]; then rm -f "$HASHF"; fi
    rm -rf "$BK"
    HOOK_SWAPPED=0
}
write_hook() {   # $1 = the hook's root shell lines
    printf '#!/bin/bash\n# augur e2e test hook (%s); removed when the run ends.\nset -e\n%s\n' "$ME" "$1" \
        > "$AUGUR_PROVISION_DIR/hook.sh"
}

# `augur update --macos`, its output shown and kept in $WORK/update-$1.log; UP_OUT and UP_RC hold
# them. $2… are extra VAR=value settings for that run.
UP_OUT=""; UP_RC=0
run_update() {
    local log="$WORK/update-$1.log"; shift
    echo "  running: augur update --macos (log: ${log})"
    env ${1+"$@"} bash "$AUGUR" update --macos 2>&1 | tee "$log"; UP_RC=${PIPESTATUS[0]}
    UP_OUT="$(cat "$log")"
}

# ── Restores (also on Ctrl-C) ──────────────────────────────────────────────────────────────────
E2E_SIGNAL=0; RESTORE_FAILED=()
e2e_restore() {
    trap - EXIT; trap '' INT TERM HUP
    (( LOCK_HELD )) && host_lock_release "$MACOS_BASE_WRITER_LOCK" "$PROBE_LOCK"
    if on "$PROBE_LIVE" || macos_vm_exists "$PROBE"; then
        if probe_delete; then echo "  deleted the throwaway clone '${PROBE}'"
        else RESTORE_FAILED+=("the throwaway clone: augur-vm stop ${PROBE}; augur-vm delete ${PROBE}"); fi
    fi
    if on "$HOOK_SWAPPED" || [[ -d "$BK" ]]; then
        if provision_restore; then echo "  restored: ${AUGUR_PROVISION_DIR} and its approval record"
        else RESTORE_FAILED+=("~/.augur/provision/: AUGUR_TEST_LIVE=1 bash ${ME} --restore (backup in ${BK})"); fi
    fi
    if (( ${#RESTORE_FAILED[@]} > 0 )); then
        fail "restore everything this run changed"
        for _r in "${RESTORE_FAILED[@]}"; do echo "         ↳ restore by hand: ${_r}"; done
    fi
    (( E2E_SIGNAL == 0 )) || fail "the run finished" "interrupted (exit ${E2E_SIGNAL}); the checks after that point did not run"
    finish; local _rc=$?
    if (( _rc == 0 && E2E_SIGNAL == 0 )); then rm -rf "$WORK"; else echo "  logs kept in ${WORK}"; fi
    (( E2E_SIGNAL == 0 )) || exit "$E2E_SIGNAL"
    exit "$_rc"
}
trap e2e_restore EXIT
trap 'E2E_SIGNAL=130; exit 130' INT; trap 'E2E_SIGNAL=143; exit 143' TERM; trap 'E2E_SIGNAL=129; exit 129' HUP

if on "$DO_RESTORE"; then
    section "Restore only"
    if [[ -d "$BK" ]]; then HOOK_SWAPPED=1; else ok "no ~/.augur/provision/ backup is pending"; fi
    exit
fi

# The messages asserted below, checked against the augur source first, so a reworded message fails
# here by name instead of as a silent mismatch.
MSG_INSTALL="Installing augur's managed"
MSG_CHECK="Checking that the base VM still holds augur's managed"
MSG_MISMATCH="no longer holds augur's managed"
MSG_HOOK_RULE="Custom provisioning must not replace or change augur's"
MSG_DISCARDED="Discarded with the old policy directory"
MSG_HOOK_RAN="Provisioning: running ~/.augur/provision/hook.sh"
for _m in "$MSG_INSTALL" "$MSG_CHECK" "$MSG_MISMATCH" "$MSG_HOOK_RULE" "$MSG_DISCARDED" "$MSG_HOOK_RAN"; do
    grep -qF -- "$_m" "$AUGUR" || fail "augur still prints the message this check expects" "not in $AUGUR: $_m"
done

if ! macos_vm_exists "$MACOS_BASE_VM"; then
    fail "base VM '${MACOS_BASE_VM}' exists" "build it first: augur build --macos ..."; exit
fi
if macos_vm_running "$MACOS_BASE_VM"; then
    fail "base VM '${MACOS_BASE_VM}' is stopped" "stop it first: augur-vm stop ${MACOS_BASE_VM}"; exit
fi
if on "$DO_HOOK" && provision_files_present; then
    if ( unset AUGUR_ACCEPT_PROVISION_HOOK; check_provision_approved ) </dev/null >/dev/null 2>&1; then
        ok "your own ~/.augur/provision/ is approved (the final clean update needs no prompt)"
    else
        fail "your own ~/.augur/provision/ is approved" "run 'augur update --macos' once and approve it, then re-run; this script never approves it"
        exit
    fi
fi

# ── --update ───────────────────────────────────────────────────────────────────────────────────
if on "$DO_UPDATE"; then
    section "augur update --macos (installs and re-checks the policy)"
    run_update user
    if (( UP_RC == 0 )); then ok "augur update --macos completes"
    else fail "augur update --macos completes" "exit ${UP_RC}: $(guest_tail "$UP_OUT" 8)"; exit; fi
    has "$UP_OUT" "$MSG_INSTALL" "…it installed the managed policy"
    has "$UP_OUT" "$MSG_CHECK" "…and re-checked it before saving"
fi

# ── --hook: provisioning hooks beside the policy ───────────────────────────────────────────────
HOOK_RAN=0
if on "$DO_HOOK"; then
    section "Provisioning hooks and the policy directory (slow: three updates)"
    if provision_backup; then
        ok "moved ~/.augur/provision/ aside (backup: ${BK})"
        HOOK_RAN=1
        q_marker="$(printf '%q' "$PDIR/$MARKER")"; q_dst="$(printf '%q' "$DST")"

        write_hook "printf 'augur-e2e\\n' > ${q_marker}"
        run_update hook-adds AUGUR_ACCEPT_PROVISION_HOOK=1
        if (( UP_RC == 0 )); then ok "an update whose hook adds ${MARKER} beside the policy succeeds"
        else fail "an update whose hook adds ${MARKER} beside the policy succeeds" "exit ${UP_RC}: $(guest_tail "$UP_OUT" 8)"; fi
        has "$UP_OUT" "$MSG_HOOK_RAN" "…the test hook ran"
        has "$UP_OUT" "$MSG_CHECK" "…and the policy was re-checked after it"

        write_hook "printf '{}\\n' > ${q_dst}"
        run_update hook-overwrites AUGUR_ACCEPT_PROVISION_HOOK=1
        if (( UP_RC != 0 )); then ok "an update whose hook overwrites ${PNAME} fails"
        else fail "an update whose hook overwrites ${PNAME} fails" "exit 0: the base VM was saved"; fi
        has "$UP_OUT" "$MSG_MISMATCH" "…naming the policy mismatch"
        has "$UP_OUT" "$MSG_HOOK_RULE" "…and the rule for provisioning"
        if macos_vm_exists "$MACOS_UPDATE_VM"; then fail "…and the staging VM '${MACOS_UPDATE_VM}' is discarded"
        else ok "…and the staging VM '${MACOS_UPDATE_VM}' is discarded"; fi

        section "The base VM after the failed update"
        if probe_up; then
            gout="$(gssh "cat $(printf '%q' "$PDIR/$MARKER") 2>/dev/null" 2>&1)"
            eq "augur-e2e" "$gout" "the base still holds the hook's ${MARKER} (the first update was saved with it)"
            if verify_macos_managed_settings "$PROBE"; then ok "…and still holds augur's own policy (the failed update saved nothing)"
            else fail "…and still holds augur's own policy (the failed update saved nothing)"; fi
        fi
        probe_delete || fail "delete the throwaway clone"
    else
        fail "move ~/.augur/provision/ aside"
    fi
    if provision_restore; then ok "put your own ~/.augur/provision/ and its approval record back"
    else fail "put your own ~/.augur/provision/ back" "run: AUGUR_TEST_LIVE=1 bash ${ME} --restore"; exit; fi

    if on "$HOOK_RAN"; then
        section "A clean update with your own provisioning"
        run_update clean
        if (( UP_RC == 0 )); then ok "augur update --macos completes with your own provisioning"
        else fail "augur update --macos completes with your own provisioning" "exit ${UP_RC}; re-run 'augur update --macos' to leave the base VM clean: $(guest_tail "$UP_OUT" 8)"; fi
        dline="$(grep -F "$MSG_DISCARDED" <<<"$UP_OUT")"
        has "$dline" "$MARKER" "…and discarded the test hook's ${MARKER} with the old policy directory"
    fi
fi

# ── Stages 1-3 on a throwaway clone of the base VM ─────────────────────────────────────────────
section "A throwaway clone of the base VM"
probe_up || exit

# ── 1. The stock parent directory ──────────────────────────────────────────────────────────────
section "1. ${PBASE} passes augur's parent check"
lsout="$(gssh "/bin/ls -lde $(printf '%q' "$PBASE"); /bin/ls -lden $(printf '%q' "$PBASE")" 2>&1)"
while IFS= read -r _l; do echo "  recorded: ${_l}"; done <<<"$lsout"
[[ -n "$lsout" ]] && ok "recorded ls -lde / ls -lden of ${PBASE}" || fail "ls -lde ${PBASE} answers"
PARENT_LINE="$(macos_managed_settings_swap_sh | grep -E '^ls_ok "\$base" ')"
if [[ -n "$PARENT_LINE" && "$PARENT_LINE" != *$'\n'* ]]; then
    ok "found the install script's parent check (one line)"
    script="$(macos_managed_settings_vars_sh)"$'\n'"$(macos_policy_checks_sh)"
    script+=$'\nfail() { echo "$1" >&2; echo AUGUR_E2E_PARENT_REFUSED; exit 1; }\n'"${PARENT_LINE}"$'\necho AUGUR_E2E_PARENT_OK'
    rs "$script"
    if (( RS_RC == 0 )) && [[ "$(last_line "$RS_OUT")" == AUGUR_E2E_PARENT_OK ]]; then
        ok "the stock ${PBASE} passes it, as root on the real /bin/sh"
    else
        fail "the stock ${PBASE} passes it" "exit ${RS_RC}, last line [$(last_line "$RS_OUT")]: $(guest_tail "$RS_ERR")"
    fi
else
    fail "found the install script's parent check" "no single 'ls_ok \"\$base\" …' line in macos_managed_settings_swap_sh"
fi

# ── 2. The policy the base VM holds ────────────────────────────────────────────────────────────
section "2. The base VM's policy, as installed"
qd="$(printf '%q' "$PDIR")"; qf="$(printf '%q' "$DST")"
pout="$(gssh "D=${qd}; F=${qf}"'
printf "dirstat=%s\n" "$(/usr/bin/stat -f "%Su:%Sg %Lp %HT" "$D")"
printf "dirlink=%s\n" "$( [ -L "$D" ] && echo yes || echo no )"
printf "dirls=%s\n" "$(/bin/ls -lde "$D" | /usr/bin/wc -l | /usr/bin/tr -d " ")"
printf "filestat=%s\n" "$(/usr/bin/stat -f "%Su:%Sg %Lp %l %HT" "$F")"
printf "filels=%s\n" "$(/bin/ls -lde "$F" | /usr/bin/wc -l | /usr/bin/tr -d " ")"
printf "filemode=%s\n" "$(/bin/ls -ld "$F" | /usr/bin/cut -c1-11 | /usr/bin/tr -d " ")"
printf "sha=%s\n" "$(/usr/bin/shasum -a 256 < "$F" | /usr/bin/cut -c1-64)"
printf "entries=%s\n" "$(/bin/ls -A "$D" | /usr/bin/tr "\n" " ")"
printf "staged=%s\n" "$( [ -e ~/.augur-managed-settings.json ] && echo yes || echo no )"' 2>&1)"
val() { sed -n "s/^$1=//p" <<<"$pout"; }
eq "root:wheel 755 Directory" "$(val dirstat)" "${PDIR} is a root:wheel 755 directory"
eq "no" "$(val dirlink)" "…not a symlink"
eq "1" "$(val dirls)" "…with no ACL (ls -lde prints one line)"
eq "root:wheel 644 1 Regular File" "$(val filestat)" "${PNAME} is a root:wheel 644 regular file with one link"
eq "1" "$(val filels)" "…with no ACL (ls -lde prints one line)"
eq "-rw-r--r--" "$(val filemode)" "…mode string without + or @"
eq "$POLICY_SHA" "$(val sha)" "…byte-identical to agent_managed_settings_json on the host (SHA-256), readable by the guest user"
echo "  recorded: ${PDIR} holds: $(val entries)"
if on "$HOOK_RAN"; then hasnt "$(val entries)" "$MARKER" "…and no longer the test hook's ${MARKER}"; fi
eq "no" "$(val staged)" "no ~/.augur-managed-settings.json is staged in the guest user's home"
rs '/bin/ls -A /var/root | /usr/bin/grep -c "^\.augur-"; /bin/ls -A '"$(printf '%q' "$PBASE")"' | /usr/bin/grep -c "^\.augur-policy\."; true'
eq "0"$'\n'"0" "$RS_OUT" "no /var/root/.augur-* quarantine and no ${PBASE}/.augur-policy.* left"
if verify_macos_managed_settings "$PROBE"; then ok "the real verify_macos_managed_settings passes"
else fail "the real verify_macos_managed_settings passes"; fi

# ── 3. BSD tools as root, and the install script in a sandbox ──────────────────────────────────
section "3. macOS tools as the root script uses them (as root, through macos_run_root_script)"
TRICKY=""; for _i in 1 2 3 4 5 6; do TRICKY+="q\"'\$x\\ \`y\` %s ${_i}"$'\t\001'; done; TRICKY+=$'\n\n'
TRICKY_B64="$(printf '%s' "$TRICKY" | base64 | tr -d '\n')"
TRICKY_SHA="$(printf '%s' "$TRICKY" | shasum -a 256 | cut -c1-64)"
script="$(macos_managed_settings_vars_sh)"$'\n'"$(macos_policy_checks_sh)"$'\n'"S='${SANDBOX}'; tb64='${TRICKY_B64}'"
script+=$'\n'"$(cat <<'SCRIPT'
r() { if [ "$2" = 0 ]; then echo "T ok $1"; else echo "T bad $1"; fi; }
no() { if [ "$2" = 0 ]; then echo "T bad $1"; else echo "T ok $1"; fi; }
line2() { printf '%s\n' "$1" | /usr/bin/sed -n 2p; }
nlines() { printf '%s\n' "$1" | /usr/bin/wc -l | /usr/bin/tr -d ' '; }
/bin/rm -rf "$S"; /bin/mkdir -m 755 "$S"; r "a sandbox directory under /var/root" $?
echo "R /bin/sh: BASH_VERSION=${BASH_VERSION:-unset}"
q="$(/usr/bin/mktemp -d /var/root/.augur-quarantine.XXXXXX)"
[ -n "$q" ] && [ -d "$q" ] && [ ! -L "$q" ]; r "mktemp -d /var/root/.augur-quarantine.XXXXXX makes a directory" $?
/bin/chmod 700 "$q" && /bin/chmod -N "$q"; r "chmod 700 and chmod -N on it" $?
/bin/rm -rf "$q"; [ ! -e "$q" ]; r "rm -rf removes it" $?

f="$S/acl-deny"; : > "$f"
/bin/chmod +a "group:everyone deny delete" "$f"; r "chmod +a adds a deny entry" $?
out="$(/bin/ls -lden "$f")"; echo "R ls -lden, deny entry: $(printf '%s' "$out" | /usr/bin/tr '\n' '|')"
[ "$(nlines "$out")" = 2 ]; r "ls -lden prints the entry on a line of its own" $?
line2 "$out" | /usr/bin/grep -Eq '^ 0: [^ ]+ deny delete$'; r "the ACL line reads ' 0: <who> deny delete'" $?
m="$(/bin/ls -ldn "$f")"; m="${m%% *}"; [ "${m%+}" != "$m" ]; r "the mode string ends in + with an ACL" $?
deny_only "$out"; r "deny_only accepts a deny-delete ACL" $?
no "ls_ok refuses a file with an ACL when deny entries are not allowed" "$(ls_ok "$f" -f '0:*' '-rw-r--r--' >/dev/null 2>&1; echo $?)"
f2="$S/acl-allow"; : > "$f2"; /bin/chmod +a "group:staff allow write" "$f2"
no "deny_only refuses an allow entry" "$(deny_only "$(/bin/ls -lden "$f2")"; echo $?)"
f3="$S/acl-denyread"; : > "$f3"; /bin/chmod +a "group:everyone deny read" "$f3"
no "deny_only refuses a deny entry that denies reading" "$(deny_only "$(/bin/ls -lden "$f3")"; echo $?)"
d="$S/inherit"; /bin/mkdir -m 755 "$d"
/bin/chmod +a "group:everyone deny delete,file_inherit,directory_inherit" "$d"; r "chmod +a adds an inheritable deny entry" $?
c="$(/usr/bin/mktemp -d "$d/.augur-policy.XXXXXX")"
out="$(/bin/ls -lden "$c")"; echo "R ls -lden, inherited entry: $(printf '%s' "$out" | /usr/bin/tr '\n' '|')"
line2 "$out" | /usr/bin/grep -Eq '^ 0: [^ ]+ inherited deny '; r "mktemp -d inherits it, shown as ' 0: <who> inherited deny …'" $?
deny_only "$out"; r "deny_only accepts the inherited deny entry" $?
/bin/chmod -N "$c"; r "chmod -N runs" $?
[ "$(nlines "$(/bin/ls -lden "$c")")" = 1 ]; r "chmod -N strips the inherited ACL (ls -lden prints one line)" $?
ls_ok "$c" -d '0:*' 'drwx------'; r "ls_ok accepts the stripped directory" $?

/bin/mkdir "$S/tgt" && : > "$S/tgt/keep" && /bin/ln -s "$S/tgt" "$S/lnk" && /bin/mkdir "$S/q"
/bin/mv "$S/lnk" "$S/q/old"; r "mv of a symlink to a directory runs" $?
[ -L "$S/q/old" ] && [ "$(/usr/bin/readlink "$S/q/old")" = "$S/tgt" ]; r "…and moves the link itself" $?
[ ! -e "$S/lnk" ] && [ ! -L "$S/lnk" ] && [ -f "$S/tgt/keep" ] && [ ! -e "$S/tgt/old" ]; r "…leaving the target and its contents where they were" $?
/bin/rm -rf "$S/q"; [ -f "$S/tgt/keep" ]; r "rm -rf of the moved link leaves the target's contents" $?

printf 'abc' > "$S/c"
printf 'abc' | /usr/bin/cmp -s - "$S/c"; r "cmp -s - reads stdin and matches equal bytes" $?
no "cmp -s - fails on different bytes" "$(printf 'abd' | /usr/bin/cmp -s - "$S/c"; echo $?)"
no "cmp -s - fails on a prefix" "$(printf 'ab' | /usr/bin/cmp -s - "$S/c"; echo $?)"
echo "R tricky=$(printf '%s' "$tb64" | /usr/bin/base64 --decode | /usr/bin/shasum -a 256 | /usr/bin/cut -c1-64)"
echo "R enc=$(printf 'a\nb' | /usr/bin/base64 | /usr/bin/tr -d '\n')"
printf '%s' "$b64" | /usr/bin/base64 --decode > "$S/policy"; r "base64 --decode decodes the policy payload" $?
/bin/rm -rf "$S"
echo T-END
SCRIPT
)"
rs "$script"
n_t=0; tricky=""; enc=""
while IFS= read -r _l; do
    case "$_l" in
        "T ok "*)  ok "${_l#T ok }"; n_t=$((n_t + 1)) ;;
        "T bad "*) fail "${_l#T bad }"; n_t=$((n_t + 1)) ;;
        "R tricky="*) tricky="${_l#R tricky=}" ;;
        "R enc="*) enc="${_l#R enc=}" ;;
        "R "*) echo "  recorded: ${_l#R }" ;;
    esac
done <<<"$RS_OUT"
if (( RS_RC == 0 )) && [[ "$(last_line "$RS_OUT")" == T-END ]]; then ok "the tool checks ran to the end (${n_t} checks)"
else fail "the tool checks ran to the end" "exit ${RS_RC} after ${n_t} checks: $(guest_tail "$RS_ERR")"; fi
eq "$TRICKY_SHA" "$tricky" "base64 --decode restores quotes, \$, backslashes, control bytes and trailing newlines exactly (SHA-256)"
eq "YQpi" "$enc" "base64 encodes on one line, as the discarded-name report expects"

section "3b. The real install script on a sandbox directory (not the clone's policy)"
SB="${SANDBOX}/lib"
sb_vars="$(macos_managed_settings_vars_sh)"$'\n'"base='${SB}'; dir='${SB}/ClaudeCode'"
SWAP="${sb_vars}"$'\n'"$(macos_policy_checks_sh)"$'\n'"$(macos_managed_settings_swap_sh)"
CHECK="${sb_vars}"$'\n'"$(macos_policy_checks_sh)"$'\n'"$(macos_managed_settings_check_sh)"
# setup SHELL-LINES: a fresh sandbox base (root:wheel 755) with the lines run in it.
setup() { rs "S='${SANDBOX}'; B='${SB}'; /bin/rm -rf \"\$S\" && /bin/mkdir -m 755 \"\$S\" \"\$B\" && cd \"\$B\" && { $1
}"; (( RS_RC == 0 )) || fail "set up the sandbox" "$(guest_tail "$RS_ERR")"; }
swap_live() {
    rs "$SWAP"
    if (( RS_RC == 0 )) && [[ "$(last_line "$RS_OUT")" == AUGUR_POLICY_LIVE ]]; then ok "$1: the swap reports AUGUR_POLICY_LIVE"
    else fail "$1: the swap reports AUGUR_POLICY_LIVE" "exit ${RS_RC}, last line [$(last_line "$RS_OUT")]: $(guest_tail "$RS_ERR")"; fi
    SWAP_OUT="$RS_OUT"
    rs "$CHECK"
    if (( RS_RC == 0 )) && [[ "$(last_line "$RS_OUT")" == AUGUR_POLICY_OK ]]; then ok "$1: the check script then reports AUGUR_POLICY_OK"
    else fail "$1: the check script then reports AUGUR_POLICY_OK" "exit ${RS_RC}: $(guest_tail "$RS_ERR")"; fi
}
probe_sb() { rs "S='${SANDBOX}'; B='${SB}'; $1"; printf '%s' "$RS_OUT"; }
discarded() {
    local _l _out=""
    while IFS= read -r _l; do
        [[ "$_l" == "AUGUR_POLICY_DISCARDED "* ]] || continue
        _out+="$(printf '%s' "${_l#AUGUR_POLICY_DISCARDED }" | base64 --decode)|"
    done <<<"$1"
    printf '%s' "$_out" | tr '|' '\n' | LC_ALL=C sort | tr '\n' '|'
}

setup "/bin/mkdir -m 777 ClaudeCode && echo old > ClaudeCode/${PNAME} && : > 'ClaudeCode/junk file' && : > ClaudeCode/.hidden && /bin/ln -s /etc/hosts ClaudeCode/lnk"
swap_live "an old 777 directory with entries"
eq ".hidden|junk file|lnk|" "$(discarded "$SWAP_OUT")" "…the discarded names are reported (base64 on the wire)"
eq "yes" "$(probe_sb '[ -f /etc/hosts ] && [ ! -L "$B/ClaudeCode" ] && echo yes')" "…/etc/hosts (a discarded link's target) is untouched"
eq "0" "$(probe_sb '/bin/ls -A /var/root | /usr/bin/grep -c "^\.augur-quarantine"; true')" "…and the quarantine is removed"

setup "/bin/mkdir -m 755 elsewhere && : > elsewhere/keep && /bin/ln -s \"\$B/elsewhere\" ClaudeCode"
swap_live "a symlink to a directory at the policy directory's path"
eq "yes" "$(probe_sb '[ -f "$B/elsewhere/keep" ] && [ -d "$B/ClaudeCode" ] && [ ! -L "$B/ClaudeCode" ] && echo yes')" "…the link's target keeps its contents and the new directory is real"

setup "/bin/chmod +a 'group:everyone deny delete,file_inherit,directory_inherit' \"\$B\""
swap_live "a base with an inheritable deny-only ACL (the fresh directory inherits it until chmod -N)"

setup "/bin/mkdir -m 755 ClaudeCode && echo old > ClaudeCode/${PNAME} && /bin/chmod +a 'group:staff allow add_subdirectory' \"\$B\""
rs "$SWAP"
if (( RS_RC != 0 )) && [[ "$(last_line "$RS_OUT")" != AUGUR_POLICY_LIVE ]]; then ok "a base with an allow ACL entry is refused"
else fail "a base with an allow ACL entry is refused" "exit ${RS_RC}"; fi
eq "old|0" "$(probe_sb 'cat "$B/ClaudeCode/'"${PNAME}"'"; /bin/ls -A "$B" | /usr/bin/grep -c "^\.augur-policy"; true' | tr '\n' '|')" "…leaving the old directory as it was and no fresh one"

setup "/bin/chmod +a 'group:everyone deny list' \"\$B\""
rs "$SWAP"
if (( RS_RC != 0 )); then ok "a base whose ACL denies listing is refused"; else fail "a base whose ACL denies listing is refused" "exit 0"; fi

setup "/bin/chmod 775 \"\$B\""
rs "$SWAP"
if (( RS_RC != 0 )); then ok "a group-writable base is refused"; else fail "a group-writable base is refused" "exit 0"; fi

rs "/bin/rm -rf '${SANDBOX}'; /bin/ls -A /var/root | /usr/bin/grep -c '^\.augur-quarantine'; true"
eq "0" "$RS_OUT" "the sandbox is removed and no quarantine is left in /var/root"

# e2e_restore (the EXIT trap) deletes the throwaway clone and prints the summary.
