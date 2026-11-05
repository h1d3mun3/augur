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

# An incomplete definition (truncated, stale, hand-edited, version-skewed) is refused just the same:
# every entry path stops with a clear message and the engine is never touched.
section "Tier 0 — augur refuses an incomplete agent definition"
mk_variant() {  # mk_variant NAME SED-EXPR: a copy of augur whose agent file is edited by SED-EXPR
  mkdir -p "$work/$1/agents"; cp "$AUGUR" "$work/$1/augur"
  sed -e "$2" "$AGENT_FILE" > "$work/$1/agents/claude.sh"
}
mk_variant no_fixed_env  '/^agent_fixed_env()/d'
mk_variant no_token_hint '/^agent_token_hint()/d'
mk_variant empty_team    's/^agent_macos_signing_team().*/agent_macos_signing_team() { echo ""; }/'
mk_variant empty_url     's/^agent_installer_url().*/agent_installer_url() { printf ""; }/'
mk_variant empty_cli     's/^agent_cli_name().*/agent_cli_name() { :; }/'
mk_variant truncated     '/^agent_state_/,$d'
for variant in no_fixed_env no_token_hint empty_team empty_url empty_cli truncated; do
  for cmd in version help __names status "up --no-egress"; do
    rm -f "$AUGUR_TEST_SHIMLOG.trace"
    # shellcheck disable=SC2086  # $cmd is a word list on purpose
    out="$( cd "$work" && PATH="$HERE/shims:$PATH" bash "$work/$variant/augur" $cmd 2>&1 </dev/null )"; rc=$?
    if [[ "$rc" -ne 0 ]]; then ok "$variant: '$cmd' exits non-zero ($rc)"
    else fail "$variant: '$cmd' exits non-zero" "exited 0"; fi
    has "$out" "incomplete agent definition" "$variant: '$cmd' says the definition is incomplete"
    has "$out" "bash install" "$variant: '$cmd' tells the operator to re-run bash install"
    if [[ ! -s "$AUGUR_TEST_SHIMLOG.trace" ]]; then ok "$variant: '$cmd' never touched the engine"
    else fail "$variant: '$cmd' never touched the engine" "$(cat "$AUGUR_TEST_SHIMLOG.trace")"; fi
  done
  out="$( cd "$work" && AUGUR_SOURCE_ONLY=1 bash -c 'source "$1" 2>/dev/null; echo REACHED' _ "$work/$variant/augur" 2>&1 )"; rc=$?
  hasnt "$out" "REACHED" "$variant: nothing runs after a failed source of augur"
done
# The unmodified file passes the same loader.
out="$( cd "$work" && AUGUR_SOURCE_ONLY=1 bash -c 'source "$1"; echo REACHED' _ "$work/present/augur" 2>&1 )"
has "$out" "REACHED" "the complete agent file loads"

# ── (b) every accessor augur calls is defined by the file ─────────────────────
section "Tier 0 — agents/claude.sh defines every agent_* accessor augur calls"
# Every agent_* word on a non-comment line of augur outside the loader's own required-accessor list,
# minus the ones augur defines itself and the plain variables (assigned or declared local) that
# merely share the prefix.
code="$(grep -v '^[[:space:]]*#' "$AUGUR" | awk '/^AGENT_REQUIRED_ACCESSORS=\(/{skip=1} !skip{print} skip&&/^\)/{skip=0}')"
mapfile -t called < <(printf '%s\n' "$code" | grep -oE '\bagent_[a-z0-9_]*[a-z0-9]' | sort -u)
missing=0; n=0; derived=()
for name in "${called[@]}"; do
  grep -qE "^${name}\(\)" <<<"$code" && continue
  grep -qE "(^|[[:space:]])${name}=|local[^#]*[[:space:]]${name}([[:space:]]|\$)" <<<"$code" && continue
  derived+=("$name")
  n=$((n+1))
  if grep -qE "^${name}\(\)" "$AGENT_FILE"; then :; else missing=1; fail "agents/claude.sh defines $name" "augur calls it, the file does not define it"; fi
