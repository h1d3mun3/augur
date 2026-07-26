#!/usr/bin/env bash
# Tier 1 — the boot self-test's SSH TRANSPORT precondition (runs anywhere; nothing is cloned,
# booted or really SSH'd).
#
# The defect, found by `make e2e` on 2026-07-26 and predicted in tests/37's header before that.
# `ssh_macos` does not RETURN when it cannot name a host for the VM — it exits the script:
#
#     host="$(macos_ssh_host "$vm")"; [[ -n "$host" ]] || { error "Cannot resolve SSH host…"; exit 1; }
#
# verify_macos_egress_locked's first probe called it as `if ! ssh_macos … &>/dev/null`, a SIMPLE
# COMMAND, so that exit terminated `augur up --macos` outright: rc=1, the `error` swallowed by the
# redirection, and — the part that matters — the fail-closed teardown at the bottom of the function
# JUMPED OVER. A self-test whose stated contract is "a detected leak must not leave a live VM with a
# live NIC behind" left exactly that. The `cannot run a command in the guest over SSH` branch existed
# for this situation and was unreachable in it.
#
# Reachable state, not a hypothetical: VM RUNNING + gvproxy DOWN. `cmd_down_macos` stops gvproxy and
# the proxy at the top, so a stop that fails to kill the VM leaves it; macos_ssh_host then falls back
# to `augur-vm ip`, which a vfkit-networked guest has no DHCP lease to answer. The next `up --macos`
# takes the already-running reconcile branch and dies there. Observed three times in a row on a real
# host, byte-identical, with five lines of output and no error at all.
#
# Why tests/36 could not see it. That fixture replaces ssh_macos wholesale with a stub whose
# unreachable case is `return 255`. The stub RETURNS where the real function EXITS, so the entire
# class of "a helper terminates the script inside a suppressed context" was invisible to it. This
# file therefore drives the REAL ssh_macos and shadows the `ssh` BINARY with a function instead —
# the seam has to sit below the code under test, not above it.
#
# What this file pins:
#   • an unresolvable transport fails CLOSED *with* the teardown, and says which state it is in
#   • the underlying mechanism (ssh_macos exits rather than returns) — so the precheck stays
#     load-bearing, and so a future "just make it return 1" is a deliberate, tested change
#   • a resolvable transport still runs the probes: the precheck must not break the happy path
#   • the narrow race (host resolves, SSH then fails) still lands on the older, less specific branch
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/lib.sh"
AUGUR="$REPO/augur"

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

# BOOT-PROOFING (tests/30, 34, 35, 36 all do this): point AUGUR_VM_BIN at a path that cannot exist
# BEFORE sourcing, so a lost override degrades to "command not found", never a booted VM.
export AUGUR_VM_BIN="$TMPD/no-such-augur-vm"

AUGUR_SOURCE_ONLY=1 source "$AUGUR"
set +e                                    # augur enables `set -e`; restore lib.sh assert-and-continue

# Sandbox every path this can write. The runner exports CLAUDE_CODE_OAUTH_TOKEN and has a real
# ~/.gitconfig; neither may be reachable from here.
HOME="$TMPD/home"; mkdir -p "$HOME"
AUGUR_DIR="$TMPD/augur"
AUGUR_PROXY_DIR="$TMPD/proxy"; mkdir -p "$AUGUR_PROXY_DIR"
unset ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN
# A key file that does NOT exist, so ssh_macos takes its no-key branch and the recorded argv is the
# same on every developer's machine (the real default is ~/.augur/vm_key, which may or may not exist).
MACOS_SSH_KEY="$TMPD/no-such-key"

LOG="$TMPD/calls"       # teardown recorder, one anchor line per call
SSHLOG="$TMPD/sshlog"   # every remote command the REAL ssh_macos handed to the `ssh` binary
: > "$LOG"; : > "$SSHLOG"

vm_cli_rec() { printf '%s\n' "$*" >> "$LOG"; [[ "$1" == ip ]] && printf '%s' "$G_VMIP"; return 0; }
VM_CLI=vm_cli_rec
stop_gvproxy() { echo "stop_gvproxy" >> "$LOG"; }
stop_proxy()   { echo "stop_proxy"   >> "$LOG"; }
logged() { grep -qx "$1" "$LOG" 2>/dev/null; }
teardown_ran() { logged "stop $1" && logged stop_gvproxy && logged stop_proxy; }

