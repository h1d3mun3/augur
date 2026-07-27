#!/usr/bin/env bash
# Tier 1 — macOS mode's git credential-helper wiring survives a host ~/.gitconfig that already
# defines credential.https://github.com.helper MORE THAN ONCE (runs anywhere; nothing is ever
# cloned, booted or SSH'd — the guest shell is a local `bash -c` against a sandboxed $HOME).
#
# The defect. cmd_up_macos scp's the HOST's ~/.gitconfig into the guest and then MUTATES that copy
# with `git config --global 'credential.https://github.com.helper' <helper>`, so HTTPS `git push`
# works off GH_TOKEN alone. But `credential.<url>.helper` is a multi-valued key by git's design, and
# `gh auth setup-git` writes TWO entries for github.com — an empty one to reset the helper chain,
# then its own. Against such a file the plain form refuses:
#
#     warning: credential.https://github.com.helper has multiple values
#     error: cannot overwrite multiple values with a single value
#     $? = 5
#
# Under augur's `set -e` that aborted `up` after the clone, the sizing, the boot and the SSH wait,
# tearing none of it down — the stranded-guest shape the pre-clone credential check (34) exists to
# prevent. Container mode is immune: it bind-mounts ~/.gitconfig read-only and injects the same
# helper through GIT_CONFIG_KEY_0/VALUE_0, never touching the file. The fix is --replace-all, which
# collapses the duplicates to the single value augur intends, plus `|| warn` for the residue
# --replace-all cannot fix (a ~/.gitconfig git cannot parse at all fails with 128).
#
# Two INDEPENDENT properties, one assertion each, because `|| warn` alone would hide the first:
#   1. the guest's config ends up holding EXACTLY augur's helper (without --replace-all git writes
#      nothing and the guest keeps the host's inert helpers — a silently unpushable guest);
#   2. `up` is not aborted when the write fails anyway (asserted under a real `set -e` subshell,
#      which is the only context in which the `|| warn` is observable at all).
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/lib.sh"
AUGUR="$REPO/augur"

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

# BOOT-PROOFING (the technique tests/30_macos_vm.sh and tests/34_up_reconcile.sh use): point
# AUGUR_VM_BIN at a path that cannot exist BEFORE sourcing, so the resolved $VM_CLI can never be a
# real augur-vm. Nothing here calls it; if a future edit does, the fallback is "command not found",
# never a cloned or booted VM. Set before the source because resolve_vm_cli runs at source time.
export AUGUR_VM_BIN="$TMPD/no-such-augur-vm"

# Pull the REAL functions out of augur without running its dispatch tail (AUGUR_SOURCE_ONLY seam),
# so this can never drift from the shipped code. The ssh_macos stub is installed AFTER the source on
# purpose: bash resolves function names at CALL time, so a later definition wins.
AUGUR_SOURCE_ONLY=1 source "$AUGUR"
set +e                                    # augur enables `set -e`; restore lib.sh assert-and-continue

# Keep every write inside the sandbox. This runner exports CLAUDE_CODE_OAUTH_TOKEN and has a real
# ~/.gitconfig of its own; neither may be reachable from here (constraint: never mutate the real
# global git config). GIT_CONFIG_NOSYSTEM keeps /etc/gitconfig out of the picture, and the
# GIT_CONFIG_* trio is unset so an ambient one cannot masquerade as a value augur wrote.
HOME="$TMPD/host-home"; mkdir -p "$HOME"
AUGUR_DIR="$TMPD/augur"
export GIT_CONFIG_NOSYSTEM=1
unset GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_CONFIG_COUNT

# The exact value cmd_up_macos means to install. Pinned as a literal on purpose: it is the contract
# with the guest (`$GH_TOKEN` stays a REFERENCE, expanded at push time, never the token itself), and
# a silent edit to the helper body should have to be re-affirmed here.
WANT='!f() { test "$1" = get && echo username=x-access-token && echo password=$GH_TOKEN; }; f'
KEY='credential.https://github.com.helper'

# Stand-in for the guest. ssh runs its argv joined-and-parsed by the remote shell, so `bash -c` with
# $HOME redirected at a throwaway "guest home" is a faithful stand-in — and it means the assertions
# below are made against REAL `git config` behaviour, not a model of it.
GUEST_HOME=""
SSHLOG="$TMPD/sshlog"
: > "$SSHLOG"
ssh_macos() {
    local vm="$1"; shift
    printf '%s\n' "$vm" >> "$SSHLOG"
    HOME="$GUEST_HOME" XDG_CONFIG_HOME="$GUEST_HOME/.config" bash -c "$*"
}

