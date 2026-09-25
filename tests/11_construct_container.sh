#!/usr/bin/env bash
# Tier 1 (offline) — Apple `container` command CONSTRUCTION via a `container` shim. No
# runtime needed. Drives the REAL augur code paths (cmd_up / cmd_claude) with egress off and
# a shimmed `container` on PATH, then asserts the constructed `container run` / `container
# exec` argv carries exactly what the agent seam declares: the cwd-keyed history mount, the fixed
# env, the launch argv — and credentials (named-only) ONLY on the session exec's --env-file, never
# on any argv and never on `container run`. This is the "verify the constructed argv is
# byte-identical" check the agent-seam design calls for, without a live container.
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
# The gh shim prints this for `gh auth token`, so the GH_TOKEN / git-credential-helper path runs.
export AUGUR_TEST_GH_TOKEN="gho_testGhToken456"
envf="$AUGUR_TEST_SHIMLOG.envfile"
AUGUR="$REPO/augur"
slug="myproj"

# ── augur up: capture the constructed `container run` ────────────────────────
export AUGUR_TEST_CONTAINER_RUNNING=0
# HOME here has no ~/.gitconfig — a regression guard for the pipefail/set -e class where
# write_container_fingerprint returning non-zero would abort cmd_up before finish_up (skipping the
# boot self-test). up MUST exit 0 here.
( cd "$proj" && bash "$AUGUR" up --no-egress ) >/dev/null 2>&1; up_rc=$?
eq "0" "$up_rc" "up: exits 0 on a host without ~/.gitconfig (fingerprint write must not abort cmd_up)"
run="$AUGUR_TEST_SHIMLOG.run"
if [[ -f "$run" ]]; then
  body="$(cat "$run")"
  cname="$(awk 'p{print;exit} $0=="--name"{p=1}' "$run")"
  eq  "run" "$(head -n1 "$run")"                               "up: invokes the engine 'run' subcommand"
  grep -qxF -- '-d' "$run" && ok "up: detached (-d, no keep-alive TTY)" || fail "up: not detached (-d missing)"
  has "$body" 'trap "exit 0" TERM'                             "up: keep-alive PID 1 traps SIGTERM (fast down, not bare sleep infinity)"
  has "$cname" "augur-${slug}-"                                 "up: container name derived from slug"
  if grep -Eq "^augur-${slug}-[0-9a-f]{12}-swift-" <<<"$cname"; then ok "up: container name keyed on full-path hash (cross-project isolation)"
  else fail "up: container name not keyed on path hash" "got: $cname"; fi
  # Secrets-zero on `container run`: Apple Container persists the run config (env included) in
  # the container bundle and `container inspect` prints it, so nothing credential-shaped or
  # per-session may be baked here — neither names nor values.
  hasnt "$body" "ANTHROPIC_API_KEY"                             "up: run argv carries no ANTHROPIC_API_KEY"
  hasnt "$body" "sk-ant-test123"                                "up: run argv carries no API key value"
  hasnt "$body" "CLAUDE_CODE_OAUTH_TOKEN"                       "up: run argv carries no CLAUDE_CODE_OAUTH_TOKEN"
  hasnt "$body" "GH_TOKEN"                                      "up: run argv carries no GH_TOKEN (gh shim has a token)"
  hasnt "$body" "gho_testGhToken456"                            "up: run argv carries no gh token value"
  hasnt "$body" "GIT_CONFIG_"                                   "up: run argv carries no GIT_CONFIG_* helper"
  if grep -q '^TZ=' "$run"; then fail "up: run argv bakes TZ" "TZ is per session only"
  else ok "up: run argv bakes no TZ (per session only)"; fi
  hasnt "$body" "--env-file"                                    "up: run argv carries no --env-file"
  [[ ! -s "$envf" ]] && ok "up: no env-file content was handed to the engine" \
                     || fail "up: an env-file reached the engine during up" "$(cat "$envf")"
  has "$body" "claude-projects/${slug}-"                        "up: host history under claude-projects/<slug>-… (state seam)"
  if grep -Eq ":/home/dev/\.claude/projects$" "$run"; then ok "up: mounts the whole projects parent, not one leaf (Option A)"
  else fail "up: does not mount the projects parent exactly" "expected a line ending exactly in :/home/dev/.claude/projects"; fi
  hasnt "$body" ":/home/dev/.claude/projects/-workspace-${slug}" "up: no leftover leaf-scoped mount target"
  # The host's gh config is not handed to the guest: gh there authenticates only via the
  # per-session GH_TOKEN, and a mounted hosts.yml would show a dead Keychain-backed account or,
  # after `gh auth login --insecure-storage`, expose a plaintext token.
  hasnt "$body" ".config/gh"                                    "up: run argv carries no ~/.config/gh mount"
  [[ ! -e "$HOME/.config/gh" ]] && ok "up: augur does not create ~/.config/gh on the host" \
                                || fail "up: augur created ~/.config/gh on the host"
  if grep -Eq "claude-projects/${slug}-[0-9a-f]{12}:" "$run"; then ok "up: history host dir keyed on full-path hash (A3/C7)"
  else fail "up: history host dir not keyed on path hash"; fi
  # User-level subagent defs (~/.claude/agents): same per-project, path-hash-keyed, outside-host-~/.claude
  # persistence as history — so `/agents` created in the guest survive down/up AND destroy/recreate.
  has "$body" "claude-agents/${slug}-"                          "up: host agents dir under claude-agents/<slug>-… (state seam)"
  if grep -Eq ":/home/dev/\.claude/agents$" "$run"; then ok "up: mounts ~/.claude/agents (user-level subagent defs persist)"
  else fail "up: does not mount ~/.claude/agents" "expected a line ending exactly in :/home/dev/.claude/agents"; fi
  if grep -Eq "claude-agents/${slug}-[0-9a-f]{12}:" "$run"; then ok "up: agents host dir keyed on full-path hash (A3/C7)"
  else fail "up: agents host dir not keyed on path hash"; fi
  # Opt-in operator profile. Host-GLOBAL — the one mount NOT keyed on the project — which is exactly
  # why it must be read-only: every project on this host reads it, so a guest able to write here
  # would plant a hook/command/skill for all of them.
  if grep -Eq ":/home/dev/\.augur-profile:ro$" "$run"; then ok "up: mounts the operator profile READ-ONLY"
  else fail "up: operator profile not mounted read-only" "expected a line ending exactly in :/home/dev/.augur-profile:ro"; fi
  if grep -Eq "claude-profile:/home/dev/\.augur-profile:ro$" "$run"; then ok "up: profile source is \$AUGUR_DIR/claude-profile (host-global)"
  else fail "up: profile source path unexpected"; fi
  if grep -Eq "claude-profile/${slug}" "$run"; then fail "up: profile must NOT be per-project" "found a slug-keyed profile path"
  else ok "up: profile is not slug-keyed (personal tooling is not project-scoped)"; fi
  if grep -Eq ":/home/dev/\.claude:ro$" "$run"; then fail "up: profile must not shadow ~/.claude" "found a RO mount at /home/dev/.claude"
  else ok "up: profile does not shadow the guest ~/.claude"; fi