# ── The transport knobs. G_GVPROXY=0 + empty G_VMIP is the observed defect state (VM up, gvproxy
#    gone, no DHCP lease to fall back to). G_SSH_OK=0 is the narrow race after resolution. ────────
G_GVPROXY=1 G_VMIP="" G_SSH_OK=1
macos_project_vm() { echo testvm; }                     # so macos_via_gvproxy's name test matches
gvproxy_running()  { [[ "$G_GVPROXY" == 1 ]]; }

# Shadow the ssh BINARY, below the real ssh_macos. The remote command is ssh's last argument.
ssh() {
    local cmd="${@: -1}"
    printf '%s\n' "$cmd" >> "$SSHLOG"
    [[ "$G_SSH_OK" == 1 ]] || return 255                # what ssh exits when it cannot connect
    case "$cmd" in
        *" true")                       return 0 ;;
        *"dscacheutil"*"'example.com'"*) return 0 ;;    # non-allowlisted: exits 0, prints no address
        *"dscacheutil"*"'${_SELFTEST_HOST}'"*)
            printf 'name: %s\nip_address: 140.82.121.6\n' "$_SELFTEST_HOST"; return 0 ;;
        *"dig "*)                       return 0 ;;     # timed out: no dotted quad on stdout
        *"ping "*)                      return 2 ;;     # 100% loss
        *"%{http_code}"*)               printf '200'; return 0 ;;
        *"curl "*)                      return 28 ;;    # IP literal: severed, burns its deadline
        *) echo "UNEXPECTED PROBE: $cmd" >&2; return 1 ;;
    esac
}

# Run the REAL function the way cmd_up_macos runs it: under `set -e`.
selftest() {   # sets $out / $rc; truncates both logs first
    : > "$LOG"; : > "$SSHLOG"
    out="$( set -e; verify_macos_egress_locked testvm 2>&1 )"; rc=$?
}
probed() { grep -qF "$1" "$SSHLOG"; }

section "Tier 1 — fixture controls (a fixture that cannot fail is not a test)"

: > "$LOG"; "$VM_CLI" stop self-check >/dev/null 2>&1; stop_gvproxy; stop_proxy
if teardown_ran self-check; then ok "teardown recorders capture stop/stop_gvproxy/stop_proxy"
else fail "teardown recorders capture stop/stop_gvproxy/stop_proxy"; fi

G_GVPROXY=1
if [[ "$(macos_ssh_host testvm)" == "127.0.0.1" ]]; then ok "gvproxy up  → macos_ssh_host resolves to the forward"
else fail "gvproxy up → macos_ssh_host resolves to the forward" "got '$(macos_ssh_host testvm)'"; fi

G_GVPROXY=0 G_VMIP=""
if [[ -z "$(macos_ssh_host testvm)" ]]; then ok "gvproxy down + no lease → macos_ssh_host resolves to NOTHING (the defect state)"
else fail "gvproxy down + no lease → macos_ssh_host resolves to NOTHING" "got '$(macos_ssh_host testvm)'"; fi

section "The mechanism the precheck compensates for: ssh_macos EXITS, it does not return"

# If ssh_macos merely returned non-zero, `echo REACHED-NEXT-LINE` would run. It does not — and this
# is why the fix lives in verify_macos_egress_locked rather than in ssh_macos, whose exit semantics
# 47 call sites depend on. Should someone convert it to `return 1`, this assertion fails loudly and
# the precheck can then be revisited on purpose.
G_GVPROXY=0 G_VMIP=""
mech="$( set -e; ssh_macos testvm true &>/dev/null; echo REACHED-NEXT-LINE )"
if [[ "$mech" != *REACHED-NEXT-LINE* ]]; then ok "ssh_macos terminates the shell when no host resolves (does not return)"
else fail "ssh_macos terminates the shell when no host resolves" "it returned instead: '$mech'"; fi

# …and that its own diagnostic is what a `&>/dev/null` caller loses.
mech2="$( set -e; ssh_macos testvm true 2>&1 )"
if [[ "$mech2" == *"Cannot resolve SSH host"* ]]; then ok "ssh_macos's own message exists (and is what the probe's redirection discarded)"
else fail "ssh_macos's own message exists" "got '$mech2'"; fi

