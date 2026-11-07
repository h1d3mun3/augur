#!/usr/bin/env bash
# Tier 1 — macOS mode delivers credentials only as the SSH environment of the session that
# `augur claude --macos` / `augur shell --macos` starts, never on the guest's disk (runs anywhere;
# nothing is cloned or booted, and the "guest" is a local `bash -c` against a sandboxed home).
#
# Pinned here:
#   • the session's ssh carries `-o SendEnv=<NAME>` for exactly the resolved credentials, and their
#     values only in that ssh process's environment: on no argv, in no file in the guest, and (for
#     values augur reads from a host file or `gh`) in no other ssh call's environment;
#   • ~/.augur-env (the guest's per-VM, non-secret env) is pushed on every up/claude/shell, holds no
#     credential, and a push replaces one an older augur wrote with credentials in it;
#   • the write is atomic and mode 600, the guest installs only content ending in the end marker,
#     and temp files older than a minute (left by a killed push) are removed while a fresh one stays;
#   • each credential is read once per invocation and the values sent are the values validated;
#   • a credential that cannot be injected, or a credential file that cannot be read, aborts before
#     anything reaches the guest (on a boot: before the VM backend is called at all), while
#     `up --macos` on a running VM still rewrites the allowlist, revives the proxy, fixes the clock
#     and runs the self-test first;
#   • a guest whose sshd does not accept the session's credentials is refused with the remedy, and
#     gets no session; so is one whose acceptance cannot be checked;
#   • a push that fails is fatal on every path;
#   • every path pushes exactly once and launches exactly once: running VM, boot, a VM that came up
#     in the meantime; `up --macos` launches nothing;
#   • augur's other ssh calls (ssh_macos) carry no SendEnv, and `setup-token --macos` gets nothing;
#   • the base VM build and update write the sshd AcceptEnv drop-in, and the session check accepts
#     exactly what they write.
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
MACOS_SSH_KEY="$TMPD/no-such-key"
unset ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN GH_TOKEN GITHUB_TOKEN GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_CONFIG_COUNT
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
SSHLOG="$TMPD/sshlog"      # every ssh_macos argv of the current run
ALL_SSH="$TMPD/all-ssh"    # every ssh argv of the whole file (ssh_macos, scp, the real `ssh`)
OTHERENV="$TMPD/otherenv"  # credential variables in augur's own environment at each ssh_macos call
STEPS="$TMPD/steps"        # guest-touching steps that are stubbed out
VMLOG="$TMPD/vmlog"        # every augur-vm call
HOSTLOG="$TMPD/hostlog"    # host-side reconcile steps (approval gate, proxy start)
GHCALLS="$TMPD/ghcalls"    # one line per `gh auth token`
VMCHECKS="$TMPD/vmchecks"
: > "$ALL_SSH"; : > "$OTHERENV"

# The real `ssh` a session execs, on PATH: records its argv (one argument per line, after an
# "ARGV" line) and the credential variables in ITS OWN environment. Exits $SHIM_RC.
SHIMDIR="$TMPD/shim"; mkdir -p "$SHIMDIR"
export SESSLOG="$TMPD/sesslog" SHIM_RC=0
cat > "$SHIMDIR/ssh" <<'EOF'
#!/usr/bin/env bash
{ echo "ARGV"; printf '%s\n' "$@"; echo "ENV"
  env | grep -E '^(ANTHROPIC_API_KEY|CLAUDE_CODE_OAUTH_TOKEN|GH_TOKEN)=' | sort; echo "END"; } >> "$SESSLOG"
exit "$SHIM_RC"
EOF
chmod +x "$SHIMDIR/ssh"
PATH="$SHIMDIR:$PATH"
macos_ssh_host() { echo 127.0.0.1; }
macos_ssh_port() { echo 2222; }

# The host's gh token, switchable per case. Empty = `gh auth token` fails (logged out).
GH_HOST_TOKEN=""
gh() {
    [[ "$1 $2" == "auth token" ]] && echo x >> "$GHCALLS"
    [[ "$1 $2" == "auth token" && -n "$GH_HOST_TOKEN" ]] || return 1
    printf '%s\n' "$GH_HOST_TOKEN"
}

