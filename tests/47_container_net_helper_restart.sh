#!/usr/bin/env bash
# Tier 1 — container mode restarts the project's network helper right before its container attaches
# (runs anywhere; launchctl is a shim, nothing real is restarted).
#
# Apple Container fixes a network's bridge unit at its first attachment and keeps it after the
# bridge goes down; `down` keeps our network, so a later attachment can take over another project's
# live bridge and cut that project off. restart_egress_network_helper prevents it by restarting the
# helper before the attach. These checks pin the two properties that make that safe:
#   1. it runs on BOTH attach paths (fresh create and stopped→start), BEFORE the attach, and never
#      on an already-running container (a restart would drop that container's own attachment) or
#      with egress off (the default network is shared with other containers);
#   2. it is best-effort: a missing service, a failed kickstart, or no launchctl warn and return 0.
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/lib.sh"
AUGUR="$REPO/augur"

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT
export PATH="$HERE/shims:$PATH"
export AUGUR_TEST_SHIMLOG="$TMPD/shim"
LCLOG="$AUGUR_TEST_SHIMLOG.launchctl"

AUGUR_SOURCE_ONLY=1 source "$AUGUR"
set +e                                    # augur enables `set -e`; restore lib.sh assert-and-continue
AUGUR_PROXY_DIR="$TMPD/proxy"; mkdir -p "$AUGUR_PROXY_DIR"
SWIFT_IMAGE_TAG="${SWIFT_VERSION:-latest}"
IMAGE_NAME="augur:swift-${SWIFT_IMAGE_TAG}"
CONTAINER_NAME="$(make_container_name)"
WORKSPACE_MOUNT="$(make_workspace_mount)"

LABEL="com.apple.container.container-network-vmnet.$(egress_network_name)"
UID_="$(id -u)"


# ── 1. restart_egress_network_helper on its own ──────────────────────────────
section "restart_egress_network_helper: restarts the gui-domain service and waits for it"
: > "$LCLOG"
out="$(AUGUR_TEST_LAUNCHCTL=running restart_egress_network_helper 2>&1)"; rc=$?
eq 0 "$rc" "returns 0"
grep -qx "kickstart -k gui/$UID_/$LABEL" "$LCLOG" && ok "kickstart -k on gui/<uid>/<label>" \
    || fail "kickstart -k on gui/<uid>/<label>" "$(cat "$LCLOG")"
eq "" "$out" "silent when the restart succeeds"

section "restart_egress_network_helper: falls back to the user domain (non-desktop session)"
: > "$LCLOG"
out="$(AUGUR_TEST_LAUNCHCTL=user restart_egress_network_helper 2>&1)"; rc=$?
eq 0 "$rc" "returns 0"
grep -qx "kickstart -k user/$UID_/$LABEL" "$LCLOG" && ok "kickstart -k on user/<uid>/<label>" \
    || fail "kickstart -k on user/<uid>/<label>" "$(cat "$LCLOG")"
eq "" "$out" "silent when the restart succeeds"

section "restart_egress_network_helper: skips when a restart is pointless or harmful"
no_kickstart() {   # $1 = name
    if grep -q '^kickstart' "$LCLOG"; then fail "$1" "$(cat "$LCLOG")"; else ok "$1"; fi
}
: > "$LCLOG"
out="$(EGRESS_NETWORK_CREATED=true AUGUR_TEST_LAUNCHCTL=running restart_egress_network_helper 2>&1)"
no_kickstart "network created by this run → no kickstart"
eq "" "$out" "network created by this run → silent"

: > "$LCLOG"
out="$(AUGUR_TEST_CONTAINER_RUNNING=1 AUGUR_TEST_CONTAINER_NAME="$CONTAINER_NAME" \
       AUGUR_TEST_LAUNCHCTL=running restart_egress_network_helper 2>&1)"
no_kickstart "container already running (another augur run started it) → no kickstart"

: > "$LCLOG"
out="$(AUGUR_EGRESS=0 AUGUR_TEST_LAUNCHCTL=running restart_egress_network_helper 2>&1)"
no_kickstart "egress off → no kickstart"