section "Unresolvable transport — fails closed WITH the teardown, and names the state"

G_GVPROXY=0 G_VMIP="" G_SSH_OK=1
selftest
if [[ $rc -ne 0 ]]; then ok "unresolvable transport ends the self-test non-zero"
else fail "unresolvable transport ends the self-test non-zero" "rc=$rc"; fi

# THE load-bearing assertion. Before the fix this was the whole defect: rc was already 1 (ssh_macos's
# own exit), so an exit-status assertion alone stays green with the fix reverted. Only the recorded
# teardown distinguishes them.
if teardown_ran testvm; then ok "the VM, gvproxy and the proxy are all torn down (no live NIC left behind)"
else fail "the VM, gvproxy and the proxy are all torn down" "recorded: $(tr '\n' ' ' < "$LOG")"; fi

if [[ "$out" == *"no SSH transport"* ]]; then ok "it says the transport is missing, rather than exiting silently"
else fail "it says the transport is missing" "got: $out"; fi
if [[ "$out" == *"gvproxy cannot be restarted under a live VM"* ]]; then ok "it explains why, so the operator is not left guessing"
else fail "it explains why" "got: $out"; fi
if [[ "$out" == *"augur up --macos"* ]]; then ok "it gives the remedy"
else fail "it gives the remedy" "got: $out"; fi
if [[ "$out" == *"Egress self-test FAILED"* ]]; then ok "it reports through the normal fail-closed verdict"
else fail "it reports through the normal fail-closed verdict" "got: $out"; fi

# No probe may be attempted once the transport is known to be missing: each one would re-enter
# ssh_macos and exit the script from inside a suppressed context all over again.
if [[ ! -s "$SSHLOG" ]]; then ok "no probe is attempted without a transport"
else fail "no probe is attempted without a transport" "issued: $(tr '\n' ' ' < "$SSHLOG")"; fi

section "Resolvable transport — the precheck must not break the happy path"

G_GVPROXY=1 G_VMIP="" G_SSH_OK=1
selftest
if [[ $rc -eq 0 ]]; then ok "a locked, reachable guest still passes"
else fail "a locked, reachable guest still passes" "rc=$rc out: $out"; fi
if [[ "$out" == *"Egress self-test passed"* ]]; then ok "it prints the passing verdict"
else fail "it prints the passing verdict" "got: $out"; fi
if ! teardown_ran testvm; then ok "nothing is torn down on the happy path"
else fail "nothing is torn down on the happy path" "recorded: $(tr '\n' ' ' < "$LOG")"; fi
# The probe SET still runs — the precheck is an addition, not a replacement.
for _shape in " true" "https://1.1.1.1" "dscacheutil -q host -a name 'example.com'" \
              "dig +time=2 +tries=1 +short @1.1.1.1" "ping -c 1 -t 2 1.1.1.1" \
              "dscacheutil -q host -a name '${_SELFTEST_HOST}'" "%{http_code}"; do
  if probed "$_shape"; then ok "probe still issued: ${_shape}"
  else fail "probe still issued: ${_shape}" "issued: $(tr '\n' ' ' < "$SSHLOG")"; fi
done

section "Host resolves but SSH then fails — the older branch, unchanged"

G_GVPROXY=1 G_VMIP="" G_SSH_OK=0
selftest
if [[ $rc -ne 0 ]]; then ok "an unreachable-but-resolvable guest ends the self-test non-zero"
else fail "an unreachable-but-resolvable guest ends the self-test non-zero" "rc=$rc"; fi
if teardown_ran testvm; then ok "…and tears down too"
else fail "…and tears down too" "recorded: $(tr '\n' ' ' < "$LOG")"; fi
if [[ "$out" == *"cannot run a command in the guest over SSH"* ]]; then ok "…with the pre-existing message (now actually reachable)"
else fail "…with the pre-existing message" "got: $out"; fi
# Exactly one probe: the transport check. The negative probes must not run against a dead transport,
# since every one of them "passes" when nothing answers.
if [[ "$(wc -l < "$SSHLOG" | tr -d ' ')" == "1" ]]; then ok "it stops after the failed transport probe"
else fail "it stops after the failed transport probe" "issued: $(tr '\n' ' ' < "$SSHLOG")"; fi

finish
