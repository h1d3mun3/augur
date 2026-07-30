#!/usr/bin/env bash
# Tier 1 — per-mode host proxy identity (runs anywhere; no container/VM host needed).
# Guards the fix for the shared-proxy bug: with BOTH Apple Container mode and macOS VM mode
# up for the same project, they used to share ONE host augur-proxy (keyed only on the project
# slug). The second `up` reused the first's proxy — bound to the wrong address, so its egress
# silently failed closed — and a `down` in either mode killed the shared proxy out from under
# the other. The proxy is now keyed on (project PATH, role), so each mode of each project owns a
# separate instance: the second half of that key was added later, when the same class of sharing
# turned out to span PROJECTS too (~/work/app vs ~/archive/app share a basename, so they shared
# every basename-derived host-state name — see the per-path section below).
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/lib.sh"
AUGUR="$REPO/augur"

# Pull the real proxy helpers out of augur without running its dispatch tail (AUGUR_SOURCE_ONLY
# seam), so this can never drift from the shipped functions.
AUGUR_SOURCE_ONLY=1 source "$AUGUR"
set +e                                    # augur enables `set -e`; restore lib.sh assert-and-continue
TMPD="$(mktemp -d)"
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$TMPD"' EXIT
AUGUR_PROXY_DIR="$TMPD"                    # keep the test off the real ~/.augur/proxy
# …and off the real ~/.augur, now that a per-project file lives directly under it
# (project_settings_file). Every other path captured below is under AUGUR_PROXY_DIR, so this
# affects nothing else. It is a path COMPUTATION either way — project_settings_file deliberately
# has no `mkdir -p`, unlike project_conf_hash_file — but a test must not depend on that.
AUGUR_DIR="$TMPD/augur"

section "Tier 1 — proxy identity is per (project, role)"

MACOS_MODE=true;  m_role="$(proxy_role)"; m_pid="$(proxy_pidfile)"; m_log="$(proxy_logfile)"; m_al="$(proxy_allowlist)"
MACOS_MODE=false; c_role="$(proxy_role)"; c_pid="$(proxy_pidfile)"; c_log="$(proxy_logfile)"; c_al="$(proxy_allowlist)"

eq "macos"     "$m_role" "proxy_role is 'macos' in macOS VM mode"
eq "container" "$c_role" "proxy_role is 'container' otherwise"
if [[ "$m_pid" != "$c_pid" ]]; then ok "pidfile differs by role"; else fail "pidfile must differ by role" "both = $m_pid"; fi
if [[ "$m_log" != "$c_log" ]]; then ok "logfile differs by role"; else fail "logfile must differ by role" "both = $m_log"; fi
eq "$m_al" "$c_al" "allowlist path is shared (same merged content, role-independent)"

section "Tier 1 — start-time isolation: one mode's proxy is invisible to the other"

# Stand-in for a running macOS-mode proxy.
sleep 60 & macos_proc=$!
MACOS_MODE=true; echo "$macos_proc" > "$(proxy_pidfile)"
if proxy_running; then ok "macOS proxy shows running in macOS mode"; else fail "macOS proxy should show running in macOS mode"; fi
# In container mode, that same proxy must NOT look 'running' — otherwise start_proxy would
# reuse it (bound to 127.0.0.1) instead of starting the container's own (bound to the gateway).
MACOS_MODE=false
if proxy_running; then fail "container mode must NOT see the macOS proxy (would reuse the wrong bind)"; else ok "container mode does not see the macOS proxy (starts its own)"; fi

section "Tier 1 — teardown isolation: down in one mode leaves the other's proxy alive"

# Both modes' proxies up for the same project.
sleep 60 & container_proc=$!
MACOS_MODE=false; echo "$container_proc" > "$(proxy_pidfile)"; c_pidfile="$(proxy_pidfile)"
# `augur down --macos` → stop_proxy in the macOS role.
MACOS_MODE=true; stop_proxy >/dev/null 2>&1
if kill -0 "$macos_proc" 2>/dev/null; then fail "down --macos should stop the macOS proxy"; else ok "down --macos stopped the macOS proxy"; fi
if kill -0 "$container_proc" 2>/dev/null && [[ -f "$c_pidfile" ]]; then
  ok "the container proxy (and its pidfile) survived 'augur down --macos'"
