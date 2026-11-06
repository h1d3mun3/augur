#!/usr/bin/env bash
# AGENT SEAM (AUGUR_AGENT_SEAM) — the definition of the coding agent augur runs.
# Anti-Corruption Layer between augur (the sandbox) and that agent. Today the ONLY agent is
# Claude Code. Every Claude-/Anthropic-specific value and command is funneled through the
# agent_* functions in this file (plus a few in-place members tagged `AUGUR_AGENT_SEAM` in
# `augur` where extraction would change behavior, and markers in Dockerfile / augur.conf). A
# future swap therefore has one discoverable change surface: `grep -rn AUGUR_AGENT_SEAM`.
# Today the definition is this one file: its name is fixed in augur's loader, `install`, the
# Makefile and the tests. A second agent needs a selection point in the loader, which is
# deliberately not built until a second agent exists.
#
# This file is sourced by `augur` from the install dir, never executed on its own. It is
# host-trusted code exactly like `augur`: it must live where no guest can write (never under a
# directory mounted or shared into a guest), and it is installed fresh by `bash install`.
#
# DESIGN RULE — do not break: the agent side only DECLARES DATA; the sandbox core
# (cmd_up, the egress/proxy stack, the mount keying, resolve_api_key injection) OWNS
# and ENFORCES every security mechanism. Adding a second agent must NOT move a control
# out of the core.
# ────────────────────────────────────────────────────────────────────────────────

# Human-facing product name (info/help text only). DATA.
agent_display_name() { echo "Claude Code"; }

# Guest CLI binary / command name. DATA.
agent_cli_name() { echo "claude"; }

# Shape of the token the login command prints, shown in the operator's paste prompt. DATA; the
# validator that enforces the shape is core code (save_oauth_token).
agent_token_hint() { echo "sk-ant-…"; }

# Interactive launch argv (space-separated tokens). DATA.
# CONTRACT (launch string): on macOS this is interpolated into an SSH remote-command string. It is
#   a single constant token today (safe). BEFORE it becomes variable per agent, add a
#   metachar/control-byte reject guard and pass argv via printf %q. The container engines
#   pass it as an argv array to `<engine> exec` — safe by construction.
# NOTE: no argv forwarding is added here for Claude Code's `--worktree` flag — this is a
#   deliberate non-fix, not an oversight: the supported path is `augur shell` plus a manual
#   `claude --worktree` launch.
agent_launch_argv() { echo "claude"; }

# Credential-capture / login subcommand argv. DATA.
agent_login_argv() { echo "claude setup-token"; }

# Non-secret agent env set at exec/launch (space-separated KEY=VALUE tokens). DATA.
agent_fixed_env() { echo "DISABLE_AUTOUPDATER=1"; }

# Command that prints the agent version, for `augur status`. DATA.
agent_version_cmd() { echo "claude --version"; }

# macOS VM mode: where the official installer puts the agent CLI, relative to the guest user's home.
# DATA. The core launches setup-token by this absolute path and runs the signature check on it.
agent_macos_cli_relpath() { echo ".local/bin/claude"; }

# macOS VM mode: the official installer's download URL and its argument (a release channel). DATA.
# The core downloads the script to a temp file and runs it; it never pipes it into a shell.
agent_installer_url()  { echo "https://claude.ai/install.sh"; }
agent_installer_args() { echo "latest"; }

# macOS VM mode: where the system-wide managed policy (agent_managed_settings_json) lives. DATA.
agent_macos_managed_settings_path() { echo "/Library/Application Support/ClaudeCode/managed-settings.json"; }

# The agent's per-user config file, relative to the guest user's home. DATA. It holds account and
# onboarding state, so the core scrubs it from the base VM and seeds the stub below into project VMs.
agent_config_file_relpath() { echo ".claude.json"; }
# The onboarding-only stub written to that file: no auth, no folder-trust. Same bytes as the
# Dockerfile's (a test asserts both copies). DATA.
agent_config_seed_json() { printf '{"hasCompletedOnboarding":true,"installMethod":"native"}\n'; }

