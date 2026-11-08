#!/usr/bin/env bash
# Tier 1 — git's GitHub credential helper in both modes (runs anywhere; nothing is ever cloned,
# booted or SSH'd — the macOS guest is a local `bash -c` against a sandboxed $HOME).
#
# git_credential_env is the one definition of augur's helper: GIT_CONFIG_* env config holding an
# empty helper value (which resets git's helper chain) and then augur's helper, which answers with
# the REFERENCE `$GH_TOKEN`. macOS exports it in the remote command of a session that sends GH_TOKEN
# (macos_session_git_env_cmd, which ssh_macos_session puts in front of the shell), Container passes
# it as `container exec -e` (_add_session_exec_env). Pinned here, against REAL git:
#
#   • git asks EVERY configured helper on `get` and calls `store` on every one after a successful
#     push: macOS's system-level osxkeychain ("failed to store: -25308" over SSH, and a GH_TOKEN copy
#     in an unlocked guest keychain) and anything the host's ~/.gitconfig or the repository names. A
#     fake helper that logs its calls sits in system config, XDG config, the global file before and
#     after the github.com section, an unconditional [include], an [includeIf "gitdir:"] matching the
#     repository, and the repository's own .git/config. It must never be called while augur's helper
#     answers with the token.
#   • the guest sees the value literally: `$GH_TOKEN` survives the export's quoting and is only
#     expanded by the helper's shell, so the token is on no ssh argv and in no GIT_CONFIG_* value.
#   • ~/.augur-env carries none of the set: a guest shell augur did not open (GUI Terminal, a
#     hand-run ssh) has no GIT_CONFIG_*, even with a GH_TOKEN of its own, and git runs its own
#     helpers there.
#   • a github.com section an older augur wrote into the guest's ~/.gitconfig is harmless.
#   • no host gh token → nothing is emitted in either mode, and ~/.gitconfig is never touched.
#   • deliberately broken variants (no reset, reset after the helper, `$GH_TOKEN` expanded when the
#     export is built or run) are each caught by the same probe, so the probe is not vacuous.
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/lib.sh"
AUGUR="$REPO/augur"

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

# BOOT-PROOFING (the technique tests/30_macos_vm.sh and tests/34_up_reconcile.sh use): point
# AUGUR_VM_BIN at a path that cannot exist BEFORE sourcing, so the resolved $VM_CLI can never be a
# real augur-vm. Set before the source because resolve_vm_cli runs at source time.
export AUGUR_VM_BIN="$TMPD/no-such-augur-vm"

# Pull the REAL functions out of augur without running its dispatch tail (AUGUR_SOURCE_ONLY seam).
# The ssh_macos stub is installed AFTER the source on purpose: bash resolves function names at CALL
# time, so a later definition wins.
AUGUR_SOURCE_ONLY=1 source "$AUGUR"
set +e                                    # augur enables `set -e`; restore lib.sh assert-and-continue

# Keep everything inside the sandbox: never the runner's real ~/.gitconfig, /etc/gitconfig or an
# ambient GIT_CONFIG_* set.
HOME="$TMPD/host-home"; mkdir -p "$HOME"
AUGUR_DIR="$TMPD/augur"
export GIT_CONFIG_NOSYSTEM=1
unset GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS GH_TOKEN
unset ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN

# The exact helper augur means to install. Pinned as a literal on purpose: it is the contract with
# the guest (`$GH_TOKEN` stays a REFERENCE), and a silent edit to the helper body should have to be
# re-affirmed here.
WANT_HELPER='!f() { test "$1" = get && echo username=x-access-token && echo "password=$GH_TOKEN"; }; f'
KEY='credential.https://github.com.helper'
TOKEN="ghp_hosttoken0123456789"

