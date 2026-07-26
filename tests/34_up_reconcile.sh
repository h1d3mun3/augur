#!/usr/bin/env bash
# Tier 1 — `up` against an ALREADY-RUNNING guest reconciles host-side state (runs anywhere; no
# container/VM host needed, and nothing is ever cloned or booted).
#
# Both cmd_up and cmd_up_macos used to `return 0` on "already running" BEFORE the approval gate and
# before any datapath work. Nothing widened (the previously approved policy stayed in force, which
# is fail-closed), but three properties the rest of augur claims silently stopped holding:
#
#   1. A REVOCATION never landed. write_merged_allowlist has exactly ONE caller — start_proxy,
#      reached only from start_egress_proxy (container) and cmd_up_macos (macOS), both BELOW the
#      short-circuit — and augur-proxy hot-reloads policy from that file's mtime. So editing the
#      allowlist and running `augur up` printed one yellow line, exited 0, and left the live proxy
#      enforcing the old policy.
#   2. I1's tripwire did not run: verify_egress_locked lives in finish_up, also below it.
#   3. A flipped egress mode / rotated credential was not surfaced: the container_fingerprint
#      reconcile that exists to catch exactly that sits below it too.
#
# The two modes are deliberately ASYMMETRIC. Container mode can refuse (`exit 1`) because it HAS a
# drift signal; macOS mode has no fingerprint and no boot self-test, so its half applies what the
# host owns and WARNS about what a live VM cannot pick up (gvproxy's DNS allowlist is read once at
# startup, VM sizing needs the VM stopped, ~/.augur-env is not re-pushed).
#
# The last section covers the OTHER half of that story: WHY an operator ended up on the
# already-running path with a credential-less guest in the first place. macOS mode validated the
# credentials it injects only at the ~/.augur-env writer — after clone, sizing, boot and the SSH
# wait — so a value that could not be injected aborted `up` with a VM already running and nothing
# torn down; the retry then hit the branch above, which cannot re-push ~/.augur-env. The check now
# runs before the clone, like container mode's has always run before `container run`.
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/lib.sh"
AUGUR="$REPO/augur"

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT
LOG="$TMPD/calls"       # ordered record of which reconcile steps ran
VMLOG="$TMPD/vmcli"     # every augur-vm invocation, so "never booted" is assertable

# BOOT-PROOFING (the technique tests/30_macos_vm.sh uses): point AUGUR_VM_BIN at a path that does
# not exist BEFORE sourcing, so the resolved $VM_CLI can never be a real augur-vm. The recorder
# function installed further down replaces it for the assertions; if that override were ever lost,
# the fallback is "command not found", never a cloned or booted VM. Set before the source because
# resolve_vm_cli runs at source time.
export AUGUR_VM_BIN="$TMPD/no-such-augur-vm"

# Pull the REAL cmd_up / cmd_up_macos out of augur without running its dispatch tail
# (AUGUR_SOURCE_ONLY seam), the same way tests/32_proxy_per_mode.sh does, so this can never drift
# from the shipped functions. Recorder stubs are installed AFTER the source on purpose: bash
# resolves function names at CALL time, so a later definition wins.
AUGUR_SOURCE_ONLY=1 source "$AUGUR"
set +e                                    # augur enables `set -e`; restore lib.sh assert-and-continue
AUGUR_PROXY_DIR="$TMPD/proxy"; mkdir -p "$AUGUR_PROXY_DIR"   # keep the test off the real ~/.augur
# These five are assigned in the dispatch tail the AUGUR_SOURCE_ONLY seam returns before, so mint
# them here exactly as that tail does — cmd_up's messages interpolate CONTAINER_NAME, cmd_up_macos's
# interpolate MACOS_SHARE, and augur runs under `set -u`.
SWIFT_IMAGE_TAG="${SWIFT_VERSION:-latest}"
IMAGE_NAME="augur:swift-${SWIFT_IMAGE_TAG}"
CONTAINER_NAME="$(make_container_name)"
WORKSPACE_MOUNT="$(make_workspace_mount)"
MACOS_SHARE="workspace-$(workspace_slug)"