# The guest. The commands that write or read guest state run for real under `bash -c` in
# GUEST_HOME, with the guest's /Users/<user> mapped onto it and /etc/ssh onto GUEST_ETC, so the
# assertions are about the resulting files.
# FAIL_PUSH=1 makes the push connection drop the way ssh reports it (255, outcome unknown);
# FAIL_PUSH=2 makes the guest report a failed install (exit 1, old file kept).
# FAIL_CHECK=1 makes the session-env acceptance check's connection fail (255).
GUEST_HOME="$TMPD/guest"; mkdir -p "$GUEST_HOME"
GUEST_ETC="$TMPD/guest-etc"; mkdir -p "$GUEST_ETC/ssh/sshd_config.d"
FAIL_PUSH=0; FAIL_CHECK=0
guest_map() { local c="${1//\/Users\/${MACOS_SSH_USER}/$GUEST_HOME}"; printf '%s' "${c//\/etc\/ssh/$GUEST_ETC/ssh}"; }
guest_run() { HOME="$GUEST_HOME" bash -c "$(guest_map "$1")"; }
ssh_macos() {
    local vm="$1"; shift
    printf '%s\n' "$*" | tee -a "$ALL_SSH" >> "$SSHLOG"
    env | grep -E '^(CLAUDE_CODE_OAUTH_TOKEN|GH_TOKEN)=' >> "$OTHERENV"
    case "$*" in
        *"sshd_config.d"*)
            [[ "$FAIL_CHECK" == 1 ]] && return 255
            guest_run "$*" ;;
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

