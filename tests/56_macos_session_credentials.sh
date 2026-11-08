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
#     credential and no GIT_CONFIG_* helper lines, and a push replaces one an older augur wrote with
#     credentials in it; git's helper set is exported by the session's remote command, after the
#     delivery check and only when GH_TOKEN is sent, so a shell augur did not open has none;
#   • the write is atomic and mode 600, the guest installs only content ending in the end marker;
#     every push removes temp files older than a minute or dated more than a minute ahead of the guest
#     clock (left by a killed push) while a fresh one, or one seconds ahead (a concurrent push), stays;
#   • each credential is read once per invocation and the values sent are the values validated;
#   • a credential that cannot be injected, or a credential file that cannot be read, aborts with no
#     session (on a boot: before the VM backend is called at all); on a running VM only after the
#     push of ~/.augur-env, which removes credentials an older augur wrote and names an old base's
#     remedy, while `up --macos` on a running VM still rewrites the allowlist, revives the proxy,
#     fixes the clock and runs the self-test first;
#   • a guest whose sshd does not accept the session's credentials is refused with the remedy by
#     `up`, `claude` and `shell` (a stopped one right after the SSH wait), gets no session (and, on a
#     boot, no GIT_CONFIG_* helper lines either), and still has the credentials an older augur wrote
#     removed, all in the one push that carries the check; the refusal is reported even when a later
#     step of that push fails; so is one whose acceptance cannot be checked;
#   • a boot whose push fails (a refusal at once; a dropped connection or a failed write on its second
#     try too) stops the VM, its gvproxy and its proxy, and keeps the clone;
#   • a session whose guest is missing a credential it sent (an sshd that dropped it) never starts
#     the agent or shell, and is refused, printing no value, with a message that names the exit
#     status, says to ignore it if the agent or shell itself exited so, and suggests `up --macos`
#     before the recreate; a session that sent nothing never reads its exit status as that refusal;
#   • a session on a running VM whose current boot has no record of a passed egress self-test (an
#     interrupted `up`) is refused with no guest step but the refusal's push of ~/.augur-env, which
#     removes the credentials an older augur wrote (a push that fails says they may remain), and
#     `up` on that VM re-runs the self-test and records it;
#   • a push that fails is fatal on every path, after one more try when the connection dropped or the
#     write failed (a concurrent push took its temp file), and never retried when the guest was
#     refused or ~/.zshenv could not be updated;
#   • every path launches exactly once and pushes exactly once, the push carrying the acceptance
#     check and no credential or GIT_CONFIG_* helper lines (on a boot, right after the SSH wait):
#     running VM, boot, a VM that came up in the meantime; `up --macos` launches nothing;
#   • augur's other ssh calls (ssh_macos) carry no SendEnv, and `setup-token --macos` gets nothing;
#   • the base VM build and update write the sshd AcceptEnv drop-in only after `sshd -T` accepted it
#     in a test config (one run per check, its error shown), as root over ONE ssh connection whose
#     stdin carries the password line, a marker and the script (nothing staged in the guest; the
#     password never run or printed, NOPASSWD sudo or not), re-check it the same way and with the
#     clones' own check as their last guest step before the save, and the session check accepts
#     exactly what they write; the AcceptEnv line is built from the validated names only.
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
TEST_PW="pw-test-0815"; macos_store_admin_password "$(macos_project_vm)" "$TEST_PW"

# Per-run logs. Files, not variables: the code under test runs in `$( … )` and calls some of these
# stubs from command substitutions of its own.
SSHLOG="$TMPD/sshlog"      # every ssh_macos argv of the current run
PUSHLOG="$TMPD/pushlog"    # the content of every ~/.augur-env push of the current run, each after a PUSH line
ALL_SSH="$TMPD/all-ssh"    # every ssh argv of the whole file (ssh_macos, scp, the real `ssh`)
OTHERENV="$TMPD/otherenv"  # credential variables in augur's own environment at each ssh_macos call
STEPS="$TMPD/steps"        # guest-touching steps that are stubbed out
VMLOG="$TMPD/vmlog"        # every augur-vm call
HOSTLOG="$TMPD/hostlog"    # host-side reconcile steps (approval gate, proxy start)
GHCALLS="$TMPD/ghcalls"    # one line per `gh auth token`
VMCHECKS="$TMPD/vmchecks"
: > "$ALL_SSH"; : > "$OTHERENV"; : > "$PUSHLOG"

# The real `ssh` a session execs, on PATH: records its argv (one argument per line, after an
# "ARGV" line) and the credential variables in ITS OWN environment. Exits $SHIM_RC, unless
# SHIM_SSHD is set: then it plays the guest's sshd and runs the remote command (its last argument)
# under `sh` with the variables its SendEnv options name, minus those SHIM_SSHD=drop:<NAME,...>
# lists, as an sshd that dropped them would. The guest's `zsh` there is a stand-in that only logs
# LAUNCHED to $SHIM_LAUNCHLOG, and its GIT_CONFIG_* environment to $SHIM_LAUNCHLOG.git.
SHIMDIR="$TMPD/shim"; mkdir -p "$SHIMDIR"
export SESSLOG="$TMPD/sesslog" SHIM_RC=0 SHIM_SSHD="" SHIM_LAUNCHLOG="$TMPD/launchlog" SHIM_GUESTBIN="$TMPD/guestbin"
mkdir -p "$SHIM_GUESTBIN"
printf '#!/bin/sh\necho LAUNCHED >> "$SHIM_LAUNCHLOG"\nenv | grep "^GIT_CONFIG_" | sort > "$SHIM_LAUNCHLOG.git"\n' > "$SHIM_GUESTBIN/zsh"; chmod +x "$SHIM_GUESTBIN/zsh"
cat > "$SHIMDIR/ssh" <<'EOF'
#!/usr/bin/env bash
{ echo "ARGV"; printf '%s\n' "$@"; echo "ENV"
  env | grep -E '^(ANTHROPIC_API_KEY|CLAUDE_CODE_OAUTH_TOKEN|GH_TOKEN)=' | sort; echo "END"; } >> "$SESSLOG"
[[ -n "$SHIM_SSHD" ]] || exit "$SHIM_RC"
sent=(); for a in "$@"; do [[ "$a" == SendEnv=* ]] && sent+=("${a#SendEnv=}"); done
drop=",${SHIM_SSHD#drop:},"; pass=()
for n in ${sent[@]+"${sent[@]}"}; do [[ "$drop" == *",$n,"* ]] || pass+=("$n=${!n}"); done
home="$(mktemp -d)"; mkdir -p "$home/$MACOS_SHARE"
env -i PATH="$SHIM_GUESTBIN:/usr/bin:/bin" HOME="$home" SHIM_LAUNCHLOG="$SHIM_LAUNCHLOG" ${pass[@]+"${pass[@]}"} sh -c "${!#}"
rc=$?; rm -rf "$home"; exit "$rc"
EOF
chmod +x "$SHIMDIR/ssh"
PATH="$SHIMDIR:$PATH"
# `ps -o lstart= -p <pid>` (the start time in a VM's run id, macos_vm_run_id) answers a fixed time for
# a live pid, so the id cannot drift during the run: Linux procps computes a start time from the
# boot time the kernel reports, which moves whenever the host clock is stepped (a VM's clock
# resync), shifting every process's start time at once. tests/51 runs the real ps. Any other ps
# call goes to the real one.
REAL_PS="$(command -v ps)"
cat > "$SHIMDIR/ps" <<EOF
#!/usr/bin/env bash
if [[ "\$*" == "-o lstart= -p "* ]]; then kill -0 "\${4}" 2>/dev/null || exit 1; echo "Sun Nov  8 10:00:00 2026"; exit 0; fi
exec "$REAL_PS" "\$@"
EOF
chmod +x "$SHIMDIR/ps"
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
# FAIL_PUSH=2 makes the guest report a failed install (exit 1, old file kept); FAIL_PUSH=once drops
# only the run's first push (255), as a passing hiccup would.
# FAIL_CHECK=1 makes a push that carries the session-env acceptance check drop (255).
# FAIL_STEP=env / =zshenv makes the guest's ~/.augur-env rename / ~/.zshenv write fail, with the
# rest of the push (the acceptance check included) run for real. FAIL_STEP=vanish removes, in the
# run's first push only, its temp file between the write and the rename, as a concurrent push's
# cleanup would. FAIL_STEP=mktemp makes the guest's mktemp of the cleanup's reference file fail.
GUEST_HOME="$TMPD/guest"; mkdir -p "$GUEST_HOME"
GUEST_ETC="$TMPD/guest-etc"; mkdir -p "$GUEST_ETC/ssh/sshd_config.d"
FAIL_PUSH=0; FAIL_CHECK=0; FAIL_STEP=""
guest_map() { local c="${1//\/Users\/${MACOS_SSH_USER}/$GUEST_HOME}"; printf '%s' "${c//\/etc\/ssh/$GUEST_ETC/ssh}"; }
guest_run() { HOME="$GUEST_HOME" bash -c "$(guest_map "$1")"; }
ssh_macos() {
    local vm="$1"; shift
    printf '%s\n' "$*" | tee -a "$ALL_SSH" >> "$SSHLOG"
    env | grep -E '^(CLAUDE_CODE_OAUTH_TOKEN|GH_TOKEN)=' >> "$OTHERENV"
    case "$*" in
        *".augur-env"*)                                     # the push (with or without the check)
            local in; in="$(cat; echo x)"; in="${in%x}"
            { echo PUSH; printf '%s' "$in"; } >> "$PUSHLOG"
            local first=false; [[ "$(grep -c '^PUSH$' "$PUSHLOG")" == 1 ]] && first=true
            if [[ "$FAIL_PUSH" == 1 ]] || { [[ "$FAIL_PUSH" == once ]] && $first; }; then return 255; fi
            if [[ "$FAIL_PUSH" == 2 ]]; then return 1; fi
            if [[ "$FAIL_CHECK" == 1 && "$*" == *"sshd_config.d"* ]]; then return 255; fi
            local c="$*"
            case "$FAIL_STEP" in
                env)    c="${c//mv -f /false && mv -f }" ;;
                vanish) $first && c="${c//&& mv -f /&& find ~ -maxdepth 1 -name '.augur-env.tmp.*' -exec rm -f {} + && mv -f }" ;;
                zshenv) c="${c//"~/.zshenv"/"/nonexistent-augur-test/zshenv"}" ;;
                mktemp) c="${c//mktemp \/tmp\/augur-env-ref/false \/tmp\/augur-env-ref}" ;;
            esac
            printf '%s' "$in" | guest_run "$c" ;;
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
stop_gvproxy()                      { echo stop_gvproxy >> "$HOSTLOG"; }
stop_proxy()                        { echo stop_proxy >> "$HOSTLOG"; }
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

