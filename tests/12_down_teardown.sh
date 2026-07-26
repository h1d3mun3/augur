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

# The egress network name gained the workspace path hash (two same-basename projects used to share
# ONE network, so project B's `up` silently attached to project A's). `destroy` must delete BOTH
# names: the current one, and the pre-hash `augur-<slug>-net` an older augur may have created for
# this same directory. Nothing looks the legacy name up any more, so if teardown misses it the
# network — and its subnet — is stranded for good.
# Both names are recomputed here INDEPENDENTLY of augur (same recipe as workspace_slug /
# workspace_path_hash, sha256sum-first like the real helper) on purpose: asking augur for them
# would make the two assertions collapse into one if a future change reverted the keying — both
# helpers would return the same string and a single `network delete` line would satisfy both.
# $proj is the LOGICAL path `cd "$proj" && pwd` yields, which is exactly what augur hashes.
slug="$(basename "$proj" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]' '-' | sed 's/^-//;s/-$//')"
if command -v sha256sum >/dev/null 2>&1; then hash="$(printf '%s' "$proj" | sha256sum | cut -c1-12)"
else                                          hash="$(printf '%s' "$proj" | shasum -a 256 | cut -c1-12)"; fi
has "$trace" "network delete augur-${slug}-${hash}-net" "destroy: deletes the path-keyed egress network"
has "$trace" "network delete augur-${slug}-net"         "destroy: also deletes the legacy pre-hash network name"
if [[ -n "$hash" ]]; then ok "the two network names are distinct (the hash is non-empty)"
else fail "workspace_path_hash recipe produced nothing" "the two assertions above would be the same check"; fi

# ── Scenario 4: destroy + container absent → notice, still exit 0 ──────────────
rm -f "$AUGUR_TEST_SHIMLOG.trace"
export AUGUR_TEST_CONTAINER_RUNNING=0
out="$( cd "$proj" && bash "$AUGUR" destroy 2>&1 )"; rc=$?
trace="$(cat "$AUGUR_TEST_SHIMLOG.trace" 2>/dev/null)"
hasnt "$trace" "delete --force"     "destroy: does not force-remove when no container exists"
has   "$out"   "No container found" "destroy: reports no container for this directory"
eq    "0" "$rc"                     "destroy: exits 0 even when nothing to remove"

# ── Scenario 5: the CLEANUP path stays ungated in $HOME ────────────────────────
# `up`/`claude`/`shell`/`setup-token` refuse a workspace containing augur's own control plane
# (docs/decisions/0014-workspace-must-not-contain-augur.md), but `down`/`destroy` must NOT —
# a pre-fix augur could already have created a container from $HOME, and gating the teardown
# would strand it with no supported way to remove it. This is the assertion that stops a
# future refactor from "consistently" applying the guard across the whole dispatch.
rm -f "$AUGUR_TEST_SHIMLOG.trace"
export AUGUR_TEST_CONTAINER_RUNNING=1
( cd "$HOME" && bash "$AUGUR" destroy ) >/dev/null 2>&1; rc=$?
trace="$(cat "$AUGUR_TEST_SHIMLOG.trace" 2>/dev/null)"
eq  "0" "$rc"                  "destroy: exits 0 from \$HOME (the containment guard must not gate cleanup)"
has "$trace" "delete --force"  "destroy: still reaches 'delete --force' from \$HOME"
has "$trace" "network delete"  "destroy: still tears down the egress network from \$HOME"

rm -f "$AUGUR_TEST_SHIMLOG.trace"
( cd "$HOME" && bash "$AUGUR" down ) >/dev/null 2>&1; rc=$?
trace="$(cat "$AUGUR_TEST_SHIMLOG.trace" 2>/dev/null)"
eq  "0" "$rc"                 "down: exits 0 from \$HOME (ungated too)"
has "$trace" "container stop" "down: still reaches 'container stop' from \$HOME"

# The read-only informational commands are ungated for the same reason: they hand nothing to a
# guest, and `list`/`status` are how an operator FINDS the stranded container to destroy.
for c in list status; do
  ( cd "$HOME" && bash "$AUGUR" "$c" ) >/dev/null 2>&1
  eq "0" "$?" "$c: exits 0 from \$HOME (read-only, hands nothing to a guest)"
done

finish