# Stand-in for the guest: ssh runs its argv joined-and-parsed by the remote shell, so `bash -c` with
# $HOME redirected at a throwaway guest home (and /Users/<user> mapped onto it) is faithful. The
# guest's /etc/ssh maps onto GUEST_ETC, which holds the sshd drop-in a current base VM has, so the
# push's acceptance check passes (tests/56 owns that check).
GUEST_HOME=""
GUEST_ETC="$TMPD/guest-etc"; mkdir -p "$GUEST_ETC/ssh/sshd_config.d"
macos_session_accept_env_line "$(macos_session_env_names)" > "$GUEST_ETC/ssh/sshd_config.d/$(basename "$(macos_session_sshd_dropin)")"
SSHLOG="$TMPD/sshlog"; ALL_SSH="$TMPD/all-ssh"; : > "$ALL_SSH"
ssh_macos() {
    local vm="$1"; shift
    local cmd="$*"
    printf '%s\n' "$cmd" | tee -a "$ALL_SSH" >> "$SSHLOG"
    cmd="${cmd//\/Users\/${MACOS_SSH_USER}/$GUEST_HOME}"; cmd="${cmd//\/etc\/ssh/$GUEST_ETC/ssh}"
    HOME="$GUEST_HOME" bash -c "$cmd"
}
GH_HOST_TOKEN=""
gh() { [[ -n "$GH_HOST_TOKEN" ]] || return 1; printf '%s\n' "$GH_HOST_TOKEN"; }

# Resolve the credentials and run the REAL push the way its callers do: inside `set -e`. Also sets
# SESSION_ENV to what the session ssh then sends (ssh_macos_session): GH_TOKEN, when there is one;
# and SESSION_PREFIX to git's helper exports the session's remote command carries
# (macos_session_git_env_cmd), built from the same resolved credentials.
wire() {   # wire <host gh token> — sets $out / $rc / SESSION_ENV / SESSION_PREFIX
    : > "$SSHLOG"; : > "$TMPD/prefix"; GH_HOST_TOKEN="$1"
    SESSION_ENV=(); [[ -n "$1" ]] && SESSION_ENV=("GH_TOKEN=$1")
    out="$( set -e; _creds=(); resolve_session_credentials; push_macos_guest_env testvm 2>&1
            macos_session_git_env_cmd 2>&1 > "$TMPD/prefix" )"; rc=$?
    SESSION_PREFIX="$(cat "$TMPD/prefix")"
    printf '%s\n' "$SESSION_PREFIX" >> "$ALL_SSH"     # it rides on the session ssh's argv
}

# A stand-in for osxkeychain or a host-path gh helper: answers nothing, logs every call.
FAKE="$TMPD/fake-helper"; FAKELOG="$TMPD/fake-helper.log"
printf '#!/bin/sh\necho "$1" >> "%s"\ncat > /dev/null\n' "$FAKELOG" > "$FAKE"
chmod +x "$FAKE"
SYSCONF="$TMPD/system-gitconfig"       # the role Apple git's system gitconfig plays on macOS
printf '[credential]\n\thelper = %s\n' "$FAKE" > "$SYSCONF"
fake_calls() { tr '\n' ' ' < "$FAKELOG" 2>/dev/null; }

# mk_guest <name> — a fresh guest home whose every config layer names the fake helper, and a
# repository under ~/work that the includeIf matches.
mk_guest() {
    GUEST_HOME="$TMPD/guest-$1"
    rm -rf "$GUEST_HOME"; mkdir -p "$GUEST_HOME/.config/git" "$GUEST_HOME/work"
    printf '[credential]\n\thelper = %s\n' "$FAKE" > "$GUEST_HOME/.config/git/config"
    printf '[credential]\n\thelper = %s\n' "$FAKE" > "$GUEST_HOME/.gitconfig-inc"
    printf '[credential]\n\thelper = %s\n' "$FAKE" > "$GUEST_HOME/.gitconfig-work"
    cat > "$GUEST_HOME/.gitconfig" <<EOF
[user]
	name = Test Operator
	email = op@example.com
[credential]
	helper = $FAKE
[credential "https://github.com"]
	helper = $FAKE
[include]
	path = $GUEST_HOME/.gitconfig-inc
[credential]
	helper = $FAKE
[includeIf "gitdir:$GUEST_HOME/work/"]
	path = $GUEST_HOME/.gitconfig-work
EOF
    REPO_DIR="$GUEST_HOME/work/repo"
    git init -q "$REPO_DIR"
    git -C "$REPO_DIR" config credential.helper "$FAKE"
    cp "$GUEST_HOME/.gitconfig" "$TMPD/guest-$1.gitconfig.orig"
}