else
  cname="augur-${slug}"
  fail "up: no container run captured" "trace: $(cat "$AUGUR_TEST_SHIMLOG.trace" 2>/dev/null)"
fi

# ── No folder-trust seed: augur does not pre-trust the mounted workspace. A blanket
#    "no exec at all" check would not hold — finish_up wires the operator profile via one exec on
#    every up — so assert the thing that actually matters instead: nothing on the create path
#    writes trust, or touches ~/.claude.json at all. ──
create_trace="$(cat "$AUGUR_TEST_SHIMLOG.trace" 2>/dev/null)"
hasnt "$create_trace" "hasTrustDialogAccepted"                "up: does NOT seed folder-trust in the guest on create"
hasnt "$create_trace" ".claude.json"                          "up: create path never writes the guest ~/.claude.json (ADR-0012)"
hasnt "$create_trace" "jq"                                    "up: no jq config merge left on the create path"
# The execs it DOES issue must be exactly the profile wiring (history restore no-ops with no
# snapshot). A new exec appearing here should force whoever added it to justify it in this test.
has   "$create_trace" "AUGUR_PROFILE_SRC=/home/dev/.augur-profile" "up: create path wires the operator profile"

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

# ── Reconcile: a persisted (stopped) container is REUSED (start) when config is unchanged ──
# The up above wrote a fingerprint (egress off, ANTHROPIC_API_KEY=…, default memory). With the
# same config and a stopped container present, cmd_up must `container start` it — NOT rebuild.
export AUGUR_TEST_CONTAINER_RUNNING=0
export AUGUR_TEST_CONTAINER_STOPPED=1
rm -f "$AUGUR_TEST_SHIMLOG.trace"
( cd "$proj" && bash "$AUGUR" up --no-egress ) >/dev/null 2>&1 || true
trace="$(cat "$AUGUR_TEST_SHIMLOG.trace" 2>/dev/null)"
has   "$trace" "container start"    "up: reuses (starts) the stopped container when config is unchanged"
hasnt "$trace" "container run"      "up: does NOT rebuild a matching persisted container"
hasnt "$trace" "delete --force"     "up: does NOT remove a matching persisted container"
# The reuse path is the WHOLE reason apply_guest_profile lives in finish_up rather than on the
# create path: a profile edited on the host must land without recreating the container.
has   "$trace" "AUGUR_PROFILE_SRC=/home/dev/.augur-profile" "up: the REUSE path also wires the operator profile (finish_up runs on both)"

# ── Reconcile: a config change (here: memory) forces a clean RECREATE (delete + run) ──
rm -f "$AUGUR_TEST_SHIMLOG.trace"
( cd "$proj" && AUGUR_CONTAINER_MEMORY=6g bash "$AUGUR" up --no-egress ) >/dev/null 2>&1 || true
trace="$(cat "$AUGUR_TEST_SHIMLOG.trace" 2>/dev/null)"
has "$trace" "delete --force"       "up: removes the stale container when baked config changed (memory)"
has "$trace" "container run"        "up: recreates the container from the image on config drift"

# Back to the default memory (another recreate), so the stored fingerprint matches the plain config.
( cd "$proj" && bash "$AUGUR" up --no-egress ) >/dev/null 2>&1 || true

# A container created while ~/.config/gh was still mounted must be recreated once, not reused with
# that mount. Its stored fingerprint is the digest of the same inputs minus the gh_config line, so
# rebuild exactly that digest from the current one's inputs and check that up recreates on it.
fp_file_gh="$(find "$HOME/.augur/container-state" -name '*.fingerprint' 2>/dev/null | head -1)"
fp_inputs="$(sed -n '/^container_fingerprint() {/,/^}/p' "$AUGUR")"
has "$fp_inputs" 'echo "gh_config=unmounted"' "fingerprint: records that ~/.config/gh is not mounted"
if [[ -n "$fp_file_gh" ]]; then
  # Digest of container_fingerprint with every line containing the fixed string $1 dropped, run in a
  # subshell with the inputs of the plain `up --no-egress` above stubbed in.
  fp_with() (
    cd "$proj" || exit 1
    eval "$(printf '%s\n' "$fp_inputs" | grep -vF -e "$1")"
    egress_enabled() { return 1; }
    resolve_container_memory() { echo 4g; }
    agent_profile_guest_mount() { echo /home/dev/.augur-profile; }
    WORKSPACE_DIR="$(pwd)"; WORKSPACE_MOUNT="/workspace-${slug}"
    container_fingerprint
  )
  # Control: the rebuild reproduces the stored digest exactly, so the mismatch below comes from the
  # missing gh_config line alone and not from a stubbed input that drifted.
  eq "$(cat "$fp_file_gh")" "$(fp_with 'no line contains this')" "fingerprint: the test rebuild reproduces the stored digest"
  old_fp="$(fp_with 'gh_config=unmounted')"
  printf '%s\n' "$old_fp" > "$fp_file_gh"
  rm -f "$AUGUR_TEST_SHIMLOG.trace"
  ( cd "$proj" && bash "$AUGUR" up --no-egress ) >/dev/null 2>&1 || true
  trace="$(cat "$AUGUR_TEST_SHIMLOG.trace" 2>/dev/null)"
  has "$trace" "delete --force" "up: a container fingerprinted before gh_config existed is removed"
  has "$trace" "container run"  "up: ...and recreated without the ~/.config/gh mount"
else
  fail "fingerprint: could not locate the fingerprint file" "looked under $HOME/.augur/container-state"
fi

# ── Credential rotation never recreates: nothing credential-shaped is baked or fingerprinted ──
rm -f "$AUGUR_TEST_SHIMLOG.trace"
( cd "$proj" && ANTHROPIC_API_KEY="sk-ant-rotated999" AUGUR_TEST_GH_TOKEN="gho_rotated789" \
    bash "$AUGUR" up --no-egress ) >/dev/null 2>&1 || true
trace="$(cat "$AUGUR_TEST_SHIMLOG.trace" 2>/dev/null)"
has   "$trace" "container start"    "up: a rotated API key / gh token reuses (starts) the stopped container"
hasnt "$trace" "container run"      "up: a rotated credential does NOT recreate the container"
hasnt "$trace" "delete --force"     "up: a rotated credential does NOT remove the container"
rm -f "$AUGUR_TEST_SHIMLOG.trace"
( cd "$proj" && env -u ANTHROPIC_API_KEY AUGUR_TEST_GH_TOKEN= bash "$AUGUR" up --no-egress ) >/dev/null 2>&1 || true
trace="$(cat "$AUGUR_TEST_SHIMLOG.trace" 2>/dev/null)"
has   "$trace" "container start"    "up: removing every credential also reuses the stopped container"
hasnt "$trace" "container run"      "up: removing every credential does NOT recreate the container"
unset AUGUR_TEST_CONTAINER_STOPPED

