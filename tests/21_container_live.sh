#!/usr/bin/env bash
# Tier 1 (live) — real Apple Container. Confirms the built image runs the agent and that
# `augur up` wires a working container end-to-end on the Apple backend. Auto-skips unless
# the `container` CLI is present and its service is up (so it's a no-op on Linux/CI and on
# macOS < 26). The container-mutating part is opt-in via AUGUR_TEST_LIVE=1.
#
#   tests/21_container_live.sh                      # read-only: image runs `claude --version`
#   AUGUR_TEST_LIVE=1 tests/21_container_live.sh    # full: augur up → exec → down (temp project)
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/lib.sh"
section "Tier 1 — live Apple Container smoke"

if ! command -v container >/dev/null 2>&1;   then skip "all Apple Container live checks" "container CLI not installed"; finish; exit $?; fi
if ! container system status >/dev/null 2>&1; then skip "all Apple Container live checks" "container service not running"; finish; exit $?; fi

# The image augur builds (tag varies with the configured Swift version) — same name as
# augur's IMAGE_NAME. Check it via `container image inspect` (the canonical existence check
# augur itself uses); don't parse `container image list`, whose plain output splits name/tag.
img="augur:swift-${SWIFT_VERSION:-latest}"
if ! container image inspect "$img" >/dev/null 2>&1; then
  skip "image checks" "no ${img} image — run 'augur build' first"
else
  ver="$(container run --rm "$img" sh -lc 'claude --version' 2>/dev/null || true)"
  if [[ -n "$ver" ]]; then ok "image '$img' runs the agent ($(printf '%s' "$ver" | tr -d '\n'))"
  else fail "image '$img' could not run 'claude --version'"; fi
fi

if [[ "${AUGUR_TEST_LIVE:-0}" != 1 ]]; then
  skip "augur up/exec/down" "set AUGUR_TEST_LIVE=1 to run the container-mutating smoke"
  finish; exit $?
fi
if [[ -z "$img" ]]; then finish; exit $?; fi

# Full lifecycle in a throwaway project (egress off to avoid the host proxy datapath).
proj="$(mktemp -d)"
slug="$(basename "$proj" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]' '-' | sed 's/^-//;s/-$//')"
cleanup() { ( cd "$proj" && bash "$REPO/augur" down --no-egress ) >/dev/null 2>&1; rm -rf "$proj"; }
trap cleanup EXIT

if ( cd "$proj" && bash "$REPO/augur" up --no-egress ) >/dev/null 2>&1; then
  ok "augur up brought a container online"
  cont="augur-${slug}-swift-$(printf '%s' "${SWIFT_VERSION:-latest}" | tr '.' '-')"
  cver="$(container exec "$cont" sh -lc 'claude --version' 2>/dev/null || true)"
  if [[ -n "$cver" ]]; then ok "agent runs inside the live container ($cont)"; else fail "agent did not run inside '$cont'"; fi
else
  fail "augur up failed"
fi

finish
