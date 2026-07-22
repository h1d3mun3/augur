#!/usr/bin/env bash
# release-gate.sh — the structural pre-release gate for augur.
#
# WHAT: runs the LOCAL macOS-VM E2E (`make e2e`) on a real Mac and posts its result as a
# GitHub commit status (context "e2e/macos-vm") on the current HEAD. Branch protection on
# the `release` branch REQUIRES that status green, so a release physically cannot ship
# without this passing — the E2E can no longer be "forgotten". The status is issued ONLY
# when `make e2e` exits 0, so there is no way to mark green without actually running it.
#
# WHY LOCAL: `make e2e` boots a macOS VM (Virtualization.framework). No GitHub-hosted
# runner can nest a VM, so execution stays here (on your Mac) while enforcement is
# server-side (branch protection). See README "Cutting a release".
#
# ONE-TIME SETUP (human — see README "Cutting a release"):
#   1. Create a fine-grained PAT (or GitHub App token) scoped to THIS repo whose ONLY
#      permission is "Commit statuses: read and write".
#   2. Store it in the login Keychain, once (it never touches disk in plaintext):
#        security add-generic-password -s augur-release-gate -a "$USER" -w <TOKEN>
#
# USAGE (from a clean checkout of the exact commit you intend to release):
#   scripts/release-gate.sh
# Exit 0 + a green e2e/macos-vm status ⇒ the SHA is releasable. Any other exit ⇒ blocked.
set -euo pipefail

OWNER=h1d3mun3
REPO=augur
CONTEXT="e2e/macos-vm"
# Model B: `main` is the everyday branch commits land on before release. The gate refuses
# to bless a SHA that is not yet on origin/main, so the tested SHA is the one that ships.
BASE_BRANCH=main

# Override with AUGUR_REPO_DIR if the script lives elsewhere; default is the repo root
# (this script sits in scripts/). Deliberately NOT named AUGUR_DIR — inside `augur` that
# variable means ~/.augur, a different thing.
REPO_DIR="${AUGUR_REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

command -v security >/dev/null 2>&1 || {
  echo "refusing: 'security' (macOS Keychain) not found — run the gate on the Mac where 'make e2e' works" >&2
  exit 2
}

sha="$(git -C "$REPO_DIR" rev-parse HEAD)"

# A dirty tree means the SHA does not describe what would actually be tested/shipped.
if ! git -C "$REPO_DIR" diff --quiet || ! git -C "$REPO_DIR" diff --cached --quiet; then
  echo "refusing: dirty working tree ($sha) — commit or stash first" >&2
  exit 2
fi

# The SHA must already be on origin/main, so the commit we test is byte-identical to the
# one that will fast-forward onto `release` and get tagged.
git -C "$REPO_DIR" fetch -q origin "$BASE_BRANCH"
if ! git -C "$REPO_DIR" merge-base --is-ancestor "$sha" "origin/$BASE_BRANCH"; then
  echo "refusing: $sha is not on origin/$BASE_BRANCH — push it first" >&2
  exit 2
fi

token="$(security find-generic-password -s augur-release-gate -w)" || {
  echo "refusing: no Keychain item 'augur-release-gate' — see ONE-TIME SETUP in this script" >&2
  exit 2
}

post() {
  curl -fsS -X POST \
    -H "Authorization: Bearer $token" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/$OWNER/$REPO/statuses/$sha" \
    -d "{\"state\":\"$1\",\"context\":\"$CONTEXT\",\"description\":\"$2\"}" >/dev/null
}

post pending "macOS-VM E2E running locally"
if make -C "$REPO_DIR" e2e; then
  post success "macOS-VM E2E passed on $(hostname -s)"
  echo "green: $sha"
else
  rc=$?
  post failure "macOS-VM E2E failed (exit $rc)"
  exit "$rc"
fi