else
  fail "down --macos killed the container proxy" "this is the exact shared-proxy bug"
fi

# Symmetric: `augur down` (container) leaves a running macOS proxy alone.
sleep 60 & macos_proc2=$!
MACOS_MODE=true; echo "$macos_proc2" > "$(proxy_pidfile)"; m_pidfile="$(proxy_pidfile)"
MACOS_MODE=false; stop_proxy >/dev/null 2>&1
if kill -0 "$container_proc" 2>/dev/null; then fail "down (container) should stop the container proxy"; else ok "down (container) stopped the container proxy"; fi
if kill -0 "$macos_proc2" 2>/dev/null && [[ -f "$m_pidfile" ]]; then
  ok "the macOS proxy (and its pidfile) survived 'augur down' (container)"
else
  fail "down (container) killed the macOS proxy"
fi

section "Tier 1 — host state is per (project PATH, role): two same-basename projects share nothing"

# ~/work/myapp and ~/archive/myapp sanitize to the SAME workspace_slug, so a slug-only key made
# them share every egress host-state name: the merged allowlist augur-proxy enforces (project B's
# `up` overwrote project A's live policy), the proxy/gvproxy pidfiles (B's `up` "found" A's proxy
# already running and reused it), the vfkit socket, and the logs. workspace_path_hash is what
# separates them now — and the slug assertion below is what proves the hash is doing that work
# rather than an incidental difference in the directory names.
#
# THE LIST BELOW IS HARD-CODED, so a new per-project host-state file that is not added to it has
# NOTHING pinning its keying. That is not hypothetical: the 2026-07-28 audit found exactly that gap
# for the share-refresher pid/logfile, which this change closes here along with adding its own file.
# Three of the entries are NOT egress state — refresher_pid, refresher_log and settings — which is
# why the "stays under AUGUR_PROXY_DIR" loop further down no longer covers all of them: the settings
# file lives one level up, directly under ~/.augur. The property that matters for it is the same one
# (I7: written host-side, OUTSIDE the project tree) and it is asserted separately, against $AUGUR_DIR
# and against the workspace.
ORIG_WS="$WORKSPACE_DIR"
mkdir -p "$TMPD/work/myapp" "$TMPD/archive/myapp"
# Every per-project path this file owns, captured for one project at a time. Ports are NOT here:
# they are computed at SOURCE time, so they need a separate re-source (next section).
capture_paths() {   # $1 = workspace dir → prints "<name>=<path>" lines
  WORKSPACE_DIR="$1"
  local r
  echo "slug=$(workspace_slug)"
  echo "allowlist=$(proxy_allowlist)"
  echo "gvproxy_pid=$(gvproxy_pidfile)"
  echo "gvproxy_log=$(gvproxy_log)"
  echo "vm_log=$(macos_vm_log)"
  echo "socket=$(gvproxy_socket)"
  echo "network=$(egress_network_name)"
  # The share refresher (ADR-0016). Not egress state, and the 2026-07-28 audit recorded that as the
  # reason it was missing here — a refresher pointed at the wrong project's marker would sweep one
  # project's shares against another's timestamp.
  echo "refresher_pid=$(share_refresher_pidfile)"
  echo "refresher_log=$(share_refresher_logfile)"
  # …and the per-project SETTINGS file (`augur config`). Host-side under ~/.augur rather than in the
  # workspace, because the guest can write the workspace and a guest that can set its own
  # share_refresh can switch off the mechanism that keeps the operator's view of it honest. A
  # slug-only key here would hand one project's refresh mode to an unrelated same-basename sibling.
  echo "settings=$(project_settings_file)"
  for r in true false; do
    MACOS_MODE=$r
    echo "proxy_pid_$(proxy_role)=$(proxy_pidfile)"
    echo "proxy_log_$(proxy_role)=$(proxy_logfile)"
  done
}
a_paths="$(capture_paths "$TMPD/work/myapp")"
b_paths="$(capture_paths "$TMPD/archive/myapp")"
WORKSPACE_DIR="$ORIG_WS"; MACOS_MODE=false

