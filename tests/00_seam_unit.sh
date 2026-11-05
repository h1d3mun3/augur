#!/usr/bin/env bash
# Tier 0 — pure seam unit tests. No container, no VM; runs anywhere.
# Asserts every pure `agent_*` function in agents/claude.sh (the agent seam) emits its expected DATA.
# This is the byte-equivalence floor: if these drift, the ACL contract changed.
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/lib.sh"
section "Tier 0 — AGENT SEAM pure functions (byte-equivalence)"

# Source the agent definition file in isolation — augur itself (and its dispatch) never runs.
# shellcheck disable=SC1090,SC1091
source "$REPO/agents/claude.sh"

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

# ── macOS-guest data: installer, managed-policy path, config file ────────────
eq "https://claude.ai/install.sh" "$(agent_installer_url)"  "agent_installer_url"
eq "latest"                       "$(agent_installer_args)" "agent_installer_args"
eq "/Library/Application Support/ClaudeCode/managed-settings.json" "$(agent_macos_managed_settings_path)" "agent_macos_managed_settings_path"
eq ".claude.json"                 "$(agent_config_file_relpath)" "agent_config_file_relpath"
eq '{"hasCompletedOnboarding":true,"installMethod":"native"}' "$(agent_config_seed_json)" "agent_config_seed_json"
eq "sk-ant-…" "$(agent_token_hint)" "agent_token_hint"
# Every value augur interpolates into a remote script or an `-e` / `-v` argument must be a plain
# constant: no quote, backslash, `$`, backtick, `;`, `&`, `|`, newline or other control byte that
# could change the script's shape. The charset is an allowlist, so each of those is excluded.
# Every accessor is classified below; one that is neither checked nor exempt (with a reason) fails,
# so a new accessor cannot reach a remote script unreviewed.
#   TEXT  words and flags (a space separates tokens; `=` for KEY=VALUE, `:` for URLs)
#   GUEST an absolute guest path, strictly under /home/dev/
#   HOST  a single directory name under $AUGUR_DIR (no slash, no `..`)
#   REL   a path relative to the guest home
#   ABS   an absolute guest path outside the home
PLAIN_TEXT=(agent_display_name agent_cli_name agent_launch_argv agent_login_argv agent_fixed_env agent_version_cmd
            agent_installer_url agent_installer_args agent_macos_signing_team agent_profile_link_dirs agent_profile_copy_files)
PLAIN_GUEST=(agent_state_guest_projects_dir agent_state_guest_agents_dir agent_state_guest_history_file
             agent_profile_guest_mount agent_profile_guest_dir)
PLAIN_HOST=(agent_state_host_subdir agent_state_agents_host_subdir agent_state_carryover_host_subdir agent_profile_host_subdir)
PLAIN_REL=(agent_macos_cli_relpath agent_config_file_relpath)
PLAIN_ABS=(agent_macos_managed_settings_path)
# Exempt, with the reason:
EXEMPT=(
  "agent_config_seed_json::JSON written to a file through stdin, never interpolated"
  "agent_managed_settings_json::JSON written to a file through stdin, never interpolated"
  "agent_auth_specs::parsed field by field (checked below), values reach the guest only via an env file"
  "agent_state_guest_leaf::takes an argument; checked below with a sample slug"
  "agent_token_hint::shown in an operator prompt only; checked below"
)
plain_ok() {  # plain_ok NAME VALUE
  local v="$2"
  [[ -n "$v" ]] || { fail "$1 is a plain constant (safe to interpolate into a remote script)" "empty"; return; }
  case "$v" in
    *[!A-Za-z0-9._/:=\ -]*) fail "$1 is a plain constant (safe to interpolate into a remote script)" "$v";;
    *)                      ok   "$1 is a plain constant (safe to interpolate into a remote script)";;
  esac
}
for _f in "${PLAIN_TEXT[@]}"; do
  _v="$($_f)"
  # Empty is legitimate for a list or an installer argument; every other text value must be non-empty.
  if [[ -z "$_v" ]]; then
    case "$_f" in agent_fixed_env|agent_installer_args|agent_profile_link_dirs|agent_profile_copy_files) ok "$_f is empty (allowed for this accessor)";; *) fail "$_f is non-empty" "empty";; esac
  else plain_ok "$_f" "$_v"; fi
done
for _f in "${PLAIN_GUEST[@]}"; do
  _v="$($_f)"; plain_ok "$_f" "$_v"
  case "$_v" in /home/dev/?*) case "$_v" in *..*|*//*|*" "*) fail "$_f is a clean path under /home/dev/" "$_v";; *) ok "$_f is a clean path under /home/dev/";; esac;;
                *)          fail "$_f is a clean path under /home/dev/" "$_v";; esac
done
for _f in "${PLAIN_HOST[@]}"; do
  _v="$($_f)"; plain_ok "$_f" "$_v"
  case "$_v" in ""|/*|*/*|*..*|*" "*) fail "$_f is a single directory name" "$_v";; *) ok "$_f is a single directory name";; esac