# guest_sh <cmd> — a guest shell in the repository with the env exactly as an augur session's gets
# it: nothing inherited (env -i) except the session's GH_TOKEN, which sshd sets before the shell
# starts (SESSION_ENV). sshd's shell sources ~/.zshenv (and through it augur's ~/.augur-env), runs
# the session's remote command, whose exports (SESSION_PREFIX) come first, and the login zsh that
# command starts sources ~/.zshenv again. (bash stands in for zsh: these are plain `export
# NAME='value'` lines.) The system config is the fake-helper file; GIT_TERMINAL_PROMPT=0 turns a
# would-be prompt into a failure.
guest_sh() {
    env -i PATH="$PATH" HOME="$GUEST_HOME" GIT_CONFIG_SYSTEM="$SYSCONF" GIT_TERMINAL_PROMPT=0 \
        ${SESSION_ENV[@]+"${SESSION_ENV[@]}"} bash -c 'source "$HOME/.zshenv" 2>/dev/null; eval "$3"; source "$HOME/.zshenv" 2>/dev/null; cd "$1" && eval "$2"' _ "$REPO_DIR" "$1" "$SESSION_PREFIX"
}
cred_fill()    { guest_sh "printf 'protocol=https\nhost=github.com\n\n' | git credential fill" 2>&1; }
cred_approve() {
    guest_sh "printf 'protocol=https\nhost=github.com\nusername=x-access-token\npassword=%s\n\n' \"\$GH_TOKEN\" | git credential approve" 2>&1
}
# Every helper git runs for one `get`, from git's own trace.
helper_runs() {
    guest_sh "printf 'protocol=https\nhost=github.com\n\n' | GIT_TRACE=1 git credential fill" 2>&1 \
        | grep -c 'trace: run_command: .* get' || true
}

# probe — run a fill and an approve in the guest repository; sets:
#   P_FILL   what `git credential fill` printed
#   P_FAKE   every call the fake helper received (get and store)
#   P_VALUE1 GIT_CONFIG_VALUE_1 as the guest shell sees it
probe() {
    : > "$FAKELOG"
    P_FILL="$(cred_fill)"
    cred_approve >/dev/null
    P_FAKE="$(fake_calls)"
    P_VALUE1="$(guest_sh 'printf %s "${GIT_CONFIG_VALUE_1-}"')"
}
# probe_ok — the probe's verdict as one word, so a broken variant can be asserted to be caught.
probe_ok() {
    [[ "$P_FILL" == *"password=$TOKEN"* ]] || { echo "no-token-answer"; return; }
    [[ -z "$P_FAKE" ]]                     || { echo "fake-called"; return; }
    [[ "$P_VALUE1" == "${WANT_HELPER}" ]]  || { echo "value-not-literal"; return; }
    grep -qF "$TOKEN" <<<"$SESSION_PREFIX" && { echo "token-in-git-config"; return; }
    echo ok
}

section "Tier 1 — controls: the fixture really reaches the fake helper at every layer"

mk_guest control
: > "$GUEST_HOME/.zshenv"; : > "$GUEST_HOME/.augur-env"     # no augur env at all
store_calls() {   # store_calls [dir] — how many times one approve reaches the fake helper
    : > "$FAKELOG"
    env -i PATH="$PATH" HOME="$GUEST_HOME" GIT_CONFIG_SYSTEM="$SYSCONF" bash -c \
        "cd \"\$1\" && printf 'protocol=https\nhost=github.com\nusername=u\npassword=p\n\n' | git credential approve" _ "${1:-$REPO_DIR}" >/dev/null 2>&1
    wc -l < "$FAKELOG" | tr -d ' '
}
# system, XDG, global generic before, github.com section, [include], generic after, includeIf,
# repository: eight helpers, so eight stores.
eq "8" "$(store_calls)" "control: without augur, one store reaches the fake helper at all eight layers"
for _f in "$SYSCONF" "$GUEST_HOME/.config/git/config" "$GUEST_HOME/.gitconfig-inc" \
          "$GUEST_HOME/.gitconfig-work" "$REPO_DIR/.git/config"; do
    cp "$_f" "$TMPD/layer.orig"
    git config --file "$_f" --unset-all credential.helper
    eq "7" "$(store_calls)" "control: ${_f#"$TMPD"/} contributes exactly one of them"
    cp "$TMPD/layer.orig" "$_f"
