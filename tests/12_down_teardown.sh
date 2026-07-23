#!/usr/bin/env bash
# Tier 1 (offline) — `augur down` / `augur destroy` TEARDOWN via a `container` shim. No runtime
# needed. Drives the REAL cmd_down / cmd_destroy paths with a shimmed `container` on PATH and
# toggles whether this directory's container "exists" (AUGUR_TEST_CONTAINER_RUNNING → shim's
# `inspect` exit). Apple Container mode now PERSISTS the container across down/up, so:
#   • `down`    STOPS the container (keeps it) and does NOT delete it or its egress network.
#   • `destroy` force-removes the container ('container delete --force') AND its network.
# Both print the "no container" notice when absent and exit 0 either way (stop_egress/stop_proxy
# are safe no-ops here: no proxy pidfile, and the shim's `network delete` just succeeds).
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/lib.sh"
section "Tier 1 — augur down/destroy teardown (shimmed container, no runtime)"

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
export HOME="$work/home";        mkdir -p "$HOME"
proj="$work/proj";               mkdir -p "$proj"
export AUGUR_TEST_SHIMLOG="$work/shim"
export PATH="$HERE/shims:$PATH"
AUGUR="$REPO/augur"

# ── Scenario 1: down + container present → STOPPED (kept), network NOT deleted ──
rm -f "$AUGUR_TEST_SHIMLOG.trace"
export AUGUR_TEST_CONTAINER_RUNNING=1
( cd "$proj" && bash "$AUGUR" down ) >/dev/null 2>&1; rc=$?
trace="$(cat "$AUGUR_TEST_SHIMLOG.trace" 2>/dev/null)"
has   "$trace" "container stop"     "down: stops the container when it exists"
hasnt "$trace" "delete --force"     "down: does NOT force-remove the container (persistence)"
hasnt "$trace" "network delete"     "down: keeps the egress network for the next up"
eq    "0" "$rc"                     "down: exits 0 after stopping the container"

# ── Scenario 2: down + container absent → nothing removed, notice, still exit 0 ─
rm -f "$AUGUR_TEST_SHIMLOG.trace"
export AUGUR_TEST_CONTAINER_RUNNING=0
out="$( cd "$proj" && bash "$AUGUR" down 2>&1 )"; rc=$?
trace="$(cat "$AUGUR_TEST_SHIMLOG.trace" 2>/dev/null)"
hasnt "$trace" "container stop"     "down: nothing to stop when no container exists"
hasnt "$trace" "delete --force"     "down: does not force-remove when no container exists"
has   "$out"   "No container found" "down: reports no container for this directory"
eq    "0" "$rc"                     "down: exits 0 even when nothing to stop"

# ── Scenario 3: destroy + container present → force-removed AND network deleted ─
rm -f "$AUGUR_TEST_SHIMLOG.trace"
export AUGUR_TEST_CONTAINER_RUNNING=1
( cd "$proj" && bash "$AUGUR" destroy ) >/dev/null 2>&1; rc=$?
trace="$(cat "$AUGUR_TEST_SHIMLOG.trace" 2>/dev/null)"
has "$trace" "delete --force"       "destroy: force-removes the container when it exists"
has "$trace" "network delete"       "destroy: tears down the egress network too"
eq  "0" "$rc"                       "destroy: exits 0 after removing the container"

# ── Scenario 4: destroy + container absent → notice, still exit 0 ──────────────
rm -f "$AUGUR_TEST_SHIMLOG.trace"
export AUGUR_TEST_CONTAINER_RUNNING=0
out="$( cd "$proj" && bash "$AUGUR" destroy 2>&1 )"; rc=$?
trace="$(cat "$AUGUR_TEST_SHIMLOG.trace" 2>/dev/null)"
hasnt "$trace" "delete --force"     "destroy: does not force-remove when no container exists"
has   "$out"   "No container found" "destroy: reports no container for this directory"
eq    "0" "$rc"                     "destroy: exits 0 even when nothing to remove"

finish