# mk_guest <name> <heredoc-on-stdin> — a fresh guest home holding the scp'd ~/.gitconfig
mk_guest() {
    GUEST_HOME="$TMPD/guest-$1"
    rm -rf "$GUEST_HOME"; mkdir -p "$GUEST_HOME"
    cat > "$GUEST_HOME/.gitconfig"
    cp "$GUEST_HOME/.gitconfig" "$TMPD/guest-$1.orig"
}
guest_values() {   # every value the guest's global config holds for KEY, newline-joined
    HOME="$GUEST_HOME" XDG_CONFIG_HOME="$GUEST_HOME/.config" \
        git config --global --get-all "$KEY" 2>/dev/null
}
# Run the REAL function the way cmd_up_macos runs it: inside `set -e`. Without that the `|| warn`
# is unobservable (a bare failing ssh_macos would just return non-zero and be ignored), and the
# abort this PR prevents is precisely a `set -e` abort.
wire() {   # wire <token> — sets $out / $rc
    : > "$SSHLOG"
    out="$( set -e; ensure_macos_git_credential_helper testvm "$1" 2>&1 )"; rc=$?
}

section "Tier 1 — a DUPLICATED credential.helper (what \`gh auth setup-git\` leaves) must not break up"

# Byte-for-byte what `gh auth setup-git` writes: the chain-reset empty helper, then gh's own.
mk_guest dup <<'EOF'
[user]
	name = Test Operator
	email = op@example.com
[credential "https://github.com"]
	helper =
	helper = !/opt/homebrew/bin/gh auth git-credential
EOF
# Control for the fixture itself: prove the key really IS duplicated, or the whole section is
# vacuous — it would then be testing the ordinary single-value path under a misleading name.
if [[ "$(guest_values | wc -l | tr -d ' ')" == "2" ]]; then
  ok "fixture: the guest's copied ~/.gitconfig really does define the helper twice (control)"
else
  fail "fixture: the guest ~/.gitconfig is not duplicated" "values: [$(guest_values)]"
fi

wire "ghp_hosttoken0123456789"
# THE assertion. Only --replace-all can produce this: a plain `git config` exits 5 and writes
# NOTHING, leaving the two host values in place. Anchored on the resulting config, not on the exit
# code (the `|| warn` keeps that at 0 either way) and not on any string a failing run also prints.
eq "$WANT" "$(guest_values)" "duplicated helper: the guest's config ends up holding EXACTLY augur's helper, once"
# …and stated the other way round, so a fix that merely APPENDED augur's value would fail too.
if [[ "$(guest_values | wc -l | tr -d ' ')" == "1" ]]; then
  ok "duplicated helper: the duplicates are collapsed to a single value (not appended to)"
else
  fail "duplicated helper: the key still has multiple values" "values: [$(guest_values)]"
fi
# The host's helpers are gone — which is the intended lossy collapse, and is what makes the guest's
# git use augur's GH_TOKEN helper rather than falling through to a host path that does not exist here.
hasnt "$(guest_values)" "gh auth git-credential" "duplicated helper: the host's own gh helper does not survive into the guest"
eq "0" "$rc" "duplicated helper: the wiring returns 0, so \`up\` continues past it"
hasnt "$out" "Could not configure git's credential helper" "duplicated helper: no warning — the write genuinely succeeded"
if [[ "$(wc -l < "$SSHLOG" | tr -d ' ')" == "1" ]]; then
  ok "duplicated helper: exactly one guest round-trip (control: the stub was really exercised)"
else
  fail "duplicated helper: unexpected number of guest calls" "sshlog: [$(cat "$SSHLOG")]"
fi

section "Tier 1 — single-value and absent-key controls (the fix must not regress the working path)"

# A host that set ONE helper is the path that worked before this change: the plain form overwrote it.
# --replace-all must land on the same result, or the fix would be a behaviour change for everyone.
mk_guest single <<'EOF'
[credential "https://github.com"]
	helper = osxkeychain
EOF
wire "ghp_hosttoken0123456789"
eq "$WANT" "$(guest_values)" "single-value helper: still overwritten with augur's helper (unchanged behaviour)"
eq "0" "$rc" "single-value helper: the wiring returns 0"

