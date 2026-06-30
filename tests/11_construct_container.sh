#!/usr/bin/env bash
# Tier 1 (offline) — Apple `container` command CONSTRUCTION via a `container` shim. No
# runtime needed. Same contract as 10_construct_docker.sh, but forces the Apple Container
# engine (AUGUR_ENGINE=container) and asserts the constructed `container run` / `container
# exec` argv carries exactly what the agent seam declares. Proves the engine abstraction
# builds byte-identical agent argv regardless of backend (docs §5 DoD).
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/lib.sh"
section "Tier 1 — Apple container run/exec construction (shimmed container, no runtime)"

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
export HOME="$work/home";        mkdir -p "$HOME"
proj="$work/myproj";             mkdir -p "$proj"
export AUGUR_TEST_SHIMLOG="$work/shim"
export PATH="$HERE/shims:$PATH"
export AUGUR_ENGINE="container"           # force the Apple Container backend (even on Linux)
export ANTHROPIC_API_KEY="sk-ant-test123"
unset CLAUDE_CODE_OAUTH_TOKEN || true
AUGUR="$REPO/augur"
slug="myproj"

# ── augur up: capture the constructed `container run` ────────────────────────
export AUGUR_TEST_CONTAINER_RUNNING=0
( cd "$proj" && bash "$AUGUR" up --no-egress ) >/dev/null 2>&1 || true
run="$AUGUR_TEST_SHIMLOG.run"
if [[ -f "$run" ]]; then
  body="$(cat "$run")"
  cname="$(awk 'p{print;exit} $0=="--name"{p=1}' "$run")"
  eq  "run" "$(head -n1 "$run")"                               "up: invokes the engine 'run' subcommand"
  grep -qxF -- '-d' "$run" && ok "up: detached (-d, no keep-alive TTY)" || fail "up: not detached (-d missing)"
  has "$cname" "augur-${slug}-swift-"                           "up: container name derived from slug"
  has "$body" "ANTHROPIC_API_KEY=sk-ant-test123"               "up: injects ANTHROPIC_API_KEY (auth seam)"
  hasnt "$body" "CLAUDE_CODE_OAUTH_TOKEN"                       "up: omits the unset oauth token (named-only auth)"
  has "$body" "claude-projects/${slug}-"                        "up: host history under claude-projects/<slug>-… (state seam)"
  has "$body" ":/home/dev/.claude/projects/-workspace-${slug}"  "up: guest leaf -workspace-<slug> (state seam)"
  if grep -Eq "claude-projects/${slug}-[0-9a-f]{12}:" "$run"; then ok "up: history host dir keyed on full-path hash (A3/C7)"
  else fail "up: history host dir not keyed on path hash"; fi
else
  cname="augur-${slug}"
  fail "up: no container run captured" "trace: $(cat "$AUGUR_TEST_SHIMLOG.trace" 2>/dev/null)"
fi

# ── augur claude: capture the constructed `container exec ... claude` ────────
export AUGUR_TEST_CONTAINER_RUNNING=1
export AUGUR_TEST_CONTAINER_NAME="$cname"
( cd "$proj" && bash "$AUGUR" claude ) >/dev/null 2>&1 || true
ex="$AUGUR_TEST_SHIMLOG.exec"
if [[ -f "$ex" ]]; then
  body="$(cat "$ex")"
  eq  "exec" "$(head -n1 "$ex")"        "claude: invokes the engine 'exec' subcommand"
  has "$body" "DISABLE_AUTOUPDATER=1"   "claude: fixed env DISABLE_AUTOUPDATER=1 (fixed-env seam)"
  has "$body" "$cname"                  "claude: targets this project's container"
  eq  "claude" "$(tail -n1 "$ex")"      "claude: launch argv is exactly 'claude' (launch seam, last token)"
else
  fail "claude: no container exec captured" "trace: $(cat "$AUGUR_TEST_SHIMLOG.trace" 2>/dev/null)"
fi

finish