done
eq "6" "$(store_calls "$GUEST_HOME")" "control: outside the repository the includeIf and repo helpers drop out (the gitdir: match is real)"

section "Tier 1 — macOS: the session exports the reset and the helper, and git obeys it"

mk_guest macos
wire "$TOKEN"
eq "0" "$rc" "the push and the session's exports are built"
envf="$(cat "$GUEST_HOME/.augur-env")"
hasnt "$envf" "GIT_CONFIG_"                                         "~/.augur-env carries none of the GIT_CONFIG_* set"
has "$SESSION_PREFIX" "export GIT_CONFIG_COUNT='2'; "               "the session exports GIT_CONFIG_COUNT=2"
has "$SESSION_PREFIX" "export GIT_CONFIG_KEY_0='${KEY}'; "          "the session: entry 0 is the github.com helper key"
has "$SESSION_PREFIX" "export GIT_CONFIG_VALUE_0=''; "              "the session: entry 0's value is the empty reset"
has "$SESSION_PREFIX" "export GIT_CONFIG_KEY_1='${KEY}'; "          "the session: entry 1 is the github.com helper key"
has "$SESSION_PREFIX" "export GIT_CONFIG_VALUE_1='${WANT_HELPER}'; " "the session: entry 1 is augur's helper, single-quoted"
probe
has "$P_FILL" "password=$TOKEN"         "macOS: augur's helper answers get with the token (from \$GH_TOKEN)"
has "$P_FILL" "username=x-access-token" "macOS: …with the x-access-token username"
eq  "" "$P_FAKE"                        "macOS: the fake helper is called on neither get nor store, at any layer"
eq  "$WANT_HELPER" "$P_VALUE1"          "macOS: the guest shell sees GIT_CONFIG_VALUE_1 literally (\$GH_TOKEN unexpanded)"
eq  "1" "$(helper_runs)"                "macOS: git runs exactly one helper for get"
eq  "ok" "$(probe_ok)"                  "macOS: the probe's verdict is ok"
eq  "2" "$(guest_sh 'printf %s "${GIT_CONFIG_COUNT-}"')" "macOS: the session's shell has the GIT_CONFIG_* set"
# A guest shell augur did not open (the VM's GUI Terminal, a hand-run ssh) runs no session exports:
# it has none of the GIT_CONFIG_* set even with a GH_TOKEN of its own, so git keeps its own helpers
# there instead of being reset.
_saved_prefix="$SESSION_PREFIX"; SESSION_PREFIX=""
eq "" "$(guest_sh 'env | grep -E "^GIT_CONFIG_(COUNT|KEY_|VALUE_)"')" "macOS: a shell augur did not open has no GIT_CONFIG_*, GH_TOKEN or not"
_saved_session_env=("${SESSION_ENV[@]}"); SESSION_ENV=()
probe
hasnt "$P_FILL" "password=$TOKEN"       "macOS: such a shell without GH_TOKEN has no token to answer with"
hasnt "$P_FILL" "username=x-access-token" "macOS: …and augur's helper does not answer at all (no empty password)"
has "$P_FAKE" "get"                     "macOS: …so git asks the guest's own helpers"
has "$P_FAKE" "store"                   "macOS: …and stores through them, as without augur"
SESSION_ENV=("${_saved_session_env[@]}"); SESSION_PREFIX="$_saved_prefix"

# The token: nowhere in ~/.augur-env or the session's exports (the helper gets it from the session's
# environment), and on no argv.
hasnt "$envf" "$TOKEN" "the token is nowhere in ~/.augur-env"
hasnt "$SESSION_PREFIX" "$TOKEN" "the token is in no GIT_CONFIG_* value the session exports"
hasnt "$envf" "export GH_TOKEN=" "~/.augur-env exports no GH_TOKEN"
if grep -qF "$TOKEN" "$ALL_SSH"; then fail "the token is on an ssh argv" "$(cat "$ALL_SSH")"
else ok "the token is on no ssh argv"; fi
[[ -s "$ALL_SSH" ]] && ok "control: the argv log is not empty" || fail "control: no ssh call was recorded"
# augur leaves the copied ~/.gitconfig byte-identical: the helper lives only in the session's env.
if cmp -s "$GUEST_HOME/.gitconfig" "$TMPD/guest-macos.gitconfig.orig"; then
    ok "macOS: the copied ~/.gitconfig is left byte-identical"
