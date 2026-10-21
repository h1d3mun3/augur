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
hasnt "$out" "skipping" "no warning when the restart succeeds"

section "restart_egress_network_helper: falls back to the user domain (non-desktop session)"
: > "$LCLOG"
out="$(AUGUR_TEST_LAUNCHCTL=user restart_egress_network_helper 2>&1)"; rc=$?
eq 0 "$rc" "returns 0"
grep -qx "kickstart -k user/$UID_/$LABEL" "$LCLOG" && ok "kickstart -k on user/<uid>/<label>" \
    || fail "kickstart -k on user/<uid>/<label>" "$(cat "$LCLOG")"

section "restart_egress_network_helper: best-effort on every failure"
: > "$LCLOG"
out="$(AUGUR_TEST_LAUNCHCTL=absent restart_egress_network_helper 2>&1)"; rc=$?
eq 0 "$rc" "service absent → returns 0"
has "$out" "not found; skipping its restart" "service absent → warns"
grep -q '^kickstart' "$LCLOG" && fail "service absent → no kickstart" "$(cat "$LCLOG")" \
    || ok "service absent → no kickstart"

out="$(AUGUR_TEST_LAUNCHCTL=kickfail restart_egress_network_helper 2>&1)"; rc=$?
eq 0 "$rc" "kickstart fails → returns 0"
has "$out" "Could not restart network helper" "kickstart fails → warns"

out="$(PATH=/nonexistent; restart_egress_network_helper 2>&1)"; rc=$?
eq 0 "$rc" "no launchctl → returns 0"
eq "" "$out" "no launchctl → silent"

# ── 2. where cmd_up calls it ─────────────────────────────────────────────────
# Recorders, installed after the source so they win at call time. Every step that matters for the
# ordering appends one line to $LOG.
LOG="$TMPD/calls"
require_engine() { :; }
require_engine_version() { :; }
require_fresh_egress_helpers() { :; }
ensure_image() { :; }
check_project_conf_approved() { :; }
ensure_egress_network() { echo "ensure_network" >> "$LOG"; }
restart_egress_network_helper() { echo "restart_helper" >> "$LOG"; }
eng() { echo "eng $1" >> "$LOG"; return 0; }
engine_rm_force() { :; }
finish_up() { echo "finish_up" >> "$LOG"; }
reconcile_running_container() { echo "reconcile" >> "$LOG"; }
_add_state_mount_run_args() { :; }
_add_host_config_run_args() { :; }
write_container_fingerprint() { :; }
restore_guest_history() { :; }
resolve_container_memory() { echo 4g; }
calls() { tr '\n' ' ' < "$LOG" | sed 's/ $//'; }

section "cmd_up: stopped container (reuse) restarts the helper before 'container start'"
: > "$LOG"
egress_enabled() { return 0; }
container_running() { return 1; }
container_exists() { return 0; }
container_fingerprint_matches() { return 0; }
cmd_up >/dev/null 2>&1
eq "ensure_network restart_helper eng start finish_up" "$(calls)" "network → helper restart → start → finish_up"

section "cmd_up: fresh create restarts the helper before 'container run'"
: > "$LOG"
container_exists() { return 1; }
cmd_up >/dev/null 2>&1
eq "ensure_network restart_helper eng run finish_up" "$(calls)" "network → helper restart → run → finish_up"

section "cmd_up: running container never restarts the helper"
: > "$LOG"
container_running() { return 0; }
cmd_up >/dev/null 2>&1
eq "reconcile" "$(calls)" "only the reconcile path runs"

section "cmd_up: egress off never restarts a helper"
: > "$LOG"
egress_enabled() { return 1; }
container_running() { return 1; }
container_exists() { return 1; }
cmd_up >/dev/null 2>&1
eq "eng run finish_up" "$(calls)" "no network, no helper restart"

finish
