#!/usr/bin/env bash
# Tier 0 — pure seam unit tests. No Docker, no VM; runs anywhere.
# Asserts every pure `agent_*` function in the AGENT SEAM emits its expected DATA.
# This is the byte-equivalence floor: if these drift, the ACL contract changed.
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/lib.sh"
section "Tier 0 — AGENT SEAM pure functions (byte-equivalence)"

# Extract the seam block exactly as documented (grep -n AUGUR_AGENT_SEAM markers) and
# source it in isolation — augur's bottom dispatch never runs.
seam="$(mktemp)"; trap 'rm -f "$seam"' EXIT
sed -n '/^# ══ AGENT SEAM/,/^# ══ end AGENT SEAM/p' "$REPO/augur" > "$seam"
# shellcheck disable=SC1090
source "$seam"

eq "Claude Code"            "$(agent_display_name)"            "agent_display_name"
eq "claude"                "$(agent_cli_name)"                "agent_cli_name"
eq "claude"                "$(agent_launch_argv)"             "agent_launch_argv"
eq "claude setup-token"    "$(agent_login_argv)"              "agent_login_argv"
eq "DISABLE_AUTOUPDATER=1" "$(agent_fixed_env)"               "agent_fixed_env"
eq "claude --version"      "$(agent_version_cmd)"             "agent_version_cmd"
eq "claude-projects"       "$(agent_state_host_subdir)"       "agent_state_host_subdir"
eq "/home/dev/.claude/projects" "$(agent_state_guest_projects_dir)" "agent_state_guest_projects_dir"
eq "-workspace-myproj"     "$(agent_state_guest_leaf myproj)" "agent_state_guest_leaf (slug interpolation)"

# auth_specs: two lines, HOME-relative file paths, ANTHROPIC precedence first.
specs="$(HOME=/h agent_auth_specs | tr '\n' ';')"
eq "ANTHROPIC_API_KEY|ANTHROPIC_API_KEY|/h/.anthropic_api_key|none;CLAUDE_CODE_OAUTH_TOKEN|CLAUDE_CODE_OAUTH_TOKEN|/h/.claude_code_oauth_token|none;" \
   "$specs" "agent_auth_specs (names · host sources · order)"

finish