# macOS VM mode: the Apple Developer ID Team ID that signs the agent's macOS binary (Anthropic PBC).
# DATA. The signature check (agent_verify_integrity_macos) accepts only a Developer ID signature
# issued to exactly this team.
agent_macos_signing_team() { echo "Q6L2SF6YDW"; }

# Credential specs, one per line: GUEST_ENV|HOST_ENV|HOST_FILE|VALIDATOR. DATA.
# The core resolves each via resolve_api_key and injects ONLY these NAMED vars — never the
# wholesale host env, never a mounted credential store. Container mode injects them per session
# (session_credential_env); macOS VM mode writes them to ~/.augur-env in cmd_up_macos.
# CONTRACT (credentials): VALIDATOR is the per-value check a FUTURE multi-agent build must run on
#   every resolved value before it is interpolated into a shell / sourced file. It is
#   'none' here to preserve current behavior byte-for-byte (today only the setup-token
#   capture path validates, via save_oauth_token).
# CONTRACT (precedence): both are injected; the agent applies the official
#   ANTHROPIC_API_KEY > CLAUDE_CODE_OAUTH_TOKEN precedence when both are set.
agent_auth_specs() {
    echo "ANTHROPIC_API_KEY|ANTHROPIC_API_KEY|$HOME/.anthropic_api_key|none"
    echo "CLAUDE_CODE_OAUTH_TOKEN|CLAUDE_CODE_OAUTH_TOKEN|$HOME/.claude_code_oauth_token|none"
}