field() { echo "$2" | sed -n "s/^$1=//p"; }   # $1 = name, $2 = a capture block

eq "$(field slug "$a_paths")" "$(field slug "$b_paths")" \
   "both projects produce the IDENTICAL slug (so the path hash is provably the disambiguator)"
eq "myapp" "$(field slug "$a_paths")" "…and that shared slug is the basename, as before"

for f in allowlist proxy_pid_macos proxy_pid_container proxy_log_macos proxy_log_container \
         gvproxy_pid gvproxy_log vm_log socket network refresher_pid refresher_log settings; do
  av="$(field "$f" "$a_paths")"; bv="$(field "$f" "$b_paths")"
  if [[ -n "$av" && "$av" != "$bv" ]]; then ok "$f differs between the two projects"
  else fail "$f must differ between the two projects" "both = [$av]"; fi
done
# Nothing escaped the host-side proxy dir while gaining the hash (I7: outside the project tree).
for f in allowlist proxy_pid_macos proxy_pid_container proxy_log_macos proxy_log_container \
         gvproxy_pid gvproxy_log vm_log socket refresher_pid refresher_log; do
  has "$(field "$f" "$a_paths")" "$AUGUR_PROXY_DIR/" "$f stays under AUGUR_PROXY_DIR"
done
# The settings file is the one entry that is NOT under AUGUR_PROXY_DIR — it is not egress state and
# not proxy state, so it lives directly under ~/.augur beside project-hashes/. The I7 property it has
# to satisfy is the substantive half of the loop above, and it is the whole reason the file is where
# it is: written host-side, OUTSIDE the project tree, so the read-write share the guest owns cannot
# reach it.
_set_a="$(field settings "$a_paths")"
has   "$_set_a" "$AUGUR_DIR/project-settings/" "settings stays under ~/.augur/project-settings"
hasnt "$_set_a" "$TMPD/work/myapp"             "settings is OUTSIDE the project tree (the guest-writable share)"
# …and outside the OTHER project's tree too. The arm above only proves it is not under the workspace
# it was computed for; a path built from `$WORKSPACE_DIR/.augur/…` would satisfy that for project B
# while still being guest-writable. An earlier cut asserted `hasnt "$_set_a" "/.augur/allowlist"`
# here, which no mutation of project_settings_file could ever make true — it pinned nothing.
hasnt "$(field settings "$b_paths")" "$TMPD/archive/myapp" "…for the second project as well, not just the one it was derived from"
# The `.augur` in this path is ~/.augur, NOT the project's own ./.augur/ — the distinction the whole
# location argument rests on. Asserted as a prefix of the absolute path, which a project-relative
# `./.augur/…` cannot satisfy.
case "$_set_a" in
  "$HOME"/*) fail "settings must not be under the caller's real \$HOME in this fixture" "$_set_a" ;;
  "$AUGUR_DIR"/*) ok "…and the \`.augur\` it sits in is the HOST's ~/.augur, not the project's ./.augur/" ;;
  *) fail "settings is under \$AUGUR_DIR" "$_set_a" ;;
esac

section "Tier 1 — the egress PORTS and subnet are per project path too"

# The ports and the internal subnet come from _augur_port_offset, a TOP-LEVEL assignment evaluated
# when augur is SOURCED — not a function — so re-reading them after reassigning WORKSPACE_DIR in
# this shell would just re-read the offset computed for the test's own cwd. Each project needs its
# own `bash -c` (a fresh process: none of these vars is exported, so nothing leaks in from here).
#
# They must move WITH the pidfile keying, not after it: hash-keyed pidfiles plus shared ports means
# project B's start_proxy no longer sees A's proxy, launches its own, and augur-proxy dies on the
# listen error for A's already-bound gateway:port — turning silent sharing into a hard failure.
port_env() {   # $1 = workspace dir → "http socks ssh subnet"
  bash -c 'cd "$1" && AUGUR_SOURCE_ONLY=1 source "$2" >/dev/null 2>&1
           echo "$AUGUR_PROXY_HTTP_PORT $AUGUR_PROXY_SOCKS_PORT $AUGUR_SSH_FWD_PORT $AUGUR_INTERNAL_SUBNET"' \
       _ "$1" "$AUGUR"
}
read -r a_http a_socks a_ssh a_subnet <<<"$(port_env "$TMPD/work/myapp")"
read -r b_http b_socks b_ssh b_subnet <<<"$(port_env "$TMPD/archive/myapp")"
[[ -n "$a_http" && -n "$b_http" ]] && ok "re-sourcing augur per directory yields the ports" \
  || fail "re-sourcing augur per directory yields the ports" "got [$a_http] and [$b_http]"
for p in http socks ssh subnet; do
  av="a_$p"; bv="b_$p"
  if [[ "${!av}" != "${!bv}" ]]; then ok "AUGUR_*_${p} differs between the two projects"
  else fail "AUGUR_*_${p} must differ between the two projects" "both = [${!av}]"; fi
done
# Same directory twice ⇒ same ports: the offset must stay STABLE per path, or every `up` would
# flip container_fingerprint's wiring digest and recreate the container.
read -r a2_http _ <<<"$(port_env "$TMPD/work/myapp")"
eq "$a_http" "$a2_http" "the offset is stable for a given path (no fingerprint churn on every up)"

section "Tier 1 — the vfkit socket stays inside macOS's 103-byte sun_path budget"

# gvproxy_socket is the ONE per-project name whose slug is truncated (24 chars): it is a unix
# socket, so it has a 103-byte usable budget where its regular-file neighbours have PATH_MAX.
long_slug_dir="$TMPD/$(printf 'x%.0s' {1..80})"
mkdir -p "$long_slug_dir"
WORKSPACE_DIR="$long_slug_dir"
long_sock="$(gvproxy_socket)"; long_sock_base="${long_sock##*/}"
long_dir_base="${long_slug_dir##*/}"
eq "80" "${#long_dir_base}"                         "the pathological project basename is 80 chars"
eq "48" "${#long_sock_base}"                        "the socket leaf is a fixed 48 bytes (24 slug + 1 + 12 hash + '.vfkit.sock')"
# The neighbours deliberately do NOT truncate — they are regular files under PATH_MAX 1024, and the
# full slug is what makes them readable. stop_gvproxy derives both from helpers, never by name.
long_pid_base="$(gvproxy_pidfile)"; long_pid_base="${long_pid_base##*/}"
if (( ${#long_pid_base} > 48 )); then ok "the gvproxy pidfile keeps the FULL slug (not truncated)"
else fail "the gvproxy pidfile should keep the full slug" "leaf = $long_pid_base"; fi
# Under the real default layout the truncated name fits with room to spare.
real_sock="/Users/admin/.augur/proxy/$long_sock_base"
if (( ${#real_sock} <= AUGUR_SOCKET_MAX_LEN )); then
  ok "the socket path fits sun_path under the default ~/.augur/proxy layout (${#real_sock} ≤ $AUGUR_SOCKET_MAX_LEN)"
else
  fail "the socket path must fit sun_path" "${#real_sock} > $AUGUR_SOCKET_MAX_LEN: $real_sock"
fi
# The residual (a relocated AUGUR_PROXY_DIR, a very long username) must fail LOUDLY, not as
# gvproxy's opaque "did not create its socket in time".
if ( require_socket_path_fits "$real_sock" ) >/dev/null 2>&1; then
  ok "require_socket_path_fits accepts a path within the limit"
else
  fail "require_socket_path_fits rejected a path within the limit"
fi
over="/$(printf 'y%.0s' {1..110}).vfkit.sock"
guard_out="$( ( require_socket_path_fits "$over" ) 2>&1 )"; guard_rc=$?
eq "1" "$guard_rc" "require_socket_path_fits exits 1 on an over-long path"
has "$guard_out" "$AUGUR_SOCKET_MAX_LEN" "…and its message names the byte limit"
has "$guard_out" "$over"                 "…and names the offending path"
WORKSPACE_DIR="$ORIG_WS"

section "Tier 1 — upgrade migration: down reaps a proxy left under the legacy pidfile"

# Simulate a proxy started by a pre-per-role augur: it wrote "<slug>.pid" (no role suffix).
sleep 60 & legacy_proc=$!
legacy_pidfile="$AUGUR_PROXY_DIR/$(workspace_slug).pid"
echo "$legacy_proc" > "$legacy_pidfile"
# Any `down` (either mode) should sweep it so the next same-address `up` doesn't collide.
MACOS_MODE=true; stop_proxy >/dev/null 2>&1
if kill -0 "$legacy_proc" 2>/dev/null; then
  fail "down did not reap the legacy (<slug>.pid) proxy" "would collide on the next up"
else
  ok "down reaps a proxy left under the legacy pre-role pidfile"
fi
[[ -f "$legacy_pidfile" ]] && fail "legacy pidfile not cleaned up" || ok "legacy pidfile removed"

# Second generation: a proxy started by a pre-path-hash augur wrote "<slug>-<role>.pid". It is
# invisible to today's "<slug>-<hash>-<role>.pid", so without this reap it survives every `down`
# and the next same-address `up` collides with it.
sleep 60 & role_legacy_proc=$!
MACOS_MODE=true; role_legacy_pidfile="$AUGUR_PROXY_DIR/$(workspace_slug)-$(proxy_role).pid"
echo "$role_legacy_proc" > "$role_legacy_pidfile"
# The OTHER role's pre-hash pidfile must survive: the migration inherits the per-role split rather
# than undoing it (a `down --macos` still may not kill the container mode's proxy).
sleep 60 & role_legacy_other=$!
MACOS_MODE=false; other_legacy_pidfile="$AUGUR_PROXY_DIR/$(workspace_slug)-$(proxy_role).pid"
echo "$role_legacy_other" > "$other_legacy_pidfile"
MACOS_MODE=true; stop_proxy >/dev/null 2>&1
if kill -0 "$role_legacy_proc" 2>/dev/null; then
  fail "down --macos did not reap the legacy (<slug>-<role>.pid) proxy" "would collide on the next up"
else
  ok "down reaps a proxy left under the legacy pre-path-hash, per-role pidfile"
fi
[[ -f "$role_legacy_pidfile" ]] && fail "legacy per-role pidfile not cleaned up" \
                                || ok "legacy per-role pidfile removed"
if kill -0 "$role_legacy_other" 2>/dev/null && [[ -f "$other_legacy_pidfile" ]]; then
  ok "the OTHER role's legacy pidfile survives (the migration keeps the per-role split)"
else
  fail "down --macos reaped the container role's legacy pidfile" "the per-role split must survive the migration"
fi
rm -f "$other_legacy_pidfile"   # the process itself is reaped by the EXIT trap, like the others

section "Tier 1 — upgrade migration: down --macos reaps a legacy gvproxy and its socket"

# stop_gvproxy had NO migration block at all. gvproxy_running only ever consults the CURRENT
# pidfile, so a gvproxy started by a pre-path-hash augur ("<slug>.gvproxy.pid", holding
# "<slug>.vfkit.sock") was invisible to every augur command — an orphan owning a live vfkit socket
# with nothing that finds it.
sleep 60 & legacy_gvp=$!
legacy_gvp_pidfile="$AUGUR_PROXY_DIR/$(workspace_slug).gvproxy.pid"
legacy_gvp_sock="$AUGUR_PROXY_DIR/$(workspace_slug).vfkit.sock"
echo "$legacy_gvp" > "$legacy_gvp_pidfile"
: > "$legacy_gvp_sock"
MACOS_MODE=true; stop_gvproxy >/dev/null 2>&1
if kill -0 "$legacy_gvp" 2>/dev/null; then
  fail "down --macos did not reap the legacy gvproxy" "orphan gvproxy holding a vfkit socket, unreachable by any command"
else
  ok "down --macos reaps a gvproxy left under the legacy pidfile"
fi
[[ -f "$legacy_gvp_pidfile" ]] && fail "legacy gvproxy pidfile not cleaned up" \
                               || ok "legacy gvproxy pidfile removed"
[[ -e "$legacy_gvp_sock" ]] && fail "legacy vfkit socket not unlinked" \
                                    "start_gvproxy's -S wait would accept this stale file" \
                            || ok "legacy vfkit socket unlinked"

finish
