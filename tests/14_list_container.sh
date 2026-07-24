#!/usr/bin/env bash
# Tier 1 (offline) — `augur list` (container mode) via a shimmed `container`. No runtime needed.
# Drives the REAL cmd_list path: shells `container list --all`, filters rows to the `augur-`
# prefix make_container_name mints, and colors running vs stopped. Asserts that augur-owned
# containers show (with STATE + ADDR), an unrelated container is filtered out, and the
# empty-of-augur case prints the guidance message (even when other containers exist on the host).
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/lib.sh"
section "Tier 1 — augur list (container mode): augur- filter + state (shimmed container)"

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
export HOME="$work/home"; mkdir -p "$HOME"
proj="$work/myproj";      mkdir -p "$proj"
export AUGUR_TEST_SHIMLOG="$work/shim"
export PATH="$HERE/shims:$PATH"
AUGUR="$REPO/augur"

# ── augur + non-augur containers present ────────────────────────────────────────────
out="$( cd "$proj" && bash "$AUGUR" list 2>&1 )"; rc=$?
eq   "0" "$rc"                                       "list: exits 0"
has  "$out" "NAME"                                   "list: prints a header row"
has  "$out" "augur-alpha-0011aabbccdd-swift-latest"  "list: shows a running augur container"
has  "$out" "augur-beta-eeff22334455-swift-6-0"      "list: shows a stopped augur container"
hasnt "$out" "nginx-sidecar"                         "list: filters out non-augur containers"

# STATE and ADDR are bound to the RIGHT row IN THE RIGHT ORDER (state, then addr). cmd_list maps
# columns by HEADER LABEL precisely so STATE and ADDR can't silently swap; a swap would reorder
# these on the line, so an order-bound grep — not a position-agnostic substring — is what actually
# guards it. `.*` absorbs the interleaved ANSI color codes between the two fields.
if grep -Eq 'augur-alpha-0011aabbccdd-swift-latest.*running.*192\.168\.64\.3' <<<"$out"; then
  ok "list: alpha binds running-state before its ADDR (no STATE/ADDR mismap)"
else
  fail "list: alpha STATE/ADDR mismapped or out of order" "$(grep alpha <<<"$out")"
fi
has "$out" "stopped"                                 "list: reports the stopped state"

# Coloring is the headline feature (GREEN running / YELLOW stopped). Colors are emitted
# unconditionally, so the escapes survive command-substitution capture — assert them directly so
# an always-yellow / color-dropped regression can't pass.
green=$'\033[0;32m'; yellow=$'\033[1;33m'
has "$out" "${green}running"                         "list: running state painted green"
has "$out" "${yellow}stopped"                        "list: stopped state painted yellow"

# A stopped container has a BLANK trailing ADDR in real Apple output; cmd_list must degrade that
# to "-". The shim's beta row emits exactly that blank field, so this exercises the fallback.
if grep 'augur-beta-eeff22334455-swift-6-0' <<<"$out" | grep -Eq -- '-[[:space:]]*$'; then
  ok "list: stopped container's blank ADDR degrades to '-'"
else
  fail "list: blank ADDR not degraded to '-'" "$(grep beta <<<"$out")"
fi

# ── no augur containers, but the host still has others ───────────────────────────────
outE="$( cd "$proj" && AUGUR_TEST_LIST_EMPTY=1 bash "$AUGUR" list 2>&1 )"; rcE=$?
eq   "0" "$rcE"                                      "list(empty): exits 0"
has  "$outE" "No augur containers found."            "list(empty): guidance shown when no augur containers"
hasnt "$outE" "nginx-sidecar"                        "list(empty): unrelated containers never leak through"

finish
