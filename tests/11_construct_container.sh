#!/usr/bin/env bash
# Tier 1 (offline) — Apple `container` command CONSTRUCTION via a `container` shim. No
# runtime needed. Drives the REAL augur code paths (cmd_up / cmd_claude) with egress off and
# a shimmed `container` on PATH, then asserts the constructed `container run` / `container
# exec` argv carries exactly what the agent seam declares: auth env (named-only), the
# cwd-keyed history mount, the fixed env, and the launch argv. This is the doc's
# "byte-identical argv" check (docs/decisions/0003-swappable-agent-abstraction.md §5 DoD) without a
# live container.
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/lib.sh"
section "Tier 1 — Apple container run/exec construction (shimmed container, no runtime)"

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
export HOME="$work/home";        mkdir -p "$HOME"
proj="$work/myproj";             mkdir -p "$proj"
export AUGUR_TEST_SHIMLOG="$work/shim"
export PATH="$HERE/shims:$PATH"
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
  if grep -Eq ":/home/dev/\.claude/projects$" "$run"; then ok "up: mounts the whole projects parent, not one leaf (Option A)"
  else fail "up: does not mount the projects parent exactly" "expected a line ending exactly in :/home/dev/.claude/projects"; fi
  hasnt "$body" ":/home/dev/.claude/projects/-workspace-${slug}" "up: no leftover leaf-scoped mount target"
  if grep -Eq "claude-projects/${slug}-[0-9a-f]{12}:" "$run"; then ok "up: history host dir keyed on full-path hash (A3/C7)"
  else fail "up: history host dir not keyed on path hash"; fi
else
  cname="augur-${slug}"
  fail "up: no container run captured" "trace: $(cat "$AUGUR_TEST_SHIMLOG.trace" 2>/dev/null)"
fi

# ── augur up (again): pre-Option-A flat layout migrates into the new leaf subdir ──
host_hist_dir="$(find "$HOME/.augur/claude-projects" -maxdepth 1 -type d -name "${slug}-*" 2>/dev/null | head -1)"
leaf_dir="$host_hist_dir/-workspace-${slug}"
if [[ -n "$host_hist_dir" && -d "$leaf_dir" ]]; then
  ok "up: fresh project already gets the nested leaf dir (${leaf_dir#"$HOME"/})"
  rmdir "$leaf_dir" 2>/dev/null || true
  echo '{"fake":"pre-option-a session"}' > "$host_hist_dir/legacy-session.jsonl"
  ( cd "$proj" && bash "$AUGUR" up --no-egress ) >/dev/null 2>&1 || true
  if [[ -f "$leaf_dir/legacy-session.jsonl" ]]; then ok "up: pre-existing flat history migrated into the leaf subdir"
  else fail "up: legacy-session.jsonl not migrated into $leaf_dir"; fi
  if [[ -f "$host_hist_dir/legacy-session.jsonl" ]]; then fail "up: legacy-session.jsonl left behind at the old flat path"
  else ok "up: nothing left behind at the old flat path"; fi
else
  fail "up: could not locate host_hist_dir to test migration" "looked under $HOME/.augur/claude-projects/${slug}-*"
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
