#!/usr/bin/env bash
# Tier 1 — macOS mode refreshes the guest's credentials on every `augur claude --macos` /
# `augur shell --macos` session (runs anywhere; nothing is cloned or booted, and the "guest" is a
# local `bash -c` against a sandboxed home).
#
# Pinned here:
#   • on a VM that is already running, each session rewrites ~/.augur-env from the host's CURRENT
#     values: a changed gh token, a new API key, and a token that disappeared from the host;
#   • the write is atomic and the file is mode 600 (a pre-existing 644 file is replaced, no temp
#     file is left behind);
#   • a credential that cannot be injected aborts the session before anything reaches the guest;
#   • no credential value is ever on an ssh argv (they travel on ssh's stdin only);
#   • a session that has to boot the VM pushes exactly once (cmd_up_macos's push, no second one).
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/lib.sh"
AUGUR="$REPO/augur"

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT
exec </dev/null
# Never a real augur-vm: resolve_vm_cli runs at source time, so this must precede the source.
export AUGUR_VM_BIN="$TMPD/no-such-augur-vm"
AUGUR_SOURCE_ONLY=1 source "$AUGUR"
set +e

HOME="$TMPD/home"; mkdir -p "$HOME"
AUGUR_DIR="$TMPD/augur"
AUGUR_PROXY_DIR="$TMPD/proxy"; mkdir -p "$AUGUR_PROXY_DIR"
WORKSPACE_DIR="$TMPD/proj"; mkdir -p "$WORKSPACE_DIR"
unset ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_CONFIG_COUNT
export GIT_CONFIG_NOSYSTEM=1
SWIFT_IMAGE_TAG="${SWIFT_VERSION:-latest}"
IMAGE_NAME="augur:swift-${SWIFT_IMAGE_TAG}"
CONTAINER_NAME="$(make_container_name)"
WORKSPACE_MOUNT="$(make_workspace_mount)"
MACOS_SHARE="workspace-$(workspace_slug)"
MACOS_MODE=true
for _vm in "$(macos_project_vm)"; do
    mkdir -p "$AUGUR_DIR/vms/$_vm"; macos_store_admin_password "$_vm" "$MACOS_MANUAL_SETUP_PASSWORD"
done

# The host's gh token, switchable per case. Empty = `gh auth token` fails (logged out).
GH_HOST_TOKEN=""
gh() { [[ "$1 $2" == "auth token" && -n "$GH_HOST_TOKEN" ]] || return 1; printf '%s\n' "$GH_HOST_TOKEN"; }

# The guest. Every ssh argv goes to SSHLOG (the argv-leak check reads it). The commands that write
# credential state run for real under `bash -c` in GUEST_HOME, with the guest's /Users/<user> mapped
# onto it, so the assertions are about the resulting files, not about a model of the command.
GUEST_HOME="$TMPD/guest"; mkdir -p "$GUEST_HOME"
SSHLOG="$TMPD/sshlog"; : > "$SSHLOG"
ALL_SSH="$TMPD/all-ssh"; : > "$ALL_SSH"     # every argv of every run, for the argv-leak check
STEPS="$TMPD/steps"; : > "$STEPS"           # guest-touching steps that are stubbed out
ssh_macos() {
    local vm="$1"; shift
    printf '%s\n' "$*" | tee -a "$ALL_SSH" >> "$SSHLOG"
    local cmd="$*"
    case "$cmd" in
        -t*) return 0 ;;                                   # the interactive launch
        *".augur-env"*|*"git config --global"*)
            cmd="${cmd//\/Users\/${MACOS_SSH_USER}/$GUEST_HOME}"
            HOME="$GUEST_HOME" bash -c "$cmd" ;;
        *) echo "UNEXPECTED GUEST COMMAND: $cmd" >&2; return 1 ;;
    esac
}
scp_to_macos() { printf 'scp %s\n' "$*" | tee -a "$ALL_SSH" >> "$SSHLOG"; }
for _f in sync_macos_guest_clock sync_macos_guest_timezone ensure_macos_workspace \
          ensure_macos_agent_projects ensure_macos_agent_agents ensure_macos_agent_profile \
          ensure_macos_agent_bin warn_if_macos_egress_pinned configure_macos_guest_session \
          verify_macos_egress_locked; do
    eval "${_f}() { printf '%s\n' ${_f} >> \"\$STEPS\"; }"
done
require_vz()                        { :; }
require_fresh_egress_helpers()      { :; }
require_macos_egress_mode_current() { :; }
macos_vm_running()                  { return 0; }

ENV_FILE="$GUEST_HOME/.augur-env"
session() {   # session claude|shell — sets $out / $rc; truncates the per-run logs first
    : > "$SSHLOG"; : > "$STEPS"
    out="$( "cmd_${1}_macos" 2>&1 )"; rc=$?
}
pushes() { grep -c 'cat > .*\.augur-env' "$SSHLOG"; }
mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }

section "Tier 1 — a session on a RUNNING VM pushes the host's current credentials"

