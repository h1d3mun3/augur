#!/usr/bin/env bash
# Tier 1 (live) — egress FAIL-CLOSED end-to-end. This is the security-critical layer: it
# brings up a real egress-enabled Apple Container and proves the README's core claim: the
# agent's ONLY way out is the host-side allowlist proxy. Apple Container needs macOS 26+
# (no nested virt on GitHub-hosted runners), so this tier has no free CI home — it is a
# LOCAL gate, run via `make e2e` / `verify_apple_container_host.sh` on real hardware.
#
# Unlike 21 (which runs with --no-egress to smoke the agent), this tier runs with egress
# ON, so `augur up` fires the existing boot self-test (verify_egress_locked in augur). A
# successful `up` therefore already proves: direct egress severed + external DNS closed +
# proxy reachable. On top of that this tier adds the two assertions the boot self-test does
# NOT make — that an ALLOWLISTED domain is reachable through the proxy, and that a
# NON-allowlisted one is actively BLOCKED (403) — and re-asserts the boot guarantees so a
# regression names which property broke.
#
# It runs the full fail-closed assertion set TWICE: once on the freshly-created container,
# and once again after `augur down` (stop, keep) + `augur up` (REUSE via `container start`).
# The reuse pass is the security-critical coverage the offline suite cannot reach: it proves
# the persisted-container reconcile path re-establishes the egress datapath and re-runs the
# boot self-test (INVARIANT I1) on a container that was NOT freshly built from the image.
#
# Run modes:
#   tests/22_egress_failclosed.sh                       # read-only: skips (this tier spins a container)
#   AUGUR_TEST_LIVE=1 tests/22_egress_failclosed.sh     # run live; SKIP if container/image absent
#   AUGUR_TEST_REQUIRE_EGRESS=1 tests/22_egress_failclosed.sh  # run live; FAIL (never skip) if it
#                                                       # cannot run — the security check must fail closed
#
# Prereqs for a live run: Apple Container (macOS 26+), `bash install`, and a built image
# (`augur build`).
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/lib.sh"
section "Tier 1 — egress fail-closed E2E (allowlist proxy is the only way out; fresh AND reuse)"

AUGUR="$REPO/augur"
require="${AUGUR_TEST_REQUIRE_EGRESS:-0}"

# In REQUIRE mode a missing prerequisite is a FAILURE, not a skip: a security guarantee that
# "couldn't be checked" must fail the build, never pass silently. Otherwise it self-skips.
missing() {  # $1 = what, $2 = detail
  if [[ "$require" == "1" ]]; then fail "$1" "$2"; else skip "$1" "$2"; fi
  finish; exit $?
}

engine_ready() { command -v container >/dev/null 2>&1 && container system status >/dev/null 2>&1; }
# Check by the exact tag augur builds (`augur:swift-<tag>`), via `container image inspect` —
# the same canonical existence check augur's own ensure_image uses. (Do NOT grep `container
# image list`: its plain output splits name/tag into separate columns, so the colon-joined
# `augur:swift-` form never appears there.)
image_present() { container image inspect "augur:swift-${SWIFT_VERSION:-latest}" >/dev/null 2>&1; }

# Gate: this tier mutates containers, so a plain `tests/run.sh` never runs it.
if [[ "$require" != "1" && "${AUGUR_TEST_LIVE:-0}" != "1" ]]; then
  skip "egress fail-closed E2E" "set AUGUR_TEST_LIVE=1 (or AUGUR_TEST_REQUIRE_EGRESS=1) to run it"
  finish; exit $?
fi

engine_ready                              || missing "Apple Container is available" "install/start Apple Container (macOS 26+)"
image_present                             || missing "an augur:swift-* image is built" "run 'augur build' first"

# ── Bring up a throwaway project with egress ON ──────────────────────────────
# AUGUR_ACCEPT_PROJECT_CONF=1: accept any project ./.augur/allowlist.conf non-interactively (there is
# none here, but it keeps the run headless). Egress is ON by default (no --no-egress).
proj="$(mktemp -d)"
slug="$(basename "$proj" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]' '-' | sed 's/^-//;s/-$//')"
# = make_container_name in augur: augur-<slug>-<sha256(WORKSPACE_DIR)[:12]>-swift-<tag>. WORKSPACE_DIR="$(pwd)"
# inside the `cd "$proj"` subshell, so hash the project dir the same way workspace_path_hash does.
phash="$(printf '%s' "$proj" | { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi; } | cut -c1-12)"
cont="augur-${slug}-${phash}-swift-$(printf '%s' "${SWIFT_VERSION:-latest}" | tr '.' '-')"
# destroy (not down): down now only STOPS the container, so the throwaway must be fully removed
# (container + egress network) on exit.
cleanup() { ( cd "$proj" && bash "$AUGUR" destroy ) >/dev/null 2>&1; rm -rf "$proj"; }
trap cleanup EXIT

