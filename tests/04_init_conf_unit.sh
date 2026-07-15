#!/usr/bin/env bash
# Tier 0/1 — `cmd_init_conf` config scaffolding. Pure file generation; runs anywhere.
# Asserts a fresh run creates all FOUR starter files (each with its sentinel comment)
# and that the never-overwrite idiom leaves a hand-edited file untouched.
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/lib.sh"
AUGUR="$REPO/augur"
section "Tier 0/1 — cmd_init_conf scaffolding (fresh + never-overwrite)"

# exists FILE NAME — assert a scaffolded file was created
exists() { if [[ -f "$1" ]]; then ok "$2"; else fail "$2" "missing: $1"; fi; }

# Isolated sandbox: redirect BOTH $HOME (→ provision paths) and cwd (→ project paths)
# so every augur-derived config var lands under the temp dir, then use those vars — never
# hardcoded paths — so this test can never drift from augur's own derivation.
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home"; mkdir -p "$HOME"
proj="$WORK/proj"; mkdir -p "$proj"
cd "$proj"

# AUGUR_SOURCE_ONLY: pull in every function AND the derived path vars without running
# augur's bottom dispatch. augur enables `set -e` when sourced — restore lib.sh's
# assert-and-continue afterward so a failed check records instead of aborting the script.
# shellcheck disable=SC1090
AUGUR_SOURCE_ONLY=1 source "$AUGUR"
set +e

# ── Fresh run: all four files created, each carrying its sentinel comment ─────────────
cmd_init_conf >/dev/null 2>&1

exists "$AUGUR_PROJECT_CONF"                "project allowlist created"
exists "$AUGUR_PROJECT_RESOURCES_CONF"      "project resources created"
exists "$AUGUR_PROVISION_MANIFEST"          "provision manifest created (host-global)"
exists "$AUGUR_PROVISION_CONTAINER_PACKAGES" "container packages created (host-global)"

has "$(cat "$AUGUR_PROJECT_CONF")"                "augur project egress allowlist"   "allowlist sentinel"
has "$(cat "$AUGUR_PROJECT_RESOURCES_CONF")"      "augur project resource settings"  "resources sentinel"
has "$(cat "$AUGUR_PROVISION_MANIFEST")"          "provisioning manifest"            "manifest sentinel"
has "$(cat "$AUGUR_PROVISION_CONTAINER_PACKAGES")" "container image provisioning"     "container packages sentinel"

# ── Never-overwrite: a hand-edited file survives a second run and is only reported ────
printf 'MYCUSTOMLINE\n' > "$AUGUR_PROJECT_CONF"
out2="$(cmd_init_conf 2>&1)"

has "$(cat "$AUGUR_PROJECT_CONF")" "MYCUSTOMLINE" "existing allowlist left untouched (not clobbered)"
has "$out2"                        "already exists" "existing allowlist reported, not rewritten"

finish
