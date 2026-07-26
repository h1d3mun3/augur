#!/usr/bin/env bash
# Tier 0 — egress allowlist hardening (pure functions, runs anywhere).
# Invariant I7 (docs/security-reviews/INVARIANTS.md): a guest-writable ./.augur/allowlist.conf
# cannot widen the egress policy — every project line is validated (conf_line_valid),
# only sanitized LDH patterns reach the MERGED allowlist, that allowlist is written
# HOST-SIDE (under ~/.augur), never inside the project tree, AND the merge honors only the
# domains SNAPSHOTTED at approval time (never a fresh read of the live mounted conf), so a
# post-approval mutation cannot be honored (TOCTOU).
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/lib.sh"
AUGUR="$REPO/augur"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# Extract the egress-allowlist helpers BY NAME (no line numbers, no markers) and source
# them in isolation — augur's entry-point dispatch never runs. Same technique as
# 30_macos_vm.sh's `awk` function slicing.
helpers="$WORK/helpers.sh"
grep -E '^proxy_allowlist\(\) \{' "$AUGUR" > "$helpers"          # one-liner
for f in write_merged_allowlist conf_line_valid project_conf_domains project_conf_invalid_count \
         write_project_snapshot project_conf_hash project_conf_hash_file check_project_conf_approved; do
  awk -v n="$f" 'index($0, n"()")==1 {f=1} f{print} f&&/^}/{exit}' "$AUGUR" >> "$helpers"
  echo >> "$helpers"
done

# Stubs for the few externals the extracted helpers reference. The path hash reads a VARIABLE
# (not a constant) so a section below can switch projects: two workspaces that share a basename
# share workspace_slug and are told apart ONLY by workspace_path_hash.
TEST_SLUG="testslug"
TEST_PATH_HASH="testpathhash"
workspace_slug()      { echo "$TEST_SLUG"; }
workspace_path_hash() { echo "$TEST_PATH_HASH"; }
warn()    { :; }
info()    { :; }
success() { :; }
error()   { echo "ERROR: $*" >&2; }
BOLD=""; YELLOW=""; RESET=""; CYAN=""; GREEN=""; RED=""

AUGUR_DIR="$WORK/augur-home"
AUGUR_PROXY_DIR="$WORK/proxy"
AUGUR_BASELINE_CONF="$WORK/baseline.conf"
AUGUR_GLOBAL_CONF="$WORK/global.conf"
AUGUR_PROJECT_CONF="$WORK/project/.augur/allowlist.conf"
mkdir -p "$WORK/project/.augur"
# shellcheck disable=SC1090
source "$helpers"

section "Tier 0 — conf_line_valid grammar (the sanitization chokepoint)"
for good in "example.com" "*.example.com" ".example.com" "api.github.com" "a-b.co.jp"; do
  if conf_line_valid "$good"; then ok "accepts $good"; else fail "accepts $good" "rejected a valid pattern"; fi
done
for bad in "evil .com" "bad;rm" "*" "*.*.com" "*evil.com" "under_score.com" ""; do
  if conf_line_valid "$bad"; then fail "rejects [$bad]" "accepted an invalid pattern"; else ok "rejects [$bad]"; fi
done
esc=$'evil\e[31m.com'   # A1: terminal-escape bytes must never survive into the policy / UI
if conf_line_valid "$esc"; then fail "rejects ESC-byte line" "accepted"; else ok "rejects ESC-byte line"; fi

section "Tier 0 — project_conf_domains sanitizes a guest-writable conf"
cat > "$AUGUR_PROJECT_CONF" <<'CONF'
# a comment line
good.example.com
  *.api.example.com