done
(( n >= 25 )) || fail "the call-site scan found the accessors" "only $n found; the scan is broken"
(( missing )) || ok "all $n accessors augur calls are defined by agents/claude.sh"
# The loader's required list is exactly the called set, so it cannot drift from the call sites: a new
# call without a list entry, or a list entry nothing calls, both fail here.
mapfile -t required < <(AUGUR_SOURCE_ONLY=1 bash -c 'source "$1" && printf "%s\n" "${AGENT_REQUIRED_ACCESSORS[@]}"' _ "$AUGUR" | sort -u)
eq "$(printf '%s\n' "${derived[@]}")" "$(printf '%s\n' "${required[@]}")" "the loader's AGENT_REQUIRED_ACCESSORS equals the accessors augur calls"
# Every accessor the file defines is one augur requires (no dead or unchecked ones).
mapfile -t defined < <(grep -oE '^agent_[a-z0-9_]+\(\)' "$AGENT_FILE" | tr -d '()' | sort -u)
eq "$(printf '%s\n' "${defined[@]}")" "$(printf '%s\n' "${required[@]}")" "the agent file defines exactly the required accessors"

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
# `mv` is a recording wrapper: it logs each destination, so the order install puts files in place
# is observable.
mvlog="$work/mvlog"
printf '#!/bin/bash\nprintf "%%s\\n" "${@: -1}" >> "%s"\nexec "%s" "$@"\n' "$mvlog" "$(command -v mv)" > "$bin/mv"
chmod +x "$bin/mv"

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
# The agent definition lands before augur does, so an interrupted install never leaves a new augur
# beside an old or missing definition; both arrive by rename, leaving no temporary file behind.
agent_pos="$(grep -n "/agents/claude.sh$" "$mvlog" | head -1 | cut -d: -f1)"
augur_pos="$(grep -n "/\.augur/augur$" "$mvlog" | head -1 | cut -d: -f1)"
if [[ -n "$agent_pos" && -n "$augur_pos" && "$agent_pos" -lt "$augur_pos" ]]; then ok "install puts agents/claude.sh in place before augur"
else fail "install puts agents/claude.sh in place before augur" "agent at ${agent_pos:-none}, augur at ${augur_pos:-none}: $(cat "$mvlog")"; fi
leftover="$(find "$HOME/.augur" -name '*.new' 2>/dev/null)"
eq "" "$leftover" "install leaves no temporary file behind"
if [[ -x "$HOME/.augur/augur" ]]; then ok "the installed augur is executable"; else fail "the installed augur is executable" "mode bits lost"; fi

# ── augur run through a symlink: SCRIPT_DIR is the real install dir ──────────
section "Tier 1 — a symlink to the installed augur works from any directory"
mkdir -p "$work/linkbin" "$work/elsewhere2"
ln -s "$HOME/.augur/augur" "$work/linkbin/augur"
out="$( cd "$work/elsewhere2" && PATH="$HERE/shims:$PATH" bash "$work/linkbin/augur" version 2>&1 </dev/null )"; rc=$?
eq "0" "$rc" "augur run via an absolute symlink exits 0"
# A relative symlink, and a link to a link.
ln -s "../linkbin/augur" "$work/elsewhere2/rel-augur"
out2="$( cd "$work" && PATH="$HERE/shims:$PATH" bash "$work/elsewhere2/rel-augur" version 2>&1 </dev/null )"; rc=$?
eq "0" "$rc" "augur run via a relative link to a link exits 0"
eq "$out" "$out2" "both links report the same version as the install"
# It finds the agent file next to the real script, not next to the link.
out="$( cd "$work/elsewhere2" && AUGUR_SOURCE_ONLY=1 bash -c 'source "$1"; echo "$SCRIPT_DIR"' _ "$work/linkbin/augur" 2>&1 )"
eq "$HOME/.augur" "$out" "SCRIPT_DIR is the real install directory"
# A link to an install with no agents/ names the REAL path it looked in.
ln -s "$work/noagent/augur" "$work/linkbin/augur-noagent"
out="$( cd "$work/elsewhere2" && PATH="$HERE/shims:$PATH" bash "$work/linkbin/augur-noagent" version 2>&1 </dev/null )"; rc=$?
if [[ "$rc" -ne 0 ]]; then ok "a link to an install without agents/ fails"; else fail "a link to an install without agents/ fails" "exited 0"; fi
has "$out" "$work/noagent/agents/claude.sh" "…and names the real path it looked for"
# A dangling link fails with a clear message and touches nothing.
ln -s "$work/does-not-exist/augur" "$work/linkbin/augur-dangling"
rm -f "$AUGUR_TEST_SHIMLOG.trace"
out="$( cd "$work/elsewhere2" && PATH="$HERE/shims:$PATH" bash "$work/linkbin/augur-dangling" version 2>&1 </dev/null )"; rc=$?
if [[ "$rc" -ne 0 ]]; then ok "a dangling symlink fails ($rc)"; else fail "a dangling symlink fails" "exited 0"; fi
has "$out" "No such file" "a dangling symlink says what is wrong"
# A link loop does not hang the loader (bash itself refuses to open it).
ln -s "$work/linkbin/loop-b" "$work/linkbin/loop-a"; ln -s "$work/linkbin/loop-a" "$work/linkbin/loop-b"
out="$( cd "$work/elsewhere2" && timeout 10 bash "$work/linkbin/loop-a" version 2>&1 </dev/null )"; rc=$?
if [[ "$rc" -ne 0 && "$rc" -ne 124 ]]; then ok "a symlink loop fails fast"; else fail "a symlink loop fails fast" "rc=$rc"; fi

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

