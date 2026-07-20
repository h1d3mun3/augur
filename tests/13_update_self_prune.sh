#!/usr/bin/env bash
# Tier 1 (offline) — `update`/`install-cert` self-prune after rebuilding, via a `container`
# shim. No runtime needed.
#
# Context: both retag $IMAGE_NAME onto a freshly built image (`update` also forces
# --no-cache), which orphans the previous generation's layers as dangling — and nothing used
# to clean that up, so it silently accumulated (observed: tens of GB after repeated updates).
# Fixed by running `container image prune` right after each rebuild. (A standalone `augur
# prune` command was considered and rejected — low enough usage to not carry as a maintained
# command; `container prune`/`container image prune --all`/`container builder delete` are
# documented directly instead, see README.)
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/lib.sh"
section "Tier 1 — update/install-cert self-prune (shimmed container, no runtime)"

command -v openssl >/dev/null || { skip "self-prune unit" "openssl not available"; finish; exit $?; }

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
export HOME="$work/home";        mkdir -p "$HOME"
proj="$work/proj";               mkdir -p "$proj"
export AUGUR_TEST_SHIMLOG="$work/shim"
export PATH="$HERE/shims:$PATH"
AUGUR="$REPO/augur"

# ── `augur update` self-prunes after rebuilding ─────────────────────────────
rm -f "$AUGUR_TEST_SHIMLOG.trace"
out="$( cd "$proj" && bash "$AUGUR" update 2>&1 )"; rc=$?
trace="$(cat "$AUGUR_TEST_SHIMLOG.trace" 2>/dev/null)"
has "$trace" "container build"        "update: rebuilds the image"
has "$trace" "container image prune"  "update: self-prunes the orphaned generation after rebuilding"
eq  "0" "$rc"                          "update: exits 0"

# ── `augur install-cert` self-prunes after baking the CA in ─────────────────
cert="$work/good.crt"
openssl req -x509 -newkey rsa:2048 -nodes -keyout /dev/null -out "$cert" -days 1 -subj "/CN=augur-test" 2>/dev/null
rm -f "$AUGUR_TEST_SHIMLOG.trace"
out="$( cd "$proj" && AUGUR_ACCEPT_CERT_INSTALL=1 bash "$AUGUR" install-cert "$cert" 2>&1 )"; rc=$?
trace="$(cat "$AUGUR_TEST_SHIMLOG.trace" 2>/dev/null)"
has "$trace" "container build"        "install-cert: rebuilds the image with the CA baked in"
has "$trace" "container image prune"  "install-cert: self-prunes the orphaned generation after rebuilding"
eq  "0" "$rc"                          "install-cert: exits 0"

finish
