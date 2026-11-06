#!/usr/bin/env bash
# Tier 0/1 (offline) — the agent definition file (agents/claude.sh) that `augur` sources.
#   (a) augur fails closed, in every entry path, when the file is missing or unreadable;
#   (b) the file defines every agent_* accessor augur calls;
#   (c) `bash install` / `bash install --here` ship the file and refuse a source tree without it;
#   (d) the file's directory is not under anything cmd_up / cmd_up_macos mounts or shares into a guest.
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/lib.sh"
AUGUR="$REPO/augur"
AGENT_FILE="$REPO/agents/claude.sh"

work="$(mktemp -d)"; trap 'chmod -R u+rwx "$work" 2>/dev/null; rm -rf "$work"' EXIT
export HOME="$work/home"; mkdir -p "$HOME"
export AUGUR_TEST_SHIMLOG="$work/shim"

# ── (a) missing / unreadable file: fail closed ────────────────────────────────
section "Tier 0 — augur refuses to run without its agent definition"

# A copy of augur with NO agents/ beside it. The `container` shim records every call, so an empty
# trace proves no engine was touched.
mkdir -p "$work/noagent"; cp "$AUGUR" "$work/noagent/augur"
for cmd in version help __names status "up --no-egress"; do
  rm -f "$AUGUR_TEST_SHIMLOG.trace"
  # shellcheck disable=SC2086  # $cmd is a word list on purpose
  out="$( cd "$work" && PATH="$HERE/shims:$PATH" bash "$work/noagent/augur" $cmd 2>&1 </dev/null )"; rc=$?
  if [[ "$rc" -ne 0 ]]; then ok "missing agent file: '$cmd' exits non-zero ($rc)"
  else fail "missing agent file: '$cmd' exits non-zero" "exited 0"; fi
  has "$out" "bash install" "missing agent file: '$cmd' tells the operator to re-run bash install"
  has "$out" "$work/noagent/agents/claude.sh" "missing agent file: '$cmd' names the path it looked for"
  if [[ ! -s "$AUGUR_TEST_SHIMLOG.trace" ]]; then ok "missing agent file: '$cmd' never touched the engine"
  else fail "missing agent file: '$cmd' never touched the engine" "$(cat "$AUGUR_TEST_SHIMLOG.trace")"; fi
done

# The test seam: sourcing augur without the file stops the sourcing shell (augur's own errexit turns
# the failed load into an exit), so nothing after the `source` runs and no accessor is defined.
out="$( cd "$work" && AUGUR_SOURCE_ONLY=1 bash -c 'source "$1" 2>/dev/null; echo REACHED' _ "$work/noagent/augur" 2>&1 )"; rc=$?
if [[ "$rc" -ne 0 ]]; then ok "missing agent file: sourcing augur (AUGUR_SOURCE_ONLY) exits non-zero ($rc)"
else fail "missing agent file: sourcing augur (AUGUR_SOURCE_ONLY) exits non-zero" "exited 0"; fi
hasnt "$out" "REACHED" "missing agent file: nothing runs after a failed source of augur"

# Unreadable (mode 000). Skipped as root, which reads anything.
mkdir -p "$work/unread/agents"; cp "$AUGUR" "$work/unread/augur"; cp "$AGENT_FILE" "$work/unread/agents/claude.sh"
chmod 000 "$work/unread/agents/claude.sh"
if [[ -r "$work/unread/agents/claude.sh" ]]; then
  skip "unreadable agent file refuses to run" "this user can read a mode-000 file (root?)"
else
  out="$( cd "$work" && PATH="$HERE/shims:$PATH" bash "$work/unread/augur" version 2>&1 </dev/null )"; rc=$?
  if [[ "$rc" -ne 0 ]]; then ok "unreadable agent file: exits non-zero ($rc)"; else fail "unreadable agent file: exits non-zero" "exited 0"; fi
  has "$out" "bash install" "unreadable agent file: tells the operator to re-run bash install"
