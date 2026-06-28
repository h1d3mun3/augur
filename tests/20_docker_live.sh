#!/usr/bin/env bash
# Tier 1 (live) — real Docker. Confirms the built image actually runs the agent and
# that `augur up` wires a working container end-to-end. Auto-skips when Docker is
# absent. The container-mutating part (up/down) is opt-in via AUGUR_TEST_LIVE=1 so a
# plain `tests/run.sh` never creates/removes containers behind your back.
#
#   tests/20_docker_live.sh                 # read-only: `docker run --rm <img> claude --version`
#   AUGUR_TEST_LIVE=1 tests/20_docker_live.sh   # full: augur up → exec → down (temp project)
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/lib.sh"
section "Tier 1 — live Docker smoke"

if ! command -v docker >/dev/null 2>&1; then skip "all Docker live checks" "docker not installed"; finish; exit $?; fi
if ! docker info >/dev/null 2>&1;        then skip "all Docker live checks" "docker daemon not running"; finish; exit $?; fi

# Find the built augur image (tag varies with the configured Swift version).
img="$(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -m1 '^augur:swift-' || true)"
if [[ -z "$img" ]]; then
  skip "image checks" "no augur:swift-* image — run 'augur build' first"
else
  # Read-only: the agent binary is installed and runs (no augur state, container auto-removed).
  ver="$(docker run --rm "$img" sh -lc 'claude --version' 2>/dev/null || true)"
  if [[ -n "$ver" ]]; then ok "image '$img' runs the agent ($(printf '%s' "$ver" | tr -d '\n'))"
  else fail "image '$img' could not run 'claude --version'"; fi
fi

if [[ "${AUGUR_TEST_LIVE:-0}" != 1 ]]; then
  skip "augur up/exec/down" "set AUGUR_TEST_LIVE=1 to run the container-mutating smoke"
  finish; exit $?
fi
if [[ -z "$img" ]]; then finish; exit $?; fi

# Full lifecycle in a throwaway project (egress off to avoid the proxy sidecar).
proj="$(mktemp -d)"
slug="$(basename "$proj" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]' '-' | sed 's/^-//;s/-$//')"
cleanup() { ( cd "$proj" && bash "$REPO/augur" down --no-egress ) >/dev/null 2>&1; rm -rf "$proj"; }
trap cleanup EXIT

if ( cd "$proj" && bash "$REPO/augur" up --no-egress ) >/dev/null 2>&1; then
  ok "augur up brought a container online"
  cont="$(docker ps --format '{{.Names}}' | grep -m1 "^augur-${slug}-" || true)"
  if [[ -n "$cont" ]]; then
    cver="$(docker exec "$cont" sh -lc 'claude --version' 2>/dev/null || true)"
    if [[ -n "$cver" ]]; then ok "agent runs inside the live container ($cont)"; else fail "agent did not run inside '$cont'"; fi
  else
    fail "no running container named augur-${slug}-* after up"
  fi
else
  fail "augur up failed"
fi

finish