# ── augur claude: capture the constructed `container exec ... claude` ────────
export AUGUR_TEST_CONTAINER_RUNNING=1
export AUGUR_TEST_CONTAINER_NAME="$cname"
rm -f "$AUGUR_TEST_SHIMLOG.trace" "$envf"
( cd "$proj" && bash "$AUGUR" claude --no-egress ) >/dev/null 2>&1 || true
ex="$AUGUR_TEST_SHIMLOG.exec"
# `cmd_claude` issues MORE than one exec: apply_guest_profile (re-wiring, since an
# ALREADY-RUNNING container never reaches cmd_up at all — `container_running || cmd_up` — so
# finish_up and the apply_guest_profile inside it never run; see the augur comment at the call
# site), the interactive launch, then the prompt-history snapshot on the way out. The shim's .exec
# file keeps only the LAST argv, so pull the launch line (the ONE `-it` exec) out of the cumulative
# trace rather than assuming position.
launch_line="$(grep -E '^container exec -it ' "$AUGUR_TEST_SHIMLOG.trace" | tail -n1)"
if [[ -f "$ex" && -n "$launch_line" ]]; then
  body="$launch_line"
  eq  "exec" "$(head -n1 "$ex")"        "claude: invokes the engine 'exec' subcommand"
  has "$body" "DISABLE_AUTOUPDATER=1"   "claude: fixed env DISABLE_AUTOUPDATER=1 (fixed-env seam)"
  has "$body" "$cname"                  "claude: targets this project's container"
  eq  "claude" "${body##* }"            "claude: launch argv is exactly 'claude' (launch seam, last token)"
  full_trace="$(cat "$AUGUR_TEST_SHIMLOG.trace" 2>/dev/null)"
  eq "1" "$(printf '%s\n' "$full_trace" | grep -cE '^container exec -it ')" \
     "claude: exactly ONE interactive (-it) exec — apply_guest_profile/save_guest_history are non-interactive"
  # Position, by LINE NUMBER (not just "first"/"last"): profile re-wiring runs BEFORE the launch
  # (the guest should already be wired when the session starts), and the history snapshot runs
  # AFTER it (a snapshot taken before the session would capture stale history).
  launch_at="$(printf '%s\n' "$full_trace" | grep -n '^container exec -it ' | head -n1 | cut -d: -f1)"
  profile_at="$(printf '%s\n' "$full_trace" | grep -n 'AUGUR_PROFILE_SRC=' | head -n1 | cut -d: -f1)"
  history_at="$(printf '%s\n' "$full_trace" | grep -n 'AUGUR_HIST=' | head -n1 | cut -d: -f1)"
  if [[ -n "$profile_at" && "$profile_at" -lt "$launch_at" ]]
  then ok "claude: re-wires the operator profile BEFORE the interactive session starts (profile@$profile_at < launch@$launch_at)"
  else fail "claude: profile wiring is not before the launch" "profile@$profile_at launch@$launch_at"; fi
  if [[ -n "$history_at" && "$history_at" -gt "$launch_at" ]]
  then ok "claude: the interactive launch runs before the history snapshot (launch@$launch_at < history@$history_at)"
  else fail "claude: launch is not before the history snapshot" "launch@$launch_at history@$history_at"; fi
  # Per-session credentials: on the launch exec's --env-file (a process-substitution pipe the shim
  # read), never on any argv; the non-secret per-session env as plain -e.
  has   "$body" "--env-file /dev/fd/"          "claude: the launch exec carries --env-file <(…) (a pipe, not a file on disk)"
  hasnt "$full_trace" "sk-ant-test123"          "claude: the API key value is on NO engine argv"
  hasnt "$full_trace" "gho_testGhToken456"      "claude: the gh token value is on NO engine argv"
  hasnt "$full_trace" "ANTHROPIC_API_KEY"       "claude: no credential NAME on any argv either"
  envc="$(cat "$envf" 2>/dev/null)"
  eq "1" "$(grep -c '^== exec ' "$envf" 2>/dev/null)" "claude: exactly ONE exec received an env-file (the launch)"
  has   "$envc" $'\nANTHROPIC_API_KEY=sk-ant-test123\n' "claude: the env-file injects ANTHROPIC_API_KEY"
  has   "$envc" $'\nGH_TOKEN=gho_testGhToken456'      "claude: the env-file injects GH_TOKEN"
  hasnt "$envc" "CLAUDE_CODE_OAUTH_TOKEN"              "claude: the unset oauth token is omitted (named-only, non-empty only)"
  hasnt "$envc" "unreadable"                           "claude: the env-file pipe was readable by the engine process"
  has   "$body" "TZ="                                  "claude: TZ is set per session"
  has   "$body" "GIT_CONFIG_COUNT=1"                   "claude: git credential helper count set (gh token present)"
  has   "$body" "GIT_CONFIG_KEY_0=credential.https://github.com.helper" "claude: git credential helper key set"
  has   "$body" 'password=$GH_TOKEN'                   "claude: the helper carries only the \$GH_TOKEN reference"
  # augur's own non-interactive execs (profile wiring, history snapshot) get no credentials.
  if printf '%s\n' "$full_trace" | grep '^container exec ' | grep -v '^container exec -it ' | grep -q -- '--env-file'
  then fail "claude: a non-interactive exec carries --env-file" "only the session launch may"
  else ok "claude: profile-wiring / history execs carry no --env-file"; fi
else
  fail "claude: no container exec captured" "trace: $(cat "$AUGUR_TEST_SHIMLOG.trace" 2>/dev/null)"
fi

# ── Operator profile wiring ──────────────────────────────────────────────────
# apply_guest_profile ships a pure-POSIX-sh program to the guest over env vars, so the REAL program
# can be exercised against temp dirs with a stand-in `eng`. This is the risky half of the feature:
# symlink-vs-copy, replacing a real dir at the link target, un-wiring a removed entry, and never
# deleting THROUGH a symlink into the read-only mount.
section "Tier 1 — apply_guest_profile in-guest wiring (real program, fake engine)"
prof_run() {                       # prof_run <tmpdir>; caller populates <tmpdir>/src beforehand
  AUGUR_PROF_TD="$1" bash -c '
    AUGUR_SOURCE_ONLY=1 source "$1"
    set +e +u
    TD="$AUGUR_PROF_TD"; CONTAINER_NAME=fake
    # Point ONLY the two path accessors at temp dirs — the wiring program itself is the shipped one.
    agent_profile_guest_mount() { echo "$TD/src"; }
    agent_profile_guest_dir()   { echo "$TD/dst"; }
    # Stand in for the engine: run the sh program locally with exactly the -e vars it was handed.
    eng() {
      shift                                   # drop `exec`
      local envs=()
      while [ "${1:-}" = "-e" ]; do envs+=("$2"); shift 2; done
      shift 3                                 # drop NAME, `sh`, `-c` → $1 is the program
      env "${envs[@]}" sh -c "$1"
    }
    apply_guest_profile
  ' _ "$AUGUR" 2>&1
}