# Per-project history/state layout. DATA only — the KEYING discipline (host source keyed
# on slug+path-hash, kept OUTSIDE the host's own agent tree, scoped to the current project)
# lives in the CORE (cmd_up). CONTRACT (state dir): a future agent whose state dir is flat (no
# cwd fan-out) or colocated with its credential file must still be hash-keyed and must never
# mount its credential store.
# NOTE: the whole guest projects dir is persisted, not one leaf, so every leaf this project
#   creates (the main checkout's and each `claude --worktree` session's) survives recreation.
#   Accepted trade-off: a compromised session in one leaf can read and modify its sibling
#   leaves — all of them this same project's history, never another project's.
agent_state_host_subdir()        { echo "claude-projects"; }              # dir under $AUGUR_DIR (both modes)
agent_state_guest_projects_dir() { echo "/home/dev/.claude/projects"; }   # guest parent dir
agent_state_guest_leaf()         { echo "-workspace-$1"; }                # leaf name from slug ($1)
# User-level custom subagent definitions (`~/.claude/agents/*.md`, the `/agents` UI). DATA only;
# the CORE keys the host source on slug+path-hash and keeps it OUTSIDE the host's own ~/.claude,
# exactly like history above — a compromised guest can therefore plant an agent def only
# into ITS OWN project's dir, never the host's real ~/.claude/agents nor another project's. That
# is why we persist a PER-PROJECT dir, not the host's global ~/.claude/agents (a global RW mount
# would let a guest inject a subagent read by every future session in every project).
agent_state_agents_host_subdir() { echo "claude-agents"; }                # dir under $AUGUR_DIR (both modes)
agent_state_guest_agents_dir()   { echo "/home/dev/.claude/agents"; }     # guest user-level subagent-defs dir
# Up-arrow prompt recall. DATA only; the CORE owns the snapshot lifecycle (save_guest_history).
# Verified against the official docs (`/docs/en/claude-directory`, 2026-07-25): "history.jsonl —
# Every prompt you've typed, with timestamp and project path. Used for up-arrow recall." It lives
# directly in ~/.claude, so unlike projects/ and agents/ it is NOT covered by a mount and dies with
# the container's writable layer. NOTE for anyone touching this: prompt history is HERE, not in
# ~/.claude.json — a mix-up worth stating because the two are easy to confuse.
agent_state_carryover_host_subdir() { echo "claude-carryover"; }          # dir under $AUGUR_DIR
agent_state_guest_history_file()    { echo "/home/dev/.claude/history.jsonl"; }
# Opt-in operator profile — the operator's OWN Claude Code assets (personal slash commands, skills,
# a user-level CLAUDE.md, user-scope settings.json) carried into the guest. DATA only; the CORE
# owns the mechanism (host dir mounted/shared READ-ONLY, wired by apply_guest_profile /
# ensure_macos_agent_profile).
#
# This is deliberately NOT the host's real ~/.claude, which augur never reads. That tree is
# EXECUTABLE config: a RW mount would let a compromised guest plant a hook/skill/command that every
# future host-side session runs in every project — the same attack the per-project keying of
# agent_state_agents_host_subdir already refuses, and it lands harder here because a hook runs
# unconditionally while a subagent runs only when invoked. A separate, explicitly-populated
# directory also means the operator placing a file there IS the assertion that it was written for
# the GUEST, so augur owes no sanitizer for host-absolute hook/statusLine paths, apiKeyHelper, or
# secrets in `env`. INERT by default: an empty (or absent) profile wires nothing.
agent_profile_host_subdir()  { echo "claude-profile"; }             # dir under $AUGUR_DIR (both modes)
agent_profile_guest_mount()  { echo "/home/dev/.augur-profile"; }   # read-only mount point (container)
agent_profile_guest_dir()    { echo "/home/dev/.claude"; }          # where the wired entries land
# SYMLINKED to the read-only mount: Claude only ever READS these, so a host-side edit is live on the
# next `claude` with no container recreate. This is the full set of user-scope directories the
# official `.claude` directory reference lists as operator-authored content — personal commands,
# skills, topic rules, output styles, dynamic workflows and themes. Two user-scope directories are
# deliberately NOT here: `agents/` (already a per-project RW mount — category 1) and `agent-memory/`
# (Claude WRITES it, so it is guest-generated state, not operator input).
agent_profile_link_dirs()    { echo "commands skills rules output-styles workflows themes"; }
# COPIED instead of symlinked: these are the user-scope FILES Claude Code may rewrite in place —
# settings.json (model selection and several /config toggles land there), CLAUDE.md (/memory can
# edit it), keybindings.json (the TUI owns it) — and a symlink into a READ-ONLY mount would turn
# any of those writes into an error rather than a feature.
agent_profile_copy_files()   { echo "settings.json CLAUDE.md keybindings.json"; }
# Managed policy — the ONE settings layer a repository cannot override. Claude Code's documented
# precedence is managed > CLI args > .claude/settings.local.json > .claude/settings.json >
# ~/.claude/settings.json, so a user-scope profile (above) is the LOWEST layer and loses to any
# repo. augur is the isolation boundary, so its own policy belongs at the TOP of that stack.
# DATA only; the CORE installs it (Dockerfile for the image, install_macos_managed_settings for the
# base VM).
#
# Deliberately ONE key. The Dockerfile already pins DISABLE_AUTOUPDATER as an ENV *because the
# integrity gate depends on it* ("keeps the on-disk binary byte-identical to the image ... and
# removes the binary's ability to rewrite itself"). But a settings-file `env` block outranks the
# process environment, so a repo could re-enable the updater and swap the very binary augur
# verifies. Managed scope is the only layer that closes that.
#
# MUST stay byte-identical to the Dockerfile's payload — Claude Code strips managed entries that
# fail validation WITHOUT failing loudly, so drift here is silent. Tests assert both copies.
# NEVER add a credential: this is baked into the SHARED augur:swift-<tag> image.
agent_managed_settings_json() { printf '{"env":{"DISABLE_AUTOUPDATER":"1"}}\n'; }
# Integrity gate (agent_verify_integrity_engine/_macos in `augur`), save_oauth_token,
# setup_token_security_notice and the macOS state/install helpers are tagged
# AUGUR_AGENT_SEAM in place. Egress baseline is file-based: see augur.conf.