done
for _f in "${PLAIN_REL[@]}"; do
  _v="$($_f)"; plain_ok "$_f" "$_v"
  case "$_v" in ""|/*|*..*|*" "*) fail "$_f is a relative path with no '..'" "$_v";; *) ok "$_f is a relative path with no '..'";; esac
done
for _f in "${PLAIN_ABS[@]}"; do
  _v="$($_f)"
  case "$_v" in /*..*|*..*) fail "$_f is an absolute path with no '..'" "$_v";; /*) ok "$_f is an absolute path with no '..'";; *) fail "$_f is an absolute path with no '..'" "$_v";; esac
  plain_ok "$_f" "$_v"
done
case "$(agent_state_guest_leaf my-proj.1)" in
  *[!A-Za-z0-9._/-]*) fail "agent_state_guest_leaf stays plain for a plain slug" "$(agent_state_guest_leaf my-proj.1)";;
  *)                  ok   "agent_state_guest_leaf stays plain for a plain slug";;
esac
# Credential specs: GUEST_ENV|HOST_ENV are variable names, the file is under HOME, the validator a word.
while IFS='|' read -r _g _h _file _val; do
  [[ -n "$_g" ]] || continue
  if [[ "$_g" =~ ^[A-Z_][A-Z0-9_]*$ && "$_h" =~ ^[A-Z_][A-Z0-9_]*$ && "$_val" =~ ^[a-z]+$ && "$_file" == /h/* ]]
  then ok "agent_auth_specs line for $_g has plain names, a HOME file and a plain validator"
  else fail "agent_auth_specs line for $_g is well-formed" "$_g|$_h|$_file|$_val"; fi
done < <(HOME=/h agent_auth_specs)
case "$(agent_token_hint)" in
  *[\"\'\\\$\`\;]*|*[[:cntrl:]]*) fail "agent_token_hint has no quote, backslash, \$, backtick, ; or control byte" "$(agent_token_hint)";;
  *)                              ok   "agent_token_hint has no quote, backslash, \$, backtick, ; or control byte";;
esac
# Every accessor in the file is classified exactly once.
_classified=" ${PLAIN_TEXT[*]} ${PLAIN_GUEST[*]} ${PLAIN_HOST[*]} ${PLAIN_REL[*]} ${PLAIN_ABS[*]} "
for _e in "${EXEMPT[@]}"; do _classified+="${_e%%::*} "; done
for _f in $(grep -oE '^agent_[a-z0-9_]+\(\)' "$REPO/agents/claude.sh" | tr -d '()'); do
  case "$_classified" in *" $_f "*) ok "$_f is classified (plain-constant check or documented exemption)";;
                         *)         fail "$_f is classified (plain-constant check or documented exemption)" "add it to a PLAIN_* list or EXEMPT with a reason";; esac
done
# Home-relative helpers: derived from the container-side seam values.
# shellcheck disable=SC2034  # the helpers live in augur's core, not the seam block: extract them.
eval "$(grep -E '^macos_agent_bindir_rel\(\)' "$REPO/augur")"
eval "$(awk '/^guest_home_relpath\(\)/{f=1} f{print} f&&/^}/{exit}' "$REPO/augur")"
eq ".claude/projects" "$(guest_home_relpath "$(agent_state_guest_projects_dir)")" "guest_home_relpath (projects dir)"
eq ".claude/agents"   "$(guest_home_relpath "$(agent_state_guest_agents_dir)")"   "guest_home_relpath (agents dir)"
eq ".claude"          "$(guest_home_relpath "$(agent_profile_guest_dir)")"        "guest_home_relpath (profile dir)"
eq ".local/bin"       "$(macos_agent_bindir_rel)"                                  "macos_agent_bindir_rel"
# guest_home_relpath fails closed on anything that is not a plain path strictly under /home/dev/.
for _bad in "/abs/path" "/home/dev" "/home/dev/" "/home/devx/a" "relative/path" "/home/dev/../etc" "/home/dev/a/../b" \
            "/home/dev//a" '/home/dev/a b' '/home/dev/a;b' '/home/dev/$x' '/home/dev/`x`' "/home/dev/a'b" '/home/dev/a"b' \
            $'/home/dev/a\nb' ""; do
  if _out="$(guest_home_relpath "$_bad" 2>/dev/null)"; then fail "guest_home_relpath refuses $(printf %q "$_bad")" "accepted: $_out"
  else ok "guest_home_relpath refuses $(printf %q "$_bad")"; fi
done

# The Dockerfile cannot call these functions, so its copies must mirror them.
if grep -qF -- "curl -fsSL $(agent_installer_url) -o" "$REPO/Dockerfile"
then ok "Dockerfile installs from the seam's installer URL"
else fail "Dockerfile installer URL drifted from the seam" "grep found no matching curl line"; fi
if grep -qF -- "printf '$(agent_config_seed_json | tr -d '\n')\\n' > /home/dev/$(agent_config_file_relpath)" "$REPO/Dockerfile"
then ok "Dockerfile bakes the same agent config stub at the seam's config path"
else fail "Dockerfile config stub drifted from the seam" "grep found no matching RUN line"; fi

finish