.apex.example.com
evil .com
bad;rm -rf /
under_score.com
*
CONF
domains="$(project_conf_domains)"
has   "$domains" "good.example.com"  "keeps a valid apex"
has   "$domains" "*.api.example.com" "keeps a valid wildcard (surrounding whitespace trimmed)"
has   "$domains" ".apex.example.com" "keeps a valid apex+sub"
hasnt "$domains" "evil .com"         "drops a line with a space"
hasnt "$domains" "bad;rm"            "drops a line with shell metacharacters"
hasnt "$domains" "under_score"       "drops a non-LDH line"
eq "4" "$(project_conf_invalid_count)" "invalid-line count is surfaced (for the approval red flag)"

section "Tier 0 — merged allowlist is host-side, and honors only the APPROVED snapshot"
printf 'baseline.example.com\n' > "$AUGUR_BASELINE_CONF"
printf 'global.example.com\n'   > "$AUGUR_GLOBAL_CONF"
al="$(proxy_allowlist)"
has   "$al" "$AUGUR_PROXY_DIR" "allowlist path is under the host-side proxy dir (~/.augur)"
hasnt "$al" "$WORK/project"    "allowlist path is NOT inside the project tree"

# Before approval there is no snapshot → the project block is omitted (fail closed).
merged="$(cat "$(write_merged_allowlist 2>/dev/null)")"
hasnt "$merged" "good.example.com" "an UNAPPROVED project conf is not honored (no snapshot → fail closed)"

# Approve the current conf (non-interactive) — writes the host-side hash + domain snapshot.
AUGUR_ACCEPT_PROJECT_CONF=1 check_project_conf_approved >/dev/null 2>&1
out="$(write_merged_allowlist)"
eq "$al" "$out" "write_merged_allowlist writes to the host-side path"
merged="$(cat "$out")"
has   "$merged" "baseline.example.com" "baseline domain present"
has   "$merged" "global.example.com"   "global domain present"
has   "$merged" "good.example.com"     "approved project domain present"
hasnt "$merged" "bad;rm"               "guest junk never reaches the merged policy"
hasnt "$merged" "under_score"          "non-LDH guest line never reaches the merged policy"
hasnt "$merged" "evil .com"            "spaced guest line never reaches the merged policy"

section "Tier 0 — TOCTOU: a post-approval mutation of the live conf is NOT honored (I7)"
# The guest appends a grammar-VALID domain AFTER approval. The merge must still emit only the
# approved snapshot, so a re-read of the mutated live file can never widen the honored policy.
printf 'evil-injected.example.com\n' >> "$AUGUR_PROJECT_CONF"
merged="$(cat "$(write_merged_allowlist)")"
hasnt "$merged" "evil-injected.example.com" "a domain added after approval is NOT honored (snapshot, not live re-read)"
has   "$merged" "good.example.com"          "the approved domains remain honored after the mutation"
# And the tamper is detectable on the next check: the hash changed, so a non-interactive run
# (no auto-accept) fails closed rather than silently re-approving. Run in a subshell so its
# `exit 1` can't abort the test.
if ( check_project_conf_approved ) </dev/null >/dev/null 2>&1; then
  fail "post-approval change detected" "check silently approved a changed conf non-interactively"
else
  ok "post-approval change is detected on the next check (non-interactive fails closed)"
fi

section "Tier 0 — a conf ending in an invalid line does not abort approval (set -e regression)"
# Regression: project_conf_domains used to inherit its trailing while-loop's status, so a conf
# whose LAST line is invalid made it return 1. The three `project_conf_domains > snap` call sites
# then aborted augur under `set -euo pipefail` (augur:7) — a guest-triggerable startup DoS plus an
# upgrade regression for repos whose conf legitimately ends in a dropped line. This harness runs
# WITHOUT `set -e`, so assert BOTH the function's status AND a real `set -e` approval run.
printf 'good.example.com\n*\n' > "$AUGUR_PROJECT_CONF"   # ends with a bare '*' (invalid but tolerated)
project_conf_domains "$AUGUR_PROJECT_CONF" >/dev/null; rc=$?
eq "0" "$rc" "project_conf_domains returns 0 when the conf's last line is invalid"
if ( set -e; AUGUR_ACCEPT_PROJECT_CONF=1 check_project_conf_approved ) >/dev/null 2>&1; then
  ok "approval of a conf ending in an invalid line completes under set -e (no mid-gate abort)"