ptd="$work/profile"; mkdir -p "$ptd/src/commands" "$ptd/src/skills" "$ptd/dst"
echo 'hi'            > "$ptd/src/commands/foo.md"
echo '{"model":"x"}' > "$ptd/src/settings.json"
echo '# mem'         > "$ptd/src/CLAUDE.md"
# A REAL, NON-EMPTY directory at the link target — i.e. commands the GUEST created before the
# operator populated the profile. Wiring the profile must never silently delete those.
mkdir -p "$ptd/dst/commands"; echo stale > "$ptd/dst/commands/old.md"
# And a REAL but EMPTY one, which is free to drop.
mkdir -p "$ptd/dst/skills"
prof_run "$ptd" >/dev/null 2>&1

[[ -L "$ptd/dst/commands" ]] && ok "profile: commands/ is a symlink (host edits go live, no recreate)" \
                             || fail "profile: commands/ is not a symlink"
[[ -L "$ptd/dst/skills" ]]   && ok "profile: skills/ is a symlink" || fail "profile: skills/ is not a symlink"
eq "$ptd/src/commands" "$(readlink "$ptd/dst/commands")" "profile: commands/ points at the read-only mount"
has "$(cat "$ptd/dst/commands/foo.md" 2>/dev/null)" "hi"  "profile: linked command is readable in the guest"
[[ -e "$ptd/src/commands/foo.md" ]] && ok "profile: replacing the target did not delete through into the profile" \
                                    || fail "profile: deleted through the symlink into the read-only mount"
# The guest's own pre-existing commands must be MOVED ASIDE, never destroyed.
has "$(cat "$ptd/dst/commands.pre-profile/old.md" 2>/dev/null)" "stale" \
    "profile: a NON-EMPTY guest dir at the target is preserved as <name>.pre-profile, not deleted"
[[ -e "$ptd/dst/skills.pre-profile" ]] && fail "profile: rescued an EMPTY dir needlessly" "empty dirs should just be dropped" \
                                       || ok "profile: an EMPTY dir at the target is simply dropped (nothing to preserve)"
[[ -f "$ptd/dst/settings.json" && ! -L "$ptd/dst/settings.json" ]] \
  && ok "profile: settings.json is a real copy, not a symlink (Claude rewrites it at user scope)" \
  || fail "profile: settings.json is not a plain copy"
[[ -f "$ptd/dst/CLAUDE.md" && ! -L "$ptd/dst/CLAUDE.md" ]] \
  && ok "profile: CLAUDE.md is a real copy, not a symlink" || fail "profile: CLAUDE.md is not a plain copy"
if echo 'rewritten' > "$ptd/dst/settings.json" 2>/dev/null; then ok "profile: the copied settings.json is writable in the guest"
else fail "profile: copied settings.json is not writable" "a read-only settings.json breaks user-scope writes"; fi

# Removing an entry from the profile must UN-wire it, not leave a dangling symlink forever.
rm -rf "$ptd/src/commands"
prof_run "$ptd" >/dev/null 2>&1
[[ -e "$ptd/dst/commands" || -L "$ptd/dst/commands" ]] \
  && fail "profile: a removed entry left a dangling symlink" "operator deleted commands/ but the link survived" \
  || ok "profile: removing an entry from the profile un-wires it"

# Inert by default: an EMPTY profile must wire nothing at all (the no-opt-in path).
etd="$work/profile-empty"; mkdir -p "$etd/src" "$etd/dst"
prof_run "$etd" >/dev/null 2>&1
eq "" "$(ls -A "$etd/dst")" "profile: an empty profile wires nothing (inert by default)"

# A profile shipping only commands/ must not fabricate a settings.json.
ptd2="$work/profile-partial"; mkdir -p "$ptd2/src/commands" "$ptd2/dst"
echo x > "$ptd2/src/commands/a.md"
prof_run "$ptd2" >/dev/null 2>&1
[[ -e "$ptd2/dst/settings.json" ]] && fail "profile: fabricated a settings.json the operator never shipped" \
                                   || ok "profile: only entries present in the profile are wired"

# ── Prompt-history carry-over ────────────────────────────────────────────────
# The snapshot is what makes up-arrow recall survive an augur-initiated recreate. Drive the REAL
# save/restore against a fake guest filesystem with a stand-in engine.
section "Tier 1 — prompt-history carry-over (real programs, fake engine)"
ctd="$work/carry"; mkdir -p "$ctd/proj"
carry_run() {   # carry_run <phase>
  AUGUR_CARRY_TD="$ctd" AUGUR_CARRY_PHASE="$1" bash -c '
    AUGUR_SOURCE_ONLY=1 source "$1"
    set +e +u
    TD="$AUGUR_CARRY_TD"; CONTAINER_NAME=fake
    WORKSPACE_DIR="$TD/proj"; AUGUR_DIR="$TD/augur"
    agent_state_guest_history_file() { echo "$TD/guest/.claude/history.jsonl"; }
    container_running() { [ "${AUGUR_CARRY_RUNNING:-1}" = 1 ]; }
    eng() {
      [ "${1:-}" = exec ] || return 0
      shift
      local envs=()
      while [ "${1:-}" = "-e" ]; do envs+=("$2"); shift 2; done
      shift 3
      env "${envs[@]}" sh -c "$1"
    }
    case "$AUGUR_CARRY_PHASE" in
      save)         save_guest_history ;;
      save-stopped) AUGUR_CARRY_RUNNING=0 save_guest_history ;;
      restore)      restore_guest_history ;;
      drop)         drop_guest_history ;;
    esac
    guest_carryover_dir     # echo the resolved dir so assertions need not recompute the hash
  ' _ "$AUGUR" 2>/dev/null | tail -n1
}

mkdir -p "$ctd/guest/.claude"
i=1; while [ $i -le 300 ]; do printf '{"display":"prompt-%d"}\n' "$i" >> "$ctd/guest/.claude/history.jsonl"; i=$((i+1)); done
snapdir="$(carry_run save)"
if [[ -n "$snapdir" && -s "$snapdir/history.jsonl" ]]; then
  eq "200" "$(wc -l < "$snapdir/history.jsonl" | tr -d ' ')" "carry-over: history capped to the tail (env-arg size bound)"
  has   "$(cat "$snapdir/history.jsonl")" 'prompt-300' "carry-over: the tail kept is the NEWEST prompts"
  hasnt "$(cat "$snapdir/history.jsonl")" '"prompt-1"' "carry-over: the oldest prompts are dropped, not the newest"
  eq "600" "$(stat -c '%a' "$snapdir/history.jsonl" 2>/dev/null || stat -f '%Lp' "$snapdir/history.jsonl")" \
     "carry-over: snapshot is mode 0600 (guest-written data living on the host)"
else
  fail "carry-over: save produced no snapshot" "dir=$snapdir"
fi

# A stopped container cannot be exec'd — save must no-op rather than truncate a good snapshot.
before="$(cat "$snapdir/history.jsonl" 2>/dev/null)"
carry_run save-stopped >/dev/null
eq "$before" "$(cat "$snapdir/history.jsonl" 2>/dev/null)" "carry-over: save no-ops (and preserves the snapshot) when the container is stopped"