# ── Recorders shared by both modes ───────────────────────────────────────────
# Each appends ONE anchor line. Assertions match those lines exactly (grep -qx), never a substring
# of augur's own prose — `has()` is unanchored, and a message can mention a function it never called.
check_project_conf_approved() { echo "gate" >> "$LOG"; }
write_merged_allowlist()      { echo "allowlist-rewritten" >> "$LOG"; echo "$AUGUR_PROXY_DIR/fake.allowlist"; }
finish_up()                   { echo "finish_up" >> "$LOG"; }
start_proxy()                 { echo "start_proxy $1" >> "$LOG"; }
egress_enabled()              { return 0; }
logged() { grep -qx "$1" "$LOG" 2>/dev/null; }   # exact-line match against the recorder log

section "Tier 1 — container: up on a RUNNING container reconciles instead of no-opping"

require_engine() { :; }
ensure_image()   { :; }
container_running() { return 0; }
container_exists()  { return 0; }
_fp_matches=0
container_fingerprint_matches() { return $_fp_matches; }

run_up() {   # sets $out / $rc; the call log is truncated first
  : > "$LOG"
  out="$( cmd_up 2>&1 )"; rc=$?
}

_fp_matches=0
run_up
eq "0" "$rc" "up: exits 0 when the running container's config still matches"
if logged gate; then ok "up: runs the project-conf approval gate (policy is being written)"
else fail "up: never ran check_project_conf_approved" "log: $(cat "$LOG")"; fi
if logged allowlist-rewritten; then ok "up: rewrites the merged allowlist (the only push to a live proxy)"
else fail "up: never rewrote the merged allowlist" "a revocation would not reach the running proxy"; fi
if logged finish_up; then ok "up: runs finish_up (restores I1's boot self-test on this path)"
else fail "up: never ran finish_up" "verify_egress_locked skipped — I1's tripwire does not fire"; fi
# The gate must precede the write, or an unapproved conf could be merged before being approved.
g_at="$(grep -n '^gate$' "$LOG" | head -n1 | cut -d: -f1)"
a_at="$(grep -n '^allowlist-rewritten$' "$LOG" | head -n1 | cut -d: -f1)"
if [[ -n "$g_at" && -n "$a_at" && "$g_at" -lt "$a_at" ]]; then ok "up: the gate runs BEFORE the merge (gate@$g_at < merge@$a_at)"
else fail "up: the approval gate does not precede the merge" "gate@${g_at:-none} merge@${a_at:-none}"; fi
# Anchored on a phrase ONLY the drift refusal can print — the success path never says this.
hasnt "$out" "A running container cannot pick those up" "up: no drift refusal when the config matches"

section "Tier 1 — container: fingerprint drift on a RUNNING container REFUSES (and still revokes)"

_fp_matches=1
run_up
if [[ "$rc" -ne 0 ]]; then ok "up: exits non-zero when the baked config drifted (a running container cannot re-provision)"
else fail "up: exited 0 on fingerprint drift" "the operator would keep running stale wiring/credentials"; fi
has "$out" "A running container cannot pick those up" "up: names why it refuses rather than warning and continuing"
has "$out" "augur down && augur up"                   "up: states the exact remedy"
# THE point of the redundant write: the refusal path exits before finish_up, so if the allowlist
# were only rewritten inside start_proxy (via finish_up) a REVOCATION would never land here.
if logged allowlist-rewritten; then ok "up: the allowlist is STILL rewritten on the refusal path (a revocation lands)"
else fail "up: drift refusal skipped the allowlist rewrite" "a revoked domain would stay honored by the live proxy"; fi
if logged gate; then ok "up: the approval gate still runs on the refusal path"
else fail "up: drift refusal skipped the approval gate"; fi
if logged finish_up; then fail "up: finish_up ran after the refusal" "exit 1 must stop before the datapath work"
else ok "up: finish_up does NOT run after the refusal"; fi

section "Tier 1 — macOS: up on a RUNNING VM reconciles the host side and NEVER boots anything"