else
  fail "approval under set -e" "check_project_conf_approved aborted (project_conf_domains returned non-zero)"
fi

section "Tier 0 — I7: an approval granted for one project never reaches another's enforcement point"
# The contamination this guards against. Projects A (~/work/myapp) and B (~/archive/myapp) share a
# BASENAME, so workspace_slug is identical for both and only workspace_path_hash separates them.
# With the merged allowlist keyed on the slug alone, both resolved to ONE file: B's `up` overwrote
# it with baseline+global+B, augur-proxy hot-reloaded it within ~2s (main.swift polls its mtime),
# and A's LIVE session lost every domain its operator had approved — while gaining B's, which that
# operator never saw. B's own TOFU gate passes here (it is keyed on the path hash and prompts "for
# this project"), so nothing in the approval path notices.
approve_and_merge() {   # $1 = path hash (the project), $2 = the domain that project approves
  TEST_PATH_HASH="$1"
  printf '%s\n' "$2" > "$AUGUR_PROJECT_CONF"
  AUGUR_ACCEPT_PROJECT_CONF=1 check_project_conf_approved >/dev/null 2>&1
  write_merged_allowlist
}
a_out="$(approve_and_merge hash-of-work-myapp   a-only.example.com)"
has "$(cat "$a_out")" "a-only.example.com" "A's merged allowlist honors A's approved domain"
b_out="$(approve_and_merge hash-of-archive-myapp b-only.example.com)"
has "$(cat "$b_out")" "b-only.example.com" "B's merged allowlist honors B's approved domain"

if [[ "$a_out" != "$b_out" ]]; then
  ok "the two same-basename projects write DIFFERENT merged-allowlist paths"
else
  fail "same-basename projects must not share a merged allowlist" "both = $a_out"
fi
# Both calls above ran with the SAME slug (this harness's stub is a constant), so the hash is
# provably the only thing that separated them. tests/32_proxy_per_mode.sh proves the same for the
# REAL workspace_slug driven from two real same-basename directories.
a_after="$(cat "$a_out")"
has   "$a_after" "a-only.example.com" "A's approved domain SURVIVES project B's up (no narrowing of a live policy)"
hasnt "$a_after" "b-only.example.com" "B's approved domain never appears in A's policy (no widening without A's approval)"
has   "$a_out" "$AUGUR_PROXY_DIR" "A's allowlist stays under the host-side proxy dir"
has   "$b_out" "$AUGUR_PROXY_DIR" "B's allowlist stays under the host-side proxy dir"

# Degenerate variant: a same-basename sibling with NO ./.augur/allowlist.conf at all.
# check_project_conf_approved returns 0 immediately and write_merged_allowlist omits the project
# block entirely, so a bare `augur up` in ANY same-basename directory used to strip a live
# session's project domains with zero interaction — no prompt, no output, nothing to notice.
rm -f "$AUGUR_PROJECT_CONF"
TEST_PATH_HASH="hash-of-tmp-myapp"
c_out="$(write_merged_allowlist)"
hasnt "$(cat "$c_out")" "a-only.example.com" "a conf-less sibling's own policy carries no other project's domains"
has   "$(cat "$a_out")" "a-only.example.com" "a bare up in a conf-less same-basename dir leaves A's live policy intact"

section "Tier 0 — write_merged_allowlist is CONTENT-idempotent (its mtime is a signal, not metadata)"