# Recreate: wipe the fake guest, then restore.
rm -rf "$ctd/guest"; mkdir -p "$ctd/guest/.claude"
carry_run restore >/dev/null
eq "200" "$(wc -l < "$ctd/guest/.claude/history.jsonl" 2>/dev/null | tr -d ' ')" "carry-over: restore repopulates prompt history in a fresh container"
has "$(cat "$ctd/guest/.claude/history.jsonl" 2>/dev/null)" 'prompt-300' "carry-over: restored history is the snapshotted tail"

# A byte-oversized snapshot must be SKIPPED, not blown into the env-arg limit mid-`up`.
rm -f "$ctd/guest/.claude/history.jsonl"
head -c 200000 /dev/zero | tr '\0' 'x' > "$snapdir/history.jsonl"
carry_run restore >/dev/null
[[ -e "$ctd/guest/.claude/history.jsonl" ]] && fail "carry-over: restored an oversized snapshot" "should refuse past the byte cap" \
                                            || ok "carry-over: refuses to restore past the byte cap"

# `.prev` is a real fallback, not dead code: when the current snapshot is gone, restore uses it.
rm -f "$ctd/guest/.claude/history.jsonl" "$snapdir/history.jsonl"
printf '{"display":"from-prev"}\n' > "$snapdir/history.jsonl.prev"
carry_run restore >/dev/null
has "$(cat "$ctd/guest/.claude/history.jsonl" 2>/dev/null)" 'from-prev' \
    "carry-over: restore falls back to the previous generation when the current snapshot is gone"
rm -f "$snapdir/history.jsonl.prev" "$ctd/guest/.claude/history.jsonl"

# `destroy` means clean: the snapshot must go, or the next `up` feeds guest data forward.
printf '{"display":"x"}\n' > "$snapdir/history.jsonl"
carry_run drop >/dev/null
[[ -e "$snapdir/history.jsonl" ]] && fail "carry-over: destroy left the snapshot behind" "clean-guest guarantee broken" \
                                  || ok "carry-over: destroy drops the snapshot (clean guest stays clean)"

# Best-effort under the PRODUCTION shell options. Everything above runs the snapshot under
# `set +e +u`, which cannot see the `set -e` trap that matters here: save_guest_history runs from
# cmd_down BEFORE the stop, from invalidate_persisted_container BEFORE the container is removed, and
# between cmd_claude's exit-code capture and its `return`. An unguarded failure there would abort
# the operator's actual command. Force cp/mv to fail with errexit fully armed and prove the caller
# still gets to its next statement.
# Re-seed a guest history file: the drop test above removed both it and the snapshot, and without a
# non-empty capture save_guest_history takes its `else` branch and never reaches the cp/mv at all —
# which would make this a test that passes for the wrong reason.
mkdir -p "$ctd/guest/.claude"; printf '{"display":"p"}\n' > "$ctd/guest/.claude/history.jsonl"
besteffort="$(AUGUR_CARRY_TD="$ctd" bash -c '
  AUGUR_SOURCE_ONLY=1 source "$1"          # augur itself enables set -euo pipefail
  TD="$AUGUR_CARRY_TD"; CONTAINER_NAME=fake
  WORKSPACE_DIR="$TD/proj"; AUGUR_DIR="$TD/augur"
  agent_state_guest_history_file() { echo "$TD/guest/.claude/history.jsonl"; }
  container_running() { true; }
  eng() {
    [ "${1:-}" = exec ] || return 0
    shift; local envs=()
    while [ "${1:-}" = "-e" ]; do envs+=("$2"); shift 2; done
    shift 3
    env ${envs[@]+"${envs[@]}"} sh -c "$1"
  }
  cp() { return 1; }                        # simulate a full disk / unwritable snapshot dir
  mv() { return 1; }
  save_guest_history
  echo REACHED_NEXT_STATEMENT
' _ "$AUGUR" 2>/dev/null)"
has "$besteffort" "REACHED_NEXT_STATEMENT" "carry-over: a failing snapshot never aborts the caller under set -euo pipefail"

# ── Re-wiring while the container is ALREADY running ────────────────────────────────────────
# `claude`/`shell` route through cmd_up only when the container is NOT running
# (`container_running || cmd_up`), so on the common case — repeated `claude`/`shell` calls with no
# intervening `down` — finish_up never runs. Left to finish_up alone, apply_guest_profile would be
# skipped entirely, so a STRUCTURAL profile change (an entry added/removed/replaced) would stay
# invisible until the operator ran `down` first, contradicting the documented "the next `augur
# claude` picks it up." Assert cmd_claude/cmd_shell wire the profile themselves, not only via
# cmd_up, by driving them with the container already RUNNING. (cmd_up's own already-running path
# reconciles rather than no-opping — see tests/34_up_reconcile.sh — but it is still not on this path.)
section "Tier 1 — profile re-wiring when the container is already running (the live-testing bug)"
export AUGUR_TEST_CONTAINER_RUNNING=1
rm -f "$AUGUR_TEST_SHIMLOG.trace"
( cd "$proj" && bash "$AUGUR" claude --no-egress ) >/dev/null 2>&1 || true
has "$(cat "$AUGUR_TEST_SHIMLOG.trace" 2>/dev/null)" "AUGUR_PROFILE_SRC=" \
    "claude: re-wires the profile even when the container was ALREADY running (no cmd_up call)"

rm -f "$AUGUR_TEST_SHIMLOG.trace" "$envf"
( cd "$proj" && bash "$AUGUR" shell --no-egress ) >/dev/null 2>&1 || true
shell_trace="$(cat "$AUGUR_TEST_SHIMLOG.trace" 2>/dev/null)"
shell_launch="$(printf '%s\n' "$shell_trace" | grep -E '^container exec -it ' | tail -n1)"
has   "$shell_launch" "--env-file /dev/fd/"     "shell: the bash exec carries --env-file <(…)"
eq    "bash" "${shell_launch##* }"               "shell: launches bash"
has   "$shell_launch" "TZ="                      "shell: TZ is set per session"
has   "$shell_launch" "GIT_CONFIG_KEY_0="        "shell: git credential helper set (gh token present)"
hasnt "$shell_trace" "sk-ant-test123"            "shell: the API key value is on NO engine argv"
hasnt "$shell_trace" "gho_testGhToken456"        "shell: the gh token value is on NO engine argv"
shell_envc="$(cat "$envf" 2>/dev/null)"
has   "$shell_envc" "ANTHROPIC_API_KEY=sk-ant-test123" "shell: the env-file injects ANTHROPIC_API_KEY"
has   "$shell_envc" "GH_TOKEN=gho_testGhToken456"      "shell: the env-file injects GH_TOKEN"
has "$shell_trace" "AUGUR_PROFILE_SRC=" \
    "shell: re-wires the profile even when the container was ALREADY running (no cmd_up call)"
# Same ordering requirement as claude: wiring before the interactive bash, not after.
shell_launch_at="$(printf '%s\n' "$shell_trace" | grep -n '^container exec -it ' | head -n1 | cut -d: -f1)"
shell_profile_at="$(printf '%s\n' "$shell_trace" | grep -n 'AUGUR_PROFILE_SRC=' | head -n1 | cut -d: -f1)"
if [[ -n "$shell_profile_at" && -n "$shell_launch_at" && "$shell_profile_at" -lt "$shell_launch_at" ]]
then ok "shell: re-wires the operator profile BEFORE the interactive bash starts"
else fail "shell: profile wiring is not before the launch" "profile@$shell_profile_at launch@$shell_launch_at"; fi

