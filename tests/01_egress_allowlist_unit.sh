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

# Stubs for the few externals the extracted helpers reference.
workspace_slug()      { echo testslug; }
workspace_path_hash() { echo testpathhash; }
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

finish
