#!/usr/bin/env bash
# Build augur-gvproxy — the augur fork of gvisor-tap-vsock that funnels all guest
# TCP through augur-proxy's SOCKS5 allowlist and disables direct UDP/ICMP egress.
#
# We don't vendor upstream into the augur repo (it carries gVisor + a large
# vendor/ tree). Instead we pin a commit, clone it, apply augur-egress.patch, and
# build. The patch is small and reviewable (see ./augur-egress.patch).
#
# Usage: bash build.sh [output-path]   (default: ./augur-gvproxy)
set -euo pipefail

# Pinned upstream commit augur-egress.patch is written against.
PIN="af3ea886ffe298dd75c94980b40fea8cfc715ebe"
REPO="https://github.com/containers/gvisor-tap-vsock"

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${1:-$SRC/augur-gvproxy}"

command -v go >/dev/null || { echo "gvproxy/build.sh: Go toolchain not found (install Go 1.23+)." >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "[gvproxy] cloning $REPO @ ${PIN:0:12}..."
git clone --quiet "$REPO" "$WORK/gtv"
git -C "$WORK/gtv" checkout --quiet "$PIN"

echo "[gvproxy] applying augur-egress.patch..."
git -C "$WORK/gtv" apply "$SRC/augur-egress.patch"

echo "[gvproxy] building (Go auto-fetches the pinned toolchain)..."
# The module's go.mod pins a newer Go; GOTOOLCHAIN=auto lets the installed Go
# download it. -mod=vendor builds from the checked-in vendor tree.
( cd "$WORK/gtv" && GOTOOLCHAIN=auto GOFLAGS=-mod=vendor go build -o "$OUT" ./cmd/gvproxy )

echo "[gvproxy] built: $OUT"
