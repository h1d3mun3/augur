#!/usr/bin/env bash
# Tier 1 (offline) — Docker command CONSTRUCTION via a `docker` shim. No daemon needed.
# Drives the REAL augur code paths (cmd_up / cmd_claude) with egress off and a shimmed
# docker on PATH, then asserts the constructed `docker run` / `docker exec` argv carries
# exactly what the agent seam declares: auth env (named-only), the cwd-keyed history
# mount, the fixed env, and the launch argv. This is the doc's "byte-identical argv"
# check (docs/swappable-agent-abstraction-design.md §5 DoD) without a live container.
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/lib.sh"
section "Tier 1 — Docker run/exec construction (shimmed docker, no daemon)"

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
export HOME="$work/home";        mkdir -p "$HOME"
proj="$work/myproj";             mkdir -p "$proj"
export AUGUR_TEST_SHIMLOG="$work/shim"
export PATH="$HERE/shims:$PATH"
export ANTHROPIC_API_KEY="sk-ant-test123"
unset CLAUDE_CODE_OAUTH_TOKEN || true
AUGUR="$REPO/augur"                       # invoked via `bash` (no reliance on +x / shebang)
slug="myproj"

# ── augur up: capture the constructed `docker run` ───────────────────────────
export AUGUR_TEST_CONTAINER_RUNNING=0
( cd "$proj" && bash "$AUGUR" up --no-egress ) >/dev/null 2>&1 || true
run="$AUGUR_TEST_SHIMLOG.run"
if [[ -f "$run" ]]; then
  body="$(cat "$run")"
  # container name = the value right after `--name` (swift tag varies by config)
  cname="$(awk 'p{print;exit} $0=="--name"{p=1}' "$run")"
  has "$body" "-dit"                                            "up: detached interactive tty (-dit)"
  has "$cname" "augur-${slug}-swift-"                           "up: container name derived from slug"
  has "$body" "ANTHROPIC_API_KEY=sk-ant-test123"               "up: injects ANTHROPIC_API_KEY (auth seam)"
  hasnt "$body" "CLAUDE_CODE_OAUTH_TOKEN"                       "up: omits the unset oauth token (named-only auth)"
  has "$body" "claude-projects/${slug}-"                        "up: host history under claude-projects/<slug>-… (state seam)"
  has "$body" ":/home/dev/.claude/projects/-workspace-${slug}"  "up: guest leaf -workspace-<slug> (state seam)"
  if grep -Eq "claude-projects/${slug}-[0-9a-f]{12}:" "$run"; then ok "up: history host dir keyed on full-path hash (A3/C7)"
  else fail "up: history host dir not keyed on path hash"; fi
else
  cname="augur-${slug}"
  fail "up: no docker run captured" "trace: $(cat "$AUGUR_TEST_SHIMLOG.trace" 2>/dev/null)"
fi

# ── augur claude: capture the constructed `docker exec ... claude` ───────────
# Report the real container (discovered above) as running so ensure_running passes.
export AUGUR_TEST_CONTAINER_RUNNING=1
export AUGUR_TEST_CONTAINER_NAME="$cname"
( cd "$proj" && bash "$AUGUR" claude ) >/dev/null 2>&1 || true
ex="$AUGUR_TEST_SHIMLOG.exec"
if [[ -f "$ex" ]]; then
  body="$(cat "$ex")"
  has "$body" "DISABLE_AUTOUPDATER=1"  "claude: fixed env DISABLE_AUTOUPDATER=1 (fixed-env seam)"
  has "$body" "$cname"                 "claude: targets this project's container"
  eq  "claude" "$(tail -n1 "$ex")"     "claude: launch argv is exactly 'claude' (launch seam, last token)"
else
  fail "claude: no docker exec captured" "trace: $(cat "$AUGUR_TEST_SHIMLOG.trace" 2>/dev/null)"
fi

finish
