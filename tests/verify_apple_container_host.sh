#!/usr/bin/env bash
# Host verification for the Apple Container backend. RUN THIS ON A macOS 26 HOST with the
# `container` CLI installed — NOT inside the Linux dev container (Apple Container only runs
# on the macOS host). It walks the macOS-26 validation checklist from PR #53 and reports
# PASS/FAIL. No sudo. Safe: uses a throwaway project and tears it down. It is intentionally
# NOT named NN_*.sh, so tests/run.sh never tries to run it without a real Apple runtime.
#
#   tests/verify_apple_container_host.sh
#
# First run builds the image (~5 min) if it isn't present.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/.." && pwd)"
AUGUR="$REPO/augur"

pass=0 fail=0 warn=0
P(){ printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
F(){ printf '  \033[31mFAIL\033[0m %s\n' "$1"; [[ -n "${2:-}" ]] && printf '        ↳ %s\n' "$2"; fail=$((fail+1)); }
W(){ printf '  \033[33mWARN\033[0m %s\n' "$1"; [[ -n "${2:-}" ]] && printf '        ↳ %s\n' "$2"; warn=$((warn+1)); }
H(){ printf '\n\033[1m# %s\033[0m\n' "$1"; }

img="augur:swift-${SWIFT_VERSION:-latest}"
proj=""
cleanup(){ cd /; [[ -n "$proj" ]] && { ( cd "$proj" && bash "$AUGUR" down >/dev/null 2>&1 ); rm -rf "$proj"; }; }
trap cleanup EXIT

H "0. Prerequisites"
if [[ "$(uname)" != Darwin ]]; then
  F "not macOS — run this on the Mac HOST (Terminal), not inside the Linux dev container"; exit 1
fi
P "macOS host"
maj="$(sw_vers -productVersion 2>/dev/null | cut -d. -f1)"
[[ "${maj:-0}" -ge 26 ]] && P "macOS ${maj} (>= 26)" \
  || F "macOS ${maj:-?} (< 26 — Apple multi-container networking / --internal unavailable)"
if command -v container >/dev/null 2>&1; then
  P "container CLI present ($(container --version 2>/dev/null | head -1))"
else
  F "container CLI not installed (https://github.com/apple/container)"; exit 1
fi
if container system status >/dev/null 2>&1; then P "container service running"
elif container system start >/dev/null 2>&1 && container system status >/dev/null 2>&1; then P "container service started (no sudo)"
else F "container service not running and could not be started (try: container system start)"; exit 1; fi

H "1. Engine reported as Apple Container"
proj="$(mktemp -d)"
sel="$( cd "$proj" && bash "$AUGUR" status --no-egress 2>&1 | sed $'s/\033\\[[0-9;]*m//g' | grep -i '^Engine:' || true )"
echo "$sel" | grep -qi "Apple Container" \
  && P "status reports Apple Container — ${sel#Engine: }" \
  || W "engine line: ${sel:-<none>}" "expected 'Apple Container'"

H "2. container inspect exit code on a missing container (drives exists/running checks)"
if container inspect __augur_does_not_exist__ >/dev/null 2>&1; then
  F "inspect returned 0 for a missing container — container_exists() would be wrong"
else
  P "inspect exits non-zero for a missing container"
fi

H "3. Build the image (container build; BuildKit should honor .dockerignore)"
if container image inspect "$img" >/dev/null 2>&1; then
  P "image ${img} already present (skipping build)"
else
  echo "    building ${img} (~5 min, first run only)..."
  if ( cd "$proj" && bash "$AUGUR" build ) >/tmp/augur-verify-build.log 2>&1; then P "augur build succeeded"
  else F "augur build failed" "see /tmp/augur-verify-build.log"; fi
fi
ver="$(container run --rm "$img" sh -lc 'claude --version' 2>/dev/null | tr -d '\n' || true)"
[[ -n "$ver" ]] && P "image runs the agent (claude ${ver})" || W "could not run 'claude --version' in ${img}"

H "4. Egress datapath — THE core check (host-only network + host proxy + boot self-test)"
echo "    'augur up' (egress ON) runs verify_egress_locked, which validates:"
echo "      • --internal severs the internet (IP-literal probes 1.1.1.1/8.8.8.8 on :80/:443)"
echo "      • --no-dns closes external DNS"
echo "      • the host-only gateway is reachable AND bindable by the host proxy"
echo "      • the proxy is the agent's ONLY egress"
echo "    A clean 'up' here means every one of those held."
upout="$( cd "$proj" && bash "$AUGUR" up 2>&1 )"; uprc=$?
echo "$upout" | sed 's/^/      | /'
if [[ $uprc -eq 0 ]] && printf '%s' "$upout" | grep -q "self-test passed"; then
  P "egress self-test passed (host-only severance + --no-dns + gateway reachable/bindable + proxy-only egress)"
else
  F "egress 'augur up' failed or self-test did not pass (rc=${uprc})" \
    "if the proxy couldn't bind the gateway, set AUGUR_CONTAINER_GATEWAY or start the proxy after attach (see start_egress)"
fi

H "5. Agent reachable inside the live container"
slug="$(basename "$proj" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]' '-' | sed 's/^-//;s/-$//')"
cont="augur-${slug}-swift-$(printf '%s' "${SWIFT_VERSION:-latest}" | tr '.' '-')"
if container inspect "$cont" >/dev/null 2>&1; then
  cver="$(container exec "$cont" sh -lc 'claude --version' 2>/dev/null | tr -d '\n' || true)"
  [[ -n "$cver" ]] && P "claude runs inside ${cont} (${cver})" || W "could not exec claude in ${cont}"
else
  W "container ${cont} not found to exec into (up may have failed above)"
fi

H "6. Teardown leaves nothing behind"
( cd "$proj" && bash "$AUGUR" down >/dev/null 2>&1 )
container inspect "$cont" >/dev/null 2>&1 && F "container still present after 'down'" || P "container removed"
nleft="$(container network list 2>/dev/null | grep -c "augur-${slug}-net" || true)"
[[ "${nleft:-0}" -eq 0 ]] && P "egress network removed" || W "${nleft} egress network(s) still present"

H "7. No sudo"
P "the whole flow ran as $(whoami) with no sudo (by construction)"

printf '\n\033[1m── verify: %d passed · %d failed · %d warn ──\033[0m\n' "$pass" "$fail" "$warn"
if [[ $fail -eq 0 ]]; then printf '\033[32m\033[1mApple Container backend looks good on this host.\033[0m\n'; else
  printf '\033[31m\033[1m%d check(s) failed — see above.\033[0m\n' "$fail"; fi
[[ $fail -eq 0 ]]