# The base VM build's drop-in install, run for real against GUEST_ETC: `sudo -S -p ''` reads the
# password line and runs the rest, `chown root:wheel` is a no-op (no root here), and `sshd -T`
# prints the AcceptEnv patterns of every drop-in, one `acceptenv` line each, as OpenSSH does.
# SSHD_T_FAILS=1 makes `sshd -T` print nothing (a configuration it cannot parse).
SSHD_T_FAILS=0
cat > "$SHIMDIR/sshd" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == -T && "${SSHD_T_FAILS:-0}" != 1 ]] || exit 255
echo "port 22"
cat "$GUEST_ETC"/ssh/sshd_config.d/*.conf 2>/dev/null | awk '$1 == "AcceptEnv" { for (i = 2; i <= NF; i++) print "acceptenv " $i }'
EOF
chmod +x "$SHIMDIR/sshd"
BUILDLOG="$TMPD/buildlog"
build_ssh() {   # an ssh_macos for the build path
    local vm="$1"; shift
    local c="$*"
    printf '%s\n' "$c" >> "$BUILDLOG"
    c="$(guest_map "$c")"
    c="${c//\/usr\/sbin\/sshd/$SHIMDIR/sshd}"
    c="${c//chown root:wheel/true}"
    [[ "$c" == "sudo -S -p '' "* ]] || { echo "UNEXPECTED BUILD COMMAND: $c" >&2; return 1; }
    IFS= read -r _pw; printf '%s\n' "$_pw" > "$TMPD/build-stdin"
    GUEST_ETC="$GUEST_ETC" SSHD_T_FAILS="$SSHD_T_FAILS" bash -c "${c#"sudo -S -p '' "}"
}
install_dropin() {   # sets $out / $rc
    : > "$BUILDLOG"
    out="$( ssh_macos() { build_ssh "$@"; }; install_macos_session_env_acceptance "$(macos_project_vm)" 2>&1 )"; rc=$?
}
DROPIN="$GUEST_ETC/ssh/sshd_config.d/$(basename "$(macos_session_sshd_dropin)")"

ENV_FILE="$GUEST_HOME/.augur-env"
run_cmd() {   # run_cmd claude|shell|up — sets $out / $rc; truncates the per-run logs first
    : > "$SSHLOG"; : > "$STEPS"; : > "$VMCHECKS"; : > "$VMLOG"; : > "$HOSTLOG"; : > "$GHCALLS"; : > "$SESSLOG"
    out="$( "cmd_${1}_macos" 2>&1 )"; rc=$?
    # The session ssh's argv joins the whole-file argv log, for the no-value-on-argv check.
    awk '/^ARGV$/{a=1; next} /^ENV$/{a=0} a' "$SESSLOG" >> "$ALL_SSH"
}
pushes()     { grep -c 'cat > .*\.augur-env' "$SSHLOG"; }
ssh_calls()  { grep -vc '^scp ' "$SSHLOG"; }            # guest connections other than the session
gh_calls()   { wc -l < "$GHCALLS" | tr -d ' '; }
launches()   { grep -cx ARGV "$SESSLOG"; }
sess_argv()  { awk '/^ARGV$/{a=1; next} /^ENV$/{a=0} a' "$SESSLOG"; }
sess_env()   { awk '/^ENV$/{a=1; next} /^END$/{a=0} a' "$SESSLOG"; }
sendenv()    { sess_argv | sed -n 's/^SendEnv=//p' | sort | tr '\n' ' '; }
mode_of()    { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
pushcmd()    { grep 'cat > .*\.augur-env' "$SSHLOG" | head -n1; }
nonzero()    { if [[ "$rc" -ne 0 ]]; then ok "$1: exits non-zero"; else fail "$1: exited 0"; fi; }

section "Tier 1 — the base VM build writes the sshd drop-in that accepts the session's credentials"

install_dropin
eq "0" "$rc" "the drop-in install succeeds when sshd confirms it"
eq "$(macos_session_accept_env_line)" "$(grep -v '^#' "$DROPIN")" "the drop-in holds exactly one AcceptEnv line"
eq "AcceptEnv ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN GH_TOKEN" "$(macos_session_accept_env_line)" \
   "it names exactly the agent's credentials and GH_TOKEN, no patterns"
eq "644" "$(mode_of "$DROPIN")" "the drop-in is mode 644"
eq "$MACOS_MANUAL_SETUP_PASSWORD" "$(cat "$TMPD/build-stdin")" "the sudo password goes on ssh's stdin"
hasnt "$(cat "$BUILDLOG")" "$MACOS_MANUAL_SETUP_PASSWORD" "the sudo password is on no ssh argv"
eq "" "$(find "$GUEST_ETC/ssh/sshd_config.d" -name '*.tmp' -print)" "no temp file is left behind"
SSHD_T_FAILS=1
install_dropin
nonzero "sshd does not confirm the names: the install"
has "$out" "Could not make the base VM's sshd accept" "sshd does not confirm the names: says so"
[[ -e "$DROPIN" ]] && fail "sshd does not confirm the names: the drop-in is left in place" \
    || ok "sshd does not confirm the names: the drop-in is removed again (sshd keeps a config it can parse)"
SSHD_T_FAILS=0
real_names="$(declare -f session_credential_names)"
session_credential_names() { echo 'BAD*NAME'; }
install_dropin
nonzero "a credential name that is a pattern: the install"
eq "" "$(cat "$BUILDLOG")" "a credential name that is a pattern: nothing reaches the guest"
eval "$real_names"
install_dropin
eq "0" "$rc" "reinstall (control)"

# Where the build and update call it: before the base VM is saved, and fatal.
fn_body() { awk -v n="$1" '$0 ~ "^"n"\\(\\) \\{"{f=1} f{print} f&&/^}/{exit}' "$AUGUR"; }
build_body="$(fn_body cmd_build_macos)"; update_body="$(fn_body cmd_update_macos)"
has "$build_body"  'install_macos_session_env_acceptance "$MACOS_BUILD_VM" || exit 1' "build --macos installs the drop-in, fatally"
has "$update_body" 'install_macos_session_env_acceptance "$MACOS_UPDATE_VM" || {' "update --macos installs the drop-in, fatally"
for _b in build update; do
    _body="$build_body"; [[ "$_b" == update ]] && _body="$update_body"
    i_at="$(printf '%s\n' "$_body" | grep -n 'install_macos_session_env_acceptance' | head -n1 | cut -d: -f1)"
    s_at="$(printf '%s\n' "$_body" | grep -n 'agent_verify_integrity_macos "\$MACOS_' | head -n1 | cut -d: -f1)"
    if [[ -n "$i_at" && -n "$s_at" && "$i_at" -lt "$s_at" ]]; then ok "$_b --macos installs it before the final check and the save"
    else fail "$_b --macos does not install it before the save" "install@${i_at:-none} check@${s_at:-none}"; fi
done

section "Tier 1 — a session on a RUNNING VM: credentials in the session's ssh environment only"

# A stale, world-readable file an older augur wrote, with a credential in it: it must be replaced.
printf "export GH_TOKEN='ghp_stale0000'\n" > "$ENV_FILE"; chmod 644 "$ENV_FILE"
export ANTHROPIC_API_KEY="test-api-key-AAA111"
GH_HOST_TOKEN="ghp_first111111"
run_cmd shell
eq "0" "$rc" "shell --macos: completes"
eq "1" "$(launches)" "shell --macos: execs the session ssh exactly once"
eq "ANTHROPIC_API_KEY GH_TOKEN " "$(sendenv)" "shell --macos: the session ssh sends exactly the resolved names"
has "$(sess_env)" "GH_TOKEN=ghp_first111111"           "shell --macos: the gh token is in the session ssh's environment"
has "$(sess_env)" "ANTHROPIC_API_KEY=test-api-key-AAA111" "shell --macos: the API key is in the session ssh's environment"
hasnt "$(sess_env)" "CLAUDE_CODE_OAUTH_TOKEN" "shell --macos: an absent credential is neither sent nor set"
has "$(sess_argv | tr '\n' ' ')" "-F /dev/null" "shell --macos: the session ssh is hermetic like every other"
has "$(sess_argv | tail -n1)" "exec zsh -l" "shell --macos: the session runs the login shell"
hasnt "$(sess_argv | tr '\n' ' ')" "SetEnv" "shell --macos: no SetEnv (it would put values on argv)"
eq "1" "$(pushes)" "shell --macos: pushes ~/.augur-env exactly once"
eq "2" "$(ssh_calls)" "shell --macos: two other ssh connections (the acceptance check, then the push)"
eq "1" "$(gh_calls)" "shell --macos: asks gh for the token once"
envc="$(cat "$ENV_FILE")"
hasnt "$envc" "export GH_TOKEN"   "shell --macos: ~/.augur-env exports no GH_TOKEN"
hasnt "$envc" "ghp_first111111"   "shell --macos: ~/.augur-env holds no gh token value"
hasnt "$envc" "ANTHROPIC_API_KEY" "shell --macos: ~/.augur-env holds no API key"
hasnt "$envc" "ghp_stale0000"     "shell --macos: the credential an older augur wrote is gone"
has   "$envc" "DEVELOPER_DIR"     "shell --macos: ~/.augur-env still carries the non-secret env (control)"
eq "$MACOS_AUGUR_ENV_END_LINE" "$(tail -n 1 "$ENV_FILE")" "the installed file ends with the end marker"
eq "600" "$(mode_of "$ENV_FILE")" "the rewritten ~/.augur-env is mode 600 (a 644 one is replaced)"
eq "" "$(find "$GUEST_HOME" -maxdepth 1 -name '.augur-env.*' -print)" "no temp file is left behind"
eq "1" "$(grep -c '.augur-env' "$GUEST_HOME/.zshenv")" "~/.zshenv sources ~/.augur-env"
has "$envc" "export GIT_CONFIG_VALUE_1='" "git's credential helper is exported in ~/.augur-env"
has "$(grep '^export GIT_CONFIG_VALUE_1=' "$ENV_FILE")" 'password=$GH_TOKEN' "…holding only the \$GH_TOKEN reference"
[[ -e "$GUEST_HOME/.gitconfig" ]] && fail "the push created ~/.gitconfig" || ok "the push does not write ~/.gitconfig"
grep -q sync_macos_guest_clock "$STEPS" && ok "shell --macos: the clock is synced on this path (control)" \
    || fail "shell --macos: the clock sync did not run" "steps: $(tr '\n' ' ' < "$STEPS")"
chk_at="$(grep -n 'sshd_config.d' "$SSHLOG" | head -n1 | cut -d: -f1)"; push_at="$(grep -n 'cat > .*\.augur-env' "$SSHLOG" | cut -d: -f1)"
if [[ "$chk_at" == 1 && -n "$push_at" ]]; then ok "shell --macos: the acceptance check is the first guest command"
else fail "shell --macos: the acceptance check is not first" "check@${chk_at:-none} push@${push_at:-none}"; fi

# The shape that makes the write atomic and private.
pc="$(pushcmd)"
umask_at="${pc%%umask 077*}"; cat_at="${pc%%cat > *}"
if [[ "$pc" == *"umask 077"* && ${#umask_at} -lt ${#cat_at} ]]; then
    ok "the temp file is created under umask 077"
else fail "the push does not set umask 077 before writing" "$pc"; fi
has "$pc" "mv -f " "the temp file is renamed over ~/.augur-env (a concurrent zsh never sees a partial file)"

GH_HOST_TOKEN="ghp_rotated22222"
export ANTHROPIC_API_KEY="test-api-key-BBB222"
printf 'test-oauth-file-CCC333\n' > "$HOME/.claude_code_oauth_token"
run_cmd claude
eq "0" "$rc" "claude --macos: completes"
eq "1" "$(launches)" "claude --macos: execs the session ssh exactly once"
eq "ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN GH_TOKEN " "$(sendenv)" "claude --macos: the session ssh sends exactly the resolved names"
has "$(sess_env)" "GH_TOKEN=ghp_rotated22222"                "claude --macos: a rotated gh token reaches the session"
has "$(sess_env)" "ANTHROPIC_API_KEY=test-api-key-BBB222"    "claude --macos: a changed API key reaches the session"
has "$(sess_env)" "CLAUDE_CODE_OAUTH_TOKEN=test-oauth-file-CCC333" "claude --macos: a token from the host file reaches the session"
has "$(sess_argv | tail -n1)" "zsh -l -c" "claude --macos: the session runs the agent under a login zsh"
eq "1" "$(pushes)" "claude --macos: pushes ~/.augur-env exactly once"
eq "1" "$(gh_calls)" "claude --macos: asks gh for the token once"
hasnt "$(cat "$ENV_FILE")" "test-oauth-file-CCC333" "claude --macos: ~/.augur-env holds no OAuth token"
eq "1" "$(grep -c '.augur-env' "$GUEST_HOME/.zshenv")" "~/.zshenv's source line is not duplicated by a second session"
# git's credential helper (git_credential_env) is in ~/.augur-env, holding only the `$GH_TOKEN`
# reference; the token itself arrives with the session.
envc="$(cat "$ENV_FILE")"
has   "$envc" "export GIT_CONFIG_COUNT='2'" "claude --macos: ~/.augur-env carries git's credential helper (GIT_CONFIG_COUNT=2)"
has   "$envc" "export GIT_CONFIG_VALUE_0=''" "claude --macos: …with the empty reset entry first"
has   "$envc" 'password=$GH_TOKEN' "claude --macos: …whose helper holds the \$GH_TOKEN reference"
hasnt "$envc" "ghp_rotated22222" "claude --macos: …and no token value"
leaks="$(grep -c . "$OTHERENV")"
eq "0" "$leaks" "no other ssh call has a file- or gh-sourced credential in its environment"
hasnt "$(cat "$SSHLOG")" "SendEnv" "no other ssh call carries a SendEnv"
grep -rlF -e ghp_rotated22222 -e test-oauth-file-CCC333 -e test-api-key-BBB222 "$GUEST_HOME" "$GUEST_ETC" >/dev/null 2>&1 \
    && fail "a credential value is in a guest file" "$(grep -rlF -e ghp_rotated22222 -e test-oauth-file-CCC333 -e test-api-key-BBB222 "$GUEST_HOME" "$GUEST_ETC")" \
    || ok "no credential value is in any guest file"
rm -f "$HOME/.claude_code_oauth_token"

# A host `gh auth logout`: the next session gets no GH_TOKEN, and the rewritten ~/.augur-env has no
# GIT_CONFIG_* credential helper either (see git_credential_env).
GH_HOST_TOKEN=""
run_cmd shell
eq "0" "$rc" "gh logged out on the host: shell --macos still completes"
eq "ANTHROPIC_API_KEY " "$(sendenv)" "gh logged out on the host: GH_TOKEN is not sent"
hasnt "$(sess_env)" "GH_TOKEN" "gh logged out on the host: GH_TOKEN is not in the session ssh's environment"
hasnt "$(cat "$ENV_FILE")" "GIT_CONFIG_" "gh logged out on the host: git's credential helper is dropped from ~/.augur-env"
hasnt "$(pushcmd)" "git config" "gh logged out on the host: the push sends no git config command"

# Nothing to send: the session ssh has no SendEnv at all.
unset ANTHROPIC_API_KEY
run_cmd shell
eq "0" "$rc" "no credentials on the host: shell --macos still completes"
eq "" "$(sendenv)" "no credentials on the host: the session ssh sends nothing"

section "Tier 1 — the guest installs only complete content, and cleans up stale temp files"

export ANTHROPIC_API_KEY="test-api-key-BBB222"
GH_HOST_TOKEN="ghp_rotated22222"
run_cmd shell
pc="$(pushcmd)"; before="$(cat "$ENV_FILE")"
# Content cut short in transit: everything but the end marker.
printf "export PATH=/broken\n" | guest_run "$pc"; trc=$?
if [[ "$trc" -ne 0 ]]; then ok "truncated content: the guest command fails"
else fail "truncated content: the guest command succeeded"; fi
eq "$before" "$(cat "$ENV_FILE")" "truncated content: the previous ~/.augur-env is kept"
eq "" "$(find "$GUEST_HOME" -maxdepth 1 -name '.augur-env.*' -print)" "truncated content: no temp file is left behind"

# A temp file left by a push killed mid-write long ago (an older augur's may hold a credential), a
# fresh one (a concurrent push still writing), and a file that is not augur's at all.
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

section "Tier 1 — a guest whose sshd does not accept the session's credentials is refused"

before="$(cat "$ENV_FILE")"
mv "$DROPIN" "$TMPD/dropin.saved"
for _cmd in shell claude; do
    run_cmd "$_cmd"
    nonzero "no drop-in, running VM: $_cmd --macos"
    has "$out" "does not accept augur's session credentials" "no drop-in, running VM: $_cmd --macos says why"
    has "$out" "augur update --macos" "no drop-in, running VM: $_cmd --macos names the base VM update"
    has "$out" "augur destroy --macos && augur up --macos" "no drop-in, running VM: $_cmd --macos names the project VM recreate"
    eq "0" "$(launches)" "no drop-in, running VM: $_cmd --macos starts no session (no credential is sent)"
    eq "0" "$(pushes)" "no drop-in, running VM: $_cmd --macos pushes nothing"
    eq "" "$(cat "$STEPS")" "no drop-in, running VM: $_cmd --macos runs no guest step (clock, workspace, …)"
done
eq "$before" "$(cat "$ENV_FILE")" "no drop-in: the guest's ~/.augur-env is unchanged"
RUNNING=0
run_cmd claude
nonzero "no drop-in, VM stopped: claude --macos"
has "$out" "is up." "no drop-in, VM stopped: the VM is booted first (control)"
has "$out" "augur update --macos" "no drop-in, VM stopped: then refused with the remedy"
eq "0" "$(launches)" "no drop-in, VM stopped: claude --macos starts no session"
RUNNING=1
run_cmd up
eq "0" "$rc" "no drop-in: up --macos is not refused (it starts no session)"
# A drop-in for a different set of names (the agent's credentials changed since the base VM build).
printf '# augur\nAcceptEnv ANTHROPIC_API_KEY GH_TOKEN\n' > "$DROPIN"
run_cmd shell
nonzero "a drop-in for other names: shell --macos"
eq "0" "$(launches)" "a drop-in for other names: no session"
mv "$TMPD/dropin.saved" "$DROPIN"
FAIL_CHECK=1
run_cmd shell
nonzero "the acceptance check cannot connect: shell --macos"
has "$out" "Could not check whether VM" "the acceptance check cannot connect: says the check failed"
eq "0" "$(launches)" "the acceptance check cannot connect: no session"
FAIL_CHECK=0

section "Tier 1 — a credential that cannot be injected aborts before the guest is touched"

before="$(cat "$ENV_FILE")"
export ANTHROPIC_API_KEY="test-api-key-bad'quote"
for _cmd in shell claude up; do
    run_cmd "$_cmd"
    nonzero "bad ANTHROPIC_API_KEY: $_cmd --macos"
    has "$out" "Refusing to inject ANTHROPIC_API_KEY" "bad ANTHROPIC_API_KEY: $_cmd --macos names the variable"
    eq "0" "$(pushes)" "bad ANTHROPIC_API_KEY: $_cmd --macos sends no push"
    eq "0" "$(launches)" "bad ANTHROPIC_API_KEY: $_cmd --macos starts no session"
    [[ "$_cmd" == up ]] && break
    eq "" "$(cat "$SSHLOG")" "bad ANTHROPIC_API_KEY: $_cmd --macos sends nothing over ssh"
    eq "" "$(cat "$STEPS")" "bad ANTHROPIC_API_KEY: $_cmd --macos runs no guest step (clock, workspace, …)"
done
# `up` on a running VM refuses only after its self-test: a bad credential must not block a
# revocation landing, a dead proxy being revived, the clock fix or the self-test that proves
# enforcement.
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
eq "0" "$(launches)" "bad gh token: no session"
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
        eq "0" "$(launches)" "unreadable token file, running VM: $_cmd --macos starts no session"
        if [[ "$_cmd" == up ]]; then
            has "$(cat "$STEPS")" "verify_macos_egress_locked" "unreadable token file, running VM: up --macos still runs the egress self-test first"
        else
            eq "" "$(cat "$STEPS")" "unreadable token file, running VM: $_cmd --macos runs no guest step (no clock/timezone sync)"
        fi
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

section "Tier 1 — each credential is read once, and the value sent is the value validated"

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
for _run in "1 shell" "0 claude"; do
    RUNNING="${_run%% *}"; _cmd="${_run#* }"
    : > "$READS"; GOOD_READS=1
    run_cmd "$_cmd"
    eq "0" "$rc" "file rewritten after its first read ($_cmd, running=$RUNNING): completes"
    eq "1" "$(wc -l < "$READS" | tr -d ' ')" "$_cmd --macos (running=$RUNNING) reads the token file exactly once"
    has   "$(sess_env)" "CLAUDE_CODE_OAUTH_TOKEN=test-oauth-good-1111" "$_cmd --macos (running=$RUNNING) sends the value it validated"
    hasnt "$(sess_env)" "injected" "$_cmd --macos (running=$RUNNING) never sends the later, unchecked content"
done
RUNNING=1
: > "$READS"; GOOD_READS=0
run_cmd shell
nonzero "token file bad from the first read: shell --macos"
eq "0" "$(pushes)" "token file bad from the first read: nothing is pushed"
eq "0" "$(launches)" "token file bad from the first read: no session"
eval "$real_resolve"

section "Tier 1 — a push that fails is fatal on every path"

export ANTHROPIC_API_KEY="test-api-key-BBB222"
before="$(cat "$ENV_FILE")"
FAIL_PUSH=1
for _cmd in shell claude; do
    run_cmd "$_cmd"
    nonzero "push fails, running VM: $_cmd --macos"
    eq "0" "$(launches)" "push fails, running VM: $_cmd --macos starts no session (an older ~/.augur-env may still be there)"
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
    RUNNING=0; run_cmd claude
    nonzero "push fails ($FAIL_PUSH), boot: claude --macos"
    eq "0" "$(launches)" "push fails ($FAIL_PUSH), boot: claude --macos starts no session"
done
RUNNING=1
FAIL_PUSH=0
eq "$before" "$(cat "$ENV_FILE")" "push fails: the guest's ~/.augur-env is unchanged"

section "Tier 1 — a guest that fails its boot self-test gets no session"

verify_macos_egress_locked() { echo "LEAK" >&2; exit 1; }
RUNNING=0
run_cmd claude
nonzero "leaky guest at boot: claude --macos"
eq "0" "$(launches)" "leaky guest at boot: claude --macos starts no session"
eval "verify_macos_egress_locked() { printf '%s\n' verify_macos_egress_locked >> \"\$STEPS\"; }"
RUNNING=1

section "Tier 1 — every path pushes exactly once and launches exactly once"

GH_HOST_TOKEN="ghp_boot333333"
RUNNING=0
for _cmd in shell claude up; do
    run_cmd "$_cmd"
    eq "0" "$rc" "not running: $_cmd --macos boots and completes"
    has "$out" "is up." "not running: $_cmd --macos went through the boot path (control)"
    eq "1" "$(pushes)" "not running: $_cmd --macos pushes ~/.augur-env exactly once"
    eq "1" "$(gh_calls)" "not running: $_cmd --macos asks gh for the token once"
    eq "1" "$(grep -c '^ensure_macos_workspace$' "$STEPS")" "not running: $_cmd --macos wires the guest once"
    hasnt "$(cat "$ENV_FILE")" "ghp_boot333333" "not running: $_cmd --macos: ~/.augur-env holds no gh token"
    if [[ "$_cmd" == up ]]; then
        eq "0" "$(launches)" "not running: up --macos starts no session"
    else
        eq "1" "$(launches)" "not running: $_cmd --macos starts one session"
        has "$(sess_env)" "GH_TOKEN=ghp_boot333333" "not running: $_cmd --macos: the session gets the host's gh token"
        st_at="$(grep -n '^verify_macos_egress_locked$' "$STEPS" | cut -d: -f1)"
        [[ -n "$st_at" ]] && ok "not running: $_cmd --macos ran the boot self-test before its session" \
            || fail "not running: $_cmd --macos never ran the self-test"
    fi
done

GH_HOST_TOKEN="ghp_race444444"
RUNNING=race
for _cmd in shell claude; do
    run_cmd "$_cmd"
    eq "0" "$rc" "VM came up in the meantime: $_cmd --macos completes"
    has "$out" "already running" "VM came up in the meantime: cmd_up_macos took its already-running branch (control)"
    eq "1" "$(pushes)" "VM came up in the meantime: $_cmd --macos still pushes exactly once"
    eq "1" "$(gh_calls)" "VM came up in the meantime: $_cmd --macos asks gh for the token once"
    eq "1" "$(launches)" "VM came up in the meantime: $_cmd --macos starts one session"
    has "$(sess_env)" "GH_TOKEN=ghp_race444444" "VM came up in the meantime: $_cmd --macos: the session has the current gh token"
done

GH_HOST_TOKEN="ghp_up5555555"
RUNNING=1
macos_record_egress_mode
run_cmd up
eq "0" "$rc" "up --macos on a running VM: completes"
has "$out" "refreshing the guest's environment" "up --macos on a running VM: says it refreshes the environment, not credentials"
eq "1" "$(pushes)" "up --macos on a running VM: pushes ~/.augur-env exactly once"
eq "1" "$(gh_calls)" "up --macos on a running VM: asks gh for the token once"
eq "0" "$(launches)" "up --macos on a running VM: starts no session"
hasnt "$(cat "$ENV_FILE")" "ghp_up5555555" "up --macos on a running VM: ~/.augur-env holds no gh token"
has "$(cat "$ENV_FILE")" "export GIT_CONFIG_COUNT='2'" "up --macos on a running VM: still writes git's helper into ~/.augur-env (a gh token exists)"
# On the running branch the self-test still precedes the push. The self-test stub leaves a marker
# in SSHLOG so the two are in one ordering.
verify_macos_egress_locked() { printf 'MARK:self-test\n' >> "$SSHLOG"; }
run_cmd up
st_at="$(grep -n '^MARK:self-test' "$SSHLOG" | cut -d: -f1)"; push_at="$(grep -n 'cat > .*\.augur-env' "$SSHLOG" | cut -d: -f1)"
if [[ -n "$st_at" && -n "$push_at" && "$st_at" -lt "$push_at" ]]; then
    ok "up --macos on a running VM: the self-test precedes the push (self-test@$st_at < push@$push_at)"
else fail "up --macos on a running VM: the push is not after the self-test" "self-test@${st_at:-none} push@${push_at:-none}"; fi

section "Tier 1 — augur's other ssh calls carry no credentials, and setup-token gets nothing"

# The REAL ssh_macos, with credentials resolved in scope: no SendEnv on its argv, and no file- or
# gh-sourced value in the ssh process's environment.
: > "$SESSLOG"
( unset ANTHROPIC_API_KEY; _creds=("GH_TOKEN=ghp_scope666666" "CLAUDE_CODE_OAUTH_TOKEN=test-oauth-scope-777")
  unset -f ssh_macos; eval "$(sed -n '/^ssh_macos() {$/,/^}$/p' "$AUGUR")"
  ssh_macos "$(macos_project_vm)" true )
eq "1" "$(launches)" "real ssh_macos: the ssh shim ran (control)"
hasnt "$(sess_argv | tr '\n' ' ')" "SendEnv" "real ssh_macos: no SendEnv, even with credentials resolved in scope"
eq "" "$(sess_env)" "real ssh_macos: no credential in the ssh process's environment"
awk '/^ARGV$/{a=1; next} /^ENV$/{a=0} a' "$SESSLOG" >> "$ALL_SSH"
# Where SendEnv and the session ssh may appear in augur at all.
eq "1" "$(grep -v '^ *#' "$AUGUR" | grep -c 'SendEnv=')" "SendEnv= appears in one line of code in augur (ssh_macos_session)"
has "$(fn_body ssh_macos_session)" 'SendEnv=' "…and that one is in ssh_macos_session"
eq "2" "$(grep -c '^ *ssh_macos_session "' "$AUGUR")" "ssh_macos_session has exactly two callers"
has "$(fn_body cmd_claude_macos)" 'ssh_macos_session "$project_vm" -t' "cmd_claude_macos launches through it"
has "$(fn_body cmd_shell_macos)"  'ssh_macos_session "$project_vm" -t' "cmd_shell_macos launches through it"
st_body="$(fn_body cmd_setup_token_macos)"
hasnt "$st_body" "ssh_macos_session" "setup-token --macos does not use the session ssh"
hasnt "$st_body" "resolve_session_credentials" "setup-token --macos resolves no credential"
hasnt "$(fn_body push_macos_guest_env)" '_creds[@]+"${_creds[@]}"}; do _content' "the ~/.augur-env push writes no credential line"

section "Tier 1 — no credential value is ever on an ssh argv"

leaked=""
for _v in ghp_first111111 ghp_rotated22222 ghp_boot333333 ghp_race444444 ghp_up5555555 ghp_bad \
          ghp_scope666666 ghp_revoked test-api-key-AAA111 test-api-key-BBB222 test-api-key-bad test-oauth; do
    grep -qF "$_v" "$ALL_SSH" && leaked+=" $_v"
done
[[ -s "$ALL_SSH" ]] && ok "control: the argv log is not empty ($(wc -l < "$ALL_SSH" | tr -d ' ') lines)" \
    || fail "control: no ssh call was recorded"
grep -q '^SendEnv=GH_TOKEN$' "$ALL_SSH" && ok "control: the session ssh argv is in the log" \
    || fail "control: the session ssh argv is missing from the log"
eq "" "$leaked" "no credential value appears on any recorded ssh / scp argv"

finish
