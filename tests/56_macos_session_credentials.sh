#!/usr/bin/env bash
# Tier 1 — macOS mode pushes the host's current credentials into the guest's ~/.augur-env on every
# `augur up --macos`, `augur claude --macos` and `augur shell --macos`, booting or running VM alike
# (runs anywhere; nothing is cloned or booted, and the "guest" is a local `bash -c` against a
# sandboxed home).
#
# Pinned here:
#   • a session on a running VM writes the host's CURRENT values: a changed gh token, a new API key,
#     and a token that disappeared from the host;
#   • one ssh connection per push, carrying ~/.augur-env, the ~/.zshenv line and the git helper,
#     and one `gh auth token` per invocation;
#   • the write is atomic and mode 600, the guest installs only content ending in the end marker,
#     and temp files older than a minute (left by a killed push) are removed while a fresh one stays;
#   • each credential is read once per invocation and the bytes written are the bytes validated;
#   • a credential that cannot be injected, or a credential file that cannot be read, aborts before
#     anything reaches the guest (on a boot: before the VM backend is called at all), while
#     `up --macos` on a running VM still rewrites the allowlist, revives the proxy, fixes the clock
#     and runs the self-test first;
#   • a push that fails in transport is a warning on claude/shell and fatal on `up`;
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

# Per-run logs. Files, not variables: the code under test runs in `$( … )` and calls some of these
# stubs from command substitutions of its own.
SSHLOG="$TMPD/sshlog"      # every ssh argv of the current run
ALL_SSH="$TMPD/all-ssh"    # every ssh argv of the whole file, for the argv-leak check
STEPS="$TMPD/steps"        # guest-touching steps that are stubbed out
VMLOG="$TMPD/vmlog"        # every augur-vm call
HOSTLOG="$TMPD/hostlog"    # host-side reconcile steps (approval gate, proxy start)
GHCALLS="$TMPD/ghcalls"    # one line per `gh auth token`
VMCHECKS="$TMPD/vmchecks"
: > "$ALL_SSH"

# The host's gh token, switchable per case. Empty = `gh auth token` fails (logged out).
GH_HOST_TOKEN=""
gh() {
    [[ "$1 $2" == "auth token" ]] && echo x >> "$GHCALLS"
    [[ "$1 $2" == "auth token" && -n "$GH_HOST_TOKEN" ]] || return 1
    printf '%s\n' "$GH_HOST_TOKEN"
}

# The guest. The commands that write credential state run for real under `bash -c` in GUEST_HOME,
# with the guest's /Users/<user> mapped onto it, so the assertions are about the resulting files.
# FAIL_PUSH=1 makes the push connection drop the way ssh reports it (255, outcome unknown);
# FAIL_PUSH=2 makes the guest report a failed install (exit 1, old file kept).
GUEST_HOME="$TMPD/guest"; mkdir -p "$GUEST_HOME"
FAIL_PUSH=0
guest_run() { HOME="$GUEST_HOME" bash -c "${1//\/Users\/${MACOS_SSH_USER}/$GUEST_HOME}"; }
ssh_macos() {
    local vm="$1"; shift
    printf '%s\n' "$*" | tee -a "$ALL_SSH" >> "$SSHLOG"
    case "$*" in
        -t*) return 0 ;;                                   # the interactive launch
        *".augur-env"*)
            if [[ "$FAIL_PUSH" == 1 ]]; then cat >/dev/null; return 255; fi
            if [[ "$FAIL_PUSH" == 2 ]]; then cat >/dev/null; return 1; fi
            guest_run "$*" ;;
        *) echo "UNEXPECTED GUEST COMMAND: $*" >&2; return 1 ;;
    esac
}
scp_to_macos() { printf 'scp %s\n' "$*" | tee -a "$ALL_SSH" >> "$SSHLOG"; }
for _f in sync_macos_guest_clock sync_macos_guest_timezone ensure_macos_workspace \
          ensure_macos_agent_projects ensure_macos_agent_agents ensure_macos_agent_profile \
          ensure_macos_agent_bin configure_macos_guest_session verify_macos_egress_locked; do
    eval "${_f}() { printf '%s\n' ${_f} >> \"\$STEPS\"; }"