# ── Reusable fail-closed assertion set (run once per phase: fresh, then reuse) ────────────────
# Proves, for the given running container, that the allowlist proxy is the ONLY way out:
#   (0) egress is routed through the proxy (HTTPS_PROXY set)
#   (1) an allowlisted domain is reachable through the proxy
#   (2) a non-allowlisted domain is BLOCKED (fail-open would be silent)
#   (3) external DNS does not resolve in the guest
#   (4) direct egress (proxy bypassed) is severed
assert_egress_locked() {  # $1 = container, $2 = phase label
  local cont="$1" phase="$2" proxy leak _probe

  # The proxy URL augur injected — the agent's only configured egress. Without it the probes below
  # would run with `-x ''` (curl goes DIRECT), so a missing value fails closed here rather than
  # letting a direct request masquerade as a proxy result.
  proxy="$(container exec "$cont" printenv HTTPS_PROXY 2>/dev/null | tr -d '\r' || true)"
  if [[ -z "$proxy" ]]; then
    fail "[$phase] guest egress is routed through the proxy (HTTPS_PROXY set)" "no HTTPS_PROXY in the container — cannot run the proxy probes"
    return
  fi
  ok "[$phase] guest egress is routed through the proxy (HTTPS_PROXY=$proxy)"

  # (1) Allowlisted domain is REACHABLE through the proxy. api.github.com is in the managed baseline.
  #     Assert on curl's EXIT CODE, not the HTTP status: the proxy permitting the CONNECT lets curl
  #     establish the tunnel and the origin answers, so curl exits 0 for ANY HTTP status (200/404/429
  #     all prove reachability — so origin rate-limiting on shared CI egress IPs cannot red the gate).
  if container exec "$cont" sh -c "curl -s -o /dev/null --max-time 25 -x '$proxy' https://api.github.com/" >/dev/null 2>&1; then
    ok "[$phase] allowlisted domain reachable via the proxy (api.github.com CONNECT succeeded)"
  else
    fail "[$phase] allowlisted domain NOT reachable via the proxy" "the proxy denied/failed the CONNECT to api.github.com (an allowlisted host)"
  fi

  # (2) Non-allowlisted domain is BLOCKED. The proxy denies the CONNECT (403 Forbidden, ProxyServer.swift),
  #     so curl cannot establish the tunnel and exits NONZERO. A zero exit is a FAIL-OPEN — the boundary
  #     silently widened, the exact bug daily dogfooding can never observe. HTTPS/CONNECT on purpose: an
  #     http:// deny returns a 403 *page* with exit 0 and would not signal a block.
  if container exec "$cont" sh -c "curl -s -o /dev/null --max-time 25 -x '$proxy' https://example.com/" >/dev/null 2>&1; then
    fail "[$phase] non-allowlisted domain was reachable via the proxy (FAIL-OPEN)" "example.com CONNECT succeeded; the allowlist did not block it"
  else
    ok "[$phase] non-allowlisted domain blocked by the proxy (example.com CONNECT denied)"
  fi

  # (3) External DNS does not resolve in the guest — no DNS-exfil channel (re-asserts the boot
  #     self-test's getent probe, naming this property explicitly).
  if container exec "$cont" sh -c 'getent hosts example.com' >/dev/null 2>&1; then
    fail "[$phase] external DNS resolved inside the guest (DNS not fail-closed)" "getent hosts example.com succeeded"
  else
    ok "[$phase] external DNS does not resolve inside the guest (no DNS tunnel)"
  fi

  # (4) Direct egress (proxy bypassed) is severed — clear the proxy env and hit several public IP
  #     literals on :443 AND :80, mirroring the boot self-test's target set (augur verify_egress_locked)
  #     so one blackholed/rerouted IP can't make a routable network look isolated. ANY success is a leak.
  leak=""
  for _probe in https://1.1.1.1 https://8.8.8.8 http://1.1.1.1 http://8.8.8.8; do
    if container exec -e HTTP_PROXY= -e HTTPS_PROXY= -e http_proxy= -e https_proxy= -e NO_PROXY='*' \
         "$cont" sh -c "curl -s --max-time 6 -o /dev/null ${_probe}" >/dev/null 2>&1; then
      leak="$_probe"; break
    fi
  done
  if [[ -n "$leak" ]]; then
    fail "[$phase] guest reached the internet directly, bypassing the proxy (egress not severed)" "reached ${leak} with the proxy env cleared"
  else
    ok "[$phase] direct egress (bypassing the proxy) is severed (IP literals on :443 and :80)"
  fi
}

