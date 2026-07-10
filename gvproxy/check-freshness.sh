#!/usr/bin/env bash
# gvproxy/check-freshness.sh
#
# Detect whether augur's pinned gvproxy fork base has fallen behind upstream in a
# way that MATTERS — not raw commit count (that is mostly tools/vendor churn), but:
#   - the augur patch no longer applies cleanly to upstream main, or
#   - a security-flavoured commit landed in the shipped code (cmd/gvproxy, pkg/), or
#   - the shipped dependency tree (go.mod / go.sum / vendor/) moved.
#
# Prints a human report, writes a Markdown issue body to $BODY_FILE, and exits
# non-zero when action is warranted so a daily GitHub Actions cron can open/refresh
# a tracking issue. Severities are TEXT (no emoji — some renderers drop glyphs):
#
#   ACTION   patch no longer applies cleanly to main            (exit 1)
#   REVIEW   security/code/dependency change in the shipped tree (exit 1)
#   NOISE    behind, but only tooling/docs/CI churn              (exit 0)
#   CURRENT  pin is at upstream main                             (exit 0)
#
# Usage:   bash gvproxy/check-freshness.sh
# Requires: gh (authenticated: GH_TOKEN or `gh auth login`), git.
# Honors:   BODY_FILE  (where to write the Markdown issue body; default ./gvproxy-freshness-body.md)
#           GITHUB_OUTPUT (if set, writes severity=/title= for the workflow)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_SH="$SCRIPT_DIR/build.sh"
PATCH="$SCRIPT_DIR/augur-egress.patch"
BODY_FILE="${BODY_FILE:-$PWD/gvproxy-freshness-body.md}"

command -v gh  >/dev/null || { echo "check-freshness: gh not found" >&2;  exit 2; }
command -v git >/dev/null || { echo "check-freshness: git not found" >&2; exit 2; }

PIN="$(grep -E '^PIN=' "$BUILD_SH" | head -1 | cut -d'"' -f2)"
REPO_URL="$(grep -E '^REPO=' "$BUILD_SH" | head -1 | cut -d'"' -f2)"
SLUG="${REPO_URL#https://github.com/}"; SLUG="${SLUG%.git}"
[ -n "$PIN" ] && [ -n "$SLUG" ] || { echo "check-freshness: could not read PIN/REPO from $BUILD_SH" >&2; exit 2; }

emit() {  # severity  title
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    { echo "severity=$1"; echo "title=$2"; } >> "$GITHUB_OUTPUT"
  fi
}

read -r MAIN_SHA MAIN_DATE < <(gh api "repos/$SLUG/commits/main" --jq '"\(.sha) \(.commit.committer.date[0:10])"')
PIN_DATE="$(gh api "repos/$SLUG/commits/$PIN" --jq '.commit.committer.date[0:10]')"
SHORT_PIN="${PIN:0:8}"; SHORT_MAIN="${MAIN_SHA:0:8}"

# Already current — nothing moved.
if [ "$PIN" = "$MAIN_SHA" ]; then
  echo "SEVERITY: CURRENT — gvproxy pin $SHORT_PIN is at upstream main ($MAIN_DATE)."
  emit CURRENT ""
  exit 0
fi

CMP="repos/$SLUG/compare/$PIN...$MAIN_SHA"
AHEAD="$(gh api "$CMP" --jq '.ahead_by')"
mapfile -t FILES   < <(gh api "$CMP" --jq '.files[].filename' 2>/dev/null || true)
mapfile -t COMMITS < <(gh api "$CMP" --jq '.commits[] | "\(.sha[0:8])\t\(.commit.committer.date[0:10])\t\(.commit.message | split("\n")[0])"')

