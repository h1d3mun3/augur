#!/usr/bin/env bash
# Build augur-vm and ad-hoc sign it with the virtualization entitlement.
# macOS (Apple Silicon) only — Virtualization.framework does not exist elsewhere.
set -euo pipefail

PKG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PKG_DIR"

CONFIG="${1:-release}"
ENTITLEMENTS="$PKG_DIR/augur-vm.entitlements"

echo "[build] swift build -c ${CONFIG}"
swift build -c "$CONFIG"

BIN="$(swift build -c "$CONFIG" --show-bin-path)/augur-vm"
[[ -f "$BIN" ]] || { echo "[build] binary not found at $BIN" >&2; exit 1; }

# Ad-hoc signing ("-") with the entitlement is sufficient for local execution on
# Apple Silicon. Developer ID signing is only needed for distribution.
echo "[build] codesign (ad-hoc) with $ENTITLEMENTS"
codesign --force --sign - --entitlements "$ENTITLEMENTS" "$BIN"

echo "[build] signed: $BIN"
echo "[build] embedded entitlements:"
codesign -d --entitlements - --xml "$BIN" 2>/dev/null | plutil -p - 2>/dev/null || \
    codesign -d --entitlements - "$BIN" 2>/dev/null || true

echo ""
echo "[build] smoke test:"
"$BIN" smoke