# ── Phase 1: fresh `augur up` (egress on) ────────────────────────────────────
upout="$( cd "$proj" && AUGUR_ACCEPT_PROJECT_CONF=1 bash "$AUGUR" up 2>&1 )"
uprc=$?

# `augur up` runs verify_egress_locked and exits nonzero (tearing the container down) on ANY
# leak. So a zero exit IS the boot self-test passing: direct egress severed, DNS closed,
# proxy reachable. A nonzero exit is a fail-closed event — exactly what we want to catch.
if [[ $uprc -ne 0 ]]; then
  fail "augur up (egress on) succeeded and the boot self-test passed" \
       "augur up exited $uprc — last lines:
$(printf '%s\n' "$upout" | tail -n 10)"
  finish; exit $?
fi
ok "augur up (egress on) succeeded"
has "$upout" "Egress self-test passed" "boot self-test (verify_egress_locked) fired and passed during up"

# The container must actually be up for the explicit proxy probes below.
if ! container exec "$cont" true >/dev/null 2>&1; then
  fail "container '$cont' is running after up" "$(printf '%s\n' "$upout" | tail -n 5)"
  finish; exit $?
fi
ok "container '$cont' is running"

# NOTE: earlier revisions asserted "secrets-zero" here (no ANTHROPIC_API_KEY /
# CLAUDE_CODE_OAUTH_TOKEN in the guest), a fork-PR-safety premise for when this tier ran
# agentless in CI. It no longer runs in CI — Apple Container needs macOS 26+, so this is a
# LOCAL gate on the trusted single-user host, where the developer IS authenticated and augur
# correctly forwards their token. Asserting its ABSENCE would fail every real local run. The
# egress fail-closed guarantee below does not depend on secrets-zero — it holds whether or
# not a token is present (that is the whole point: the proxy is the only way out regardless).

assert_egress_locked "$cont" "fresh"

# ── Phase 2: persistence reuse — down (stop, keep) → up (reuse via `container start`) ─────────
# Drop a marker OUTSIDE the bind mounts (in the container's own writable layer, dev-writable
# /home/dev — only /workspace-<slug>, ~/.claude/projects, ~/.gitconfig, ~/.config/gh are mounted)
# so we can PROVE the next up reused this exact container rather than rebuilding it.
marker="/home/dev/augur-reuse-marker-$$"
container exec "$cont" sh -lc "echo alive > '$marker'" >/dev/null 2>&1 || true

( cd "$proj" && bash "$AUGUR" down ) >/dev/null 2>&1
if container inspect "$cont" >/dev/null 2>&1; then
  ok "down kept the container (stopped, not deleted)"
else
  fail "down kept the container" "container '$cont' is gone after 'augur down' (expected stop/keep)"
  finish; exit $?
fi

upout2="$( cd "$proj" && AUGUR_ACCEPT_PROJECT_CONF=1 bash "$AUGUR" up 2>&1 )"
uprc2=$?
if [[ $uprc2 -ne 0 ]]; then
  fail "augur up (reuse, egress on) succeeded and re-ran the boot self-test" \
       "augur up exited $uprc2 — last lines:
$(printf '%s\n' "$upout2" | tail -n 10)"
  finish; exit $?
fi
ok "augur up (reuse, egress on) succeeded"
has "$upout2" "Reusing stopped container"   "up took the REUSE path (container start), not a rebuild"
has "$upout2" "Egress self-test passed"      "boot self-test re-ran on the reused container (I1 gates reuse)"

# Marker survived → the container was genuinely reused (a rebuild starts from the image and loses it).
survived="$(container exec "$cont" sh -lc "cat '$marker' 2>/dev/null" 2>/dev/null | tr -d '\r' || true)"
if [[ "$survived" == "alive" ]]; then
  ok "reuse preserved the writable layer (marker survived down/up — container was not rebuilt)"
else
  fail "reuse preserved the writable layer" "marker lost after down/up — the container was rebuilt, not reused"
fi

# The whole point: the REUSED container is just as fail-closed as a fresh one.
assert_egress_locked "$cont" "reuse"

finish
