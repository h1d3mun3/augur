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
# HOME here has no ~/.gitconfig — a regression guard for the pipefail/set -e class where
# write_container_fingerprint returned non-zero and aborted cmd_up before finish_up (skipping the
# I1 self-test). up MUST exit 0 here.
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
  has "$body" "ANTHROPIC_API_KEY=sk-ant-test123"               "up: injects ANTHROPIC_API_KEY (auth seam)"
  hasnt "$body" "CLAUDE_CODE_OAUTH_TOKEN"                       "up: omits the unset oauth token (named-only auth)"
  has "$body" "claude-projects/${slug}-"                        "up: host history under claude-projects/<slug>-… (state seam)"
  if grep -Eq ":/home/dev/\.claude/projects$" "$run"; then ok "up: mounts the whole projects parent, not one leaf (Option A)"
  else fail "up: does not mount the projects parent exactly" "expected a line ending exactly in :/home/dev/.claude/projects"; fi
  hasnt "$body" ":/home/dev/.claude/projects/-workspace-${slug}" "up: no leftover leaf-scoped mount target"
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

# ── No folder-trust seed: augur no longer pre-trusts the mounted workspace (ADR-0012, reverses
#    ADR-0011). The blanket "no exec at all" check this used to make no longer holds — finish_up
#    now wires the operator profile via one exec on every up — so assert the thing that actually
#    matters instead: nothing on the create path writes trust, or touches ~/.claude.json at all. ──
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
unset AUGUR_TEST_CONTAINER_STOPPED

# ── augur claude: capture the constructed `container exec ... claude` ────────
export AUGUR_TEST_CONTAINER_RUNNING=1
export AUGUR_TEST_CONTAINER_NAME="$cname"
rm -f "$AUGUR_TEST_SHIMLOG.trace"
( cd "$proj" && bash "$AUGUR" claude ) >/dev/null 2>&1 || true
ex="$AUGUR_TEST_SHIMLOG.exec"
# `cmd_claude` issues MORE than one exec now: apply_guest_profile (re-wiring, since an
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

# ── Re-wiring while the container is ALREADY running (real bug, found in live testing) ──────
# `claude`/`shell` route through cmd_up only when the container is NOT running
# (`container_running || cmd_up`), so on the common case — repeated `claude`/`shell` calls with no
# intervening `down` — finish_up never runs. That skipped apply_guest_profile entirely, so a
# STRUCTURAL profile change (an entry added/removed/replaced) was invisible until the operator ran
# `down` first, contradicting the documented "the next `augur claude` picks it up." Assert
# cmd_claude/cmd_shell wire the profile themselves, not only via cmd_up, by driving them with the
# container already RUNNING. (cmd_up's own already-running path now reconciles rather than
# no-opping — see tests/34_up_reconcile.sh — but it is still not on this path.)
section "Tier 1 — profile re-wiring when the container is already running (the live-testing bug)"
export AUGUR_TEST_CONTAINER_RUNNING=1
rm -f "$AUGUR_TEST_SHIMLOG.trace"
( cd "$proj" && bash "$AUGUR" claude ) >/dev/null 2>&1 || true
has "$(cat "$AUGUR_TEST_SHIMLOG.trace" 2>/dev/null)" "AUGUR_PROFILE_SRC=" \
    "claude: re-wires the profile even when the container was ALREADY running (no cmd_up call)"

rm -f "$AUGUR_TEST_SHIMLOG.trace"
( cd "$proj" && bash "$AUGUR" shell ) >/dev/null 2>&1 || true
shell_trace="$(cat "$AUGUR_TEST_SHIMLOG.trace" 2>/dev/null)"
has "$shell_trace" "AUGUR_PROFILE_SRC=" \
    "shell: re-wires the profile even when the container was ALREADY running (no cmd_up call)"
# Same ordering requirement as claude: wiring before the interactive bash, not after.
shell_launch_at="$(printf '%s\n' "$shell_trace" | grep -n '^container exec -it ' | head -n1 | cut -d: -f1)"
shell_profile_at="$(printf '%s\n' "$shell_trace" | grep -n 'AUGUR_PROFILE_SRC=' | head -n1 | cut -d: -f1)"
if [[ -n "$shell_profile_at" && -n "$shell_launch_at" && "$shell_profile_at" -lt "$shell_launch_at" ]]
then ok "shell: re-wires the operator profile BEFORE the interactive bash starts"
else fail "shell: profile wiring is not before the launch" "profile@$shell_profile_at launch@$shell_launch_at"; fi

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
up_body="$(awk '/^cmd_up\(\)/{f=1} f{print} f&&/^}/{exit}' "$AUGUR")"
down_body="$(awk '/^cmd_down\(\)/{f=1} f{print} f&&/^}/{exit}' "$AUGUR")"
destroy_body="$(awk '/^cmd_destroy\(\)/{f=1} f{print} f&&/^}/{exit}' "$AUGUR")"
inval_body="$(awk '/^invalidate_persisted_container\(\)/{f=1} f{print} f&&/^}/{exit}' "$AUGUR")"
has   "$up_body"      'restore_guest_history' "carry-over: cmd_up restores on the create path"
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
# See docs/decisions/0014-workspace-must-not-contain-augur.md.
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