done
require_vz()                        { :; }
require_fresh_egress_helpers()      { :; }
require_macos_egress_mode_current() { :; }
warn_if_macos_egress_pinned()       { :; }        # host-side only
macos_vm_exists()                   { return 0; }
egress_enabled()                    { return 0; }
check_project_conf_approved()       { echo gate >> "$HOSTLOG"; }
start_proxy()                       { echo start_proxy >> "$HOSTLOG"; }
start_gvproxy()                     { :; }
resolve_macos_vm_cpu()              { echo 4; }
resolve_macos_vm_memory_mb()        { echo 8192; }
wait_for_macos_ssh()                { return 0; }
warn_if_macos_profile_stale()       { :; }
vm_cli_rec()                        { echo "$*" >> "$VMLOG"; return 0; }
VM_CLI=vm_cli_rec
# RUNNING: "1" = the VM is running, "0" = stopped, "race" = stopped at the first check and running
# from then on (another `up` brought it up in the meantime).
RUNNING=1
macos_vm_running() {
    case "$RUNNING" in
        1) return 0 ;; 0) return 1 ;;
        race) [[ -s "$VMCHECKS" ]] && return 0; echo x >> "$VMCHECKS"; return 1 ;;
    esac
}

ENV_FILE="$GUEST_HOME/.augur-env"
run_cmd() {   # run_cmd claude|shell|up — sets $out / $rc; truncates the per-run logs first
    : > "$SSHLOG"; : > "$STEPS"; : > "$VMCHECKS"; : > "$VMLOG"; : > "$HOSTLOG"; : > "$GHCALLS"
    out="$( "cmd_${1}_macos" 2>&1 )"; rc=$?
}
pushes()     { grep -c 'cat > .*\.augur-env' "$SSHLOG"; }
ssh_calls()  { grep -vc '^-t \|^scp ' "$SSHLOG"; }      # guest connections other than the launch
gh_calls()   { wc -l < "$GHCALLS" | tr -d ' '; }
mode_of()    { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
pushcmd()    { grep 'cat > .*\.augur-env' "$SSHLOG" | head -n1; }
nonzero()    { if [[ "$rc" -ne 0 ]]; then ok "$1: exits non-zero"; else fail "$1: exited 0"; fi; }

section "Tier 1 — a session on a RUNNING VM pushes the host's current credentials"

# A stale, world-readable file from an earlier push: it must be replaced, not merely rewritten.
printf "export GH_TOKEN='ghp_stale0000'\n" > "$ENV_FILE"; chmod 644 "$ENV_FILE"
export ANTHROPIC_API_KEY="test-api-key-AAA111"
GH_HOST_TOKEN="ghp_first111111"
run_cmd shell
eq "0" "$rc" "shell --macos: completes"
eq "1" "$(pushes)" "shell --macos: pushes ~/.augur-env exactly once"
eq "1" "$(ssh_calls)" "shell --macos: the push is one ssh connection (env, ~/.zshenv line and git helper together)"
eq "1" "$(gh_calls)" "shell --macos: asks gh for the token once"
envc="$(cat "$ENV_FILE")"
has   "$envc" "export GH_TOKEN='ghp_first111111'"        "shell --macos: the guest gets the host's current gh token"
has   "$envc" "export ANTHROPIC_API_KEY='test-api-key-AAA111'" "shell --macos: the guest gets the host's API key"
hasnt "$envc" "ghp_stale0000"                            "shell --macos: the stale value is gone"
eq "$MACOS_AUGUR_ENV_END_LINE" "$(tail -n 1 "$ENV_FILE")" "the installed file ends with the end marker"
eq "600" "$(mode_of "$ENV_FILE")" "the rewritten ~/.augur-env is mode 600 (a 644 one is replaced)"
eq "" "$(find "$GUEST_HOME" -maxdepth 1 -name '.augur-env.*' -print)" "no temp file is left behind"
eq "1" "$(grep -c '.augur-env' "$GUEST_HOME/.zshenv")" "~/.zshenv sources ~/.augur-env"
has "$envc" "export GIT_CONFIG_VALUE_1='" "git's credential helper is exported in ~/.augur-env"
has "$(grep '^export GIT_CONFIG_VALUE_1=' "$ENV_FILE")" 'password=$GH_TOKEN' "…holding only the \$GH_TOKEN reference"
[[ -e "$GUEST_HOME/.gitconfig" ]] && fail "the push created ~/.gitconfig" || ok "the push does not write ~/.gitconfig"
grep -q sync_macos_guest_clock "$STEPS" && ok "shell --macos: the clock is synced on this path (control)" \
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
eq "1" "$(gh_calls)" "claude --macos: asks gh for the token once"
envc="$(cat "$ENV_FILE")"
has   "$envc" "export GH_TOKEN='ghp_rotated22222'"       "claude --macos: a rotated gh token reaches the running guest"
hasnt "$envc" "ghp_first111111"                          "claude --macos: the old gh token is gone"
has   "$envc" "export ANTHROPIC_API_KEY='test-api-key-BBB222'" "claude --macos: a changed API key reaches the running guest"
eq "1" "$(grep -c '.augur-env' "$GUEST_HOME/.zshenv")" "~/.zshenv's source line is not duplicated by a second session"
launch_at="$(grep -n '^-t ' "$SSHLOG" | cut -d: -f1)"; push_at="$(grep -n 'cat > .*\.augur-env' "$SSHLOG" | cut -d: -f1)"
if [[ -n "$launch_at" && -n "$push_at" && "$push_at" -lt "$launch_at" ]]; then
    ok "claude --macos: the push precedes the launch (push@$push_at < launch@$launch_at)"
else fail "claude --macos: the agent launches before the push" "push@${push_at:-none} launch@${launch_at:-none}"; fi

# A host `gh auth logout`: the whole file is rewritten, so GH_TOKEN disappears from the guest, and
# the GIT_CONFIG_* credential helper goes with it (see git_credential_env).
GH_HOST_TOKEN=""
run_cmd shell
eq "0" "$rc" "gh logged out on the host: shell --macos still completes"
envc="$(cat "$ENV_FILE")"
hasnt "$envc" "GH_TOKEN" "gh logged out on the host: GH_TOKEN is dropped from ~/.augur-env"
has   "$envc" "ANTHROPIC_API_KEY" "gh logged out on the host: the other credentials are still written"
hasnt "$envc" "GIT_CONFIG_" "gh logged out on the host: git's credential helper is dropped from ~/.augur-env too"

section "Tier 1 — the guest installs only complete content, and cleans up stale temp files"

GH_HOST_TOKEN="ghp_rotated22222"
run_cmd shell
pc="$(pushcmd)"; before="$(cat "$ENV_FILE")"
# Content cut short in transit: everything but the end marker.
printf "export GH_TOKEN='ghp_trunc'\n" | guest_run "$pc"; trc=$?
if [[ "$trc" -ne 0 ]]; then ok "truncated content: the guest command fails"
else fail "truncated content: the guest command succeeded"; fi
eq "$before" "$(cat "$ENV_FILE")" "truncated content: the previous ~/.augur-env is kept"
eq "" "$(find "$GUEST_HOME" -maxdepth 1 -name '.augur-env.*' -print)" "truncated content: no temp file is left behind"

# A temp file left by a push killed mid-write long ago, a fresh one (a concurrent push still
# writing), and a file that is not augur's at all.
printf "export GH_TOKEN='ghp_revoked'\n" > "$GUEST_HOME/.augur-env.tmp.4242"; touch -t 202001010000 "$GUEST_HOME/.augur-env.tmp.4242"
printf 'in progress\n'                   > "$GUEST_HOME/.augur-env.tmp.4343"
printf 'mine\n'                          > "$GUEST_HOME/.augur-env.bak"; touch -t 202001010000 "$GUEST_HOME/.augur-env.bak"
run_cmd shell
eq "0" "$rc" "stale temp files: shell --macos completes"
[[ -e "$GUEST_HOME/.augur-env.tmp.4242" ]] && fail "an old temp file survives (it may hold revoked secrets)" \
    || ok "a temp file older than a minute is removed"
[[ -e "$GUEST_HOME/.augur-env.tmp.4343" ]] && ok "a fresh temp file (a concurrent push) is left alone" \
    || fail "a concurrent push's temp file was removed (its mv would then fail)"
[[ -e "$GUEST_HOME/.augur-env.bak" ]] && ok "a file outside augur's temp-name pattern is left alone" \
    || fail "cleanup removed a file that is not augur's"
rm -f "$GUEST_HOME/.augur-env.tmp.4343" "$GUEST_HOME/.augur-env.bak"

section "Tier 1 — a credential that cannot be injected aborts before the guest is touched"

before="$(cat "$ENV_FILE")"
export ANTHROPIC_API_KEY="test-api-key-bad'quote"
for _cmd in shell claude up; do
    run_cmd "$_cmd"
    nonzero "bad ANTHROPIC_API_KEY: $_cmd --macos"
    has "$out" "Refusing to inject ANTHROPIC_API_KEY" "bad ANTHROPIC_API_KEY: $_cmd --macos names the variable"
    eq "0" "$(pushes)" "bad ANTHROPIC_API_KEY: $_cmd --macos sends no push"
    [[ "$_cmd" == up ]] && break
    eq "" "$(cat "$SSHLOG")" "bad ANTHROPIC_API_KEY: $_cmd --macos sends nothing over ssh"
    eq "" "$(cat "$STEPS")" "bad ANTHROPIC_API_KEY: $_cmd --macos runs no guest step (clock, workspace, …)"
done
# `up` on a running VM refuses only at the push: a bad credential must not block a revocation
# landing, a dead proxy being revived, the clock fix or the self-test that proves enforcement.
has "$(cat "$HOSTLOG")" "gate"        "bad ANTHROPIC_API_KEY: up --macos on a running VM still runs the approval gate (allowlist rewrite)"
has "$(cat "$HOSTLOG")" "start_proxy" "bad ANTHROPIC_API_KEY: up --macos on a running VM still revives the proxy"
has "$(cat "$STEPS")" "sync_macos_guest_clock"     "bad ANTHROPIC_API_KEY: up --macos on a running VM still fixes the guest clock"
has "$(cat "$STEPS")" "verify_macos_egress_locked" "bad ANTHROPIC_API_KEY: up --macos on a running VM still runs the egress self-test"
eq "$before" "$(cat "$ENV_FILE")" "bad ANTHROPIC_API_KEY: the guest's ~/.augur-env is unchanged"
# On a boot it refuses before the VM backend is called at all.
RUNNING=0
for _cmd in claude up; do
    run_cmd "$_cmd"
    nonzero "bad ANTHROPIC_API_KEY, VM stopped: $_cmd --macos"
    eq "" "$(cat "$VMLOG")" "bad ANTHROPIC_API_KEY, VM stopped: $_cmd --macos never calls augur-vm (no clone, set or run)"
done
RUNNING=1
export ANTHROPIC_API_KEY="test-api-key-BBB222"
GH_HOST_TOKEN=$'ghp_bad\tcontrol'
run_cmd claude
nonzero "bad gh token: claude --macos"
has "$out" "Refusing to inject GH_TOKEN" "bad gh token: names GH_TOKEN"
eq "" "$(cat "$SSHLOG")" "bad gh token: nothing is sent over ssh"
eq "$before" "$(cat "$ENV_FILE")" "bad gh token: the guest's ~/.augur-env is unchanged"
GH_HOST_TOKEN="ghp_rotated22222"

section "Tier 1 — a credential file that cannot be read aborts before the guest is touched"

unset ANTHROPIC_API_KEY
if [[ "$(id -u)" == 0 ]]; then
    skip "unreadable credential file" "running as root: chmod 000 does not stop root reading it"
else
    printf 'test-oauth-unreadable\n' > "$HOME/.claude_code_oauth_token"; chmod 000 "$HOME/.claude_code_oauth_token"
    for _cmd in shell claude up; do
        run_cmd "$_cmd"
        nonzero "unreadable token file, running VM: $_cmd --macos"
        has "$out" "Could not read" "unreadable token file, running VM: $_cmd --macos says the file could not be read"
        eq "0" "$(pushes)" "unreadable token file, running VM: $_cmd --macos sends no push"
        if [[ "$_cmd" == up ]]; then
            has "$(cat "$STEPS")" "verify_macos_egress_locked" "unreadable token file, running VM: up --macos still runs the egress self-test first"
        else
            eq "" "$(cat "$STEPS")" "unreadable token file, running VM: $_cmd --macos runs no guest step (no clock/timezone sync)"
        fi
        eq "$before" "$(cat "$ENV_FILE")" "unreadable token file, running VM: $_cmd --macos leaves the guest's ~/.augur-env unchanged"
    done
    RUNNING=0
    for _cmd in claude up; do
        run_cmd "$_cmd"
        nonzero "unreadable token file, VM stopped: $_cmd --macos"
        has "$out" "Could not read" "unreadable token file, VM stopped: $_cmd --macos says the file could not be read"
        eq "" "$(cat "$VMLOG")" "unreadable token file, VM stopped: $_cmd --macos never calls augur-vm (no clone, set or run)"
        eq "" "$(cat "$STEPS")" "unreadable token file, VM stopped: $_cmd --macos runs no guest step"
    done
    RUNNING=1
    chmod 600 "$HOME/.claude_code_oauth_token"; rm -f "$HOME/.claude_code_oauth_token"
fi

section "Tier 1 — each credential is read once, and the bytes written are the bytes validated"

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
for _cmd in shell up; do
    : > "$READS"; GOOD_READS=1
    run_cmd "$_cmd"
    eq "0" "$rc" "file rewritten after its first read: $_cmd --macos completes"
    eq "1" "$(wc -l < "$READS" | tr -d ' ')" "$_cmd --macos reads the token file exactly once"
    has   "$(cat "$ENV_FILE")" "export CLAUDE_CODE_OAUTH_TOKEN='test-oauth-good-1111'" "$_cmd --macos writes the value it validated"
    hasnt "$(cat "$ENV_FILE")" "injected" "$_cmd --macos never writes the later, unchecked content"
done
: > "$READS"; GOOD_READS=0
run_cmd shell
nonzero "token file bad from the first read: shell --macos"
eq "0" "$(pushes)" "token file bad from the first read: nothing is pushed"
eval "$real_resolve"

section "Tier 1 — a push that fails in transport"

export ANTHROPIC_API_KEY="test-api-key-BBB222"
before="$(cat "$ENV_FILE")"
FAIL_PUSH=1
for _cmd in shell claude; do
    run_cmd "$_cmd"
    eq "0" "$rc" "push fails, running VM: $_cmd --macos still opens the session"
    has "$out" "Continuing to open the session" "push fails, running VM: $_cmd --macos says it goes on without the refresh"
    grep -q '^-t ' "$SSHLOG" && ok "push fails, running VM: $_cmd --macos still launches" \
        || fail "push fails, running VM: $_cmd --macos did not launch"
done
# A dropped connection (ssh's 255) may have come after the rename, so it must not claim either way.
has   "$out" "unknown outcome (ssh exit 255)" "connection dropped: the outcome is reported as unknown"
hasnt "$out" "is unchanged"                   "connection dropped: it does not claim the old file is still there"
FAIL_PUSH=2
run_cmd shell
has   "$out" "is unchanged"                   "guest reports a failed install: says the old file is kept"
hasnt "$out" "unknown outcome"                "guest reports a failed install: the outcome is not called unknown"
for FAIL_PUSH in 1 2; do
    RUNNING=1; run_cmd up
    nonzero "push fails ($FAIL_PUSH), running VM: up --macos"
    RUNNING=0; run_cmd up
    nonzero "push fails ($FAIL_PUSH), boot: up --macos"
done
RUNNING=1
FAIL_PUSH=0
eq "$before" "$(cat "$ENV_FILE")" "push fails: the guest's ~/.augur-env is unchanged"

section "Tier 1 — every path pushes exactly once"

GH_HOST_TOKEN="ghp_boot333333"
RUNNING=0
for _cmd in shell claude up; do
    run_cmd "$_cmd"
    eq "0" "$rc" "not running: $_cmd --macos boots and completes"
    has "$out" "is up." "not running: $_cmd --macos went through the boot path (control)"
    eq "1" "$(pushes)" "not running: $_cmd --macos pushes ~/.augur-env exactly once"
    eq "1" "$(gh_calls)" "not running: $_cmd --macos asks gh for the token once"
    eq "1" "$(grep -c '^ensure_macos_workspace$' "$STEPS")" "not running: $_cmd --macos wires the guest once"
    has "$(cat "$ENV_FILE")" "export GH_TOKEN='ghp_boot333333'" "not running: $_cmd --macos: the booted guest has the host's gh token"
done

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
eq "1" "$(gh_calls)" "up --macos on a running VM: asks gh for the token once"
has "$(cat "$ENV_FILE")" "export GH_TOKEN='ghp_up5555555'" "up --macos on a running VM: the guest gets the current gh token"
# On the running branch the self-test still precedes the push: credentials go to a guest just
# proven contained. The self-test stub leaves a marker in SSHLOG so the two are in one ordering.
verify_macos_egress_locked() { printf 'MARK:self-test\n' >> "$SSHLOG"; }
run_cmd up
st_at="$(grep -n '^MARK:self-test' "$SSHLOG" | cut -d: -f1)"; push_at="$(grep -n 'cat > .*\.augur-env' "$SSHLOG" | cut -d: -f1)"
if [[ -n "$st_at" && -n "$push_at" && "$st_at" -lt "$push_at" ]]; then
    ok "up --macos on a running VM: the self-test precedes the push (self-test@$st_at < push@$push_at)"
else fail "up --macos on a running VM: the push is not after the self-test" "self-test@${st_at:-none} push@${push_at:-none}"; fi

section "Tier 1 — no credential value is ever on an ssh argv"

leaked=""
for _v in ghp_first111111 ghp_rotated22222 ghp_boot333333 ghp_race444444 ghp_up5555555 ghp_bad \
          ghp_revoked test-api-key-AAA111 test-api-key-BBB222 test-api-key-bad test-oauth; do
    grep -qF "$_v" "$ALL_SSH" && leaked+=" $_v"
done
[[ -s "$ALL_SSH" ]] && ok "control: the argv log is not empty ($(wc -l < "$ALL_SSH" | tr -d ' ') calls)" \
    || fail "control: no ssh call was recorded"
eq "" "$leaked" "no credential value appears on any recorded ssh / scp argv"

finish
