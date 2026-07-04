#!/usr/bin/env bash
# Tier 1 (live) — egress FAIL-CLOSED end-to-end. This is the security-critical layer the
# CI runs on Linux/Docker (the only augur datapath that needs no nested virtualization, so
# it is free on ubuntu-latest). It brings up a real egress-enabled container and proves the
# README's core claim: the agent's ONLY way out is the host-side allowlist proxy.
#
# Unlike 20/21 (which run with --no-egress to smoke the agent), this tier runs with egress
# ON, so `augur up` fires the existing boot self-test (verify_egress_locked in augur). A
# successful `up` therefore already proves: direct egress severed + external DNS closed +
# proxy reachable. On top of that this tier adds the two assertions the boot self-test does
# NOT make — that an ALLOWLISTED domain is reachable through the proxy, and that a
# NON-allowlisted one is actively BLOCKED (403) — and re-asserts the boot guarantees so a
# regression names which property broke.
#
# Run modes:
#   tests/22_egress_failclosed.sh                       # read-only: skips (this tier spins a container)
#   AUGUR_TEST_LIVE=1 tests/22_egress_failclosed.sh     # run live; SKIP if Docker/image absent
#   AUGUR_TEST_REQUIRE_EGRESS=1 tests/22_egress_failclosed.sh  # CI: run live; FAIL (never skip) if it
#                                                       # cannot run — the security check must fail closed
#
# Prereqs for a live run (CI does these first): an engine (Docker), `bash install` (stages
# ~/.augur/augur-proxy-src + the managed allowlist), and a built image (`augur build`).
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/lib.sh"
section "Tier 1 — egress fail-closed E2E (allowlist proxy is the only way out)"

AUGUR="$REPO/augur"
ENG="${AUGUR_ENGINE:-docker}"          # CI uses Docker; AUGUR_ENGINE=container works locally on macOS 26+
require="${AUGUR_TEST_REQUIRE_EGRESS:-0}"

# In REQUIRE mode a missing prerequisite is a FAILURE, not a skip: a security guarantee that
# "couldn't be checked" must fail the build, never pass silently. Otherwise it self-skips.
missing() {  # $1 = what, $2 = detail
  if [[ "$require" == "1" ]]; then fail "$1" "$2"; else skip "$1" "$2"; fi
  finish; exit $?
}

engine_ready() {
  case "$ENG" in
    docker)    command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 ;;
    container) command -v container >/dev/null 2>&1 && container system status >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}
image_present() {
  case "$ENG" in
    docker)    docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -q '^augur:swift-' ;;
    container) container image list 2>/dev/null | grep -q 'augur:swift-' ;;
    *) return 1 ;;
  esac
}

# Gate: this tier mutates containers, so a plain `tests/run.sh` never runs it.
if [[ "$require" != "1" && "${AUGUR_TEST_LIVE:-0}" != "1" ]]; then
  skip "egress fail-closed E2E" "set AUGUR_TEST_LIVE=1 (or AUGUR_TEST_REQUIRE_EGRESS=1 in CI) to run it"
  finish; exit $?
fi

engine_ready                              || missing "engine '$ENG' is available" "install/start Docker (or set AUGUR_ENGINE)"
[[ -d "$HOME/.augur/augur-proxy-src" ]]   || missing "augur-proxy source is staged" "run 'bash install' first (stages ~/.augur/augur-proxy-src + allowlist)"
image_present                             || missing "an augur:swift-* image is built" "run 'augur build' first"

# ── Bring up a throwaway project with egress ON ──────────────────────────────
# AUGUR_ACCEPT_PROJECT_CONF=1: accept any project ./.augur/allowlist.conf non-interactively (there is
# none here, but it keeps the run headless). Egress is ON by default (no --no-egress).
proj="$(mktemp -d)"
slug="$(basename "$proj" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]' '-' | sed 's/^-//;s/-$//')"
cont="augur-${slug}-swift-$(printf '%s' "${SWIFT_VERSION:-latest}" | tr '.' '-')"   # = make_container_name in augur
cleanup() { ( cd "$proj" && AUGUR_ENGINE="$ENG" bash "$AUGUR" down ) >/dev/null 2>&1; rm -rf "$proj"; }
trap cleanup EXIT

upout="$( cd "$proj" && AUGUR_ENGINE="$ENG" AUGUR_ACCEPT_PROJECT_CONF=1 bash "$AUGUR" up 2>&1 )"
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

# Prefer the engine's ACTUAL container name over the computed one, so the probes can't target a
# stale/wrong name if SWIFT_VERSION is set unexported (the computed $cont would then disagree with
# what the augur child process used). Docker only — the format flag is Docker-specific.
if [[ "$ENG" == "docker" ]]; then
  d="$(docker ps --format '{{.Names}}' 2>/dev/null | grep -m1 "^augur-${slug}-swift-" || true)"
  [[ -n "$d" ]] && cont="$d"