# The base VM build's drop-in install and check, run for real against GUEST_ETC: the remote command
# runs under bash with a `sudo` stand-in on PATH that, like `sudo -S`, reads the password line from
# stdin one byte at a time and refuses a wrong one (SUDO_NOPASSWD=1: reads nothing, as with a
# NOPASSWD grant), and the rest of stdin, the root script, has the guest's paths mapped on the way.
# `chown root:wheel` is a no-op (no root here), and `sshd -T [-f <config>]` follows Include lines
# from <config> (default: the guest's sshd_config) and prints one `AcceptEnv <NAME>` line per
# pattern, the form macOS's sshd -T prints (SSHD_LOWER=1: upstream OpenSSH's lowercase
# `acceptenv`). Each sshd run is logged with whether the drop-in was live at that moment.
# SSHD_T_FAILS=1 makes every sshd -T fail with a parse error on stderr; =live only the one without -f.
# FRESH_RC is what the fresh connection after the install exits with.
SSHD_T_FAILS=0; FRESH_RC=0; SUDO_NOPASSWD=0
SSHDLOG="$TMPD/sshd-calls"
printf 'Include %s/ssh/sshd_config.d/*\nAcceptEnv LANG LC_*\n' "$GUEST_ETC" > "$GUEST_ETC/ssh/sshd_config"
cat > "$SHIMDIR/sshd" <<'EOF2'
#!/usr/bin/env bash
kw=AcceptEnv; [[ "${SSHD_LOWER:-0}" == 1 ]] && kw=acceptenv
cfg="$GUEST_ETC/ssh/sshd_config"
[[ "$1" == -T ]] || exit 255
[[ "${2:-}" == -f ]] && cfg="$3"
live=no; [[ -e "$DROPIN" ]] && live=yes
echo "sshd ${2:-} drop-in-live=$live" >> "$SSHDLOG"
if [[ "$SSHD_T_FAILS" == 1 || ( "$SSHD_T_FAILS" == live && -z "${2:-}" ) ]]; then
    echo "$cfg line 1: Bad configuration option: AcceptEnvv" >&2; exit 255
fi
parse() {
    local l f p
    while read -r l; do
        case "$l" in
            Include\ *) for f in ${l#Include }; do [[ -f "$f" ]] && parse "$f"; done ;;
            AcceptEnv\ *) read -ra p <<< "${l#AcceptEnv }"; for f in "${p[@]}"; do echo "$kw $f"; done ;;
        esac
    done < "$1"
}
echo "port 22"; parse "$cfg"
EOF2
chmod +x "$SHIMDIR/sshd"
ROOTBIN="$TMPD/rootbin"; mkdir -p "$ROOTBIN"
cat > "$ROOTBIN/sudo" <<'EOF2'
#!/usr/bin/env bash
# sudo -S [-k] -p <prompt> <cmd...>
[[ "$1" == -S ]] || { echo "sudo stand-in: not -S" >&2; exit 1; }
while [[ "${1:-}" == -* ]]; do case "$1" in -p) shift 2 ;; *) echo "${1}" >> "$SUDO_FLAGLOG"; shift ;; esac; done
if [[ "$SUDO_NOPASSWD" != 1 ]]; then
    IFS= read -r pw; printf '%s\n' "$pw" > "$SUDO_PWLOG"
    [[ "$pw" == "$SUDO_WANT" ]] || { echo "Sorry, try again." >&2; exit 1; }
fi
exec "$@"
EOF2
chmod +x "$ROOTBIN/sudo"
BUILDLOG="$TMPD/buildlog"
build_ssh() {   # an ssh_macos for the build path
    local vm="$1"; shift
    local c="$*" s
    printf '%s\n' "$c" >> "$BUILDLOG"
    case "$c" in
        "sudo "*)
            s="$(cat; echo x)"; s="${s%x}"; s="$(guest_map "$s")"
            s="${s//\/usr\/sbin\/sshd/$SHIMDIR/sshd}"; s="${s//chown root:wheel/true}"
            printf '%s' "$s" > "$TMPD/build-stdin"
            printf '%s' "$s" | PATH="$ROOTBIN:$PATH" SUDO_FLAGLOG="$TMPD/sudo-flags" SUDO_PWLOG="$TMPD/sudo-pw" \
                SUDO_WANT="$TEST_PW" SUDO_NOPASSWD="$SUDO_NOPASSWD" \
                GUEST_ETC="$GUEST_ETC" DROPIN="$DROPIN" SSHDLOG="$SSHDLOG" SSHD_T_FAILS="$SSHD_T_FAILS" SSHD_LOWER="${SSHD_LOWER:-0}" \
                bash -c "$c" ;;
        true) return "$FRESH_RC" ;;
        *) echo "UNEXPECTED BUILD COMMAND: $c" >&2; return 1 ;;
    esac
}
DROPIN="$GUEST_ETC/ssh/sshd_config.d/$(basename "$(macos_session_sshd_dropin)")"
install_dropin() {   # sets $out / $rc
    : > "$BUILDLOG"; : > "$SSHDLOG"; rm -f "$TMPD/sudo-pw" "$TMPD/sudo-flags"
    out="$( ssh_macos() { build_ssh "$@"; }; install_macos_session_env_acceptance "$(macos_project_vm)" 2>&1 )"; rc=$?
}
verify_dropin() {   # sets $out / $rc
    : > "$BUILDLOG"; : > "$SSHDLOG"; rm -f "$TMPD/sudo-pw" "$TMPD/sudo-flags"
    out="$( ssh_macos() { build_ssh "$@"; }; verify_macos_session_env_acceptance "$(macos_project_vm)" 2>&1 )"; rc=$?
}