# Classify changed files: shipped code / shipped deps vs. dev-only noise.
code=(); dep=(); noise=()
for f in "${FILES[@]}"; do
  case "$f" in
    tools/*)                 noise+=("$f") ;;   # dev tooling (linters) — never shipped
    cmd/gvproxy/*|pkg/*)     code+=("$f")  ;;
    go.mod|go.sum|vendor/*)  dep+=("$f")   ;;
    *)                       noise+=("$f") ;;
  esac
done

# Flag security-flavoured commit subjects (enriches the report; does not gate).
sec=()
for c in "${COMMITS[@]}"; do
  msg="${c#*$'\t'}"; msg="${msg#*$'\t'}"
  if printf '%s' "$msg" | grep -qiE 'secur|cve|vuln|overflow|panic|leak|bypass|out.of.bounds|(^| )oob( |$)|denial|dos'; then
    sec+=("$c")
  fi
done

# Does the augur patch still apply to current main? (highest-priority signal)
PATCH_STATE="unknown"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
if git clone --quiet --depth 1 "$REPO_URL" "$WORK/gtv" 2>/dev/null; then
  if git -C "$WORK/gtv" apply --check "$PATCH" 2>/dev/null; then PATCH_STATE="clean"; else PATCH_STATE="conflict"; fi
fi

relevant=$(( ${#code[@]} + ${#dep[@]} ))
if [ "$PATCH_STATE" = "conflict" ]; then
  SEV="ACTION"; TITLE="gvproxy: patch no longer applies to upstream main (action required)"
elif [ "$relevant" -gt 0 ]; then
  SEV="REVIEW"; TITLE="gvproxy: upstream security/code update available (review)"
else
  SEV="NOISE";  TITLE=""
fi

# --- Markdown issue body ---------------------------------------------------
{
  echo "**gvproxy fork drift — $SEV**"
  echo
  echo "| | commit | date |"
  echo "|---|---|---|"
  echo "| pinned (\`build.sh\`) | \`$SHORT_PIN\` | $PIN_DATE |"
  echo "| upstream \`main\`     | \`$SHORT_MAIN\` | $MAIN_DATE |"
  echo
  echo "- **$AHEAD** commits ahead of the pin"
  case "$PATCH_STATE" in
    clean)    echo "- \`augur-egress.patch\` **applies cleanly** to main" ;;
    conflict) echo "- \`augur-egress.patch\` **NO LONGER APPLIES** to main — re-pin needs a manual rebase" ;;
    *)        echo "- patch apply-check could not run (clone failed)" ;;
  esac
  echo

  if [ "${#code[@]}" -gt 0 ]; then
    echo "**Shipped code changed (\`cmd/gvproxy\`, \`pkg/\`):**"
    printf '%s\n' "${code[@]}" | sort -u | sed 's/^/- `/; s/$/`/'
    echo
  fi
  if [ "${#dep[@]}" -gt 0 ]; then
    echo "**Shipped dependencies changed (\`go.mod\`/\`vendor\`):**"
    printf '%s\n' "${dep[@]}" | sort -u | sed 's/^/- `/; s/$/`/'
    echo
  fi
  if [ "${#sec[@]}" -gt 0 ]; then
    echo "**Security-flavoured commits since the pin:**"
    printf '%s\n' "${sec[@]}" | while IFS=$'\t' read -r sha date subject; do
      echo "- \`$sha\` ($date) $subject"
    done
    echo
  fi

  echo "**Runbook**"
  echo "1. Bump \`PIN\` in \`gvproxy/build.sh\` to \`$MAIN_SHA\` (or a chosen newer commit)."
  echo "2. Re-apply \`augur-egress.patch\` and rebuild (\`bash gvproxy/build.sh\`)."
  echo "3. Run the macOS egress E2E on Apple Silicon (allowlisted host reachable, blocked host denied, SSH via gvproxy)."
  echo "4. If the patch conflicted, rebase it against main first, then re-run this check."
  echo
  echo "_Filed automatically by \`gvproxy/check-freshness.sh\` (daily). Body refreshes in place; closes when the pin catches up._"
} > "$BODY_FILE"

# --- stdout human summary --------------------------------------------------
echo "SEVERITY: $SEV"
echo "  pinned : $SHORT_PIN ($PIN_DATE)"
echo "  main   : $SHORT_MAIN ($MAIN_DATE)   [$AHEAD ahead]"
echo "  patch  : $PATCH_STATE"
echo "  shipped code files : ${#code[@]}   shipped dep files : ${#dep[@]}   security-flagged commits : ${#sec[@]}   (noise: ${#noise[@]})"
echo "  body   : $BODY_FILE"

emit "$SEV" "$TITLE"

case "$SEV" in
  ACTION|REVIEW) exit 1 ;;
  *)             exit 0 ;;
esac