MACOS_MODE=true
require_vz()        { :; }
macos_vm_exists()   { return 0; }
macos_vm_running()  { return 0; }
start_gvproxy()     { echo "start_gvproxy" >> "$LOG"; }
stop_gvproxy()      { :; }
stop_proxy()        { :; }
wait_for_macos_ssh() { return 1; }   # would fail loudly if the branch ever fell through
ssh_macos()         { echo "ssh_macos" >> "$LOG"; return 0; }
scp_to_macos()      { :; }
# Recorder standing in for the augur-vm CLI. $VM_CLI is invoked as "$VM_CLI" <subcmd>, so a function
# name works — and unlike a stub that silently succeeds, this makes "run was never invoked" a real
# assertion rather than a vacuous one.
vm_cli_rec() { printf '%s\n' "$*" >> "$VMLOG"; return 0; }
VM_CLI=vm_cli_rec

# Negative control for the recorder itself: prove it DOES capture a `run`, so the "never invoked"
# assertion below cannot pass just because the recorder is broken.
: > "$VMLOG"; "$VM_CLI" run self-check >/dev/null 2>&1
if grep -q '^run self-check$' "$VMLOG"; then ok "macOS: the augur-vm recorder captures a 'run' when one happens (control)"
else fail "macOS: the augur-vm recorder does not capture 'run'" "the 'never booted' assertion would be vacuous"; fi

# Make the host-side policy provably NEWER than gvproxy's snapshot: the pidfile is written when
# gvproxy starts, i.e. when it read --dns-allowlist once and for all.
mk_pinned_state() {   # $1 = "stale" (allowlist newer) | "fresh" (pidfile newer)
  : > "$(gvproxy_pidfile)"; : > "$(proxy_allowlist)"
  sleep 1
  case "$1" in
    stale) touch "$(proxy_allowlist)" ;;
    fresh) touch "$(gvproxy_pidfile)" ;;
  esac
}

mk_pinned_state stale
: > "$LOG"; : > "$VMLOG"
mout="$( cmd_up_macos 2>&1 )"; mrc=$?
eq "0" "$mrc" "up --macos: returns 0 on a running VM (no fingerprint ⇒ no drift signal to refuse on)"
if logged gate; then ok "up --macos: runs the project-conf approval gate"
else fail "up --macos: never ran check_project_conf_approved" "log: $(cat "$LOG")"; fi
if logged "start_proxy 127.0.0.1"; then ok "up --macos: starts/refreshes the proxy on 127.0.0.1 (gvproxy's SOCKS upstream)"
else fail "up --macos: start_proxy was not called with 127.0.0.1" "log: $(cat "$LOG")"; fi
has "$mout" "gvproxy snapshots its DNS allowlist ONCE" "up --macos: warns that gvproxy's DNS allowlist is pinned to boot"
if [[ -s "$VMLOG" ]]; then fail "up --macos: touched the augur-vm CLI on the already-running path" "$(cat "$VMLOG")"
else ok "up --macos: never invokes the augur-vm CLI at all (no clone, no set, no run)"; fi
if grep -q '^run' "$VMLOG" 2>/dev/null; then fail "up --macos: BOOTED a VM on the already-running path" "$(cat "$VMLOG")"
else ok "up --macos: 'run' is never invoked (nothing is booted)"; fi
if logged start_gvproxy; then fail "up --macos: restarted gvproxy under a live VM" "its unixgram socket IS the VM's NIC"
else ok "up --macos: does NOT restart gvproxy under a live VM"; fi

# Negative control on the warning: with gvproxy's snapshot NEWER than the policy there is nothing
# stale, so `up --macos` must stay quiet about it. Without this, an unconditional warn would pass.
mk_pinned_state fresh
: > "$LOG"
mout2="$( cmd_up_macos 2>&1 )"
hasnt "$mout2" "gvproxy snapshots its DNS allowlist ONCE" "up --macos: silent when gvproxy's snapshot is newer than the policy"
if logged gate; then ok "up --macos: still reconciles the policy when nothing is pinned-stale"
else fail "up --macos: skipped the gate on the non-stale path"; fi

