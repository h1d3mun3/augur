#!/usr/bin/env bash
# Tier 1 — macOS mode pushes the host's current credentials into the guest's ~/.augur-env on every
# `augur up --macos`, `augur claude --macos` and `augur shell --macos`, booting or running VM alike
# (runs anywhere; nothing is cloned or booted, and the "guest" is a local `bash -c` against a
# sandboxed home).
#
# Pinned here:
#   • a session on a running VM writes the host's CURRENT values: a changed gh token, a new API key,
#     and a token that disappeared from the host;
#   • one ssh connection per push, carrying ~/.augur-env, the ~/.zshenv line and the git helper;
#   • the write is atomic and mode 600, and the guest installs only content ending in the end marker;
#   • the bytes written are the bytes validated: a credential file that changes during the run is
#     never written unchecked;
#   • a credential that cannot be injected, or a credential file that cannot be read, aborts before
#     anything reaches the guest, which keeps its previous file;
#   • no credential value is ever on an ssh argv;
#   • every path pushes exactly once: running VM, boot, a VM that came up in the meantime, and
#     `up --macos` on a running VM.
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/lib.sh"
AUGUR="$REPO/augur"

TMPD="$(mktemp -d)"
trap 'chmod -R u+rwX "$TMPD" 2>/dev/null; rm -rf "$TMPD"' EXIT
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
mkdir -p "$AUGUR_DIR/vms/$(macos_project_vm)"
macos_store_admin_password "$(macos_project_vm)" "$MACOS_MANUAL_SETUP_PASSWORD"

# The host's gh token, switchable per case. Empty = `gh auth token` fails (logged out).
GH_HOST_TOKEN=""
gh() { [[ "$1 $2" == "auth token" && -n "$GH_HOST_TOKEN" ]] || return 1; printf '%s\n' "$GH_HOST_TOKEN"; }

# The guest. Every ssh argv goes to SSHLOG (per run) and ALL_SSH (the whole file, for the argv-leak
# check). The commands that write credential state run for real under `bash -c` in GUEST_HOME, with
# the guest's /Users/<user> mapped onto it, so the assertions are about the resulting files.
GUEST_HOME="$TMPD/guest"; mkdir -p "$GUEST_HOME"
SSHLOG="$TMPD/sshlog"; : > "$SSHLOG"
ALL_SSH="$TMPD/all-ssh"; : > "$ALL_SSH"
STEPS="$TMPD/steps"; : > "$STEPS"           # guest-touching steps that are stubbed out
guest_run() { HOME="$GUEST_HOME" bash -c "${1//\/Users\/${MACOS_SSH_USER}/$GUEST_HOME}"; }
ssh_macos() {
    local vm="$1"; shift
    printf '%s\n' "$*" | tee -a "$ALL_SSH" >> "$SSHLOG"
    case "$*" in
        -t*) return 0 ;;                                   # the interactive launch
        *".augur-env"*) guest_run "$*" ;;
        *) echo "UNEXPECTED GUEST COMMAND: $*" >&2; return 1 ;;
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
macos_vm_exists()                   { return 0; }
egress_enabled()                    { return 0; }
check_project_conf_approved()       { :; }
start_proxy()                       { :; }
start_gvproxy()                     { :; }
resolve_macos_vm_cpu()              { echo 4; }
resolve_macos_vm_memory_mb()        { echo 8192; }
wait_for_macos_ssh()                { return 0; }
warn_if_macos_profile_stale()       { :; }
vm_cli_rec()                        { return 0; }
VM_CLI=vm_cli_rec
# RUNNING: "1" = the VM is running, "0" = stopped, "race" = stopped at the first check and running
# from then on (another `up` brought it up in the meantime).
RUNNING=1
VMCHECKS="$TMPD/vmchecks"
macos_vm_running() {
    case "$RUNNING" in
        1) return 0 ;; 0) return 1 ;;
        race) [[ -s "$VMCHECKS" ]] && return 0; echo x >> "$VMCHECKS"; return 1 ;;
    esac
}