# The text scan above cannot see a mount built from a variable, so the real argv is checked too:
# every guest-visible host path must be the workspace itself or a strict child of one of the
# per-project / profile subdirs, and never the install root, SCRIPT_DIR, agents/, or a parent of
# any of them. Run for the installed layout (SCRIPT_DIR is the install root) and a checkout layout.
section "Tier 1 — constructed mounts never expose the install dir or agents/ (behavioral)"
# check_mount_sources LABEL AUGUR_DIR SCRIPT_DIR WORKSPACE SOURCE...
check_mount_sources() {
  local label="$1" adir="$2" sdir="$3" ws="$4" s r sub known bad=0; shift 4
  local -a subs=("$(agent_state_host_subdir)" "$(agent_state_agents_host_subdir)" "$(agent_state_carryover_host_subdir)" "$(agent_profile_host_subdir)")
  (( $# >= 3 )) || { fail "$label: mount sources were captured" "only $# found"; return; }
  for s in "$@"; do
    for r in "$adir" "$sdir" "$sdir/agents"; do
      if [[ "$s" == "$r" || "$r" == "$s"/* ]]; then fail "$label: '$s' is not the install dir or a parent of it" "matches $r"; bad=1; fi
    done
    [[ "$s" == "$sdir/agents" || "$s" == "$sdir/agents"/* ]] && { fail "$label: '$s' is outside agents/" "inside $sdir/agents"; bad=1; }
    [[ "$s" == "$ws" ]] && continue
    known=0
    for sub in "${subs[@]}"; do [[ "$s" == "$adir/$sub"/* || "$s" == "$adir/$sub" ]] && known=1; done
    (( known )) || { fail "$label: '$s' is the workspace or under a known state subdir" "unknown host path"; bad=1; }
  done
  (( bad )) || ok "$label: all $# guest-visible host paths are the workspace or per-project state"
}
dproj="$work/dproj"; mkdir -p "$dproj"
for layout in installed checkout; do
  export HOME="$work/dhome-$layout"; rm -rf "$HOME"; mkdir -p "$HOME/.augur/agents"
  if [[ "$layout" == installed ]]; then sdir="$HOME/.augur"; else sdir="$work/co-$layout"; mkdir -p "$sdir/agents"; fi
  cp "$AUGUR" "$sdir/augur"; cp "$AGENT_FILE" "$sdir/agents/claude.sh"
  rm -f "$AUGUR_TEST_SHIMLOG.run"
  ( cd "$dproj" && AUGUR_TEST_CONTAINER_RUNNING=0 PATH="$HERE/shims:$PATH" bash "$sdir/augur" up --no-egress ) >/dev/null 2>&1 </dev/null
  srcs=(); prev=""
  if [[ -f "$AUGUR_TEST_SHIMLOG.run" ]]; then
    while IFS= read -r a; do
      if [[ "$prev" == "-v" ]]; then srcs+=("${a%%:*}"); fi
      prev="$a"
    done < "$AUGUR_TEST_SHIMLOG.run"
  fi
  check_mount_sources "container ($layout layout) -v" "$HOME/.augur" "$sdir" "$dproj" "${srcs[@]+"${srcs[@]}"}"
done
unset prev

# macOS: cmd_up_macos is not driven end to end here (it clones and boots a VM), so its --dir= shares
# are taken from the real source lines and expanded with the real accessors and a sample VM name.
dirlines="$(awk '/^cmd_up_macos\(\)/{f=1} f&&/--dir="/{print} f&&/^}/{exit}' "$AUGUR" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*\\$//')"
specs="$(HOME="$work/dhome-installed" AUGUR_SOURCE_ONLY=1 bash -c 'source "$1"; set +e; project_vm=augur-dproj-0123456789ab; MACOS_SHARE=workspace-dproj; WORKSPACE_DIR="$2"; while IFS= read -r l; do eval "printf \"%s\\n\" $l"; done <<<"$3"' _ "$AUGUR" "$dproj" "$dirlines" 2>&1)"
srcs=()
while IFS= read -r a; do
  [[ "$a" == --dir=* ]] || continue
  a="${a#--dir=}"; a="${a#*:}"; srcs+=("${a%:ro}")
done <<<"$specs"
check_mount_sources "macOS --dir" "$work/dhome-installed/.augur" "$work/dhome-installed/.augur" "$dproj" "${srcs[@]+"${srcs[@]}"}"

finish