# No gh token on the host → no GH_TOKEN and no git credential helper at all.
rm -f "$AUGUR_TEST_SHIMLOG.trace" "$envf"
( cd "$proj" && AUGUR_TEST_GH_TOKEN='' bash "$AUGUR" shell --no-egress ) >/dev/null 2>&1 || true
nogh_launch="$(grep -E '^container exec -it ' "$AUGUR_TEST_SHIMLOG.trace" 2>/dev/null | tail -n1)"
has   "$nogh_launch" "--env-file /dev/fd/"       "shell (no gh token): still carries --env-file"
hasnt "$nogh_launch" "GIT_CONFIG_"               "shell (no gh token): no git credential helper"
hasnt "$(cat "$envf" 2>/dev/null)" "GH_TOKEN"    "shell (no gh token): no GH_TOKEN in the env-file"
has   "$(cat "$envf" 2>/dev/null)" "ANTHROPIC_API_KEY=sk-ant-test123" "shell (no gh token): the API key is still injected"

# ── setup-token: no credentials at all ────────────────────────────────────────
# It exists to mint a token; the current one is not handed to a guest binary for that. The shim
# makes the integrity gate's two sha256 probes agree so the flow reaches its interactive exec.
section "Tier 1 — setup-token and augur's own execs get no credentials"
rm -f "$AUGUR_TEST_SHIMLOG.trace" "$envf"
claude_sha="$(printf 'a%.0s' {1..64})"
( cd "$proj" && AUGUR_TEST_CLAUDE_SHA256="$claude_sha" bash "$AUGUR" setup-token --no-egress ) </dev/null >/dev/null 2>&1 || true
st_trace="$(cat "$AUGUR_TEST_SHIMLOG.trace" 2>/dev/null)"
st_launch="$(printf '%s\n' "$st_trace" | grep -E '^container exec -it ' | tail -n1)"
if [[ -n "$st_launch" ]]; then
  eq    "setup-token" "${st_launch##* }"         "setup-token: reached its interactive 'claude setup-token' exec"
  hasnt "$st_launch" "--env-file"                 "setup-token: the exec carries no --env-file"
  hasnt "$st_launch" "GIT_CONFIG_"                "setup-token: the exec carries no git credential helper"
  hasnt "$st_trace"  "sk-ant-test123"             "setup-token: no API key value on any argv"
  [[ ! -s "$envf" ]] && ok "setup-token: no env-file content reached the engine at all" \
                     || fail "setup-token: an env-file reached the engine" "$(cat "$envf")"
else
  fail "setup-token: never reached its interactive exec" "trace: $st_trace"
fi

# ── setup-token's integrity gate: absolute programs only, and the launch runs what was hashed ──
# A persisted container's ~/.local/bin (first in the image PATH, writable by the guest user) is
# where the runtime resolves any bare program name, so a bare `sh`/`sha256sum`/`claude` could be a
# stub left by a prior session. The gate must name every program by absolute path, and the launch
# must run the exact path the gate hashed rather than looking `claude` up again.
section "Tier 1 — setup-token integrity gate runs absolute programs and launches the hashed path"
gate_run="$(printf '%s\n' "$st_trace" | grep -F 'container run --rm' | grep -F sha256sum | tail -n1)"
gate_exec="$(printf '%s\n' "$st_trace" | grep -E '^container exec ' | grep -F sha256sum | tail -n1)"
has   "$gate_run"  "/bin/sh -c /usr/bin/sha256sum" "gate (image side): /bin/sh and /usr/bin/sha256sum by absolute path"
if grep -Eq '(^| )sh -c' <<<"$gate_run"; then fail "gate (image side): uses a bare 'sh -c'" "$gate_run"
else ok "gate (image side): no bare 'sh -c'"; fi
eq    "container exec ${cname} /usr/bin/sha256sum /home/dev/.local/bin/claude" "$gate_exec" \
      "gate (container side): /usr/bin/sha256sum of the image-resolved path, no shell, no lookup"
has   "$st_launch" "${cname} /home/dev/.local/bin/claude setup-token" "setup-token: launches the exact path the gate hashed"
# Tampered binary: the container's hash differs → refuse before any interactive exec.
rm -f "$AUGUR_TEST_SHIMLOG.trace"
out="$( cd "$proj" && AUGUR_TEST_CLAUDE_SHA256="$claude_sha" AUGUR_TEST_CLAUDE_SHA256_EXEC="$(printf 'b%.0s' {1..64})" \
        bash "$AUGUR" setup-token --no-egress 2>&1 </dev/null )"; rc=$?
[[ $rc -ne 0 ]] && ok "setup-token: refuses a container whose claude hash differs" || fail "setup-token: accepted a differing hash"
hasnt "$(cat "$AUGUR_TEST_SHIMLOG.trace" 2>/dev/null)" "exec -it" "setup-token: a differing hash never reaches the interactive exec"
# An image-reported path that is not a plain absolute path is never launched.
rm -f "$AUGUR_TEST_SHIMLOG.trace"
( cd "$proj" && AUGUR_TEST_CLAUDE_SHA256="$claude_sha" AUGUR_TEST_CLAUDE_PATH="claude" \
    bash "$AUGUR" setup-token --no-egress ) </dev/null >/dev/null 2>&1; rc=$?
[[ $rc -ne 0 ]] && ok "setup-token: refuses a non-absolute claude path from the image" || fail "setup-token: accepted a relative claude path"
hasnt "$(cat "$AUGUR_TEST_SHIMLOG.trace" 2>/dev/null)" "exec -it" "setup-token: a relative path never reaches the interactive exec"