fi
chmod 644 "$work/unread/agents/claude.sh"

# A present file is found by the path beside augur, whatever the cwd (not the workspace).
mkdir -p "$work/present/agents" "$work/elsewhere"; cp "$AUGUR" "$work/present/augur"; cp "$AGENT_FILE" "$work/present/agents/claude.sh"
out="$( cd "$work/elsewhere" && PATH="$HERE/shims:$PATH" bash "$work/present/augur" version 2>&1 </dev/null )"; rc=$?
eq "0" "$rc" "present agent file: augur version runs from an unrelated cwd"
# A decoy in the cwd must not be picked up in place of the installed file.
mkdir -p "$work/elsewhere/agents"; printf 'agent_cli_name() { echo DECOY; }\n' > "$work/elsewhere/agents/claude.sh"
out="$( cd "$work/elsewhere" && AUGUR_SOURCE_ONLY=1 bash -c 'source "$1"; agent_cli_name' _ "$work/present/augur" 2>&1 )"
eq "claude" "$out" "the agent file is taken from beside augur, never from the cwd"

# ── (b) every accessor augur calls is defined by the file ─────────────────────
section "Tier 0 — agents/claude.sh defines every agent_* accessor augur calls"
# Every agent_* word on a non-comment line of augur, minus the ones augur defines itself and the
# plain variables (assigned or declared local) that merely share the prefix.
mapfile -t called < <(grep -v '^[[:space:]]*#' "$AUGUR" | grep -oE '\bagent_[a-z0-9_]*[a-z0-9]' | sort -u)
missing=0; n=0
for name in "${called[@]}"; do
  grep -qE "^${name}\(\)" "$AUGUR" && continue
  grep -qE "(^|[[:space:]])${name}=|local[^#]*[[:space:]]${name}([[:space:]]|\$)" "$AUGUR" && continue
  n=$((n+1))
  if grep -qE "^${name}\(\)" "$AGENT_FILE"; then :; else missing=1; fail "agents/claude.sh defines $name" "augur calls it, the file does not define it"; fi
done
(( n >= 25 )) || fail "the call-site scan found the accessors" "only $n found; the scan is broken"
(( missing )) || ok "all $n accessors augur calls are defined by agents/claude.sh"

# The file declares data only: it defines nothing but agent_* functions, and loads nothing else.
stray="$(grep -E '^[A-Za-z_][A-Za-z0-9_]*\(\)' "$AGENT_FILE" | grep -vE '^agent_[a-z0-9_]+\(\)' || true)"
eq "" "$stray" "agents/claude.sh defines only agent_* functions"
if grep -qE '^[[:space:]]*(source|\.|eval)[[:space:]]' "$AGENT_FILE"; then fail "agents/claude.sh sources/evals nothing" "found one"
else ok "agents/claude.sh sources/evals nothing"; fi
if grep -nE 'eval.*AGENT_DEFINITION_FILE|AGENT_DEFINITION_FILE.*eval' "$AUGUR" >/dev/null; then fail "augur never evals the agent file" "found an eval"
else ok "augur never evals the agent file (it is sourced by absolute path under SCRIPT_DIR)"; fi

# ── (c) install ships the file ────────────────────────────────────────────────
section "Tier 1 — bash install copies agents/claude.sh"
# A PATH holding the tools install needs but no swift/go, so no sidecar is built.
bin="$work/bin"; mkdir -p "$bin"
for t in bash git cat cp mkdir chmod grep uname rm mktemp tar rsync sed dirname date head tr; do
  p="$(command -v "$t" 2>/dev/null)" && ln -s "$p" "$bin/$t"
done

src="$work/src"; mkdir -p "$src/completions"
cp "$REPO/install" "$REPO/augur" "$REPO/Dockerfile" "$REPO/.dockerignore" "$REPO/VERSION" "$REPO/augur.conf" "$src/"
cp "$REPO/completions/augur.bash" "$REPO/completions/augur.zsh" "$src/completions/"
mkdir -p "$src/agents"; cp "$AGENT_FILE" "$src/agents/claude.sh"

