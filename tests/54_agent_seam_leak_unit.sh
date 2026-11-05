#!/usr/bin/env bash
# Tier 0 — the agent seam does not leak. No container, no VM; runs anywhere.
# Fails when a Claude / Anthropic / sk-ant literal shows up in a non-comment line of `augur`
# outside the agent seam (the whole of agents/claude.sh, which is not scanned), the lines tagged
# AUGUR_AGENT_SEAM, and the short allowlists below.
# A new agent-specific value belongs behind an agent_* accessor; only user-facing text and the
# `augur claude` subcommand surface are allowed to name the agent directly.
#
# How the allowlists apply:
#   - ALLOW_FUNCS exempts the lines INSIDE the named function only. A function's extent runs from its
#     definition line (`name() {`, `function name {`, indented or not) to the closing brace at the
#     same indent, so top-level code after it is scanned like any other.
#   - ALLOW_LINES removes the allowed PHRASE from the line and scans what is left, so a leak that
#     shares a line with an allowed phrase is still caught.
# Known gap: the search terms are the vendor names above. Other agent-specific values (the guest
# install path `.local/bin`, DISABLE_AUTOUPDATER, the signing Team ID, `/home/dev/.claude`) are not
# searched for.
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
# Phrases allowed to name the agent, removed from a line before it is scanned: EXTENDED-REGEX::REASON
ALLOW_LINES=(
  'augur claude::the `augur claude` subcommand name shown to the operator'
  'cmd_claude::the functions behind the `augur claude` subcommand'
  '\|claude\||^[[:space:]]*claude\)::the `claude` word in the subcommand parser and dispatch'
  'api\.anthropic\.com::names a default allowlisted egress domain in a warning, not agent code'
)

# scan_file FILE: appends "LINE (FUNCTION): TEXT" to the global `leaks` for every offending line.
scan_file() {
  local file="$1" line n=0 fn="" fn_indent="" rest e pat
  local def_re='^([[:space:]]*)(function[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*(\(\))?[[:space:]]*\{'
  local one_liner_re='\{.*\}[[:space:]]*(#.*)?$'
  while IFS= read -r line; do
    n=$((n+1))
    local closes_here=0
    if [[ "$line" =~ $def_re && ( -n "${BASH_REMATCH[2]}" || -n "${BASH_REMATCH[4]}" ) ]]; then
      fn="${BASH_REMATCH[3]}"; fn_indent="${BASH_REMATCH[1]}"
      [[ "$line" =~ $one_liner_re ]] && closes_here=1
    elif [[ -n "$fn" && "$line" =~ ^${fn_indent}\}[[:space:]]*(#.*)?$ ]]; then
      closes_here=1
    fi
    if [[ ! "$line" =~ ^[[:space:]]*# && "$line" != *AUGUR_AGENT_SEAM* ]]; then
      local allowed_fn=0
      for e in "${ALLOW_FUNCS[@]}"; do [[ -n "$fn" && "$fn" == "${e%%::*}" ]] && allowed_fn=1; done
      if (( ! allowed_fn )); then
        rest="$line"
        shopt -s nocasematch
        for e in "${ALLOW_LINES[@]}"; do
          pat="${e%%::*}"
          while [[ "$rest" =~ $pat && -n "${BASH_REMATCH[0]}" ]]; do rest="${rest/"${BASH_REMATCH[0]}"/}"; done
        done
        [[ "$rest" =~ claude|anthropic|sk-ant ]] && leaks+=("$n (${fn:-top level}): $line")
        shopt -u nocasematch
      fi
    fi
    if (( closes_here )); then fn=""; fn_indent=""; fi
  done < "$file"
}

leaks=()
scan_file "$AUGUR_FILE"
if (( ${#leaks[@]} == 0 )); then
  ok "no agent-specific literal outside the seam, the tagged lines and the allowlist"
else
  for l in "${leaks[@]}"; do fail "agent literal outside the seam" "line $l"; done
fi

# Every allowlist entry must still match something, so a stale entry cannot linger and widen the gap.
for e in "${ALLOW_FUNCS[@]}"; do
  grep -qE "^[[:space:]]*(function +)?${e%%::*} *(\(\))? *\{" "$AUGUR_FILE" && ok "allowlisted function exists: ${e%%::*}" \
    || fail "allowlisted function is gone: ${e%%::*}" "remove its ALLOW_FUNCS entry"
done
for e in "${ALLOW_LINES[@]}"; do
  grep -qE -- "${e%%::*}" "$AUGUR_FILE" && ok "allowlist pattern still matches: ${e%%::*}" \
    || fail "allowlist pattern matches nothing: ${e%%::*}" "remove its ALLOW_LINES entry"
done

# ── The scanner itself: stray literals are caught where the old whole-line / whole-function
#    exemptions let them through. Each offending line of this fixture must be reported, and no other.
section "Tier 0 — the leak scanner catches strays next to allowed code"
fixture="$(mktemp)"; trap 'rm -f "$fixture"' EXIT
cat > "$fixture" <<'FIXTURE'
cmd_help() {
    echo "claude is allowed inside this function"
}
echo claude-after-an-allowed-function
foo() { echo "augur claude"; }
curl https://claude.ai/install.sh  # augur claude
  function bar {
    echo anthropic
  }
echo "the augur claude subcommand"
cmd_claude "$@"
x=sk-ant-token cmd_claude
FIXTURE
leaks=()
scan_file "$fixture"
got="$(printf '%s\n' "${leaks[@]}" | cut -d' ' -f1 | tr '\n' ' ')"
eq "4 6 8 12 " "$got" "flagged lines: top-level after an allowed function, a leak sharing a line with 'augur claude', an indented function, a leak beside cmd_claude"

finish