# ── The boot self-test's probes: /bin/sh by absolute path, PATH pinned inside it ──
# Egress is off in this tier, so `up` never reaches verify_egress_locked; call it directly from a
# sourced augur. The shim's exec always succeeds, so the self-test "sees a leak" and exits 1 — only
# the constructed probe argv matters here.
section "Tier 1 — boot self-test probes exec /bin/sh by absolute path"
rm -f "$AUGUR_TEST_SHIMLOG.trace"
( cd "$proj" && bash -c 'AUGUR_SOURCE_ONLY=1 source "$1" >/dev/null 2>&1
    CONTAINER_NAME="$2"; stop_egress() { :; }; egress_proxy_url() { echo http://192.0.2.1:3128; }
    verify_egress_locked' _ "$AUGUR" "$cname" ) >/dev/null 2>&1 || true
probes="$(grep -E '^container exec ' "$AUGUR_TEST_SHIMLOG.trace" 2>/dev/null)"
eq "9" "$(grep -c . <<<"$probes")" "self-test: ran 9 probe execs (7 direct, DNS, through-proxy)"
eq "9" "$(grep -cF " ${cname} /bin/sh -c " <<<"$probes")" "self-test: every probe execs /bin/sh by absolute path"
eq "9" "$(grep -cF "PATH=/usr/bin:/bin:/usr/local/bin " <<<"$probes")" "self-test: every probe pins PATH to system dirs"
if grep -Eq '(^| )sh -c' <<<"$probes"; then fail "self-test: a probe uses a bare 'sh -c'" "$probes"
else ok "self-test: no probe uses a bare 'sh -c'"; fi

# ── A RUNNING container with a stale fingerprint: claude/shell refuse before any exec -it ──
# Includes a container an older augur created with credentials/TZ baked into `container run`: exec
# env is appended to the baked env without de-duplication, so its baked values would shadow the
# per-session ones for anything using libc getenv.
section "Tier 1 — claude/shell refuse a RUNNING container whose fingerprint is stale"
fp_file="$(find "$HOME/.augur/container-state" -name '*.fingerprint' 2>/dev/null | head -1)"
if [[ -n "$fp_file" ]]; then
  fp_saved="$(cat "$fp_file")"
  echo "created-by-an-older-augur" > "$fp_file"
  for c in claude shell setup-token; do
    rm -f "$AUGUR_TEST_SHIMLOG.trace" "$envf"
    out="$( cd "$proj" && bash "$AUGUR" "$c" --no-egress 2>&1 )"; rc=$?
    out="$(printf '%s\n' "$out" | sed $'s/\033\\[[0-9;]*m//g')"
    [[ $rc -ne 0 ]] && ok "$c: exits non-zero on a stale running container" || fail "$c: exited 0 on a stale running container"
    has   "$out" "augur down && augur up"  "$c: names the remedy"
    hasnt "$(cat "$AUGUR_TEST_SHIMLOG.trace" 2>/dev/null)" "exec -it" "$c: refuses BEFORE any interactive exec"
    [[ ! -s "$envf" ]] && ok "$c: no credential reached the stale container" || fail "$c: credentials reached the stale container"
  done
  printf '%s\n' "$fp_saved" > "$fp_file"
else
  fail "stale fingerprint: could not locate the fingerprint file" "looked under $HOME/.augur/container-state"
fi

# ── Credential validation runs at session start; `up` itself injects nothing and does not check ──
section "Tier 1 — credential validation at session start"
rm -f "$AUGUR_TEST_SHIMLOG.trace" "$envf"
out="$( cd "$proj" && ANTHROPIC_API_KEY=$'sk-ant-bad\nEVIL=1' bash "$AUGUR" claude --no-egress 2>&1 )"; rc=$?
[[ $rc -ne 0 ]] && ok "claude: refuses a credential with a control character" || fail "claude: accepted a newline-bearing credential"
has   "$out" "ANTHROPIC_API_KEY" "claude: the refusal names the offending variable"
hasnt "$(cat "$AUGUR_TEST_SHIMLOG.trace" 2>/dev/null)" "exec -it" "claude: the bad credential is refused before any interactive exec"
[[ ! -s "$envf" ]] && ok "claude: nothing was written to an env-file" || fail "claude: a bad credential reached the env-file" "$(cat "$envf")"
# `up` must still work with a bad stored token, so `augur setup-token` can replace it.
export AUGUR_TEST_CONTAINER_RUNNING=0
rm -f "$AUGUR_TEST_SHIMLOG.trace"
( cd "$proj" && ANTHROPIC_API_KEY="sk-ant-it's-bad" bash "$AUGUR" up --no-egress ) >/dev/null 2>&1; rc=$?
eq "0" "$rc" "up: proceeds with an uninjectable stored credential (setup-token must stay reachable)"

# ── Apple Container CLI floor (1.0.0) ─────────────────────────────────────────
section "Tier 1 — Apple Container version floor"
for c in up claude shell setup-token; do
  rm -f "$AUGUR_TEST_SHIMLOG.trace" "$AUGUR_TEST_SHIMLOG.run"
  out="$( cd "$proj" && AUGUR_TEST_CONTAINER_VERSION=0.12.3 bash "$AUGUR" "$c" --no-egress 2>&1 )"; rc=$?
  [[ $rc -ne 0 ]] && ok "$c: refuses Apple Container 0.12.3" || fail "$c: accepted Apple Container 0.12.3"
  has   "$out" "1.0.0 or newer"  "$c: the refusal names the minimum version"
  st="$(cat "$AUGUR_TEST_SHIMLOG.trace" 2>/dev/null)"
  hasnt "$st" "container run"    "$c: nothing is created on a too-old CLI"
  hasnt "$st" "exec -it"         "$c: no session starts on a too-old CLI"
done
rm -f "$AUGUR_TEST_SHIMLOG.trace"
( cd "$proj" && AUGUR_TEST_CONTAINER_VERSION=1.0.0 bash "$AUGUR" up --no-egress ) >/dev/null 2>&1; rc=$?
eq "0" "$rc" "up: accepts exactly Apple Container 1.0.0"
# Deliberately NOT gated: teardown must work on an old CLI so the operator can clean up.
for c in down destroy list; do
  out="$( cd "$proj" && AUGUR_TEST_CONTAINER_VERSION=0.12.3 bash "$AUGUR" "$c" --no-egress 2>&1 )"; rc=$?
  eq "0" "$rc" "$c: still runs on Apple Container 0.12.3"
  hasnt "$out" "too old" "$c: no version refusal"
done
# Unparseable --version output fails OPEN with a warning (the floor is a usability guard).
rm -f "$AUGUR_TEST_SHIMLOG.trace"
out="$( cd "$proj" && AUGUR_TEST_CONTAINER_VERSION=garbage bash "$AUGUR" up --no-egress 2>&1 )"; rc=$?
eq "0" "$rc" "up: an unparseable 'container --version' does not block"
has "$out" "Could not read the Apple Container version" "up: an unparseable version is warned about"
export AUGUR_TEST_CONTAINER_RUNNING=1

# Source guards for the lifecycle wiring — behaviour above cannot see WHERE these are called.
claude_body="$(awk '/^cmd_claude\(\)/{f=1} f{print} f&&/^}/{exit}' "$AUGUR")"
shell_body="$(awk '/^cmd_shell\(\)/{f=1} f{print} f&&/^}/{exit}' "$AUGUR")"
has "$claude_body" 'apply_guest_profile' "carry-over: cmd_claude re-wires the profile directly (not only via cmd_up)"
has "$shell_body"  'apply_guest_profile' "carry-over: cmd_shell re-wires the profile directly (not only via cmd_up)"
has "$claude_body" 'save_guest_history' "carry-over: cmd_claude snapshots on the way out"
has "$shell_body"  'save_guest_history' "carry-over: cmd_shell snapshots on the way out"
# Both must preserve the interactive exit status rather than returning the snapshot's.
has "$claude_body" 'return "$_rc"'      "carry-over: cmd_claude still returns the agent's own exit status"
has "$shell_body"  'return "$_rc"'      "carry-over: cmd_shell still returns the shell's own exit status"
fn_body() { awk -v n="$1" '$0 ~ "^"n"\\(\\) \\{"{f=1} f{print} f&&/^}/{exit}' "$AUGUR"; }
recreate_body="$(fn_body recreate_container)"
down_body="$(awk '/^cmd_down\(\)/{f=1} f{print} f&&/^}/{exit}' "$AUGUR")"
destroy_body="$(awk '/^cmd_destroy\(\)/{f=1} f{print} f&&/^}/{exit}' "$AUGUR")"
inval_body="$(awk '/^invalidate_persisted_container\(\)/{f=1} f{print} f&&/^}/{exit}' "$AUGUR")"
has   "$recreate_body" 'restore_guest_history' "carry-over: the create path (recreate_container) restores"
has   "$down_body"    'save_guest_history'    "carry-over: cmd_down snapshots before stopping"
has   "$destroy_body" 'drop_guest_history'    "carry-over: cmd_destroy drops the snapshot"
hasnt "$destroy_body" 'save_guest_history'    "carry-over: cmd_destroy never snapshots (destroy is the clean-guest button)"
# build/update/install-cert all discard the writable layer through here, possibly while RUNNING.
has   "$inval_body"   'save_guest_history'    "carry-over: build/update/install-cert snapshot before discarding the layer"

# ── The workspace must not CONTAIN augur's own control plane ─────────────────
# $WORKSPACE_DIR is mounted READ-WRITE, and ~/.augur holds the host-executed binaries install
# puts first on the host's PATH (augur, augur-proxy, augur-gvproxy, augur-vm) plus the merged
# allowlist augur-proxy hot-reloads. Sharing $HOME (or ~/.augur, or an ancestor of either) is
# therefore guest→host code execution, not just "the guest can attack the repo you gave it".
#
# Asserted BEHAVIOURALLY through the real dispatch, three ways per case: a non-zero exit, NO
# shim run-log at all (proof nothing was ever mounted — a message plus a mount would be worse
# than no message), and stderr naming the offending directory so the operator can act on it.
section "Tier 1 — refuse a workspace containing augur's control plane (R1–R4, real dispatch)"
export AUGUR_TEST_CONTAINER_RUNNING=0
unset AUGUR_TEST_CONTAINER_NAME || true
guard_log="$work/guardshim"
mkdir -p "$HOME/sub" "$HOME/.augur/proxy"
ln -sfn "$HOME" "$work/homelink"          # a LOGICAL path that resolves to $HOME

# The refusal is colorized, and ${BOLD} sits between "share " and the path — so assert on the
# ANSI-stripped text, or a passing check would depend on where the escapes happen to fall.
strip_ansi() { sed $'s/\033\\[[0-9;]*m//g'; }

guard_case() {   # guard_case <label> <dir> <expected-substring-in-stderr> [rule-phrase]
  rm -f "$guard_log.run" "$guard_log.trace"
  local out rc
  # Capture status from a NON-pipelined assignment, then strip — so the exit-code assertion does
  # not silently depend on `pipefail` being set.
  out="$( cd "$2" && AUGUR_TEST_SHIMLOG="$guard_log" bash "$AUGUR" up --no-egress 2>&1 )"; rc=$?
  out="$(printf '%s\n' "$out" | strip_ansi)"
  if [[ $rc -ne 0 ]]; then ok "$1: up exits non-zero"
  else fail "$1: up exited 0" "the guard did not refuse"; fi
  if [[ ! -e "$guard_log.run" ]]; then ok "$1: no 'container run' constructed (nothing was mounted)"
  else fail "$1: a container run WAS constructed" "$(tr '\n' ' ' < "$guard_log.run")"; fi
  has "$out" "Refusing to share $3" "$1: stderr names the offending directory"
  [[ -n "${4:-}" ]] && has "$out" "$4" "$1: stderr says which rule was hit"
  return 0
}

# The guard compares — and reports — PHYSICAL paths, so the expectations must be physical too.
# On macOS `mktemp -d` hands back /var/folders/… which is itself a symlink to /private/var/…;
# asserting on the logical string would pass on the Linux CI runner and fail on a Mac.
phys() { ( cd "$1" && pwd -P ); }
work_p="$(phys "$work")"; home_p="$(phys "$HOME")"

guard_case "R1 root"               "/"                  "/"               "filesystem root"
guard_case "R2 \$HOME"              "$HOME"              "$home_p"         "your home directory"
guard_case "R3 ancestor of \$HOME"   "$work"              "$work_p"         "contains your home directory"
guard_case "R4 \$AUGUR_DIR"          "$HOME/.augur"       "$home_p/.augur"  "augur's own directory"
guard_case "R4 inside \$AUGUR_DIR"   "$HOME/.augur/proxy" "$home_p/.augur/proxy" "augur's own directory"
# WORKSPACE_DIR is $(pwd) — the LOGICAL path. Comparing it as a string would let a symlinked
# cwd through while the engine happily shares the physical $HOME behind it.
guard_case "R2 via a symlinked cwd" "$work/homelink"     "$home_p"         "your home directory"
# …and the refusal must name the RESOLVED target, not the link the operator typed — otherwise
# the operator cannot tell why a cwd that "isn't $HOME" was refused.
sym_out="$( cd "$work/homelink" && AUGUR_TEST_SHIMLOG="$guard_log" bash "$AUGUR" up --no-egress 2>&1 )"
sym_out="$(printf '%s\n' "$sym_out" | strip_ansi)"
hasnt "$sym_out" "homelink" "R2 via a symlinked cwd: the message reports the resolved path, not the symlink"
# The message must state BOTH remedies, not just "no".
rm -f "$guard_log.run"
guard_out="$( cd "$HOME" && AUGUR_TEST_SHIMLOG="$guard_log" bash "$AUGUR" up --no-egress 2>&1 )"
guard_out="$(printf '%s\n' "$guard_out" | strip_ansi)"
has "$guard_out" "subdirectory"             "guard: the refusal offers the move-into-a-subdirectory remedy"
# NOT a bare "augur destroy": a SUCCESSFUL up prints that in its next-steps hint (augur:1636), so
# the bare substring passes even with the guard neutered. Anchor on wording only the refusal has.
has "$guard_out" "augur destroy here first" "guard: the refusal offers 'augur destroy' for a pre-fix container"

# POSITIVE CONTROL — the guard must not swallow the normal case. A directory INSIDE $HOME that
# is not $HOME and not ~/.augur still produces a real `container run`. Without this, deleting
# every mount in cmd_up would leave the three assertions above passing.
rm -f "$guard_log.run" "$guard_log.trace"
( cd "$HOME/sub" && AUGUR_TEST_SHIMLOG="$guard_log" bash "$AUGUR" up --no-egress ) >/dev/null 2>&1
sub_rc=$?
eq "0" "$sub_rc" "positive control: up from \$HOME/sub exits 0"
if [[ -f "$guard_log.run" ]]; then
  ok "positive control: up from \$HOME/sub still constructs a 'container run'"
  eq "run" "$(head -n1 "$guard_log.run")" "positive control: it is the engine 'run' subcommand"
  has "$(cat "$guard_log.run")" "$HOME/sub:" "positive control: \$HOME/sub is the mount source"
else
  fail "positive control: no container run from \$HOME/sub" "the guard over-refuses"
fi

finish