# The file used to carry a "generated at <date>" header rewritten on EVERY call, so its mtime bumped
# unconditionally. Two consumers read that mtime as a POLICY-CHANGED signal:
#   • augur-proxy hot-reloads on mtime change (main.swift polls every ~2s) — so every `up` forced a
#     pointless reload of a byte-identical policy;
#   • warn_if_macos_egress_pinned compares this file against the gvproxy pidfile to detect a DNS
#     allowlist gvproxy snapshotted BEFORE the policy changed — which would have cried wolf forever.
# Asserted with `-nt` against a reference file rather than by parsing timestamps: no `stat` portability
# (BSD `-f %m` vs GNU `-c %Y`) and no clock arithmetic. Same technique as warn_if_macos_profile_stale.
TEST_PATH_HASH="hash-idempotence"
printf 'idem.example.com\n' > "$AUGUR_PROJECT_CONF"
AUGUR_ACCEPT_PROJECT_CONF=1 check_project_conf_approved >/dev/null 2>&1
i_out="$(write_merged_allowlist)"                 # baseline write
has "$(cat "$i_out")" "idem.example.com" "baseline: the approved domain is in the merged policy"

# Stamp the reference NOW, then sleep — so every later write lands STRICTLY after it. (Stamping the
# reference after the sleep instead would put it in the same second as the next write, and `-nt`
# is false on equal timestamps: the assertion would pass even against an unconditional rewrite.)
touch "$WORK/ref"
sleep 1
i_out2="$(write_merged_allowlist)"                # identical inputs → must NOT touch the live file
eq "$i_out" "$i_out2" "the return value is unchanged across calls (start_proxy consumes it)"
if [[ "$i_out" -nt "$WORK/ref" ]]; then
  fail "a content-identical rewrite must NOT bump the mtime" "the generated-at header is back, or the compare ignores it"
else
  ok "a content-identical rewrite leaves the live file (and its mtime) untouched"
fi
has "$(cat "$i_out")" "idem.example.com" "…and the policy itself is intact after the no-op call"

# A REAL policy change must still land — and bump the mtime, or augur-proxy would never hot-reload it.
sleep 1
printf 'idem.example.com\nsecond.example.com\n' > "$AUGUR_PROJECT_CONF"
AUGUR_ACCEPT_PROJECT_CONF=1 check_project_conf_approved >/dev/null 2>&1
write_merged_allowlist >/dev/null
if [[ "$i_out" -nt "$WORK/ref" ]]; then ok "a CHANGED approved snapshot does bump the mtime (the proxy reloads)"
else fail "a changed policy did not bump the mtime" "augur-proxy would keep enforcing the old policy"; fi
has "$(cat "$i_out")" "second.example.com" "…and the newly approved domain is honored"

# A REVOCATION is the direction that matters most: it must land too, not just an addition.
sleep 1
printf 'idem.example.com\n' > "$AUGUR_PROJECT_CONF"
AUGUR_ACCEPT_PROJECT_CONF=1 check_project_conf_approved >/dev/null 2>&1
write_merged_allowlist >/dev/null
hasnt "$(cat "$i_out")" "second.example.com" "a revoked domain is removed from the merged policy"

# The same-directory temp file must never be left behind: the proxy dir is gvproxy's --dns-allowlist
# neighbourhood, and a leaked copy of the policy is host-side clutter with a stale mtime.
leftovers="$(find "$AUGUR_PROXY_DIR" -name '*.allowlist.??????' 2>/dev/null | wc -l | tr -d ' ')"
eq "0" "$leftovers" "no staging temp file is left in the proxy dir"

# The fail-closed missing-snapshot branch must survive the rewrite: no snapshot ⇒ the project block
# is OMITTED (a narrower policy) and an error is surfaced, never a fresh read of the live conf.
rm -f "$(project_conf_hash_file).domains"
nosnap_err="$(write_merged_allowlist 2>&1 >/dev/null)"
hasnt "$(cat "$i_out")" "idem.example.com" "no approved snapshot → the project block is omitted (fail closed)"
has   "$nosnap_err" "No approved snapshot" "…and the omission is reported, not silent"

finish
