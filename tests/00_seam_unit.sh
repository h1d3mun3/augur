#!/usr/bin/env bash
# Tier 0 — pure seam unit tests. No container, no VM; runs anywhere.
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
eq "claude-agents"         "$(agent_state_agents_host_subdir)" "agent_state_agents_host_subdir"
eq "/home/dev/.claude/agents" "$(agent_state_guest_agents_dir)" "agent_state_guest_agents_dir"

# auth_specs: two lines, HOME-relative file paths, ANTHROPIC precedence first.
specs="$(HOME=/h agent_auth_specs | tr '\n' ';')"
eq "ANTHROPIC_API_KEY|ANTHROPIC_API_KEY|/h/.anthropic_api_key|none;CLAUDE_CODE_OAUTH_TOKEN|CLAUDE_CODE_OAUTH_TOKEN|/h/.claude_code_oauth_token|none;" \
   "$specs" "agent_auth_specs (names · host sources · order)"

# ── Prompt-history carry-over ────────────────────────────────────────────────
eq "claude-carryover"            "$(agent_state_carryover_host_subdir)" "agent_state_carryover_host_subdir"
eq "/home/dev/.claude/history.jsonl" "$(agent_state_guest_history_file)" "agent_state_guest_history_file (up-arrow recall lives HERE, not in ~/.claude.json)"
# It must sit under the guest ~/.claude but NOT inside a mounted subdir, or it would already persist
# and the whole snapshot mechanism would be dead code.
case "$(agent_state_guest_history_file)" in
  "$(agent_state_guest_projects_dir)"/*|"$(agent_state_guest_agents_dir)"/*)
      fail "history file is outside the mounted subdirs" "it nests inside a mount, so the snapshot is redundant";;
  *) ok "history file is outside the mounted subdirs (which is why it needs a snapshot)";;
esac

# ── Opt-in operator profile ──────────────────────────────────────────────────
eq "claude-profile"          "$(agent_profile_host_subdir)"  "agent_profile_host_subdir"
eq "/home/dev/.augur-profile" "$(agent_profile_guest_mount)" "agent_profile_guest_mount"
eq "/home/dev/.claude"       "$(agent_profile_guest_dir)"    "agent_profile_guest_dir"
eq "commands skills rules output-styles workflows themes" "$(agent_profile_link_dirs)" \
   "agent_profile_link_dirs (every operator-authored user-scope dir → symlink)"
eq "settings.json CLAUDE.md keybindings.json" "$(agent_profile_copy_files)" \
   "agent_profile_copy_files (the user-scope files Claude rewrites → copy)"
# The profile must never claim an entry another category already owns: agents/ and projects/ are
# per-project RW mounts, and agent-memory/ is written BY Claude (guest-generated state, category 1),
# so wiring any of them read-only here would fight the mount or break a write.
for _owned in agents projects agent-memory; do
  case " $(agent_profile_link_dirs) $(agent_profile_copy_files) " in
    *" $_owned "*) fail "profile does not claim '$_owned' (owned by the per-project state mounts)" "found in a profile list";;
    *)             ok   "profile does not claim '$_owned' (owned by the per-project state mounts)";;
  esac
done
# The read-only mount point must sit OUTSIDE the wired dir, or it would shadow the guest ~/.claude.
case "$(agent_profile_guest_mount)" in
  "$(agent_profile_guest_dir)"/*) fail "profile mount is outside the guest ~/.claude tree" "mount nests inside the wired dir";;
  *)                              ok   "profile mount is outside the guest ~/.claude tree";;
esac

# ── Managed policy ───────────────────────────────────────────────────────────
# Claude Code SILENTLY STRIPS managed entries that fail schema validation, so a typo degrades to
# inert instead of failing loudly — assert the exact bytes, and assert the Dockerfile ships the SAME
# bytes so the container image and the macOS base VM cannot drift apart.
managed="$(agent_managed_settings_json)"
eq '{"env":{"DISABLE_AUTOUPDATER":"1"}}' "$managed" "agent_managed_settings_json (exact bytes)"
if command -v jq >/dev/null 2>&1; then
  eq "1" "$(printf '%s' "$managed" | jq -r '.env.DISABLE_AUTOUPDATER')" "managed policy pins DISABLE_AUTOUPDATER"
  eq "1" "$(printf '%s' "$managed" | jq -r '.env | length')"            "managed env carries exactly ONE key"
  eq "1" "$(printf '%s' "$managed" | jq -r 'length')"                   "managed policy has exactly one top-level key"
else
  skip "managed policy JSON shape" "jq not installed on this host"
fi
# A credential here would be baked into the SHARED augur:swift-<tag> image, readable by every
# project on the host. Auth must stay a per-container runtime injection.
while IFS='|' read -r _genv _rest; do
  [[ -z "$_genv" ]] && continue
  case "$managed" in
    *"$_genv"*) fail "managed policy must not name the credential $_genv" "found in the managed payload";;
    *)          ok   "managed policy does not name the credential $_genv";;
  esac
done < <(HOME=/h agent_auth_specs)
if grep -qF -- "printf '{\"env\":{\"DISABLE_AUTOUPDATER\":\"1\"}}\\n' > /etc/claude-code/managed-settings.json" "$REPO/Dockerfile"
then ok "Dockerfile bakes the same managed payload at /etc/claude-code/managed-settings.json"
else fail "Dockerfile managed payload drifted from the seam" "grep found no matching RUN line"; fi

finish