# A stale, world-readable file from an earlier push: it must be replaced, not merely rewritten.
printf "export GH_TOKEN='ghp_stale0000'\n" > "$ENV_FILE"; chmod 644 "$ENV_FILE"
export ANTHROPIC_API_KEY="test-api-key-AAA111"
GH_HOST_TOKEN="ghp_first111111"
session shell
eq "0" "$rc" "shell --macos: completes"
eq "1" "$(pushes)" "shell --macos: pushes ~/.augur-env exactly once"
envc="$(cat "$ENV_FILE")"
has   "$envc" "export GH_TOKEN='ghp_first111111'"        "shell --macos: the guest gets the host's current gh token"
has   "$envc" "export ANTHROPIC_API_KEY='test-api-key-AAA111'" "shell --macos: the guest gets the host's API key"
hasnt "$envc" "ghp_stale0000"                            "shell --macos: the stale value is gone"
eq "600" "$(mode_of "$ENV_FILE")" "the rewritten ~/.augur-env is mode 600 (a 644 one is replaced)"
eq "" "$(find "$GUEST_HOME" -maxdepth 1 -name '.augur-env.*' -print)" "no temp file is left behind"
eq "1" "$(grep -c '.augur-env' "$GUEST_HOME/.zshenv")" "~/.zshenv sources ~/.augur-env"
helper="$(HOME="$GUEST_HOME" git config --global --get-all 'credential.https://github.com.helper')"
has "$helper" 'password=$GH_TOKEN' "git's credential helper is wired, holding only the \$GH_TOKEN reference"
# Ordering: the token arrives after the clock is corrected (it is a JWT to the agent).
grep -q sync_macos_guest_clock "$STEPS" && ok "shell --macos: the clock is synced on this path (control)" \
    || fail "shell --macos: the clock sync did not run" "steps: $(tr '\n' ' ' < "$STEPS")"