export HOME="$work/ihome"; mkdir -p "$HOME"
out="$( PATH="$bin" bash "$src/install" --here 2>&1 </dev/null )"; rc=$?
eq "0" "$rc" "install --here from a source tree exits 0"
if [[ -f "$HOME/.augur/agents/claude.sh" ]] && cmp -s "$AGENT_FILE" "$HOME/.augur/agents/claude.sh"
then ok "install --here copies agents/claude.sh into ~/.augur/agents/"
else fail "install --here copies agents/claude.sh into ~/.augur/agents/" "$out"; fi
# Always refreshed: a stale or hand-edited installed copy is overwritten.
echo '# stale' > "$HOME/.augur/agents/claude.sh"
PATH="$bin" bash "$src/install" --here >/dev/null 2>&1 </dev/null
if cmp -s "$AGENT_FILE" "$HOME/.augur/agents/claude.sh"; then ok "a re-install overwrites an edited agent file"
else fail "a re-install overwrites an edited agent file" "installed copy still differs"; fi
# The installed pair works together.
out="$( cd "$work" && PATH="$HERE/shims:$PATH" bash "$HOME/.augur/augur" version 2>&1 </dev/null )"; rc=$?
eq "0" "$rc" "the installed augur runs with the installed agent file"

# A source tree without the file is refused before anything is copied.
rm -rf "$src/agents"; export HOME="$work/ihome2"; mkdir -p "$HOME"
out="$( PATH="$bin" bash "$src/install" --here 2>&1 </dev/null )"; rc=$?
if [[ "$rc" -ne 0 ]]; then ok "install refuses a source tree without agents/claude.sh"
else fail "install refuses a source tree without agents/claude.sh" "exited 0"; fi
has "$out" "agents/claude.sh not found" "install names the missing agent file"
if [[ ! -e "$HOME/.augur/augur" ]]; then ok "install copied nothing from the incomplete tree"
else fail "install copied nothing from the incomplete tree" "~/.augur/augur exists"; fi

# ── (d) the file is outside every guest-mounted host path ─────────────────────
section "Tier 0 — agents/ is not under any directory mounted or shared into a guest"
AGENT_DIR_NAME="agents"
# The per-project / host-global dirs the guest can see, by the names the seam gives them.
source "$AGENT_FILE"
guest_dirs=("$(agent_state_host_subdir)" "$(agent_state_agents_host_subdir)" "$(agent_state_carryover_host_subdir)" "$(agent_profile_host_subdir)")
for d in "${guest_dirs[@]}"; do
  if [[ "$d" != "$AGENT_DIR_NAME" && "$d" != "$AGENT_DIR_NAME"/* && "$AGENT_DIR_NAME" != "$d"/* ]]
  then ok "agents/ is not the guest-mounted dir '$d' nor nested in it"
  else fail "agents/ collides with the guest-mounted dir '$d'" "$AGENT_DIR_NAME vs $d"; fi
done
# Every container -v source and macOS --dir share in augur, by its host path expression.
mounts="$(grep -E -- '-v "[^"]*:|--dir="' "$AUGUR" | grep -v '^[[:space:]]*#' || true)"
(( $(printf '%s\n' "$mounts" | grep -c .) >= 6 )) || fail "the mount scan found the -v / --dir lines" "$mounts"
bad="$(printf '%s\n' "$mounts" | grep -E 'SCRIPT_DIR|AGENT_DEFINITION_FILE|/agents[/:"}]|AUGUR_DIR\}?"?:|\$AUGUR_DIR"?:' || true)"
# agent_state_agents_host_subdir lines legitimately say "agents" inside a function name; the
# patterns above only match a literal path segment, so anything left is a real overlap.
eq "" "$bad" "no -v / --dir mount source is SCRIPT_DIR, the install root, or agents/"

finish