section "Tier 1 — warn_if_macos_egress_pinned behaviour (host-side only, no new state file)"

# Exercised directly: the signal is "the merged allowlist is newer than the gvproxy pidfile", which
# is exact ONLY because write_merged_allowlist is content-idempotent (see 01_egress_allowlist_unit).
pinned_run() { warn_if_macos_egress_pinned testvm 2>&1; }

rm -f "$(gvproxy_pidfile)" "$(proxy_allowlist)"
eq "" "$(pinned_run)" "no gvproxy pidfile → silent (nothing snapshotted a policy; never guess)"

: > "$(proxy_allowlist)"
eq "" "$(pinned_run)" "an allowlist with no gvproxy pidfile → still silent"

mk_pinned_state fresh
eq "" "$(pinned_run)" "gvproxy's snapshot newer than the policy → silent"

mk_pinned_state stale
pin_out="$(pinned_run)"
has "$pin_out" "changed since VM 'testvm' booted"          "policy newer than gvproxy's snapshot → warns, naming the VM"
has "$pin_out" "gvproxy snapshots its DNS allowlist ONCE"   "…names gvproxy's read-once DNS allowlist (thing 1)"
has "$pin_out" "VM sizing (cpu/memory)"                     "…names VM sizing (thing 2)"
has "$pin_out" ".augur-env credentials"                     "…names the ~/.augur-env credentials (thing 3)"
has "$pin_out" "augur down --macos && augur up --macos"     "…and states the same remedy as its profile-stale peer"
has "$pin_out" "newly APPROVED domain stays unresolvable"   "…is honest that only WIDENING is blocked (DNS is the first gate)"

section "Tier 1 — macOS: a credential that cannot be injected fails BEFORE anything is created"

# Same asymmetry, other half. Container mode resolves and validates every credential before
# `container run`; macOS mode used to do it only at the ~/.augur-env writer — after `augur-vm
# clone`, `augur-vm set`, `augur-vm run` and the SSH wait — and that `exit 1` tore NOTHING down
# (unlike the SSH-timeout path right above it, which stops the VM, gvproxy and the proxy). So the
# operator fixed the value, re-ran `up --macos`, and landed on the already-running branch tested
# above, which by design cannot re-push ~/.augur-env: a live guest with no credentials at all,
# remedy `down --macos && up --macos`.
#
# The load-bearing assertion is therefore NOT the exit code — it is that the augur-vm CLI was never
# invoked. Nothing was cloned, nothing was resized, nothing was booted.
macos_vm_running() { return 1; }                  # not running → take the bring-up path
_clone_exists=1                                   # 0 = a stopped clone exists, 1 = it must be cloned
macos_vm_exists() { [[ "$1" == "$MACOS_BASE_VM" ]] && return 0; return $_clone_exists; }
HOME="$TMPD/home"; mkdir -p "$HOME"               # host credential FILES live here; keep off the real ~
AUGUR_DIR="$TMPD/augur"                           # known_hosts / vm-state writes stay in the sandbox
gh() { return 1; }                                # no host gh token unless a case installs one
unset ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN   # this runner may well have one exported

up_macos_run() {   # sets $mout / $mrc; truncates both logs first
  : > "$LOG"; : > "$VMLOG"
  mout="$( cmd_up_macos 2>&1 )"; mrc=$?
}
nothing_created() {   # nothing_created <case label> — the whole point, asserted identically per case
  if [[ -s "$VMLOG" ]]; then fail "$1: the augur-vm CLI WAS invoked" "$(cat "$VMLOG")"
  else ok "$1: the augur-vm CLI is never invoked (no clone, no set, no run)"; fi
}