ENV_FILE="$GUEST_HOME/.augur-env"
# The value git_credential_env gives augur's helper (entry 1), as the session must export it.
git_credential_env_value_1() { local _creds=(GH_TOKEN=x); git_credential_env | sed -n 's/^GIT_CONFIG_VALUE_1=//p'; }
# The VM's current boot (augur-vm's run.pid), and the record that its self-test passed during it
# (macos_egress_verified_file). The boot's pid is this test shell's, so the process is alive and
# its start time readable, as augur-vm's would be. A running VM has that record before each run
# unless UNVERIFIED=1; tests/51 covers the record itself.
printf '%s' "$$" > "$AUGUR_DIR/vms/$(macos_project_vm)/run.pid"
BOOT_ID="$(macos_vm_run_id "$(macos_project_vm)")"
[[ "$BOOT_ID" == "$$ "?* ]] || { echo "cannot read this shell's start time for the boot id: '$BOOT_ID'" >&2; exit 1; }
UNVERIFIED=0
run_cmd() {   # run_cmd claude|shell|up — sets $out / $rc; truncates the per-run logs first
    if [[ "$RUNNING" != 0 && "$UNVERIFIED" == 0 ]]; then printf '%s\n' "$BOOT_ID" > "$(macos_egress_verified_file)"; fi
    : > "$SSHLOG"; : > "$PUSHLOG"; : > "$STEPS"; : > "$VMCHECKS"; : > "$VMLOG"; : > "$HOSTLOG"; : > "$GHCALLS"; : > "$SESSLOG"
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
push_content() { awk -v n="$1" '/^PUSH$/{i++; next} i == n' "$PUSHLOG"; }   # the content of push n
nonzero()    { if [[ "$rc" -ne 0 ]]; then ok "$1: exits non-zero"; else fail "$1: exited 0"; fi; }
# stopped_boot <label>: the run stopped the VM it booted, and its gvproxy and proxy, and kept the clone.
stopped_boot() {
    has "$(cat "$VMLOG")" "stop $(macos_project_vm)" "$1: stops the VM it booted"
    hasnt "$(cat "$VMLOG")" "delete" "$1: keeps the clone"
    has "$(cat "$HOSTLOG")" "stop_gvproxy" "$1: stops gvproxy"
    has "$(cat "$HOSTLOG")" "stop_proxy" "$1: stops the proxy"
    has "$out" "Stopping VM '$(macos_project_vm)' (its clone is kept)" "$1: says it stops the VM"
}

section "Tier 1 — the base VM build writes the sshd drop-in that accepts the session's credentials"

install_dropin
eq "0" "$rc" "the drop-in install succeeds when sshd confirms it"
eq "$(macos_session_accept_env_line "$(macos_session_env_names)")" "$(grep -v '^#' "$DROPIN")" "the drop-in holds exactly one AcceptEnv line"
eq "AcceptEnv ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN GH_TOKEN" "$(macos_session_accept_env_line "$(macos_session_env_names)")" \
   "it names exactly the agent's credentials and GH_TOKEN, no patterns"
eq "644" "$(mode_of "$DROPIN")" "the drop-in is mode 644"
eq "$TEST_PW" "$(sed -n 1p "$TMPD/build-stdin")" "the sudo password is the first line of ssh's stdin"
hasnt "$(cat "$BUILDLOG")" "$TEST_PW" "the sudo password is on no ssh argv"
eq "" "$(ls "$GUEST_ETC/ssh/sshd_config.d" | grep -v '^200-augur-session-env.conf$')" "nothing else lands in sshd_config.d"
eq $'sshd -f drop-in-live=no\nsshd  drop-in-live=yes' "$(cat "$SSHDLOG")" \
   "sshd -T runs once against a test config BEFORE the drop-in is live, then once against the live config"
has "$(cat "$BUILDLOG")" $'\ntrue' "one fresh connection follows the install"
rm -f "$DROPIN"
SSHD_LOWER=1
install_dropin
eq "0" "$rc" "the install also accepts upstream OpenSSH's lowercase acceptenv output"
SSHD_LOWER=0
rm -f "$DROPIN"
SSHD_T_FAILS=1
install_dropin
nonzero "sshd rejects the candidate: the install"
has "$out" "Could not make the base VM's sshd accept" "sshd rejects the candidate: says so"
has "$out" "Bad configuration option: AcceptEnvv" "sshd rejects the candidate: sshd's own message is shown"
eq "sshd -f drop-in-live=no" "$(cat "$SSHDLOG")" "sshd rejects the candidate: it never goes live"
[[ -e "$DROPIN" ]] && fail "sshd rejects the candidate: the drop-in is in place" \
    || ok "sshd rejects the candidate: no drop-in is installed (sshd keeps a config it can parse)"
SSHD_T_FAILS=live
install_dropin
nonzero "the live config fails after the rename: the install"
[[ -e "$DROPIN" ]] && fail "the live config fails after the rename: the drop-in stays" \
    || ok "the live config fails after the rename: the drop-in is removed again"
SSHD_T_FAILS=0
FRESH_RC=255
install_dropin
nonzero "no fresh connection after the install: the install"
has "$out" "no new SSH connection is accepted" "no fresh connection after the install: says so"
FRESH_RC=0
SSHD_T_FAILS=0
real_names="$(declare -f session_credential_names)"
session_credential_names() { echo 'BAD*NAME'; }
install_dropin
nonzero "a credential name that is a pattern: the install"
eq "" "$(cat "$BUILDLOG")" "a credential name that is a pattern: nothing reaches the guest"
eval "$real_names"
install_dropin
eq "0" "$rc" "reinstall (control)"

# One ssh connection runs the root script, which arrives on its stdin after the password line and
# the marker; nothing is staged in the guest, so no guest-user process can swap it before root runs
# it. The fresh connection is the only other one.
rm -f "$DROPIN"; install_dropin
eq "0" "$rc" "the install runs over the stdin protocol"
eq "2" "$(wc -l < "$BUILDLOG" | tr -d ' ')" "the install opens two connections: the root script's and the fresh one"
eq "1" "$(grep -c '^sudo -S -k -p '"''"' /bin/sh -c ' "$BUILDLOG")" "the root script runs under one sudo -S -k, from stdin"
hasnt "$(cat "$BUILDLOG")" "cat > " "nothing is written to a file in the guest before sudo runs"
eq "" "$(find "$GUEST_HOME" -name '*.sh' 2>/dev/null)" "no script is left in (or staged into) the guest user's home"
eq "$MACOS_ROOT_SCRIPT_BEGIN" "$(sed -n 2p "$TMPD/build-stdin")" "the marker follows the password line on stdin"
eq "$TEST_PW" "$(cat "$TMPD/sudo-pw")" "sudo -S read exactly the password line"
has "$(cat "$TMPD/sudo-flags" 2>/dev/null)" "-k" "sudo ignores a cached credential (-k), so it always reads the password line"
# A NOPASSWD grant (the build has one until it revokes it) leaves the password line unread by sudo:
# the root shell skips it, so it is never run as a command and never printed.
rm -f "$DROPIN"; SUDO_NOPASSWD=1; install_dropin; SUDO_NOPASSWD=0
eq "0" "$rc" "NOPASSWD sudo: the install still succeeds"
[[ -f "$DROPIN" ]] && ok "NOPASSWD sudo: the drop-in is installed" || fail "NOPASSWD sudo: no drop-in"
hasnt "$out" "$TEST_PW" "NOPASSWD sudo: the password is not printed (not run as a command)"
eq $'sshd -f drop-in-live=no\nsshd  drop-in-live=yes' "$(cat "$SSHDLOG")" "NOPASSWD sudo: the whole script ran"
# A wrong password: sudo refuses, and no line of the script runs as root.
rm -f "$DROPIN"; _pw_saved="$TEST_PW"; TEST_PW="not-the-password"; install_dropin; TEST_PW="$_pw_saved"
nonzero "a wrong sudo password: the install"
eq "" "$(cat "$SSHDLOG")" "a wrong sudo password: no line of the script ran"
[[ -e "$DROPIN" ]] && fail "a wrong sudo password: a drop-in was installed" || ok "a wrong sudo password: no drop-in"
hasnt "$out" "$_pw_saved" "a wrong sudo password: the password is not printed"
# The stream without its marker: the root shell runs nothing.
_rs_real="$(declare -f macos_run_root_script)"
eval "$(declare -f macos_run_root_script | sed 's/"\$MACOS_ROOT_SCRIPT_BEGIN" "\$script"/"\$script"/')"
rm -f "$DROPIN"; install_dropin
nonzero "no marker on stdin: the install"
eq "" "$(cat "$SSHDLOG")" "no marker on stdin: the root shell runs nothing"
eval "$_rs_real"
install_dropin
eq "0" "$rc" "reinstall (control)"

# The re-check build and update run last, before the base VM is saved: one root connection, the
# same sshd -T test against the live configuration, nothing written.
verify_dropin
eq "0" "$rc" "the re-check passes on a guest with the drop-in"
eq "sshd  drop-in-live=yes" "$(cat "$SSHDLOG")" "the re-check runs sshd -T once, on the live configuration"
eq "1" "$(wc -l < "$BUILDLOG" | tr -d ' ')" "the re-check opens one connection"
hasnt "$(cat "$BUILDLOG")" "$TEST_PW" "the re-check puts the sudo password on no argv"
eq "$TEST_PW" "$(cat "$TMPD/sudo-pw")" "the re-check feeds sudo -S the password line"
SUDO_NOPASSWD=1; verify_dropin; SUDO_NOPASSWD=0
eq "0" "$rc" "the re-check passes under NOPASSWD sudo too"
hasnt "$out" "$TEST_PW" "the re-check under NOPASSWD sudo prints no password"
mv "$DROPIN" "$TMPD/dropin.saved"
verify_dropin
nonzero "the re-check on a guest that lost the drop-in"
has "$out" "no longer accepts augur's session credentials" "the re-check: says so"
has "$out" "sshd does not accept ANTHROPIC_API_KEY" "the re-check: names what sshd lacks"
mv "$TMPD/dropin.saved" "$DROPIN"
SSHD_T_FAILS=1; verify_dropin; SSHD_T_FAILS=0
nonzero "the re-check when sshd cannot parse its configuration"
has "$out" "Bad configuration option: AcceptEnvv" "the re-check: sshd's own message is shown"
# The re-check also runs, as is, the check every clone's `up` and session run on the drop-in
# (macos_session_env_check_cmd), so a base its clones would refuse is never saved, even when sshd
# accepts the names some other way.
verify_dropin
has "$(sed -n '3,$p' "$TMPD/build-stdin")" "$(guest_map "$(macos_session_env_check_cmd "$(macos_session_env_names)")") ||" \
    "the re-check runs the clones' own acceptance check (macos_session_env_check_cmd)"
cp "$GUEST_ETC/ssh/sshd_config" "$TMPD/sshd_config.saved"
printf '%s\n' "$(macos_session_accept_env_line "$(macos_session_env_names)")" >> "$GUEST_ETC/ssh/sshd_config"; mv "$DROPIN" "$TMPD/dropin.saved"
verify_dropin
nonzero "the re-check on a guest whose sshd accepts the names but has no drop-in"
eq "sshd  drop-in-live=no" "$(cat "$SSHDLOG")" "…where sshd -T itself accepts them (control)"
has "$out" "does not hold the line every clone checks for" "…says the drop-in lacks the line clones check for"
hasnt "$out" "No such file" "…with no raw grep error from the root script"
mv "$TMPD/dropin.saved" "$DROPIN"; cp "$TMPD/sshd_config.saved" "$GUEST_ETC/ssh/sshd_config"
cp "$DROPIN" "$TMPD/dropin.saved"
printf '# augur\nAcceptEnv GH_TOKEN ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN\n' > "$DROPIN"
verify_dropin
nonzero "the re-check on a drop-in that names the credentials in another order"
has "$out" "does not hold the line every clone checks for" "…says the drop-in lacks the line clones check for"
guest_run "$(macos_session_env_check_cmd "$(macos_session_env_names)")" && fail "control: a clone's own check accepts that drop-in (the case is vacuous)" \
    || ok "control: a clone's own check refuses that drop-in too"
cp "$TMPD/dropin.saved" "$DROPIN"
verify_dropin
eq "0" "$rc" "the re-check passes again with augur's own drop-in (control)"
session_credential_names() { echo 'BAD*NAME'; }
verify_dropin
nonzero "the re-check with a credential name that is a pattern"
eq "" "$(cat "$BUILDLOG")" "the re-check with a pattern name: nothing reaches the guest"
# The AcceptEnv line, and so the drop-in and the clones' check, is built from the validated names:
# macos_session_env_names is the one place they are checked, and every caller of the line and the
# check computes them once, there.
session_credential_names() { echo 'BAD*NAME'; }
_al="$(macos_session_env_names 2>/dev/null)" && fail "the session's names take a pattern credential name" "[$_al]" \
    || ok "the session's names refuse a credential name that is a pattern"
eq "" "$_al" "…and give no names for it"
: > "$SSHLOG"; out="$( push_macos_guest_env "$(macos_project_vm)" 2>&1 )"; rc=$?
eq "1" "$rc" "a push with a pattern credential name fails as one that cannot work (no retry)"
eq "" "$(cat "$SSHLOG")" "a push with a pattern credential name: nothing reaches the guest"
: > "$SSHLOG"; out="$( push_macos_guest_env_retrying "$(macos_project_vm)" 2>&1 )"; rc=$?
nonzero "a retried push with a pattern credential name"
eq "" "$(cat "$SSHLOG")" "a retried push with a pattern credential name: nothing reaches the guest, twice or once"
eval "$real_names"
# The names come from the canonical list, not from the display line.
_line_real="$(declare -f macos_session_accept_env_line)"
macos_session_accept_env_line() { printf 'AcceptEnv X_DISPLAY_ONLY'; }
rm -f "$DROPIN"; install_dropin
has "$(sed -n '3,$p' "$TMPD/build-stdin")" "for n in ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN GH_TOKEN; do" \
    "the install checks the names session_credential_names gives, not ones parsed from the AcceptEnv line"
eval "$_line_real"
rm -f "$DROPIN"; install_dropin
eq "0" "$rc" "reinstall (control, again)"

# Where the build and update call it: before the base VM is saved, and fatal.
fn_body() { awk -v n="$1" '$0 ~ "^"n"\\(\\) \\{"{f=1} f{print} f&&/^}/{exit}' "$AUGUR"; }
for _f in install_macos_session_env_acceptance verify_macos_session_env_acceptance push_macos_guest_env; do
    eq "1" "$(fn_body "$_f" | grep -c 'macos_session_env_names')" "$_f computes the session's names once"
done
hasnt "$(declare -f macos_session_accept_env_line macos_session_env_check_cmd)" 'macos_session_env_names' "the AcceptEnv line and the clones' check take the names, never compute them"
build_body="$(fn_body cmd_build_macos)"; update_body="$(fn_body cmd_update_macos)"
has "$build_body"  'install_macos_session_env_acceptance "$MACOS_BUILD_VM" || exit 1' "build --macos installs the drop-in, fatally"
has "$update_body" 'install_macos_session_env_acceptance "$MACOS_UPDATE_VM" || {' "update --macos installs the drop-in, fatally"
has "$build_body"  'verify_macos_session_env_acceptance "$MACOS_BUILD_VM" || {' "build --macos re-checks the drop-in before the save, fatally (tests/52 pins the order)"
has "$update_body" 'verify_macos_session_env_acceptance "$MACOS_UPDATE_VM" || {' "update --macos re-checks the drop-in before the save, fatally (tests/52 pins the order)"
for _b in build update; do
    _body="$build_body"; [[ "$_b" == update ]] && _body="$update_body"
    i_at="$(printf '%s\n' "$_body" | grep -n 'install_macos_session_env_acceptance' | head -n1 | cut -d: -f1)"
    s_at="$(printf '%s\n' "$_body" | grep -n 'agent_verify_integrity_macos "\$MACOS_' | head -n1 | cut -d: -f1)"
    if [[ -n "$i_at" && -n "$s_at" && "$i_at" -lt "$s_at" ]]; then ok "$_b --macos installs it before the final check and the save"
    else fail "$_b --macos does not install it before the save" "install@${i_at:-none} check@${s_at:-none}"; fi
done
# The update installs it before every step that needs the network, right after the staging VM's
# SSH comes up, so a Homebrew or download failure is not what keeps the install from running.
_ln() { printf '%s\n' "$update_body" | grep -n -- "$1" | head -n1 | cut -d: -f1; }
i_at="$(_ln 'install_macos_session_env_acceptance "\$MACOS_UPDATE_VM"')"
boot_at="$(_ln 'macos_boot_scratch_vm_nat "\$MACOS_UPDATE_VM"')"
agent_at="$(_ln '_agent_url=')"; brew_at="$(_ln 'brew update')"; prov_at="$(_ln 'run_base_provisioning "\$MACOS_UPDATE_VM"')"
if [[ -n "$i_at" && -n "$boot_at" && -n "$agent_at" && -n "$brew_at" && -n "$prov_at" \
      && "$boot_at" -lt "$i_at" && "$i_at" -lt "$agent_at" && "$i_at" -lt "$brew_at" && "$i_at" -lt "$prov_at" ]]; then
    ok "update --macos installs it after the boot and before the agent installer, Homebrew and provisioning"
else fail "update --macos installs it after a step that needs the network" \
    "boot@${boot_at:-none} install@${i_at:-none} agent@${agent_at:-none} brew@${brew_at:-none} provisioning@${prov_at:-none}"; fi

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
eq "1" "$(ssh_calls)" "shell --macos: one other ssh connection (the push, which carries the acceptance check)"
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
# git's credential helper (git_credential_env) is exported by the session's remote command, after
# the delivery check and before the shell, and nowhere in ~/.augur-env.
hasnt "$envc" "GIT_CONFIG_" "shell --macos: ~/.augur-env holds no GIT_CONFIG_* helper lines"
remote="$(sess_argv | tail -n1)"
has "$remote" "export GIT_CONFIG_COUNT='2'; " "shell --macos: the session's remote command exports git's helper set"
has "$remote" "export GIT_CONFIG_VALUE_0=''; " "shell --macos: …with the empty reset entry"
has "$remote" "export GIT_CONFIG_VALUE_1='$(git_credential_env_value_1)'; " "shell --macos: …and the helper, single-quoted (\$GH_TOKEN a reference)"
chk_at="${remote%%\[ -n \"\${GH_TOKEN:-\}\" \] || exit*}"; git_at="${remote%%export GIT_CONFIG_COUNT*}"; cmd_at="${remote%%cd ~/*}"
if (( ${#chk_at} < ${#git_at} && ${#git_at} < ${#cmd_at} )); then ok "shell --macos: delivery check, then git's helper set, then the shell"
else fail "shell --macos: the remote command's order is wrong" "$remote"; fi
# A guest shell augur did not open (the GUI Terminal, a hand-run ssh) sources ~/.augur-env and gets
# no GIT_CONFIG_*, GH_TOKEN or not. Sourced under sh, which runs it as zsh would.
src_git_env() { env -i PATH=/usr/bin:/bin HOME="$GUEST_HOME" "$@" sh -c '. "$HOME/.augur-env" >/dev/null 2>&1; env | grep "^GIT_CONFIG_" | sort'; }
eq "" "$(src_git_env)" "a shell that only sources ~/.augur-env gets no GIT_CONFIG_*"
eq "" "$(src_git_env GH_TOKEN=ghp_session)" "…not even with a GH_TOKEN of its own"
[[ -e "$GUEST_HOME/.gitconfig" ]] && fail "the push created ~/.gitconfig" || ok "the push does not write ~/.gitconfig"
grep -q sync_macos_guest_clock "$STEPS" && ok "shell --macos: the clock is synced on this path (control)" \
    || fail "shell --macos: the clock sync did not run" "steps: $(tr '\n' ' ' < "$STEPS")"
pc="$(pushcmd)"
if [[ "$pc" == "_acc=0; grep -sqxF '$(macos_session_accept_env_line "$(macos_session_env_names)")' "* ]]; then ok "shell --macos: the acceptance check is the push's first step"
else fail "shell --macos: the acceptance check is not the push's first step" "$pc"; fi

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
# git's credential helper (git_credential_env) rides in the session's remote command, holding only
# the `$GH_TOKEN` reference; the token itself arrives with the session's environment.
remote="$(sess_argv | tail -n1)"
has   "$remote" "export GIT_CONFIG_COUNT='2'; " "claude --macos: the remote command exports git's credential helper (GIT_CONFIG_COUNT=2)"
has   "$remote" 'password=$GH_TOKEN' "claude --macos: …whose helper holds the \$GH_TOKEN reference"
hasnt "$remote" "ghp_rotated22222" "claude --macos: …and no token value"
git_at="${remote%%export GIT_CONFIG_COUNT*}"; cmd_at="${remote%%zsh -l -c*}"
(( ${#git_at} < ${#cmd_at} )) && ok "claude --macos: git's helper set is exported before the agent's login zsh" \
    || fail "claude --macos: git's helper set comes after the agent's login zsh" "$remote"
hasnt "$(cat "$ENV_FILE")" "GIT_CONFIG_" "claude --macos: ~/.augur-env holds no GIT_CONFIG_* helper lines"
leaks="$(grep -c . "$OTHERENV")"
eq "0" "$leaks" "no other ssh call has a file- or gh-sourced credential in its environment"
hasnt "$(cat "$SSHLOG")" "SendEnv" "no other ssh call carries a SendEnv"
grep -rlF -e ghp_rotated22222 -e test-oauth-file-CCC333 -e test-api-key-BBB222 "$GUEST_HOME" "$GUEST_ETC" >/dev/null 2>&1 \
    && fail "a credential value is in a guest file" "$(grep -rlF -e ghp_rotated22222 -e test-oauth-file-CCC333 -e test-api-key-BBB222 "$GUEST_HOME" "$GUEST_ETC")" \
    || ok "no credential value is in any guest file"
rm -f "$HOME/.claude_code_oauth_token"
# A host `gh auth logout`: the next session gets no GH_TOKEN, and exports no GIT_CONFIG_* credential
# helper either (see git_credential_env).
# GIT_CONFIG_* credential helper either (see git_credential_env).
GH_HOST_TOKEN=""
run_cmd shell
eq "0" "$rc" "gh logged out on the host: shell --macos still completes"
eq "ANTHROPIC_API_KEY " "$(sendenv)" "gh logged out on the host: GH_TOKEN is not sent"
hasnt "$(sess_env)" "GH_TOKEN" "gh logged out on the host: GH_TOKEN is not in the session ssh's environment"
hasnt "$(sess_argv | tail -n1)" "GIT_CONFIG_" "gh logged out on the host: the session exports no git credential helper"
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

# A temp file left by a push killed mid-write long ago (an older augur's may hold a credential), one
# whose mtime is far ahead of the guest's clock (written before a reboot, the clock lagging after
# it), a fresh one (a concurrent push still writing), one a few seconds ahead (a concurrent push
# that created its file after this push touched its reference file), and a file that is not
# augur's at all.
ahead_t() { local t=$(( $(date +%s) + $1 )); date -r "$t" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$t" +%Y%m%d%H%M.%S; }
stale_fixture() {
    printf "export GH_TOKEN='ghp_revoked'\n" > "$GUEST_HOME/.augur-env.tmp.4242"; touch -t 202001010000 "$GUEST_HOME/.augur-env.tmp.4242"
    printf "export GH_TOKEN='ghp_revoked'\n" > "$GUEST_HOME/.augur-env.tmp.4141"; touch -t 209901010000 "$GUEST_HOME/.augur-env.tmp.4141"
    printf "export GH_TOKEN='ghp_revoked'\n" > "$GUEST_HOME/.augur-env.tmp.4343"
    printf "export GH_TOKEN='ghp_revoked'\n" > "$GUEST_HOME/.augur-env.tmp.4444"; touch -t "$(ahead_t 20)" "$GUEST_HOME/.augur-env.tmp.4444"
    printf 'mine\n'                          > "$GUEST_HOME/.augur-env.bak"; touch -t 202001010000 "$GUEST_HOME/.augur-env.bak"
}
# stale_cleaned <label>: the old and the far-future temp files are gone, the fresh one, the one a
# few seconds ahead and the non-augur file are left alone.
stale_cleaned() {
    [[ -e "$GUEST_HOME/.augur-env.tmp.4242" ]] && fail "$1: an old temp file survives (it may hold revoked secrets)" \
        || ok "$1: a temp file older than a minute is removed"
    [[ -e "$GUEST_HOME/.augur-env.tmp.4141" ]] && fail "$1: a temp file dated far ahead of the guest clock survives" \
        || ok "$1: a temp file dated far ahead of the guest clock is removed"
    [[ -e "$GUEST_HOME/.augur-env.tmp.4343" ]] && ok "$1: a fresh temp file (a concurrent push) is left alone" \
        || fail "$1: a concurrent push's temp file was removed (its mv would then fail)"
    [[ -e "$GUEST_HOME/.augur-env.tmp.4444" ]] && ok "$1: a temp file a few seconds ahead (a concurrent push's, made after the reference) is left alone" \
        || fail "$1: a temp file a few seconds ahead was removed (a concurrent push created after the reference would fail)"
    [[ -e "$GUEST_HOME/.augur-env.bak" ]] && ok "$1: a file outside augur's temp-name pattern is left alone" \
        || fail "$1: cleanup removed a file that is not augur's"
    rm -f "$GUEST_HOME"/.augur-env.tmp.*
}
# Every push (every session, `up` on a running VM, the boot's only push) carries the acceptance
# check and the cleanup.
stale_fixture; ref_files() { find /tmp -maxdepth 1 -name 'augur-env-ref.*' 2>/dev/null | wc -l | tr -d ' '; }; refs_before="$(ref_files)"
run_cmd shell
eq "0" "$rc" "stale temp files: shell --macos completes"
stale_cleaned "checked push"
has "$(pushcmd)" "! -name .augur-env.tmp.\$\$" "checked push: the push's own temp file is spared"
has "$(pushcmd)" '\( -mmin +1 -o -newer "$_ref" \)' "checked push: the age test is the BSD-find-safe -mmin / -newer pair"
has "$(pushcmd)" 'date -r "$_t" +%Y%m%d%H%M.%S' "checked push: the reference time is formatted the macOS (BSD date) way first"
eq "$refs_before" "$(ref_files)" "checked push: its reference file in /tmp is removed again"
# On a refused guest too.
mv "$DROPIN" "$TMPD/dropin.saved"
stale_fixture
run_cmd shell
nonzero "stale temp files, refused guest: shell --macos"
stale_cleaned "refused guest"
mv "$TMPD/dropin.saved" "$DROPIN"
# A guest whose mktemp fails cannot make the reference file: the age test still runs, so an old
# temp file (which may hold an older augur's credentials) still goes; only the far-future check is
# skipped.
stale_fixture
FAIL_STEP=mktemp; run_cmd shell; FAIL_STEP=""
eq "0" "$rc" "mktemp fails in the guest: shell --macos completes"
has "$(pushcmd)" 'augur-env-ref' "mktemp fails in the guest: the push asked for a reference file (control)"
[[ -e "$GUEST_HOME/.augur-env.tmp.4242" ]] && fail "mktemp fails in the guest: an old temp file survives (it may hold revoked secrets)" \
    || ok "mktemp fails in the guest: a temp file older than a minute is still removed"
[[ -e "$GUEST_HOME/.augur-env.tmp.4343" ]] && ok "mktemp fails in the guest: a fresh temp file (a concurrent push) is left alone" \
    || fail "mktemp fails in the guest: a concurrent push's temp file was removed"
[[ -e "$GUEST_HOME/.augur-env.bak" ]] && ok "mktemp fails in the guest: a file outside augur's temp-name pattern is left alone" \
    || fail "mktemp fails in the guest: cleanup removed a file that is not augur's"
has "$(cat "$ENV_FILE")" "$MACOS_AUGUR_ENV_END_LINE" "mktemp fails in the guest: the new ~/.augur-env is installed"
rm -f "$GUEST_HOME"/.augur-env.tmp.*
rm -f "$GUEST_HOME/.augur-env.bak"

section "Tier 1 — a guest whose sshd does not accept the session's credentials is refused"

# An old base: no drop-in, and a ~/.augur-env an older augur wrote with credentials in it. Every
# refusal still installs the new ~/.augur-env first, so those credentials leave the guest's disk.
old_env() { printf "export GH_TOKEN='ghp_oldbase0000'\nexport ANTHROPIC_API_KEY='sk-oldbase'\n" > "$ENV_FILE"; }
refused() {   # refused <label>
    nonzero "$1"
    has "$out" "does not accept augur's session credentials" "$1: says why"
    hasnt "$out" "No such file" "$1: no raw grep error on a guest without the drop-in reaches the output"
    has "$out" "augur update --macos" "$1: names the base VM update"
    has "$out" "augur destroy --macos && augur up --macos" "$1: names the project VM recreate"
    eq "0" "$(launches)" "$1: starts no session (no credential is sent)"
    hasnt "$(cat "$ENV_FILE")" "oldbase" "$1: the credentials an older augur wrote are removed from ~/.augur-env"
    has "$(cat "$ENV_FILE")" "$MACOS_AUGUR_ENV_END_LINE" "$1: the new ~/.augur-env is installed"
    [[ -z "$GH_HOST_TOKEN" ]] || hasnt "$(cat "$ENV_FILE")" "$GH_HOST_TOKEN" "$1: the new ~/.augur-env holds no gh token value"
}
mv "$DROPIN" "$TMPD/dropin.saved"
for _cmd in shell claude up; do
    old_env; run_cmd "$_cmd"
    refused "no drop-in, running VM: $_cmd --macos"
    eq "1" "$(pushes)" "no drop-in, running VM: $_cmd --macos pushes once (the check rides in the push)"
    hasnt "$(cat "$STEPS")" "ensure_macos_workspace" "no drop-in, running VM: $_cmd --macos stops at the push"
done
# Stopped: refused right after the SSH wait, before the clock, the self-test and the rest of the
# bring-up. The VM is stopped with its egress helpers (its self-test never ran), the clone kept.
# A host gh token is resolved here, so a push that wrote git's GIT_CONFIG_* helper lines would show it.
RUNNING=0
for _cmd in claude up; do
    old_env; rm -f "$GUEST_HOME/.gitconfig"; run_cmd "$_cmd"
    refused "no drop-in, VM stopped: $_cmd --macos"
    grep -q '^run ' "$VMLOG" && ok "no drop-in, VM stopped: $_cmd --macos booted the VM (control)" \
        || fail "no drop-in, VM stopped: $_cmd --macos never booted" "$(cat "$VMLOG")"
    eq "" "$(cat "$STEPS")" "no drop-in, VM stopped: $_cmd --macos refuses before the clock, the self-test and the wiring"
    stopped_boot "no drop-in, VM stopped: $_cmd --macos"
    eq "1" "$(pushes)" "no drop-in, VM stopped: $_cmd --macos pushes once (the check and the cleanup in one)"
    eq "1" "$(ssh_calls)" "no drop-in, VM stopped: $_cmd --macos makes no other guest connection"
    has "$(pushcmd)" "sshd_config.d" "no drop-in, VM stopped: $_cmd --macos checks within that push (the running VM's code path)"
    hasnt "$(push_content 1)" "GIT_CONFIG_" "no drop-in, VM stopped: $_cmd --macos pushes no GIT_CONFIG_* helper lines to the refused guest"
    hasnt "$(cat "$ENV_FILE")" "GIT_CONFIG_" "no drop-in, VM stopped: $_cmd --macos leaves the refused guest's ~/.augur-env without them"
    hasnt "$(pushcmd)" "git config" "no drop-in, VM stopped: $_cmd --macos sends no git config command"
    [[ -e "$GUEST_HOME/.gitconfig" ]] && fail "no drop-in, VM stopped: $_cmd --macos wrote ~/.gitconfig" \
        || ok "no drop-in, VM stopped: $_cmd --macos leaves no ~/.gitconfig in the refused guest"
done
RUNNING=1
# A drop-in for a different set of names (the agent's credentials changed since the base VM build).
printf '# augur\nAcceptEnv ANTHROPIC_API_KEY GH_TOKEN\n' > "$DROPIN"
old_env; run_cmd shell
refused "a drop-in for other names: shell --macos"
mv "$TMPD/dropin.saved" "$DROPIN"
# With the drop-in, a boot checks once, in its only push, which writes no GIT_CONFIG_* helper lines:
# the session that follows exports them itself. No guest command checks on its own.
RUNNING=0
run_cmd claude
eq "0" "$rc" "drop-in present, VM stopped: claude --macos completes"
eq "1" "$(grep -c 'sshd_config.d' "$SSHLOG")" "drop-in present, VM stopped: the acceptance check runs once"
eq "" "$(grep 'sshd_config.d' "$SSHLOG" | grep -v 'cat > .*\.augur-env')" \
   "drop-in present, VM stopped: the check rides in a push (no extra connection)"
eq "1" "$(pushes)" "drop-in present, VM stopped: claude --macos pushes ~/.augur-env once"
first_push="$(grep 'cat > .*\.augur-env' "$SSHLOG" | sed -n 1p)"
has "$first_push" "sshd_config.d" "drop-in present, VM stopped: the push carries the check"
hasnt "$(push_content 1)" "GIT_CONFIG_" "drop-in present, VM stopped: the push writes no GIT_CONFIG_* helper lines"
hasnt "$(push_content 1)" "$GH_HOST_TOKEN" "drop-in present, VM stopped: …and no token value"
has "$(sess_argv | tail -n1)" "export GIT_CONFIG_COUNT='2'; " "drop-in present, VM stopped: the session exports git's helper set (a gh token exists)"
FAIL_CHECK=1
run_cmd claude
nonzero "the acceptance check cannot connect: claude --macos"
has "$out" "unknown outcome (ssh exit 255)" "the acceptance check cannot connect: says the push's outcome is unknown"
eq "" "$(cat "$STEPS")" "the acceptance check cannot connect: the boot stops before the clock and the self-test"
eq "0" "$(launches)" "the acceptance check cannot connect: no session"
stopped_boot "the acceptance check cannot connect: claude --macos"
RUNNING=1
FAIL_CHECK=0

# A refused guest whose push also fails a later step: the refusal and its remedy are still
# reported, next to what failed.
mv "$DROPIN" "$TMPD/dropin.saved"
for _run in "1 shell" "1 up" "0 up"; do
    RUNNING="${_run%% *}"; _cmd="${_run#* }"
    old_env; FAIL_STEP=env; run_cmd "$_cmd"; FAIL_STEP=""
    _l="no drop-in and the ~/.augur-env write fails (running=$RUNNING): $_cmd --macos"
    nonzero "$_l"
    has "$out" "Could not write ~/.augur-env" "$_l: says the write failed"
    has "$out" "may still hold credentials an older augur wrote" "$_l: says old credentials may remain"
    has "$out" "does not accept augur's session credentials" "$_l: still reports the refusal"
    has "$out" "augur destroy --macos && augur up --macos" "$_l: still names the remedy"
    eq "0" "$(launches)" "$_l: no session"
    [[ "$RUNNING" == 0 ]] && stopped_boot "$_l"
    rm -f "$GUEST_HOME/.zshenv"; FAIL_STEP=zshenv; run_cmd "$_cmd"; FAIL_STEP=""
    _l="no drop-in and the ~/.zshenv write fails (running=$RUNNING): $_cmd --macos"
    nonzero "$_l"
    has "$out" "~/.zshenv could not be updated" "$_l: says the ~/.zshenv step failed"
    has "$out" "does not accept augur's session credentials" "$_l: still reports the refusal"
    hasnt "$(cat "$ENV_FILE")" "oldbase" "$_l: the old credentials are still removed"
    eq "0" "$(launches)" "$_l: no session"
    [[ "$RUNNING" == 0 ]] && stopped_boot "$_l"
done
RUNNING=1
mv "$TMPD/dropin.saved" "$DROPIN"
# The same failures on a guest that accepts: no refusal is claimed.
FAIL_STEP=env; run_cmd shell; FAIL_STEP=""
nonzero "the ~/.augur-env write fails on a current guest: shell --macos"
hasnt "$out" "does not accept augur's session credentials" "the ~/.augur-env write fails on a current guest: no refusal is claimed"
hasnt "$out" "may still hold credentials" "the ~/.augur-env write fails on a current guest: no old-credential warning"

section "Tier 1 — a credential that cannot be injected aborts, after only the push of ~/.augur-env"

# On a running VM the guest may still hold an older augur's credential-bearing ~/.augur-env, so a
# failed resolution still rewrites it (no credential, no GIT_CONFIG_* helper lines) before refusing.
# no_cred_push <label>: the one push of a run that failed to resolve.
no_cred_push() {
    eq "1" "$(pushes)" "$1: sends one push"
    eq "1" "$(ssh_calls)" "$1: makes no other guest connection"
    hasnt "$(push_content 1)" "GIT_CONFIG_" "$1: the push writes no GIT_CONFIG_* helper lines"
    hasnt "$(cat "$ENV_FILE")" "GIT_CONFIG_" "$1: the guest's ~/.augur-env is left without them"
    hasnt "$(cat "$ENV_FILE")" "oldbase" "$1: the credentials an older augur wrote are removed"
    eq "0" "$(launches)" "$1: starts no session"
}
GH_HOST_TOKEN="ghp_rotated22222"
export ANTHROPIC_API_KEY="test-api-key-bad'quote"
for _cmd in shell claude up; do
    old_env; run_cmd "$_cmd"
    nonzero "bad ANTHROPIC_API_KEY: $_cmd --macos"
    has "$out" "Refusing to inject ANTHROPIC_API_KEY" "bad ANTHROPIC_API_KEY: $_cmd --macos names the variable"
    has "$out" "a credential could not be used" "bad ANTHROPIC_API_KEY: $_cmd --macos says why it stops"
    no_cred_push "bad ANTHROPIC_API_KEY: $_cmd --macos"
    [[ "$_cmd" == up ]] && break
    eq "" "$(cat "$STEPS")" "bad ANTHROPIC_API_KEY: $_cmd --macos runs no other guest step (clock, workspace, …)"
done
# `up` on a running VM refuses only after its self-test: a bad credential must not block a
# revocation landing, a dead proxy being revived, the clock fix or the self-test that proves
# enforcement.
has "$(cat "$HOSTLOG")" "gate"        "bad ANTHROPIC_API_KEY: up --macos on a running VM still runs the approval gate (allowlist rewrite)"
has "$(cat "$HOSTLOG")" "start_proxy" "bad ANTHROPIC_API_KEY: up --macos on a running VM still revives the proxy"
has "$(cat "$STEPS")" "sync_macos_guest_clock"     "bad ANTHROPIC_API_KEY: up --macos on a running VM still fixes the guest clock"
has "$(cat "$STEPS")" "verify_macos_egress_locked" "bad ANTHROPIC_API_KEY: up --macos on a running VM still runs the egress self-test"
verify_macos_egress_locked() { printf 'MARK:self-test\n' >> "$SSHLOG"; }
run_cmd up
st_at="$(grep -n '^MARK:self-test' "$SSHLOG" | cut -d: -f1)"; push_at="$(grep -n 'cat > .*\.augur-env' "$SSHLOG" | cut -d: -f1)"
if [[ -n "$st_at" && -n "$push_at" && "$st_at" -lt "$push_at" ]]; then
    ok "bad ANTHROPIC_API_KEY: up --macos on a running VM pushes only after the self-test (self-test@$st_at < push@$push_at)"
else fail "bad ANTHROPIC_API_KEY: up --macos on a running VM pushes before the self-test" "self-test@${st_at:-none} push@${push_at:-none}"; fi
eval "verify_macos_egress_locked() { printf '%s\n' verify_macos_egress_locked >> \"\$STEPS\"; }"
# An old base too: both the resolution error and the remedy are shown.
mv "$DROPIN" "$TMPD/dropin.saved"
for _cmd in shell up; do
    old_env; run_cmd "$_cmd"
    nonzero "bad ANTHROPIC_API_KEY, no drop-in: $_cmd --macos"
    has "$out" "Refusing to inject ANTHROPIC_API_KEY" "bad ANTHROPIC_API_KEY, no drop-in: $_cmd --macos names the variable"
    has "$out" "does not accept augur's session credentials" "bad ANTHROPIC_API_KEY, no drop-in: $_cmd --macos reports the refusal"
    has "$out" "augur update --macos" "bad ANTHROPIC_API_KEY, no drop-in: $_cmd --macos names the remedy"
    no_cred_push "bad ANTHROPIC_API_KEY, no drop-in: $_cmd --macos"
done
mv "$TMPD/dropin.saved" "$DROPIN"
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
hasnt "$(cat "$SSHLOG")" "ghp_bad" "bad gh token: the value is sent nowhere"
no_cred_push "bad gh token: claude --macos"
GH_HOST_TOKEN="ghp_rotated22222"

section "Tier 1 — a credential file that cannot be read aborts, after only the push of ~/.augur-env"

unset ANTHROPIC_API_KEY
if [[ "$(id -u)" == 0 ]]; then
    skip "unreadable credential file" "running as root: chmod 000 does not stop root reading it"
else
    printf 'test-oauth-unreadable\n' > "$HOME/.claude_code_oauth_token"; chmod 000 "$HOME/.claude_code_oauth_token"
    for _cmd in shell claude up; do
        old_env; run_cmd "$_cmd"
        nonzero "unreadable token file, running VM: $_cmd --macos"
        has "$out" "Could not read" "unreadable token file, running VM: $_cmd --macos says the file could not be read"
        no_cred_push "unreadable token file, running VM: $_cmd --macos"
        if [[ "$_cmd" == up ]]; then
            has "$(cat "$STEPS")" "verify_macos_egress_locked" "unreadable token file, running VM: up --macos still runs the egress self-test first"
        else
            eq "" "$(cat "$STEPS")" "unreadable token file, running VM: $_cmd --macos runs no other guest step (no clock/timezone sync)"
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
old_env; run_cmd shell
nonzero "token file bad from the first read: shell --macos"
no_cred_push "token file bad from the first read: shell --macos"
eval "$real_resolve"

section "Tier 1 — a push that fails is fatal on every path, after one more try"

export ANTHROPIC_API_KEY="test-api-key-BBB222"
before="$(cat "$ENV_FILE")"
FAIL_PUSH=1
for _cmd in shell claude; do
    run_cmd "$_cmd"
    nonzero "push fails, running VM: $_cmd --macos"
    eq "0" "$(launches)" "push fails, running VM: $_cmd --macos starts no session (an older ~/.augur-env may still be there)"
    eq "2" "$(pushes)" "push fails, running VM: $_cmd --macos tries the push twice, no more"
done
# A dropped connection (ssh's 255) may have come after the rename, so it must not claim either way.
has   "$out" "unknown outcome (ssh exit 255)" "connection dropped: the outcome is reported as unknown"
hasnt "$out" "is unchanged"                   "connection dropped: it does not claim the old file is still there"
has   "$out" "once more"                      "connection dropped: says it tries once more"
FAIL_PUSH=2
run_cmd shell
has   "$out" "is unchanged"                   "guest reports a failed install: says the old file is kept"
hasnt "$out" "unknown outcome"                "guest reports a failed install: the outcome is not called unknown"
eq "2" "$(pushes)" "guest reports a failed install: tried twice (a concurrent push may have taken its file)"
for FAIL_PUSH in 1 2; do
    RUNNING=1; run_cmd up
    nonzero "push fails ($FAIL_PUSH), running VM: up --macos"
    eq "2" "$(pushes)" "push fails ($FAIL_PUSH), running VM: up --macos tries twice"
    hasnt "$(cat "$VMLOG")" "stop" "push fails ($FAIL_PUSH), running VM: up --macos leaves the VM running"
    RUNNING=0; run_cmd up
    nonzero "push fails ($FAIL_PUSH) twice, boot: up --macos"
    eq "2" "$(pushes)" "push fails ($FAIL_PUSH) twice, boot: up --macos tries twice before it stops"
    stopped_boot "push fails ($FAIL_PUSH) twice, boot: up --macos"
    RUNNING=0; run_cmd claude
    nonzero "push fails ($FAIL_PUSH) twice, boot: claude --macos"
    eq "0" "$(launches)" "push fails ($FAIL_PUSH) twice, boot: claude --macos starts no session"
done
RUNNING=1
FAIL_PUSH=0
eq "$before" "$(cat "$ENV_FILE")" "push fails: the guest's ~/.augur-env is unchanged"
# A ~/.zshenv that cannot be updated fails the same way every time: no second try.
FAIL_STEP=zshenv; run_cmd shell; FAIL_STEP=""
nonzero "the ~/.zshenv write fails: shell --macos"
eq "1" "$(pushes)" "the ~/.zshenv write fails: no second try"
hasnt "$out" "once more" "the ~/.zshenv write fails: says no retry"
RUNNING=0; FAIL_STEP=zshenv; run_cmd up; FAIL_STEP=""; RUNNING=1
eq "1" "$(pushes)" "the ~/.zshenv write fails, boot: no second try"
stopped_boot "the ~/.zshenv write fails, boot: up --macos"

# A passing hiccup: the first push's connection drops, the second goes through, on every path.
for _run in "1 shell" "1 claude" "1 up" "0 shell" "0 claude" "0 up"; do
    RUNNING="${_run%% *}"; _cmd="${_run#* }"
    FAIL_PUSH=once; run_cmd "$_cmd"; FAIL_PUSH=0
    _l="the first push drops, the second succeeds (running=$RUNNING): $_cmd --macos"
    eq "0" "$rc" "$_l: completes"
    eq "2" "$(pushes)" "$_l: pushes twice"
    has "$out" "once more" "$_l: says it tried once more"
    hasnt "$(cat "$VMLOG")" "stop " "$_l: the VM keeps running"
    if [[ "$_cmd" == up ]]; then eq "0" "$(launches)" "$_l: up starts no session"
    else eq "1" "$(launches)" "$_l: starts its one session"; fi
done
RUNNING=1
# Two sessions at once: the other one's cleanup removes this push's temp file between its write and
# its rename. The push fails with the old file in place, and the second try goes through.
for _run in "1 shell" "0 claude"; do
    RUNNING="${_run%% *}"; _cmd="${_run#* }"
    FAIL_STEP=vanish; run_cmd "$_cmd"; FAIL_STEP=""
    _l="a concurrent push removes this one's temp file (running=$RUNNING): $_cmd --macos"
    has "$out" "Could not write ~/.augur-env" "$_l: the first push fails with the old file in place (control)"
    eq "0" "$rc" "$_l: completes after the second try"
    eq "2" "$(pushes)" "$_l: pushes twice"
    eq "1" "$(launches)" "$_l: starts its one session"
    has "$(cat "$ENV_FILE")" "$MACOS_AUGUR_ENV_END_LINE" "$_l: the new ~/.augur-env is installed"
done
RUNNING=1
# A refusal is never retried: the guest that does not accept the credentials is refused at once.
mv "$DROPIN" "$TMPD/dropin.saved"
for _run in "1 shell" "1 up" "0 claude"; do
    RUNNING="${_run%% *}"; _cmd="${_run#* }"
    run_cmd "$_cmd"
    _l="a refused guest (running=$RUNNING): $_cmd --macos"
    nonzero "$_l"
    has "$out" "does not accept augur's session credentials" "$_l: is refused (control)"
    eq "1" "$(pushes)" "$_l: pushes once, no retry"
    hasnt "$out" "once more" "$_l: says nothing of a retry"
    [[ "$RUNNING" == 0 ]] && stopped_boot "$_l"
    # Not even when a later step of that push also failed (a refused guest's failed write).
    FAIL_STEP=env; run_cmd "$_cmd"; FAIL_STEP=""
    eq "1" "$(pushes)" "$_l, its write failing too: pushes once, no retry"
done
RUNNING=1
mv "$TMPD/dropin.saved" "$DROPIN"
# No SSH transport to the VM (its gvproxy down, or its forward port unreadable): nothing is sent, the
# push says so rather than calling it a failed write, and it is not retried.
no_transport() {   # no_transport <label>
    nonzero "$1"
    has "$out" "No SSH transport to VM" "$1: says there is no SSH transport"
    hasnt "$out" "Could not write ~/.augur-env" "$1: does not call it a failed write"
    hasnt "$out" "once more" "$1: does not retry"
    eq "0" "$(pushes)" "$1: sends no push"
    eq "0" "$(launches)" "$1: starts no session"
}
for _run in "1 shell" "1 up"; do
    RUNNING="${_run%% *}"; _cmd="${_run#* }"
    run_cmd "$_cmd"   # control: the same run with a transport
    eq "0" "$rc" "control: $_cmd --macos (running=$RUNNING) completes with a transport"
    out="$( macos_ssh_port() { :; }; run_cmd "$_cmd"; printf '%s' "$out"; exit "$rc" )"; rc=$?
    no_transport "no SSH transport (running=$RUNNING): $_cmd --macos"
done
# As a refusal's push too: it adds that the old file may still hold credentials.
UNVERIFIED=1; rm -f "$(macos_egress_verified_file)"
out="$( macos_ssh_host() { :; }; run_cmd shell; printf '%s' "$out"; exit "$rc" )"; rc=$?
UNVERIFIED=0
no_transport "no SSH transport, unverified VM: shell --macos"
has "$out" "no egress self-test has passed since it booted" "no SSH transport, unverified VM: still refuses, saying why"
has "$out" "may still hold credentials an older augur wrote" "no SSH transport, unverified VM: says old credentials may remain"
# Through the real ssh_macos, whose unresolvable port ends the pipeline's subshell with status 1:
# without the check first, that would read as a failed write and be retried.
: > "$SSHLOG"; : > "$SESSLOG"
out="$( unset -f ssh_macos; eval "$(sed -n '/^ssh_macos() {$/,/^}$/p' "$AUGUR")"; macos_ssh_port() { :; }
        push_macos_guest_env_retrying "$(macos_project_vm)" 2>&1 )"; rc=$?
_l="no SSH transport, the real ssh_macos"
nonzero "$_l"
has "$out" "No SSH transport to VM" "$_l: says there is no SSH transport"
hasnt "$out" "Could not write ~/.augur-env" "$_l: does not call it a failed write"
hasnt "$out" "once more" "$_l: does not retry"
eq "0" "$(launches)" "$_l: no ssh process is started"

section "Tier 1 — a session checks in the guest that every credential it sent arrived"

# The guest's sshd plays along (SHIM_SSHD): the remote command runs, the stand-in zsh logs a launch.
# delivery_refused <label>: the message for a session that sent credentials and exited with
# MACOS_SESSION_ENV_MISSING_RC. That status may be the agent's or shell's own, so it names the
# status, says to ignore it then, and starts from the cheap check (`up --macos`) before the recreate.
delivery_refused() {
    has "$out" "exited with status $MACOS_SESSION_ENV_MISSING_RC" "$1: names the exit status"
    has "$out" "did not pass on a credential augur sent" "$1: says what the delivery check's status means"
    has "$out" "exited with ${MACOS_SESSION_ENV_MISSING_RC}, ignore this" "$1: says to ignore it if the agent or shell exited so itself"
    local _first="${out%%augur destroy --macos*}"
    has "$_first" "augur up --macos" "$1: suggests up --macos before any destroy"
    has "$_first" "which checks that the drop-in is still in place" "$1: …saying what it checks"
    has "$out" "augur destroy --macos && augur up --macos" "$1: names the recreate if it persists"
    has "$out" "augur update --macos" "$1: names the base VM update"
}
export MACOS_SHARE ANTHROPIC_API_KEY="test-api-key-BBB222"
GH_HOST_TOKEN="ghp_rotated22222"
RUNNING=1
for _cmd in claude shell; do
    : > "$SHIM_LAUNCHLOG"; SHIM_SSHD="drop:"; run_cmd "$_cmd"
    eq "0" "$rc" "every credential arrives: $_cmd --macos completes"
    eq "LAUNCHED" "$(cat "$SHIM_LAUNCHLOG")" "every credential arrives: $_cmd --macos launches"
    has "$(cat "$SHIM_LAUNCHLOG.git")" "GIT_CONFIG_COUNT=2" "every credential arrives: $_cmd --macos: the agent or shell has git's helper set"
    has "$(cat "$SHIM_LAUNCHLOG.git")" "GIT_CONFIG_VALUE_1=$(git_credential_env_value_1)" \
        "every credential arrives: $_cmd --macos: …with \$GH_TOKEN still a reference"
    for _n in ANTHROPIC_API_KEY GH_TOKEN; do
        has "$(sess_argv | tail -n1)" "[ -n \"\${${_n}:-}\" ] || exit $MACOS_SESSION_ENV_MISSING_RC" \
            "$_cmd --macos: the remote command checks ${_n} before it launches"
    done
    for _drop in GH_TOKEN ANTHROPIC_API_KEY ANTHROPIC_API_KEY,GH_TOKEN; do
        : > "$SHIM_LAUNCHLOG"; SHIM_SSHD="drop:$_drop"; run_cmd "$_cmd"
        _l="the guest's sshd drops $_drop: $_cmd --macos"
        nonzero "$_l"
        eq "" "$(cat "$SHIM_LAUNCHLOG")" "$_l: the agent or shell never starts"
        delivery_refused "$_l"
        hasnt "$out" "test-api-key-BBB222" "$_l: prints no API key"
        hasnt "$out" "ghp_rotated22222" "$_l: prints no gh token"
    done
done
# The check comes before the agent starts, in the same remote command, and prints nothing.
pre="$(sess_argv | tail -n1)"; pre="${pre%%export GIT_CONFIG*}"
has "$pre" "|| exit $MACOS_SESSION_ENV_MISSING_RC" "control: the delivery check is in front of git's helper set"
hasnt "$pre" "echo" "the delivery check prints nothing in the guest"
hasnt "$pre" "printf" "…no printf either"
# Nothing to send: nothing to check, and the session launches.
unset ANTHROPIC_API_KEY; GH_HOST_TOKEN=""
: > "$SHIM_LAUNCHLOG"; SHIM_SSHD="drop:"; run_cmd shell
eq "0" "$rc" "no credentials on the host: shell --macos completes with no delivery check"
eq "LAUNCHED" "$(cat "$SHIM_LAUNCHLOG")" "no credentials on the host: shell --macos launches"
eq "" "$(cat "$SHIM_LAUNCHLOG.git")" "no credentials on the host: the shell has no GIT_CONFIG_* (git keeps its own helpers)"
hasnt "$(sess_argv | tail -n1)" "exit $MACOS_SESSION_ENV_MISSING_RC" "no credentials on the host: no check is sent"
# An agent that exits with some other status: passed through, no refusal claimed.
SHIM_SSHD=""; SHIM_RC=3; run_cmd shell
eq "3" "$rc" "the session's own exit status is passed through"
hasnt "$out" "delivery check" "…and no refusal is claimed for it"
# A session that sent nothing ran no delivery check, so even the check's own status is the shell's.
SHIM_RC="$MACOS_SESSION_ENV_MISSING_RC"; run_cmd shell
eq "$MACOS_SESSION_ENV_MISSING_RC" "$rc" "nothing sent, the shell exits $MACOS_SESSION_ENV_MISSING_RC: passed through"
hasnt "$out" "delivery check" "…and not read as a refusal (no check ran)"
SHIM_RC=0
export ANTHROPIC_API_KEY="test-api-key-BBB222"; GH_HOST_TOKEN="ghp_rotated22222"
# With credentials sent, that status is the refusal (the accepted trade-off in ssh_macos_session).
SHIM_RC="$MACOS_SESSION_ENV_MISSING_RC"; run_cmd shell
nonzero "credentials sent, the session exits $MACOS_SESSION_ENV_MISSING_RC"
delivery_refused "credentials sent, the session exits $MACOS_SESSION_ENV_MISSING_RC"
SHIM_RC=0

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
    eq "1" "$(pushes)" "not running: $_cmd --macos pushes ~/.augur-env once (the one that carries the check)"
    eq "1" "$(gh_calls)" "not running: $_cmd --macos asks gh for the token once"
    eq "1" "$(grep -c '^ensure_macos_workspace$' "$STEPS")" "not running: $_cmd --macos wires the guest once"
    hasnt "$(cat "$VMLOG")" "stop " "not running: $_cmd --macos leaves the booted VM running"
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
hasnt "$(cat "$ENV_FILE")" "GIT_CONFIG_" "up --macos on a running VM: writes no git helper into ~/.augur-env (a gh token exists)"
# On the running branch the self-test still precedes the push. The self-test stub leaves a marker
# in SSHLOG so the two are in one ordering.
verify_macos_egress_locked() { printf 'MARK:self-test\n' >> "$SSHLOG"; }
run_cmd up
st_at="$(grep -n '^MARK:self-test' "$SSHLOG" | cut -d: -f1)"; push_at="$(grep -n 'cat > .*\.augur-env' "$SSHLOG" | cut -d: -f1)"
if [[ -n "$st_at" && -n "$push_at" && "$st_at" -lt "$push_at" ]]; then
    ok "up --macos on a running VM: the self-test precedes the push (self-test@$st_at < push@$push_at)"
else fail "up --macos on a running VM: the push is not after the self-test" "self-test@${st_at:-none} push@${push_at:-none}"; fi

section "Tier 1 — a running VM whose boot never passed its self-test gets no credential"

# An `up --macos` interrupted between `augur-vm run` and the self-test leaves the VM running with no
# record of a passed self-test (macos_egress_verified_file). A session refuses it with no guest step
# but the refusal's push of ~/.augur-env, which sends no credential and removes those an older augur
# wrote: no session, nothing sent.
RUNNING=1; UNVERIFIED=1
eval "verify_macos_egress_locked() { printf '%s\\n' verify_macos_egress_locked >> \"\$STEPS\"; }"
for _cmd in claude shell; do
    old_env; rm -f "$(macos_egress_verified_file)"; run_cmd "$_cmd"
    _l="no passed self-test since the boot: $_cmd --macos"
    nonzero "$_l"
    has "$out" "no egress self-test has passed since it booted" "$_l: says why"
    has "$out" "to re-run the egress self-test on the running VM" "$_l: names the remedy (up --macos)"
    hasnt "$out" "augur down --macos" "$_l: does not send the operator through a restart"
    no_cred_push "$_l"
    eq "" "$(cat "$STEPS")" "$_l: runs no other guest step (clock, workspace, …)"
    eq "0" "$(gh_calls)" "$_l: does not even resolve the gh token"
    hasnt "$(cat "$VMLOG")" "stop" "$_l: leaves the VM running"
done
# A refusal whose push fails still refuses, and says the old file may still hold credentials.
for FAIL_PUSH in 1 2; do
    old_env; rm -f "$(macos_egress_verified_file)"; run_cmd shell
    _l="no passed self-test, the push fails ($FAIL_PUSH): shell --macos"
    nonzero "$_l"
    has "$out" "no egress self-test has passed since it booted" "$_l: still refuses, saying why"
    has "$out" "may still hold credentials an older augur wrote" "$_l: says old credentials may remain"
    eq "0" "$(launches)" "$_l: starts no session"
done
FAIL_PUSH=0
# On an old base too: both refusals are reported, after the one push.
mv "$DROPIN" "$TMPD/dropin.saved"
old_env; rm -f "$(macos_egress_verified_file)"; run_cmd claude
_l="no passed self-test and no drop-in: claude --macos"
has "$out" "no egress self-test has passed since it booted" "$_l: reports the missing self-test"
has "$out" "does not accept augur's session credentials" "$_l: reports the old base"
no_cred_push "$_l"
mv "$TMPD/dropin.saved" "$DROPIN"
# A record from an earlier boot of the VM is no better, even one whose pid was handed to this boot's
# process (a recycled pid): the start time differs.
printf '%s Thu Jan 1 00:00:00 1970\n' "$$" > "$(macos_egress_verified_file)"; run_cmd claude
nonzero "a record from an earlier boot: claude --macos"
eq "0" "$(launches)" "a record from an earlier boot: claude --macos starts no session"
# `up --macos` on that VM re-runs the self-test, records its pass for this boot, and the next
# session goes ahead.
rm -f "$(macos_egress_verified_file)"; run_cmd up
eq "0" "$rc" "up --macos on the unverified running VM: completes"
has "$(cat "$STEPS")" "verify_macos_egress_locked" "up --macos on the unverified running VM: runs the self-test"
eq "$BOOT_ID" "$(cat "$(macos_egress_verified_file)" 2>/dev/null)" "up --macos on the unverified running VM: records the pass for this boot"
run_cmd claude
eq "0" "$rc" "…after which claude --macos completes"
eq "1" "$(launches)" "…and starts its session"
UNVERIFIED=0

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
hasnt "$(fn_body push_macos_guest_env)" '_creds' "the ~/.augur-env push does not read the resolved credentials at all"
hasnt "$(fn_body push_macos_guest_env)" 'git_credential_env' "the ~/.augur-env push writes no git helper"
has "$(fn_body ssh_macos_session)" '$(macos_session_git_env_cmd)' "the session's remote command takes git's helper from macos_session_git_env_cmd"
has "$(fn_body macos_session_git_env_cmd)" 'macos_env_add_export "$_kv" || return 1' "…which writes each line through macos_env_add_export"

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