# The shape that makes the write atomic and never world-readable.
pushcmd="$(grep 'cat > .*\.augur-env' "$SSHLOG")"
umask_at="${pushcmd%%umask 077*}"; cat_at="${pushcmd%%cat > *}"
if [[ "$pushcmd" == *"umask 077"* && ${#umask_at} -lt ${#cat_at} ]]; then
    ok "the temp file is created under umask 077 (mode 600 before any secret is written)"
else fail "the push does not set umask 077 before writing" "$pushcmd"; fi
has "$pushcmd" "mv -f " "the temp file is renamed over ~/.augur-env (a concurrent zsh never sees a partial file)"

GH_HOST_TOKEN="ghp_rotated22222"
export ANTHROPIC_API_KEY="test-api-key-BBB222"
session claude
eq "0" "$rc" "claude --macos: completes"
eq "1" "$(pushes)" "claude --macos: pushes ~/.augur-env exactly once"
envc="$(cat "$ENV_FILE")"
has   "$envc" "export GH_TOKEN='ghp_rotated22222'"       "claude --macos: a rotated gh token reaches the running guest"
hasnt "$envc" "ghp_first111111"                          "claude --macos: the old gh token is gone"
has   "$envc" "export ANTHROPIC_API_KEY='test-api-key-BBB222'" "claude --macos: a changed API key reaches the running guest"
eq "1" "$(grep -c '.augur-env' "$GUEST_HOME/.zshenv")" "~/.zshenv's source line is not duplicated by a second session"
launch_at="$(grep -n '^-t ' "$SSHLOG" | cut -d: -f1)"; push_at="$(grep -n 'cat > .*\.augur-env' "$SSHLOG" | cut -d: -f1)"
if [[ -n "$launch_at" && -n "$push_at" && "$push_at" -lt "$launch_at" ]]; then
    ok "claude --macos: the push precedes the launch (push@$push_at < launch@$launch_at)"
else fail "claude --macos: the agent launches before the push" "push@${push_at:-none} launch@${launch_at:-none}"; fi

# A host `gh auth logout`: the whole file is rewritten, so GH_TOKEN disappears from the guest. The
# helper stays (deliberately; see ensure_macos_git_credential_helper) and holds no secret.
GH_HOST_TOKEN=""
session shell
eq "0" "$rc" "gh logged out on the host: shell --macos still completes"
envc="$(cat "$ENV_FILE")"
hasnt "$envc" "GH_TOKEN" "gh logged out on the host: GH_TOKEN is dropped from ~/.augur-env"
has   "$envc" "ANTHROPIC_API_KEY" "gh logged out on the host: the other credentials are still written"
helper="$(HOME="$GUEST_HOME" git config --global --get-all 'credential.https://github.com.helper')"
hasnt "$helper" "ghp_" "gh logged out on the host: the helper left in ~/.gitconfig holds no token"

section "Tier 1 — a credential that cannot be injected aborts before the guest is touched"

GH_HOST_TOKEN="ghp_rotated22222"
before="$(cat "$ENV_FILE")"
export ANTHROPIC_API_KEY="test-api-key-bad'quote"
for _cmd in shell claude; do
    session "$_cmd"
    if [[ "$rc" -ne 0 ]]; then ok "bad ANTHROPIC_API_KEY: $_cmd --macos exits non-zero"
    else fail "bad ANTHROPIC_API_KEY: $_cmd --macos exited 0"; fi
    has "$out" "Refusing to inject ANTHROPIC_API_KEY" "bad ANTHROPIC_API_KEY: $_cmd --macos names the variable"
    eq "" "$(cat "$SSHLOG")" "bad ANTHROPIC_API_KEY: $_cmd --macos sends nothing over ssh"
    eq "" "$(cat "$STEPS")" "bad ANTHROPIC_API_KEY: $_cmd --macos runs no guest step (clock, workspace, …)"
done
eq "$before" "$(cat "$ENV_FILE")" "bad ANTHROPIC_API_KEY: the guest's ~/.augur-env is unchanged"
export ANTHROPIC_API_KEY="test-api-key-BBB222"
GH_HOST_TOKEN=$'ghp_bad\tcontrol'
session claude
if [[ "$rc" -ne 0 ]]; then ok "bad gh token: claude --macos exits non-zero"
else fail "bad gh token: claude --macos exited 0"; fi
has "$out" "Refusing to inject GH_TOKEN" "bad gh token: names GH_TOKEN"
eq "" "$(cat "$SSHLOG")" "bad gh token: nothing is sent over ssh"
eq "$before" "$(cat "$ENV_FILE")" "bad gh token: the guest's ~/.augur-env is unchanged"

section "Tier 1 — a session that boots the VM pushes exactly once"

# The real cmd_up_macos, with its host-side and VM-backend steps stubbed (as tests/38 does).
macos_vm_running()            { return 1; }
macos_vm_exists()             { return 0; }
egress_enabled()              { return 0; }
check_project_conf_approved() { :; }
start_proxy()                 { :; }
start_gvproxy()               { :; }
resolve_macos_vm_cpu()        { echo 4; }
resolve_macos_vm_memory_mb()  { echo 8192; }
wait_for_macos_ssh()          { return 0; }
warn_if_macos_profile_stale() { :; }
vm_cli_rec()                  { return 0; }
VM_CLI=vm_cli_rec
GH_HOST_TOKEN="ghp_boot333333"
for _cmd in shell claude; do
    session "$_cmd"
    eq "0" "$rc" "not running: $_cmd --macos boots and completes"
    has "$out" "is up." "not running: $_cmd --macos went through cmd_up_macos (control)"
    eq "1" "$(pushes)" "not running: $_cmd --macos pushes ~/.augur-env exactly once"
    has "$(cat "$ENV_FILE")" "export GH_TOKEN='ghp_boot333333'" "not running: $_cmd --macos: the booted guest has the host's gh token"
done

section "Tier 1 — no credential value is ever on an ssh argv"

leaked=""
for _v in ghp_first111111 ghp_rotated22222 ghp_boot333333 ghp_bad test-api-key-AAA111 test-api-key-BBB222 test-api-key-bad; do
    grep -qF "$_v" "$ALL_SSH" && leaked+=" $_v"
done
[[ -s "$ALL_SSH" ]] && ok "control: the argv log is not empty ($(wc -l < "$ALL_SSH" | tr -d ' ') calls)" \
    || fail "control: no ssh call was recorded"
eq "" "$leaked" "no credential value appears on any recorded ssh / scp argv"

section "Tier 1 — source guards"

fn_body() { awk -v n="$1" '$0 ~ "^"n"\\(\\) \\{"{f=1} f{print} f&&/^}/{exit}' "$AUGUR"; }
for _cmd in cmd_claude_macos cmd_shell_macos; do
    body="$(fn_body "$_cmd")"
    v_at="$(printf '%s\n' "$body" | grep -n '^ *validate_resolved_credentials ' | head -n1 | cut -d: -f1)"
    r_at="$(printf '%s\n' "$body" | grep -n 'macos_vm_running "\$project_vm"' | head -n1 | cut -d: -f1)"
    if [[ -n "$v_at" && -n "$r_at" && "$v_at" -lt "$r_at" ]]; then
        ok "$_cmd validates credentials before it touches the guest or boots it (check@$v_at < running@$r_at)"
    else fail "$_cmd does not validate credentials first" "check@${v_at:-none} running@${r_at:-none}"; fi
    has "$body" '$_booted || push_macos_guest_env "$project_vm"' "$_cmd pushes only when cmd_up_macos did not just do so"
done
push_fn="$(fn_body push_macos_guest_env)"
v_at="$(printf '%s\n' "$push_fn" | grep -n '^ *validate_resolved_credentials || exit 1' | head -n1 | cut -d: -f1)"
w_at="$(printf '%s\n' "$push_fn" | grep -n 'ssh_macos' | head -n1 | cut -d: -f1)"
if [[ -n "$v_at" && -n "$w_at" && "$v_at" -lt "$w_at" ]]; then
    ok "push_macos_guest_env re-validates before its first ssh (check@$v_at < ssh@$w_at)"
else fail "push_macos_guest_env does not validate before writing" "check@${v_at:-none} ssh@${w_at:-none}"; fi
eq "1" "$(fn_body cmd_up_macos | grep -c 'push_macos_guest_env "\$project_vm"')" "cmd_up_macos pushes in exactly one place"

finish