fi

# The container must actually be up for the explicit proxy probes below.
if ! "$ENG" exec "$cont" true >/dev/null 2>&1; then
  fail "container '$cont' is running after up" "$(printf '%s\n' "$upout" | tail -n 5)"
  finish; exit $?
fi
ok "container '$cont' is running"

# Secrets-zero: the agent is never authenticated in CI (mock-the-agent). Prove it from the
# guest's own env so a future regression that wires a real token into egress runs is caught
# here — this is what keeps fork PRs safe to run (nothing to exfiltrate).
for v in ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN; do
  val="$("$ENG" exec "$cont" printenv "$v" 2>/dev/null || true)"
  if [[ -z "$val" ]]; then ok "agent credential $v is absent in the guest (secrets-zero / agent mocked)"
  else fail "agent credential $v leaked into the guest" "CI must run agent-less so fork PRs stay safe"; fi
done

# The proxy URL augur injected — the agent's only configured egress. Without it the probes below
# would run with `-x ''` (curl goes DIRECT), so a missing value fails closed here rather than
# letting a direct request masquerade as a proxy result.
proxy="$("$ENG" exec "$cont" printenv HTTPS_PROXY 2>/dev/null | tr -d '\r' || true)"
if [[ -z "$proxy" ]]; then
  fail "guest egress is routed through the proxy (HTTPS_PROXY set)" "no HTTPS_PROXY in the container — cannot run the proxy probes"
  finish; exit $?
fi
ok "guest egress is routed through the proxy (HTTPS_PROXY=$proxy)"

# (1) Allowlisted domain is REACHABLE through the proxy. api.github.com is in the managed baseline.
#     Assert on curl's EXIT CODE, not the HTTP status: the proxy permitting the CONNECT lets curl
#     establish the tunnel and the origin answers, so curl exits 0 for ANY HTTP status (200/404/429
#     all prove reachability — so origin rate-limiting on shared CI egress IPs cannot red the gate).
if "$ENG" exec "$cont" sh -c "curl -s -o /dev/null --max-time 25 -x '$proxy' https://api.github.com/" >/dev/null 2>&1; then
  ok "allowlisted domain reachable via the proxy (api.github.com CONNECT succeeded)"
else
  fail "allowlisted domain NOT reachable via the proxy" "the proxy denied/failed the CONNECT to api.github.com (an allowlisted host)"
fi

# (2) Non-allowlisted domain is BLOCKED. The proxy denies the CONNECT (403 Forbidden, ProxyServer.swift),
#     so curl cannot establish the tunnel and exits NONZERO. A zero exit is a FAIL-OPEN — the boundary
#     silently widened, the exact bug daily dogfooding can never observe. HTTPS/CONNECT on purpose: an
#     http:// deny returns a 403 *page* with exit 0 and would not signal a block.
if "$ENG" exec "$cont" sh -c "curl -s -o /dev/null --max-time 25 -x '$proxy' https://example.com/" >/dev/null 2>&1; then
  fail "non-allowlisted domain was reachable via the proxy (FAIL-OPEN)" "example.com CONNECT succeeded; the allowlist did not block it"
else
  ok "non-allowlisted domain blocked by the proxy (example.com CONNECT denied)"
fi

# (3) External DNS does not resolve in the guest — no DNS-exfil channel (re-asserts the boot
#     self-test's getent probe, naming this property explicitly).
if "$ENG" exec "$cont" sh -c 'getent hosts example.com' >/dev/null 2>&1; then
  fail "external DNS resolved inside the guest (DNS not fail-closed)" "getent hosts example.com succeeded"
else
  ok "external DNS does not resolve inside the guest (no DNS tunnel)"
fi

# (4) Direct egress (proxy bypassed) is severed — clear the proxy env and hit several public IP
#     literals on :443 AND :80, mirroring the boot self-test's target set (augur verify_egress_locked)
#     so one blackholed/rerouted IP can't make a routable network look isolated. ANY success is a leak.
leak=""
for _probe in https://1.1.1.1 https://8.8.8.8 http://1.1.1.1 http://8.8.8.8; do
  if "$ENG" exec -e HTTP_PROXY= -e HTTPS_PROXY= -e http_proxy= -e https_proxy= -e NO_PROXY='*' \
       "$cont" sh -c "curl -s --max-time 6 -o /dev/null ${_probe}" >/dev/null 2>&1; then
    leak="$_probe"; break
  fi
done
if [[ -n "$leak" ]]; then
  fail "guest reached the internet directly, bypassing the proxy (egress not severed)" "reached ${leak} with the proxy env cleared"
else
  ok "direct egress (bypassing the proxy) is severed (IP literals on :443 and :80)"
fi

finish