# (a) env-supplied value carrying the one character that escapes `export VAR='<value>'`.
ANTHROPIC_API_KEY="sk-ant-bad'quote"
up_macos_run
unset ANTHROPIC_API_KEY
if [[ "$mrc" -ne 0 ]]; then ok "bad ANTHROPIC_API_KEY: up --macos exits non-zero"
else fail "bad ANTHROPIC_API_KEY: up --macos exited 0" "an uninjectable value must abort the bring-up"; fi
has "$mout" "Refusing to inject ANTHROPIC_API_KEY" "bad ANTHROPIC_API_KEY: the refusal still names the variable"
nothing_created "bad ANTHROPIC_API_KEY"
# Control for the two assertions above: prove the run really entered the bring-up path and refused
# THERE, rather than dying earlier for some unrelated reason (which would make them vacuous).
if logged gate; then ok "bad ANTHROPIC_API_KEY: the run got past the approval gate before refusing"
else fail "bad ANTHROPIC_API_KEY: never reached the approval gate" "it failed before the credential check; log: $(cat "$LOG")"; fi
hasnt "$mout" "VM SSH did not become available" "bad ANTHROPIC_API_KEY: no VM was booted and waited for"

# (b) the _fresh_clone interaction: an EXISTING stopped clone must fail before `augur-vm set`, not
# only before `clone`. Value comes from the host FILE this time, and trips the control-byte branch.
_clone_exists=0
printf 'sk-ant-bad\tcontrol\n' > "$HOME/.claude_code_oauth_token"
up_macos_run
rm -f "$HOME/.claude_code_oauth_token"
if [[ "$mrc" -ne 0 ]]; then ok "bad ~/.claude_code_oauth_token: up --macos exits non-zero (stopped clone already exists)"
else fail "bad ~/.claude_code_oauth_token: up --macos exited 0" "an existing clone must fail before set/run too"; fi
has "$mout" "Refusing to inject CLAUDE_CODE_OAUTH_TOKEN" "bad ~/.claude_code_oauth_token: names the variable (resolved from the host FILE)"
nothing_created "bad ~/.claude_code_oauth_token (existing stopped clone)"

# (c) the gh token is on the same early gate — it is interpolated into the same sourced file.
gh() { printf "ghp_bad'quote\n"; }
up_macos_run
gh() { return 1; }
if [[ "$mrc" -ne 0 ]]; then ok "bad gh token: up --macos exits non-zero"
else fail "bad gh token: up --macos exited 0" "GH_TOKEN lands in the same ~/.augur-env"; fi
has "$mout" "Refusing to inject GH_TOKEN" "bad gh token: the refusal names GH_TOKEN"
nothing_created "bad gh token"

# (d) POSITIVE CONTROL. With injectable credentials the check must let bring-up through — otherwise
# every assertion above would also pass with the whole thing refusing unconditionally. `mrc` is
# non-zero here on purpose: wait_for_macos_ssh is stubbed to fail, which is exactly what proves the
# run got all the way to a booted VM before stopping.
_clone_exists=1
ANTHROPIC_API_KEY="sk-ant-valid_test-0123456789"
gh() { printf 'ghp_validtoken0123456789\n'; }
up_macos_run
unset ANTHROPIC_API_KEY
gh() { return 1; }
hasnt "$mout" "Refusing to inject" "valid credentials: the check refuses nothing"
if grep -q '^clone ' "$VMLOG"; then ok "valid credentials: bring-up proceeds past the check to 'augur-vm clone'"
else fail "valid credentials: the clone was never reached" "vm log: $(cat "$VMLOG")"; fi
if grep -q '^set ' "$VMLOG"; then ok "valid credentials: sizing is applied ('augur-vm set' is reached)"
else fail "valid credentials: 'augur-vm set' was never reached" "vm log: $(cat "$VMLOG")"; fi
has "$mout" "VM SSH did not become available" "valid credentials: the VM is booted, and only the stubbed SSH wait stops the run"

section "Tier 1 — source guards: the reconcile is wired where behaviour cannot see it"

