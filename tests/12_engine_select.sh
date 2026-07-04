#!/usr/bin/env bash
# Tier 1 (offline) — engine selection + status reporting. Drives `augur status` through
# the docker and container shims and asserts the AUGUR_ENGINE override picks the right
# backend, that require_engine accepts both, and that status reports the selected engine.
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/lib.sh"
section "Tier 1 — engine selection (AUGUR_ENGINE override → status report)"

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
export HOME="$work/home"; mkdir -p "$HOME"
proj="$work/myproj";      mkdir -p "$proj"
export AUGUR_TEST_SHIMLOG="$work/shim"
export PATH="$HERE/shims:$PATH"
AUGUR="$REPO/augur"

status_for() {  # $1 = engine; echoes `augur status` output (ANSI-stripped)
  ( cd "$proj" && AUGUR_ENGINE="$1" AUGUR_TEST_CONTAINER_RUNNING=0 bash "$AUGUR" status --no-egress ) 2>&1 \
    | sed $'s/\033\\[[0-9;]*m//g'
}

c="$(status_for container)"
has "$c" "Engine:"                          "container: status prints an Engine line"
has "$c" "Apple Container (container)"       "container: AUGUR_ENGINE=container selects the Apple backend"

d="$(status_for docker)"
has "$d" "Docker (docker)"                   "docker: AUGUR_ENGINE=docker selects the Docker backend"

# Default (no override): mirrors augur's own detect_engine — Apple Container on macOS 26+
# when its CLI is installed, Docker otherwise. Source augur (AUGUR_SOURCE_ONLY, like
# 23_proxy_bind_isolation.sh) to call the REAL detect_engine instead of re-deriving the same
# condition here and silently drifting from it (this assertion used to hardcode "Docker",
# which is wrong on an actual macOS 26+ dev machine with Apple Container installed).
AUGUR_SOURCE_ONLY=1 source "$AUGUR"
set +e   # augur enables `set -e`; restore lib.sh assert-and-continue
expected_label="Docker (docker)"
[[ "$(detect_engine)" == "container" ]] && expected_label="Apple Container (container)"

def="$( ( cd "$proj" && AUGUR_TEST_CONTAINER_RUNNING=0 bash "$AUGUR" status --no-egress ) 2>&1 | sed $'s/\033\\[[0-9;]*m//g' )"
has "$def" "$expected_label"                 "default: auto-selects the right engine for this host"

finish