# No credential section at all — the majority case. --replace-all must ADD, not require a match.
mk_guest nokey <<'EOF'
[user]
	name = Test Operator
EOF
wire "ghp_hosttoken0123456789"
eq "$WANT" "$(guest_values)" "no existing helper: augur's helper is created"
eq "0" "$rc" "no existing helper: the wiring returns 0"

section "Tier 1 — no host gh token: the guest is never touched at all"

mk_guest notoken <<'EOF'
[credential "https://github.com"]
	helper = osxkeychain
EOF
wire ""
eq "0" "$rc" "no gh token: the wiring returns 0"
if [[ -s "$SSHLOG" ]]; then
  fail "no gh token: the guest WAS contacted" "sshlog: [$(cat "$SSHLOG")]"
else
  ok "no gh token: no guest round-trip at all (a helper referencing an unset \$GH_TOKEN is worse than none)"
fi
if cmp -s "$GUEST_HOME/.gitconfig" "$TMPD/guest-notoken.orig"; then
  ok "no gh token: the copied ~/.gitconfig is left byte-identical"
else
  fail "no gh token: the copied ~/.gitconfig was modified" "$(diff "$TMPD/guest-notoken.orig" "$GUEST_HOME/.gitconfig")"
fi

section "Tier 1 — a ~/.gitconfig git cannot parse warns instead of aborting the bring-up"

# --replace-all fixes the duplicate-key shape; it cannot fix arbitrary operator-authored syntax
# (`git config` exits 128 on a malformed section header). The copied file is arbitrary host input,
# and this wiring runs with the VM already cloned, sized, booted and SSH-reachable — so a hard
# failure here is the stranded-guest shape again, for a convenience feature. It must warn instead.
mk_guest malformed <<'EOF'
[credential "https://github.com"
	helper = osxkeychain
EOF
wire "ghp_hosttoken0123456789"
# Non-vacuous by construction: `wire` runs under `set -e`, so dropping the `|| warn` makes rc != 0.
eq "0" "$rc" "malformed ~/.gitconfig: the wiring still returns 0 under \`set -e\` (\`up\` is not aborted)"
has "$out" "Could not configure git's credential helper" "malformed ~/.gitconfig: warns, so the missing push credential is not silent"
has "$out" "git push"                                    "malformed ~/.gitconfig: the warning names the capability that is lost"

section "Tier 1 — source guards: ordering, and container mode's immunity"

up_macos_body="$(awk '/^cmd_up_macos\(\)/{f=1} f{print} f&&/^}/{exit}' "$AUGUR")"
up_body="$(awk       '/^cmd_up\(\)/{f=1}       f{print} f&&/^}/{exit}' "$AUGUR")"

# The scp REPLACES the file the helper is written into, so their order is load-bearing in a way no
# behavioural test of the function alone can see: swap them and the helper is silently discarded on
# every fresh `up`, with git push failing only later, in the guest, at the operator's first push.
scp_at="$(printf  '%s\n' "$up_macos_body" | grep -n 'scp_to_macos .* "\$HOME/\.gitconfig"' | head -n1 | cut -d: -f1)"
wire_at="$(printf '%s\n' "$up_macos_body" | grep -n '^ *ensure_macos_git_credential_helper '   | head -n1 | cut -d: -f1)"
if [[ -n "$scp_at" && -n "$wire_at" && "$scp_at" -lt "$wire_at" ]]; then
  ok "macOS up copies ~/.gitconfig BEFORE writing the helper into it (scp@$scp_at < helper@$wire_at)"
else
  fail "macOS up does not write the credential helper after the ~/.gitconfig copy" \
       "scp@${scp_at:-none} helper@${wire_at:-none}"
fi

# Container mode's immunity is the reason only one mode ever had this bug, and it is a property worth
# pinning: the mounted ~/.gitconfig is read-only there, so the helper MUST arrive via env vars.
hasnt "$up_body" 'git config --global' "container up never mutates the mounted ~/.gitconfig"
has   "$up_body" 'GIT_CONFIG_KEY_0=credential.https://github.com.helper' \
                                       "container up injects the same helper through GIT_CONFIG_* env vars instead"
has   "$up_body" '.gitconfig:/home/dev/.gitconfig:ro' "container up mounts ~/.gitconfig READ-ONLY"

finish