up_body="$(awk '/^cmd_up\(\)/{f=1} f{print} f&&/^}/{exit}' "$AUGUR")"
up_macos_body="$(awk '/^cmd_up_macos\(\)/{f=1} f{print} f&&/^}/{exit}' "$AUGUR")"
claude_macos_body="$(awk '/^cmd_claude_macos\(\)/{f=1} f{print} f&&/^}/{exit}' "$AUGUR")"
shell_macos_body="$(awk '/^cmd_shell_macos\(\)/{f=1} f{print} f&&/^}/{exit}' "$AUGUR")"
pinned_fn="$(awk '/^warn_if_macos_egress_pinned\(\)/{f=1} f{print} f&&/^}/{exit}' "$AUGUR")"

# `claude`/`shell` attach to a running VM WITHOUT going through cmd_up_macos, so they must warn
# themselves — exactly why warn_if_macos_profile_stale is called from those same two sites.
if printf '%s\n' "$claude_macos_body" | grep -q '^ *warn_if_macos_egress_pinned '
then ok "macOS claude warns about pinned egress state (it attaches without going through up)"
else fail "macOS claude does not call warn_if_macos_egress_pinned"; fi
if printf '%s\n' "$shell_macos_body" | grep -q '^ *warn_if_macos_egress_pinned '
then ok "macOS shell warns about pinned egress state"
else fail "macOS shell does not call warn_if_macos_egress_pinned"; fi
# Host-side only, like its peer: the thing being reported must not be asked to judge itself.
hasnt "$pinned_fn" 'ssh_macos'   "the pinned-state check never reads the guest"
hasnt "$pinned_fn" '$VM_CLI'     "the pinned-state check never asks the VM backend"
has   "$pinned_fn" 'gvproxy_pidfile' "the pinned-state check keys off the gvproxy pidfile (no new state file)"
# The container half refuses; the macOS half must NOT (no fingerprint ⇒ no reliable drift signal).
has   "$up_body"       'exit 1'  "cmd_up can refuse on drift (it has container_fingerprint)"
if printf '%s\n' "$up_macos_body" | sed -n '/already running/,/^    fi$/p' | grep -q 'exit 1'
then fail "cmd_up_macos refuses on the already-running path" "macOS has no drift signal to refuse on"
else ok "cmd_up_macos returns 0 on the already-running path (no fingerprint, no boot self-test)"; fi

# The credential check's POSITION in the source, not just its effect: a future edit that moves it
# back below the boot must fail here too, not only behaviourally.
cred_fn="$(awk '/^validate_resolved_credentials\(\)/{f=1} f{print} f&&/^}/{exit}' "$AUGUR")"
v_at="$(printf  '%s\n' "$up_macos_body" | grep -n '^ *validate_resolved_credentials ' | head -n1 | cut -d: -f1)"
cl_at="$(printf '%s\n' "$up_macos_body" | grep -n '"\$VM_CLI" clone' | head -n1 | cut -d: -f1)"
st_at="$(printf '%s\n' "$up_macos_body" | grep -n '"\$VM_CLI" set'   | head -n1 | cut -d: -f1)"
rn_at="$(printf '%s\n' "$up_macos_body" | grep -n '"\$VM_CLI" run'   | head -n1 | cut -d: -f1)"
if [[ -n "$v_at" && -n "$cl_at" && -n "$st_at" && -n "$rn_at" \
      && "$v_at" -lt "$cl_at" && "$v_at" -lt "$st_at" && "$v_at" -lt "$rn_at" ]]
then ok "macOS up checks credentials BEFORE clone/set/run (check@$v_at < clone@$cl_at, set@$st_at, run@$rn_at)"
else fail "macOS up does not check credentials before clone/set/run" \
          "check@${v_at:-none} clone@${cl_at:-none} set@${st_at:-none} run@${rn_at:-none}"; fi
# Host-side only — which is exactly WHY it can run before the guest exists.
hasnt "$cred_fn" 'ssh_macos' "the credential check never reaches the guest"
hasnt "$cred_fn" '$VM_CLI'   "the credential check never asks the VM backend"
has   "$cred_fn" 'validate_secret_value' "the credential check reuses the shared validator (no second one to drift)"
has   "$cred_fn" 'agent_auth_specs'      "the credential check resolves the agent's declared specs"

finish
