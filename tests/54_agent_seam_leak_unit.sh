#!/usr/bin/env bash
# Tier 0 — the agent seam does not leak. No container, no VM; runs anywhere.
# Fails when a Claude / Anthropic / sk-ant literal shows up in a non-comment line of `augur`
# outside the agent seam block, the lines tagged AUGUR_AGENT_SEAM, and the short allowlist below.
# A new agent-specific value belongs behind an agent_* accessor; only user-facing text and the
# `augur claude` subcommand surface are allowed to name the agent directly.
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/lib.sh"
section "Tier 0 — no Claude/Anthropic literals in augur outside the agent seam"

AUGUR_FILE="${AUGUR_LEAK_TEST_FILE:-$REPO/augur}"

# Whole functions allowed to name the agent: NAME::REASON
ALLOW_FUNCS=(
  "cmd_help::help text: describes the product and the augur claude subcommand to the operator"
  "save_oauth_token::the agent's token shape, destination file and variable name, tagged in place because the validator is not data"
  "setup_token_security_notice::operator warning about the agent's own sign-in flow, tagged in place"
)
# Individual lines allowed to name the agent: EXTENDED-REGEX::REASON
ALLOW_LINES=(
  'augur claude::the `augur claude` subcommand name shown to the operator'
  'cmd_claude::the functions behind the `augur claude` subcommand'
  '\|claude\||^[[:space:]]*claude\)::the `claude` word in the subcommand parser and dispatch'
  'api\.anthropic\.com::names a default allowlisted egress domain in a warning, not agent code'
)

in_seam=0; fn=""; n=0; leaks=()
while IFS= read -r line; do
  n=$((n+1))
  case "$line" in
    "# ══ AGENT SEAM"*) in_seam=1; continue;;
    "# ══ end AGENT SEAM"*) in_seam=0; continue;;
  esac
  (( in_seam )) && continue
  [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)\(\)[[:space:]]*\{ ]] && fn="${BASH_REMATCH[1]}"
  [[ "$line" =~ ^[[:space:]]*# ]] && continue
  shopt -s nocasematch
  [[ "$line" =~ claude|anthropic|sk-ant ]] || { shopt -u nocasematch; continue; }
  shopt -u nocasematch
  [[ "$line" == *AUGUR_AGENT_SEAM* ]] && continue
  allowed=0
  for e in "${ALLOW_FUNCS[@]}"; do [[ "$fn" == "${e%%::*}" ]] && allowed=1; done
  for e in "${ALLOW_LINES[@]}"; do [[ "$line" =~ ${e%%::*} ]] && allowed=1; done
  (( allowed )) || leaks+=("$n ($fn): $line")
done < "$AUGUR_FILE"

if (( ${#leaks[@]} == 0 )); then
  ok "no agent-specific literal outside the seam, the tagged lines and the allowlist"
else
  for l in "${leaks[@]}"; do fail "agent literal outside the seam" "line $l"; done
fi

# Every allowlist entry must still match something, so a stale entry cannot linger and widen the gap.
for e in "${ALLOW_FUNCS[@]}"; do
  grep -qE "^${e%%::*}\(\) *\{" "$AUGUR_FILE" && ok "allowlisted function exists: ${e%%::*}" \
    || fail "allowlisted function is gone: ${e%%::*}" "remove its ALLOW_FUNCS entry"
done
for e in "${ALLOW_LINES[@]}"; do
  grep -qE -- "${e%%::*}" "$AUGUR_FILE" && ok "allowlist pattern still matches: ${e%%::*}" \
    || fail "allowlist pattern matches nothing: ${e%%::*}" "remove its ALLOW_LINES entry"
done

finish
