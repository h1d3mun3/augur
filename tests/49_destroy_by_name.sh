#!/usr/bin/env bash
# Tier 1 (offline) — `augur destroy <name>` / `augur destroy --macos <name>`. No runtime needed.
# A name shown by `augur list` must be removable from ANY directory, with the same per-project
# cleanup `destroy` does for the current directory. That works because every piece of per-project
# host state is keyed on the slug + path hash embedded in the name, so the name is parsed back
# into those two. Drives the real cmd_destroy via a shimmed `container`, and the real
# adopt_target_name / macos_project_vm by sourcing augur.
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/lib.sh"
section "Tier 1 — augur destroy <name> (shimmed container, no runtime)"

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
export HOME="$work/home";        mkdir -p "$HOME"
other="$work/elsewhere";         mkdir -p "$other"
export AUGUR_TEST_SHIMLOG="$work/shim"
export PATH="$HERE/shims:$PATH"
AUGUR="$REPO/augur"

# A name for a project that is NOT the current directory. The slug deliberately contains
# "-swift-" and hyphens, to prove the parse anchors on the hash rather than the first match.
slug="my-swift-app"; hash="0123456789ab"
cname="augur-${slug}-${hash}-swift-6-0"

mkdir -p "$HOME/.augur/container-state" "$HOME/.augur/claude-carryover/${slug}-${hash}"
touch "$HOME/.augur/container-state/${cname}.fingerprint"
touch "$HOME/.augur/claude-carryover/${slug}-${hash}/history.jsonl"

# ── Scenario 1: destroy <name> from an unrelated directory ─────────────────────
rm -f "$AUGUR_TEST_SHIMLOG.trace"
export AUGUR_TEST_CONTAINER_RUNNING=1
( cd "$other" && bash "$AUGUR" destroy "$cname" ) >/dev/null 2>&1; rc=$?
trace="$(cat "$AUGUR_TEST_SHIMLOG.trace" 2>/dev/null)"
eq  "0" "$rc"                                              "destroy <name>: exits 0"
has "$trace" "delete --force ${cname}"                     "destroy <name>: force-removes THAT container, not this directory's"
has "$trace" "network delete augur-${slug}-${hash}-net"    "destroy <name>: deletes the named project's egress network"
[[ ! -e "$HOME/.augur/container-state/${cname}.fingerprint" ]] \
  && ok "destroy <name>: drops the named container's reconcile fingerprint" \
  || fail "destroy <name>: fingerprint still present"
[[ ! -e "$HOME/.augur/claude-carryover/${slug}-${hash}" ]] \
  && ok "destroy <name>: drops the named project's carried-over history" \
  || fail "destroy <name>: carry-over history still present"
other_slug="$(basename "$other")"
hasnt "$trace" "augur-${other_slug}-" "destroy <name>: never touches a name derived from the current directory"

# ── Scenario 2: a name outside augur's naming scheme is refused ────────────────
for bad in "postgres" "augur-nohash-swift-latest" "augur-app-ZZZZZZZZZZZZ-swift-latest" "augur-macos-app-0123456789ab"; do
  rm -f "$AUGUR_TEST_SHIMLOG.trace"
  out="$( cd "$other" && bash "$AUGUR" destroy "$bad" 2>&1 )"; rc=$?
  trace="$(cat "$AUGUR_TEST_SHIMLOG.trace" 2>/dev/null)"
  eq    "1" "$rc"                    "destroy '$bad': refused with exit 1"
  has   "$out" "not an augur-managed" "destroy '$bad': says why"
  hasnt "$trace" "delete"            "destroy '$bad': removes nothing"
done

# ── Scenario 3: too many arguments ─────────────────────────────────────────────
rm -f "$AUGUR_TEST_SHIMLOG.trace"
( cd "$other" && bash "$AUGUR" destroy "$cname" extra ) >/dev/null 2>&1; rc=$?
eq "1" "$rc" "destroy <name> <extra>: refused with exit 1"
hasnt "$(cat "$AUGUR_TEST_SHIMLOG.trace" 2>/dev/null)" "delete" "destroy <name> <extra>: removes nothing"

# ── Scenario 4: a name that no longer exists → notice, exit 0, state still cleaned ──
rm -f "$AUGUR_TEST_SHIMLOG.trace"
export AUGUR_TEST_CONTAINER_RUNNING=0
out="$( cd "$other" && bash "$AUGUR" destroy "$cname" 2>&1 )"; rc=$?
eq  "0" "$rc"                    "destroy <name> (absent): exits 0"
has "$out" "No container found"  "destroy <name> (absent): reports it"
hasnt "$(cat "$AUGUR_TEST_SHIMLOG.trace" 2>/dev/null)" "delete --force" "destroy <name> (absent): nothing to force-remove"

# ── Scenario 5: no argument still means "this directory" ───────────────────────
rm -f "$AUGUR_TEST_SHIMLOG.trace"
export AUGUR_TEST_CONTAINER_RUNNING=1
( cd "$other" && bash "$AUGUR" destroy ) >/dev/null 2>&1; rc=$?
trace="$(cat "$AUGUR_TEST_SHIMLOG.trace" 2>/dev/null)"
eq  "0" "$rc"                                   "destroy (no name): still exits 0"
has "$trace" "delete --force augur-${other_slug}-" "destroy (no name): still targets the current directory"

# ── macOS VM names: parse + round trip, via the real functions ─────────────────
section "Tier 1 — adopt_target_name / macos_project_vm round trip"
AUGUR_SOURCE_ONLY=1 source "$AUGUR"
set +e                                    # augur enables `set -e`; restore lib.sh assert-and-continue

vm="augur-macos-${slug}-${hash}"
adopt_target_name macos "$vm" >/dev/null 2>&1
eq "$slug" "$TARGET_SLUG" "macOS name: slug parsed (hyphens and '-swift-' kept)"
eq "$hash" "$TARGET_HASH" "macOS name: hash parsed"
MACOS_MODE=true
eq "$vm" "$(macos_project_vm)" "macOS name: macos_project_vm round-trips to the same VM name"
eq "${slug}-${hash}-macos.pid" "$(basename "$(proxy_pidfile)")" "macOS name: proxy pidfile keyed on the parsed slug+hash"

TARGET_SLUG=""; TARGET_HASH=""
adopt_target_name container "$cname" >/dev/null 2>&1
eq "$slug"  "$TARGET_SLUG"    "container name: slug parsed"
eq "$hash"  "$TARGET_HASH"    "container name: hash parsed"
eq "$cname" "$CONTAINER_NAME" "container name: CONTAINER_NAME set to the given name"
eq "augur-${slug}-${hash}-net" "$(egress_network_name)" "container name: egress network recomputed from the parsed slug+hash"

TARGET_SLUG=""; TARGET_HASH=""
adopt_target_name macos "augur-${slug}-${hash}-swift-latest" >/dev/null 2>&1; rc=$?
eq "1" "$rc" "a container name is not accepted as a macOS VM name"

finish