ENV_FILE="$GUEST_HOME/.augur-env"
run_cmd() {   # run_cmd claude|shell|up — sets $out / $rc; truncates the per-run logs first
    : > "$SSHLOG"; : > "$STEPS"; : > "$VMCHECKS"
    out="$( "cmd_${1}_macos" 2>&1 )"; rc=$?
}
pushes()     { grep -c 'cat > .*\.augur-env' "$SSHLOG"; }
ssh_calls()  { grep -vc '^-t \|^scp ' "$SSHLOG"; }      # guest connections other than the launch
mode_of()    { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
pushcmd()    { grep 'cat > .*\.augur-env' "$SSHLOG" | head -n1; }

section "Tier 1 — a session on a RUNNING VM pushes the host's current credentials"

# A stale, world-readable file from an earlier push: it must be replaced, not merely rewritten.
printf "export GH_TOKEN='ghp_stale0000'\n" > "$ENV_FILE"; chmod 644 "$ENV_FILE"
export ANTHROPIC_API_KEY="test-api-key-AAA111"
GH_HOST_TOKEN="ghp_first111111"
run_cmd shell
eq "0" "$rc" "shell --macos: completes"
eq "1" "$(pushes)" "shell --macos: pushes ~/.augur-env exactly once"
eq "1" "$(ssh_calls)" "shell --macos: the push is one ssh connection (env, ~/.zshenv line and git helper together)"
envc="$(cat "$ENV_FILE")"
has   "$envc" "export GH_TOKEN='ghp_first111111'"        "shell --macos: the guest gets the host's current gh token"
has   "$envc" "export ANTHROPIC_API_KEY='test-api-key-AAA111'" "shell --macos: the guest gets the host's API key"
hasnt "$envc" "ghp_stale0000"                            "shell --macos: the stale value is gone"
eq "$MACOS_AUGUR_ENV_END_LINE" "$(tail -n 1 "$ENV_FILE")" "the installed file ends with the end marker"
eq "600" "$(mode_of "$ENV_FILE")" "the rewritten ~/.augur-env is mode 600 (a 644 one is replaced)"
eq "" "$(find "$GUEST_HOME" -maxdepth 1 -name '.augur-env.*' -print)" "no temp file is left behind"
eq "1" "$(grep -c '.augur-env' "$GUEST_HOME/.zshenv")" "~/.zshenv sources ~/.augur-env"
helper="$(HOME="$GUEST_HOME" git config --global --get-all 'credential.https://github.com.helper')"
has "$helper" 'password=$GH_TOKEN' "git's credential helper is wired, holding only the \$GH_TOKEN reference"
clk_at="$(grep -n sync_macos_guest_clock "$STEPS" | cut -d: -f1)"
[[ -n "$clk_at" ]] && ok "shell --macos: the clock is synced on this path (control)" \
    || fail "shell --macos: the clock sync did not run" "steps: $(tr '\n' ' ' < "$STEPS")"

# The shape that makes the write atomic and never world-readable.
pc="$(pushcmd)"
umask_at="${pc%%umask 077*}"; cat_at="${pc%%cat > *}"
if [[ "$pc" == *"umask 077"* && ${#umask_at} -lt ${#cat_at} ]]; then
    ok "the temp file is created under umask 077 (mode 600 before any secret is written)"
else fail "the push does not set umask 077 before writing" "$pc"; fi
has "$pc" "mv -f " "the temp file is renamed over ~/.augur-env (a concurrent zsh never sees a partial file)"

GH_HOST_TOKEN="ghp_rotated22222"
export ANTHROPIC_API_KEY="test-api-key-BBB222"
run_cmd claude
eq "0" "$rc" "claude --macos: completes"
eq "1" "$(pushes)" "claude --macos: pushes ~/.augur-env exactly once"
eq "1" "$(ssh_calls)" "claude --macos: one ssh connection for the push"
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
# helper stays (deliberately; see macos_git_credential_helper_cmd) and holds no secret.
GH_HOST_TOKEN=""
run_cmd shell
eq "0" "$rc" "gh logged out on the host: shell --macos still completes"
envc="$(cat "$ENV_FILE")"
hasnt "$envc" "GH_TOKEN" "gh logged out on the host: GH_TOKEN is dropped from ~/.augur-env"
has   "$envc" "ANTHROPIC_API_KEY" "gh logged out on the host: the other credentials are still written"
hasnt "$(pushcmd)" "git config" "gh logged out on the host: no helper write is sent"
helper="$(HOME="$GUEST_HOME" git config --global --get-all 'credential.https://github.com.helper')"
hasnt "$helper" "ghp_" "gh logged out on the host: the helper left in ~/.gitconfig holds no token"

section "Tier 1 — the guest installs only complete content"

GH_HOST_TOKEN="ghp_rotated22222"
run_cmd shell
pc="$(pushcmd)"; before="$(cat "$ENV_FILE")"
# Content cut short in transit: everything but the end marker.
printf "export GH_TOKEN='ghp_trunc'\n" | guest_run "$pc"; trc=$?
if [[ "$trc" -ne 0 ]]; then ok "truncated content: the guest command fails"
else fail "truncated content: the guest command succeeded"; fi
eq "$before" "$(cat "$ENV_FILE")" "truncated content: the previous ~/.augur-env is kept"
eq "" "$(find "$GUEST_HOME" -maxdepth 1 -name '.augur-env.*' -print)" "truncated content: no temp file is left behind"

section "Tier 1 — a credential that cannot be injected aborts before the guest is touched"

before="$(cat "$ENV_FILE")"
export ANTHROPIC_API_KEY="test-api-key-bad'quote"
for _cmd in shell claude up; do
    run_cmd "$_cmd"
    if [[ "$rc" -ne 0 ]]; then ok "bad ANTHROPIC_API_KEY: $_cmd --macos exits non-zero"
    else fail "bad ANTHROPIC_API_KEY: $_cmd --macos exited 0"; fi
    has "$out" "Refusing to inject ANTHROPIC_API_KEY" "bad ANTHROPIC_API_KEY: $_cmd --macos names the variable"
    eq "" "$(cat "$SSHLOG")" "bad ANTHROPIC_API_KEY: $_cmd --macos sends nothing over ssh"
    eq "" "$(cat "$STEPS")" "bad ANTHROPIC_API_KEY: $_cmd --macos runs no guest step (clock, workspace, …)"
done
eq "$before" "$(cat "$ENV_FILE")" "bad ANTHROPIC_API_KEY: the guest's ~/.augur-env is unchanged"
export ANTHROPIC_API_KEY="test-api-key-BBB222"
GH_HOST_TOKEN=$'ghp_bad\tcontrol'
run_cmd claude
if [[ "$rc" -ne 0 ]]; then ok "bad gh token: claude --macos exits non-zero"
else fail "bad gh token: claude --macos exited 0"; fi
has "$out" "Refusing to inject GH_TOKEN" "bad gh token: names GH_TOKEN"
eq "" "$(cat "$SSHLOG")" "bad gh token: nothing is sent over ssh"
eq "$before" "$(cat "$ENV_FILE")" "bad gh token: the guest's ~/.augur-env is unchanged"
GH_HOST_TOKEN="ghp_rotated22222"

section "Tier 1 — a credential file that cannot be read aborts before any push"

unset ANTHROPIC_API_KEY
if [[ "$(id -u)" == 0 ]]; then
    skip "unreadable credential file" "running as root: chmod 000 does not stop root reading it"
else
    printf 'test-oauth-unreadable\n' > "$HOME/.claude_code_oauth_token"; chmod 000 "$HOME/.claude_code_oauth_token"
    for _cmd in shell claude; do
        run_cmd "$_cmd"
        if [[ "$rc" -ne 0 ]]; then ok "unreadable token file: $_cmd --macos exits non-zero"
        else fail "unreadable token file: $_cmd --macos exited 0" "a truncated ~/.augur-env would replace the working one"; fi
        has "$out" "Could not read" "unreadable token file: $_cmd --macos says the file could not be read"
        eq "0" "$(pushes)" "unreadable token file: $_cmd --macos sends no push at all"
        eq "$before" "$(cat "$ENV_FILE")" "unreadable token file: $_cmd --macos leaves the guest's ~/.augur-env unchanged"
    done
    chmod 600 "$HOME/.claude_code_oauth_token"; rm -f "$HOME/.claude_code_oauth_token"
fi

section "Tier 1 — the bytes written are the bytes validated"

# The token FILE is rewritten while augur runs. resolve_api_key is the only reader of credential
# files; this wrapper counts reads of the token file (in a file: the reads happen in command
# substitutions) and switches the content after the first GOOD_READS of them.
real_resolve="$(declare -f resolve_api_key)"
READS="$TMPD/reads"
GOOD_READS=1
resolve_api_key() {
    if [[ "$2" == "$HOME/.claude_code_oauth_token" ]]; then
        echo x >> "$READS"
        if [[ "$(wc -l < "$READS" | tr -d ' ')" -le "$GOOD_READS" ]]; then echo "test-oauth-good-1111"
        else echo "test-oauth-bad'injected"; fi
        return 0
    fi
    [[ -n "$1" ]] && echo "$1"
    return 0
}
# (a) good at the early check, bad from then on: the push reads it once, rejects it, sends nothing.
: > "$READS"; GOOD_READS=1
run_cmd shell
if [[ "$rc" -ne 0 ]]; then ok "file changed after the early check: shell --macos exits non-zero"
else fail "file changed after the early check: shell --macos exited 0"; fi
has "$out" "Refusing to inject CLAUDE_CODE_OAUTH_TOKEN" "file changed after the early check: the push's own check refuses it"
eq "0" "$(pushes)" "file changed after the early check: nothing is pushed"
hasnt "$(cat "$ENV_FILE")" "injected" "file changed after the early check: the bad value never reaches the guest"
# (b) good for the first two reads, bad from the third: the push must write the value it checked,
#     not read the file a third time.
: > "$READS"; GOOD_READS=2
run_cmd shell
eq "0" "$rc" "file changed after the push's check: shell --macos completes"
has   "$(cat "$ENV_FILE")" "export CLAUDE_CODE_OAUTH_TOKEN='test-oauth-good-1111'" "file changed after the push's check: the validated value is the one written"
hasnt "$(cat "$ENV_FILE")" "injected" "file changed after the push's check: the later, unchecked content is not written"
eq "2" "$(wc -l < "$READS" | tr -d ' ')" "the token file is read exactly once by the early check and once by the push"
eval "$real_resolve"

section "Tier 1 — every path pushes exactly once"

export ANTHROPIC_API_KEY="test-api-key-BBB222"
GH_HOST_TOKEN="ghp_boot333333"
RUNNING=0
for _cmd in shell claude up; do
    run_cmd "$_cmd"
    eq "0" "$rc" "not running: $_cmd --macos boots and completes"
    has "$out" "is up." "not running: $_cmd --macos went through the boot path (control)"
    eq "1" "$(pushes)" "not running: $_cmd --macos pushes ~/.augur-env exactly once"
    has "$(cat "$ENV_FILE")" "export GH_TOKEN='ghp_boot333333'" "not running: $_cmd --macos: the booted guest has the host's gh token"
done
st_at="$(grep -n verify_macos_egress_locked "$STEPS" | tail -n1 | cut -d: -f1)"
[[ -n "$st_at" ]] && ok "boot: the egress self-test ran (control for the ordering below)" || fail "boot: no self-test"

GH_HOST_TOKEN="ghp_race444444"
RUNNING=race
for _cmd in shell claude; do
    run_cmd "$_cmd"
    eq "0" "$rc" "VM came up in the meantime: $_cmd --macos completes"
    has "$out" "already running" "VM came up in the meantime: cmd_up_macos took its already-running branch (control)"
    eq "1" "$(pushes)" "VM came up in the meantime: $_cmd --macos still pushes exactly once"
    has "$(cat "$ENV_FILE")" "export GH_TOKEN='ghp_race444444'" "VM came up in the meantime: $_cmd --macos: the guest has the current gh token"
done

GH_HOST_TOKEN="ghp_up5555555"
RUNNING=1
macos_record_egress_mode
run_cmd up
eq "0" "$rc" "up --macos on a running VM: completes"
eq "1" "$(pushes)" "up --macos on a running VM: pushes ~/.augur-env exactly once"
has "$(cat "$ENV_FILE")" "export GH_TOKEN='ghp_up5555555'" "up --macos on a running VM: the guest gets the current gh token"
# On the running branch the self-test still precedes the push: credentials go to a guest just
# proven contained. The self-test is a stub logging to STEPS, the push is in SSHLOG, so compare
# against a marker the stub leaves in SSHLOG too.
verify_macos_egress_locked() { printf 'MARK:self-test\n' >> "$SSHLOG"; }
run_cmd up
st_at="$(grep -n '^MARK:self-test' "$SSHLOG" | cut -d: -f1)"; push_at="$(grep -n 'cat > .*\.augur-env' "$SSHLOG" | cut -d: -f1)"
if [[ -n "$st_at" && -n "$push_at" && "$st_at" -lt "$push_at" ]]; then
    ok "up --macos on a running VM: the self-test precedes the push (self-test@$st_at < push@$push_at)"
else fail "up --macos on a running VM: the push is not after the self-test" "self-test@${st_at:-none} push@${push_at:-none}"; fi

section "Tier 1 — no credential value is ever on an ssh argv"

leaked=""
for _v in ghp_first111111 ghp_rotated22222 ghp_boot333333 ghp_race444444 ghp_up5555555 ghp_bad \
          test-api-key-AAA111 test-api-key-BBB222 test-api-key-bad test-oauth; do
    grep -qF "$_v" "$ALL_SSH" && leaked+=" $_v"
done
[[ -s "$ALL_SSH" ]] && ok "control: the argv log is not empty ($(wc -l < "$ALL_SSH" | tr -d ' ') calls)" \
    || fail "control: no ssh call was recorded"
eq "" "$leaked" "no credential value appears on any recorded ssh / scp argv"

finish