else fail "macOS: the copied ~/.gitconfig was modified" "$(diff "$TMPD/guest-macos.gitconfig.orig" "$GUEST_HOME/.gitconfig")"; fi
hasnt "$(cat "$SSHLOG")" "git config" "macOS: the push sends no git config command"

# A GIT_CONFIG_* set a guest startup file exports replaces augur's, reset included: the login zsh
# the session starts sources it after augur's exports, and so does every zsh the agent starts for a
# command (the accepted trade-off at git_credential_env, which says why the exports stay where
# they are).
{ printf "export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0='%s'\n" "$FAKE"
  cat "$GUEST_HOME/.zshenv"; } > "$GUEST_HOME/.zshenv.new" && mv "$GUEST_HOME/.zshenv.new" "$GUEST_HOME/.zshenv"
probe
eq "no-token-answer" "$(probe_ok)" "an operator GIT_CONFIG_* set in a guest startup file wins over augur's"

section "Tier 1 — macOS: a github.com section an older augur left in ~/.gitconfig is harmless"

# What an older augur wrote at the end of the guest's ~/.gitconfig. ~/.gitconfig is re-copied from
# the host only on boot, so a running VM keeps it across claude/shell sessions.
mk_guest leftover
cat >> "$GUEST_HOME/.gitconfig" <<'EOF'
[credential "https://github.com"]
	helper =
	helper = !f() { test \"$1\" = get && echo username=x-access-token && echo password=$GH_TOKEN; }; f
EOF
wire "$TOKEN"
probe
eq "ok" "$(probe_ok)"   "leftover section: augur's helper answers, the fake helper is never called"
eq "1" "$(helper_runs)" "leftover section: git still runs exactly one helper (the env reset clears the old one too)"

section "Tier 1 — no host gh token: nothing is emitted in either mode"

mk_guest notoken
wire ""
eq "0" "$rc" "no gh token: the push returns 0"
eq "" "$SESSION_PREFIX" "no gh token: the session exports no GIT_CONFIG_*"
hasnt "$(cat "$GUEST_HOME/.augur-env")" "GIT_CONFIG_" "no gh token: ~/.augur-env carries no GIT_CONFIG_*"
hasnt "$(cat "$GUEST_HOME/.augur-env")" "GH_TOKEN"    "no gh token: …and no GH_TOKEN"
if cmp -s "$GUEST_HOME/.gitconfig" "$TMPD/guest-notoken.gitconfig.orig"; then
    ok "no gh token: the copied ~/.gitconfig is left byte-identical"
else fail "no gh token: the copied ~/.gitconfig was modified"; fi
# git behaves as it would without augur: the configured helpers are asked.
probe
has "$P_FAKE" "store" "no gh token: git runs the configured helpers as without augur (no lone reset)"
_creds=(); _env=(); _add_session_exec_env
hasnt "${_env[*]}" "GIT_CONFIG_" "no gh token: the container exec env carries no GIT_CONFIG_*"
eq "" "$(git_credential_env)" "no gh token: git_credential_env prints nothing"

section "Tier 1 — Container: the same set, via -e, and real git obeys it"

_creds=("GH_TOKEN=$TOKEN")
_env=()
_add_session_exec_env
cenv=()
for ((i = 0; i < ${#_env[@]}; i++)); do
  [[ "${_env[i]}" == -e && "${_env[i+1]:-}" == GIT_CONFIG_* ]] && cenv+=("${_env[i+1]}")
done
eq "$(git_credential_env)" "$(printf '%s\n' "${cenv[@]}")" "container: the -e GIT_CONFIG_* pairs are exactly git_credential_env's lines, in order"
eq "GIT_CONFIG_VALUE_0=" "${cenv[2]:-}" "container: the first helper value is the empty reset"
eq "GIT_CONFIG_VALUE_1=$WANT_HELPER" "${cenv[4]:-}" "container: the second is augur's helper, \$GH_TOKEN unexpanded"
hasnt "${_env[*]}" "$TOKEN" "container: the token is in no -e argument"
_creds=()
mk_guest container
: > "$FAKELOG"
cfill="$(cd "$REPO_DIR" && printf 'protocol=https\nhost=github.com\n\n' | env -i PATH="$PATH" HOME="$GUEST_HOME" \
    GIT_CONFIG_SYSTEM="$SYSCONF" GIT_TERMINAL_PROMPT=0 GH_TOKEN="$TOKEN" "${cenv[@]}" git credential fill 2>&1)"
( cd "$REPO_DIR" && printf 'protocol=https\nhost=github.com\nusername=x-access-token\npassword=%s\n\n' "$TOKEN" \
    | env -i PATH="$PATH" HOME="$GUEST_HOME" GIT_CONFIG_SYSTEM="$SYSCONF" "${cenv[@]}" git credential approve >/dev/null 2>&1 )
has "$cfill" "password=$TOKEN" "container: augur's helper answers get (password from \$GH_TOKEN)"
eq "" "$(fake_calls)"          "container: the fake helper is called on neither get nor store, at any layer"

section "Tier 1 — deliberate breakage: each broken variant is caught by the probe"

real_gce="$(declare -f git_credential_env)"
real_export="$(declare -f macos_env_add_export)"
broken() {   # broken <slug> <label> <expected verdict> — wire with the current (broken) definitions, probe
    mk_guest "broken-$1"; shift
    wire "$TOKEN"
    probe
    local v; v="$(probe_ok)"
    if [[ "$v" == ok ]]; then fail "breakage '$1' is NOT caught" "probe said ok"
    else eq "$2" "$v" "breakage '$1' is caught ($v)"; fi
    eval "$real_gce"; eval "$real_export"
}

# 1. No empty reset: the helpers from every config layer are asked again.
git_credential_env() {
    creds_have_gh_token || return 0
    printf '%s\n' 'GIT_CONFIG_COUNT=1' "GIT_CONFIG_KEY_0=$KEY" "GIT_CONFIG_VALUE_0=$WANT_HELPER"
}
broken noreset "no reset" fake-called

# 2. The reset AFTER the helper: it clears augur's helper too, so nothing answers.
git_credential_env() {
    creds_have_gh_token || return 0
    printf '%s\n' 'GIT_CONFIG_COUNT=2' "GIT_CONFIG_KEY_0=$KEY" "GIT_CONFIG_VALUE_0=$WANT_HELPER" \
        "GIT_CONFIG_KEY_1=$KEY" 'GIT_CONFIG_VALUE_1='
}
broken resetafter "reset after the helper" no-token-answer

# 3. `$GH_TOKEN` expanded on the host when the value is written (a double-quoted helper body, with
# the token in augur's own environment, as `gh auth token` sees a host GH_TOKEN).
git_credential_env() {
    creds_have_gh_token || return 0
    printf '%s\n' 'GIT_CONFIG_COUNT=2' "GIT_CONFIG_KEY_0=$KEY" 'GIT_CONFIG_VALUE_0=' "GIT_CONFIG_KEY_1=$KEY" \
        "GIT_CONFIG_VALUE_1=!f() { test \"\${1-}\" = get && echo username=x-access-token && echo \"password=$GH_TOKEN\"; }; f"
}
GH_TOKEN="$TOKEN" broken hostexp "\$GH_TOKEN expanded when the session's exports are built" value-not-literal
grep -qF "$TOKEN" <<<"$SESSION_PREFIX" && ok "…and the token value did land in a GIT_CONFIG_* export (the hazard is real)" \
    || fail "…the host-expansion variant did not put the token in the session's exports (fixture is vacuous)"

# 4. `$GH_TOKEN` expanded when the guest shell RUNS the export: the writer double-quotes the value.
eval "$(printf '%s\n' "$real_export" | sed 's/='"'"'\${value}'"'"'/=\\"${value}\\"/')"
[[ "$(declare -f macos_env_add_export)" != "$real_export" ]] \
    && ok "control: the writer was really mutated to double quotes" || fail "control: the sed did not change the writer"
broken runexp "\$GH_TOKEN expanded when the guest shell runs the export" no-token-answer

eq "$real_gce" "$(declare -f git_credential_env)" "control: the real git_credential_env is restored"
eq "$real_export" "$(declare -f macos_env_add_export)" "control: the real export line writer is restored"

section "Tier 1 — macOS: a value the single-quoted export cannot hold stops the session before ssh"

# refused <slug> <label> — wire with the current (unsafe) git_credential_env; building the session's
# exports must fail, and the real ssh_macos_session must then return before it connects.
refused() {
    mk_guest "refused-$1"; shift
    wire "$TOKEN"
    [[ "$rc" != 0 ]] && ok "$1: building the session's exports fails" || fail "$1: building the session's exports returned 0" "$out"
    has "$out" "Refusing to" "$1: it says why"
    eq "" "$SESSION_PREFIX" "$1: nothing is exported"
    : > "$TMPD/connect"
    ( _creds=("GH_TOKEN=$TOKEN")
      _macos_ssh_cmd() { echo CONNECT >> "$TMPD/connect"; _ssh=(true); _ssh_dest=x; }
      ssh_macos_session testvm -t "exec zsh -l" ) >/dev/null 2>&1
    [[ "$?" != 0 ]] && ok "$1: the session fails" || fail "$1: the session returned 0"
    eq "" "$(cat "$TMPD/connect")" "$1: the session ssh is never started"
    eval "$real_gce"
}
git_credential_env() {
    creds_have_gh_token || return 0
    printf '%s\n' 'GIT_CONFIG_COUNT=1' "GIT_CONFIG_KEY_0=$KEY" "GIT_CONFIG_VALUE_0=!f() { echo 'x'; }; f"
}
refused quote "a single quote in a helper value"
git_credential_env() {
    creds_have_gh_token || return 0
    printf '%s\n' 'GIT_CONFIG_COUNT=1' "GIT_CONFIG_KEY_0=$KEY" $'GIT_CONFIG_VALUE_0=a\tb'
}
refused ctrl "a control byte in a helper value"
git_credential_env() {
    creds_have_gh_token || return 0
    printf '%s\n' 'GIT CONFIG=1'
}
refused name "an entry whose name is not a shell variable name"
eq "$real_gce" "$(declare -f git_credential_env)" "control: the real git_credential_env is restored again"

section "Tier 1 — source guards"

fn_body() { awk -v n="$1" '$0 ~ "^"n"\\(\\) \\{"{f=1} f{print} f&&/^}/{exit}' "$AUGUR"; }
host_config_body="$(fn_body _add_host_config_run_args)"
has   "$(fn_body _add_session_exec_env)" '< <(git_credential_env)'  "container sessions take the helper from git_credential_env"
has   "$(fn_body macos_session_git_env_cmd)" '< <(git_credential_env)' "macOS sessions take it from git_credential_env"
has   "$(fn_body macos_session_git_env_cmd)" 'macos_env_add_export "$_kv" || return 1' \
      "…through macos_env_add_export, aborting on refusal"
hasnt "$(fn_body macos_session_git_env_cmd)" '${_kv#*=}'  "…formatting no NAME=value pair itself"
has   "$(fn_body ssh_macos_session)" '_git="$(macos_session_git_env_cmd)" || return 1' "a macOS session that cannot build them does not start"
hasnt "$(fn_body push_macos_guest_env)" 'git_credential_env' "the macOS ~/.augur-env push writes no git helper"
hasnt "$(fn_body push_macos_guest_env)"  '${_kv#*=}'  "the push formats no NAME=value pair itself"
hasnt "$host_config_body" 'GIT_CONFIG_' "container \`run\` bakes no GIT_CONFIG_* (the helper is per session)"
has   "$host_config_body" '.gitconfig:/home/dev/.gitconfig:ro' "container up mounts ~/.gitconfig READ-ONLY"
hasnt "$(cat "$AUGUR")" 'git config --global' "augur never mutates a global git config, in either mode"

finish