section "restart_egress_network_helper: best-effort on every failure"
: > "$LCLOG"
out="$(AUGUR_TEST_LAUNCHCTL=absent restart_egress_network_helper 2>&1)"; rc=$?
eq 0 "$rc" "service absent → returns 0"
has "$out" "Network helper '${LABEL}' not found" "service absent → warns"
hasnt "$out" "container system stop" "service absent → never suggests stopping every container"
no_kickstart "service absent → no kickstart"

out="$(AUGUR_TEST_LAUNCHCTL=kickfail restart_egress_network_helper 2>&1)"; rc=$?
eq 0 "$rc" "kickstart fails → returns 0"
has "$out" "Could not restart network helper" "kickstart fails → warns"

out="$(PATH=/nonexistent; restart_egress_network_helper 2>&1)"; rc=$?
eq 0 "$rc" "no launchctl → returns 0"
eq "" "$out" "no launchctl → silent"

# ── 2. where cmd_up calls it ─────────────────────────────────────────────────
# Recorders, installed after the source so they win at call time. Every step that matters for the
# ordering appends one line to $LOG. The REAL restart_egress_network_helper runs, so its own guards
# (egress off, freshly created network, running container) are part of what is checked; only
# launchctl is replaced, and a kickstart is recorded as "restart_helper".
LOG="$TMPD/calls"
require_engine() { :; }
require_engine_version() { :; }
require_fresh_egress_helpers() { :; }
ensure_image() { :; }
check_project_conf_approved() { :; }
NET_NEW=false
ensure_egress_network() { echo "ensure_network" >> "$LOG"; if $NET_NEW; then EGRESS_NETWORK_CREATED=true; fi; }
launchctl() {
    case "$1" in
        print)     [[ "$2" == gui/* ]] || return 113; echo "state = running" ;;
        kickstart) echo "restart_helper" >> "$LOG" ;;
    esac
}
sleep() { :; }
START_FAILS=0
eng() {
    echo "eng $1" >> "$LOG"
    if [[ "$1" == start && $START_FAILS -gt 0 ]]; then START_FAILS=$((START_FAILS - 1)); return 1; fi
    return 0
}
engine_rm_force() { :; }
finish_up() { echo "finish_up" >> "$LOG"; }
reconcile_running_container() { echo "reconcile" >> "$LOG"; }
_add_state_mount_run_args() { :; }
_add_host_config_run_args() { :; }
write_container_fingerprint() { :; }
restore_guest_history() { :; }
resolve_container_memory() { echo 4g; }
calls() { tr '\n' ' ' < "$LOG" | sed 's/ $//'; }
run_up() { : > "$LOG"; EGRESS_NETWORK_CREATED=false; cmd_up >/dev/null 2>&1; }

egress_enabled() { return 0; }
container_running() { return 1; }
container_fingerprint_matches() { return 0; }

section "cmd_up: stopped container (reuse) restarts the helper before 'container start'"
container_exists() { return 0; }
run_up
eq "ensure_network restart_helper eng start finish_up" "$(calls)" "network → helper restart → start → finish_up"

section "cmd_up: a transiently failing 'container start' is retried, not recreated"
# A recreate throws away the writable layer, so a start that fails only while the just-restarted
# helper comes up must be retried instead (start_stopped_container).
START_FAILS=2
run_up
eq "ensure_network restart_helper eng start eng start eng start finish_up" "$(calls)" \
    "two failed starts, third succeeds → no 'container run'"

START_FAILS=99
run_up
eq "ensure_network restart_helper eng start eng start eng start ensure_network restart_helper eng run finish_up" \
    "$(calls)" "start keeps failing → recreate after three attempts"
START_FAILS=0

section "cmd_up: fresh create restarts the helper right before 'container run'"
container_exists() { return 1; }
run_up
eq "ensure_network restart_helper eng run finish_up" "$(calls)" "network → helper restart → run → finish_up"

NET_NEW=true
run_up
eq "ensure_network eng run finish_up" "$(calls)" "network created by this run → no helper restart"
NET_NEW=false

section "cmd_up: running container never restarts the helper"
container_running() { return 0; }
run_up
eq "reconcile" "$(calls)" "only the reconcile path runs"

section "cmd_up: egress off never restarts a helper"
egress_enabled() { return 1; }
container_running() { return 1; }
container_exists() { return 1; }
run_up
eq "eng run finish_up" "$(calls)" "no network, no helper restart"

finish
