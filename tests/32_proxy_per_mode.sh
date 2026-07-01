#!/usr/bin/env bash
# Tier 1 — per-mode host proxy identity (runs anywhere; no Docker/VM host needed).
# Guards the fix for the shared-proxy bug: with BOTH Apple Container mode and macOS VM mode
# up for the same project, they used to share ONE host augur-proxy (keyed only on the project
# slug). The second `up` reused the first's proxy — bound to the wrong address, so its egress
# silently failed closed — and a `down` in either mode killed the shared proxy out from under
# the other. The proxy is now keyed on (project slug, role), so each mode owns a separate
# instance. Docker mode uses a sidecar container (not the host proxy) and is unaffected.
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

finish
