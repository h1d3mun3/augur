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
# WORKSPACE_DIR="$(pwd)" inside the `cd "$proj"` subshells, so this matches augur's workspace_path_hash.
phash="$(printf '%s' "$proj" | { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi; } | cut -c1-12)"
augur_dir="${AUGUR_DIR:-$HOME/.augur}"
# destroy (not down): down now only STOPS the container (persistence), so the test must fully
# remove it on exit. Also remove the per-project HOST state dirs this test created under ~/.augur
# (history + agents) — destroy deliberately does NOT touch them, so clean them up here.
cleanup() {
  ( cd "$proj" && bash "$REPO/augur" destroy --no-egress ) >/dev/null 2>&1
  rm -rf "$proj" "$augur_dir/claude-projects/${slug}-${phash}" "$augur_dir/claude-agents/${slug}-${phash}"
}
trap cleanup EXIT

if ( cd "$proj" && bash "$REPO/augur" up --no-egress ) >/dev/null 2>&1; then
  ok "augur up brought a container online"
  # Container name embeds the workspace path hash (cross-project isolation): augur-<slug>-<hash>-swift-<tag>.
  cont="augur-${slug}-${phash}-swift-$(printf '%s' "${SWIFT_VERSION:-latest}" | tr '.' '-')"
  cver="$(container exec "$cont" sh -lc 'claude --version' 2>/dev/null || true)"
  if [[ -n "$cver" ]]; then ok "agent runs inside the live container ($cont)"; else fail "agent did not run inside '$cont'"; fi

  # ── Persistence: `down` keeps the container; `up` reuses it and the writable layer survives ──
  # Write a marker OUTSIDE the bind-mounted workspace (in the container's own writable layer),
  # then down (stop) + up (reuse) and confirm it's still there — proof the container was not
  # recreated. A rebuild-on-up would start from the image and lose the marker.
  # /home/dev is owned by the exec user (dev, uid 1001) and is NOT a bind mount (only
  # /workspace-<slug>, ~/.claude/projects/<slug>, ~/.gitconfig, ~/.config/gh are), so a marker here
  # lives in the container's persistent writable layer. /root would fail (dev cannot write it).
  marker="/home/dev/augur-persist-marker-$$"
  container exec "$cont" sh -lc "echo alive > '$marker'" 2>/dev/null || true
  ( cd "$proj" && bash "$REPO/augur" down --no-egress ) >/dev/null 2>&1
  if container inspect "$cont" >/dev/null 2>&1; then ok "down keeps the container (not deleted)"; else fail "down removed the container (expected stop/keep)"; fi
  ( cd "$proj" && bash "$REPO/augur" up --no-egress ) >/dev/null 2>&1
  survived="$(container exec "$cont" sh -lc "cat '$marker' 2>/dev/null" 2>/dev/null || true)"
  if [[ "$survived" == "alive" ]]; then ok "up reused the container — writable-layer state survived down/up"; else fail "up did not reuse the container (marker lost)"; fi

  # ── Agent-config persistence: user-level /agents survive DESTROY+up (host-mounted, #113) ──
  # Write a user-level subagent def into ~/.claude/agents (the newly bind-mounted host dir), then
  # DESTROY (removes the container + its writable layer) and up (a fresh container). Unlike the
  # writable-layer marker above, this MUST survive: ~/.claude/agents is a host mount that `destroy`
  # never touches — exactly the reported gap (augur up → /agents → destroy → up used to lose it).
  agentdef="/home/dev/.claude/agents/augur-test-agent.md"
  container exec "$cont" sh -lc "mkdir -p ~/.claude/agents && printf '%s\n' '---' 'name: augur-test-agent' '---' 'probe' > '$agentdef'" >/dev/null 2>&1 || true
  ( cd "$proj" && bash "$REPO/augur" destroy --no-egress ) >/dev/null 2>&1
  ( cd "$proj" && bash "$REPO/augur" up --no-egress ) >/dev/null 2>&1
  if container exec "$cont" sh -lc "grep -q augur-test-agent '$agentdef'" >/dev/null 2>&1; then
    ok "user-level subagent def survived destroy+up (~/.claude/agents is host-persisted)"
  else
    fail "subagent def lost across destroy+up" "~/.claude/agents did not persist (expected host mount)"
  fi

  # ── destroy removes it ──
  ( cd "$proj" && bash "$REPO/augur" destroy --no-egress ) >/dev/null 2>&1
  if container inspect "$cont" >/dev/null 2>&1; then fail "destroy left the container behind"; else ok "destroy removed the container"; fi
else
  fail "augur up failed"
fi

finish
