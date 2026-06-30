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

# Default (no override) on a non-macOS host falls back to docker.
def="$( ( cd "$proj" && AUGUR_TEST_CONTAINER_RUNNING=0 bash "$AUGUR" status --no-egress ) 2>&1 | sed $'s/\033\\[[0-9;]*m//g' )"
has "$def" "Docker (docker)"                 "default: non-macOS host auto-selects Docker"

finish
