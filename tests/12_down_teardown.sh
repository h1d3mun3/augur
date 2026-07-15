#!/usr/bin/env bash
# Tier 1 (offline) — `augur down` TEARDOWN via a `container` shim. No runtime needed. Drives
# the REAL cmd_down path with a shimmed `container` on PATH and toggles whether this
# directory's container "exists" (AUGUR_TEST_CONTAINER_RUNNING → shim's `inspect` exit). It
# asserts down force-removes the container when present ('container delete --force'), does NOT
# when absent, prints the "no container" notice, and exits 0 either way (stop_egress is a safe
# no-op here: no proxy pidfile, and the shim's `network delete` just succeeds).
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/lib.sh"
section "Tier 1 — augur down teardown (shimmed container, no runtime)"

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
export HOME="$work/home";        mkdir -p "$HOME"
proj="$work/proj";               mkdir -p "$proj"
export AUGUR_TEST_SHIMLOG="$work/shim"
export PATH="$HERE/shims:$PATH"
AUGUR="$REPO/augur"

# ── Scenario 1: container present → force-removed ───────────────────────────
rm -f "$AUGUR_TEST_SHIMLOG.trace"
export AUGUR_TEST_CONTAINER_RUNNING=1
( cd "$proj" && bash "$AUGUR" down ) >/dev/null 2>&1; rc=$?
trace="$(cat "$AUGUR_TEST_SHIMLOG.trace" 2>/dev/null)"
has "$trace" "delete --force"     "down: force-removes the container when it exists"
eq  "0" "$rc"                      "down: exits 0 after removing the container"

# ── Scenario 2: container absent → nothing removed, notice, still exit 0 ─────
rm -f "$AUGUR_TEST_SHIMLOG.trace"
export AUGUR_TEST_CONTAINER_RUNNING=0
out="$( cd "$proj" && bash "$AUGUR" down 2>&1 )"; rc=$?
trace="$(cat "$AUGUR_TEST_SHIMLOG.trace" 2>/dev/null)"
hasnt "$trace" "delete --force"   "down: does not force-remove when no container exists"
has   "$out"   "No container found" "down: reports no container for this directory"
eq    "0" "$rc"                    "down: exits 0 even when nothing to remove"

finish
