#!/usr/bin/env bash
# Tier 1 (live, real binary) — host proxy per-mode bind + teardown isolation, end-to-end
# against the REAL augur-proxy. This is the automated counterpart to the pure/mock checks in
# 32_proxy_per_mode.sh: it launches the actual proxy binary for BOTH roles on two addresses
# and proves, with real TCP connects, that (a) the two instances coexist on the SAME ports but
# different addresses, and (b) `down` in one mode leaves the other's proxy listening.
#
# Needs the augur-proxy binary (built by `make unit`/`bash install`) and two bindable loopback
# addresses. Self-skips cleanly when either is unavailable (e.g. macOS, where 127.0.0.2 is not a
# default lo0 alias — that path is covered by the real VM+container `make e2e` gate instead).
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/lib.sh"
AUGUR="$REPO/augur"
section "Tier 1 — real augur-proxy per-mode bind + teardown isolation"

AUGUR_SOURCE_ONLY=1 source "$AUGUR"
set +e                                    # augur enables `set -e`; restore lib.sh assert-and-continue

# Resolve the real proxy binary via augur's own logic; skip if it isn't built. Require a real
# executable FILE (or a PATH command) — resolve_proxy_cli falls back to the bare name "augur-proxy",
# and a plain `-x` test would match the repo's augur-proxy/ DIRECTORY (dirs are searchable), so an
# unbuilt binary would look present and start_proxy would then fail instead of skipping.
bin="$(resolve_proxy_cli)"
if ! command -v "$bin" >/dev/null 2>&1 && [[ ! -f "$bin" || ! -x "$bin" ]]; then
  skip "real-proxy bind isolation" "augur-proxy not built (run: bash install, or make unit)"; finish; exit $?
fi
# The binary exists and is +x, but that does not mean it can run HERE: a stale cross-arch build
# (e.g. a macOS Mach-O left in .build/release on a Linux host) passes the -f/-x test yet fails to
# exec. Running it would make start_proxy fail-closed (`exit 1`) and, because we call start_proxy
# with output redirected, take this whole script down with no diagnostic. Probe that it actually
# runs on THIS host (`--help` exits 0 before any bind) and self-skip if it cannot — the same
# "skip cleanly when the proxy isn't usable here" contract as the build check above.
if ! "$bin" --help >/dev/null 2>&1; then
  skip "real-proxy bind isolation" "resolved augur-proxy ($bin) is not runnable on this host (stale or cross-arch build?)"; finish; exit $?
fi

ADDR_A="127.0.0.1"                         # stands in for macOS VM mode's loopback bind
ADDR_B="${AUGUR_TEST_ADDR_B:-127.0.0.2}"   # stands in for Apple Container mode's gateway bind
# ADDR_B must be independently bindable, else we can't tell "fix regressed" from "OS can't bind it".
# On Linux all of 127.0.0.0/8 is loopback; on macOS 127.0.0.2 needs an explicit lo0 alias.
if [[ "$(uname -s)" != "Linux" && "${AUGUR_TEST_ADDR_B:-}" == "" ]]; then
  skip "real-proxy bind isolation" "second loopback addr ($ADDR_B) not guaranteed off Linux — covered by 'make e2e'"; finish; exit $?
fi

TMPD="$(mktemp -d)"
probe() { (exec 3<>"/dev/tcp/$1/$2") 2>/dev/null && { exec 3>&-; return 0; } || return 1; }
cleanup() {
  MACOS_MODE=true  AUGUR_PROXY_DIR="$TMPD" stop_proxy >/dev/null 2>&1
  MACOS_MODE=false AUGUR_PROXY_DIR="$TMPD" stop_proxy >/dev/null 2>&1
  pkill -f "$TMPD" 2>/dev/null; rm -rf "$TMPD"
}
trap cleanup EXIT

# Isolate all proxy state under TMPD, and give write_merged_allowlist a real source to merge.
AUGUR_PROXY_DIR="$TMPD"
AUGUR_BASELINE_CONF="$TMPD/baseline.conf"; echo "example.com" > "$AUGUR_BASELINE_CONF"
AUGUR_GLOBAL_CONF="$TMPD/global.conf"; AUGUR_PROJECT_CONF="$TMPD/project.conf"
port="$AUGUR_PROXY_SOCKS_PORT"             # both roles share this port; only the address differs

# ── Bring up the macOS-role proxy (addr A) ────────────────────────────────────────────────────
MACOS_MODE=true
# Run start_proxy in a subshell: it fails closed with `exit 1` if the proxy never binds, which
# would otherwise terminate this whole test with no `fail` line. The subshell turns that into a
# non-zero status the `if` can report (the proxy is backgrounded + disowned, so it survives the
# subshell exiting and proxy_running still sees its pidfile).
if ( start_proxy "$ADDR_A" ) >/dev/null 2>&1 && proxy_running && probe "$ADDR_A" "$port"; then
  ok "macOS-role proxy listening on ${ADDR_A}:${port}"
else
  fail "macOS-role proxy did not come up on ${ADDR_A}:${port}"; finish; exit $?
fi

# ── Bring up the container-role proxy (addr B), SAME ports, different address ──────────────────
MACOS_MODE=false
( start_proxy "$ADDR_B" ) >/dev/null 2>&1     # subshell-contained (see the ADDR_A call above)
if ! proxy_running || ! probe "$ADDR_B" "$port"; then
  # On Linux this is a real failure (the fix must start a second, separate instance). Elsewhere the
  # address may simply be unbindable — but we already gated non-Linux above, so treat it as a fail.
  fail "container-role proxy did not come up on ${ADDR_B}:${port}" \
       "under the pre-fix (slug-only) code the second 'up' reuses the first's proxy — nothing binds ${ADDR_B}"
  finish; exit $?
fi
ok "container-role proxy listening on ${ADDR_B}:${port} (same port, different address)"

# ── Coexistence: BOTH bound at once (proves the bind-address mismatch is fixed) ────────────────
if probe "$ADDR_A" "$port" && probe "$ADDR_B" "$port"; then
  ok "both mode proxies bound simultaneously on ${port} (${ADDR_A} and ${ADDR_B})"
else
  fail "the two mode proxies do not coexist" "one clobbered the other — bind-mismatch not fixed"
fi

# ── Teardown isolation: down the macOS-role proxy; the container-role one must survive ─────────
MACOS_MODE=true; stop_proxy >/dev/null 2>&1
if probe "$ADDR_A" "$port"; then
  fail "down --macos did not stop the macOS-role proxy (${ADDR_A}:${port} still listening)"
else
  ok "down --macos stopped the macOS-role proxy (${ADDR_A}:${port} closed)"
fi
if probe "$ADDR_B" "$port"; then
  ok "the container-role proxy SURVIVED 'down --macos' (${ADDR_B}:${port} still listening)"
else
  fail "'down --macos' killed the container-role proxy" "this is the exact shared-proxy bug"
fi

# ── Symmetric: downing the container-role proxy closes its socket ─────────────────────────────
MACOS_MODE=false; stop_proxy >/dev/null 2>&1
if probe "$ADDR_B" "$port"; then
  fail "down (container) did not stop the container-role proxy"
else
  ok "down (container) stopped the container-role proxy (${ADDR_B}:${port} closed)"
fi

finish
