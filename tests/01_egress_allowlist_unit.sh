#!/usr/bin/env bash
# Tier 0 — egress allowlist hardening (pure functions, runs anywhere).
# Invariant I7 (docs/security-reviews/INVARIANTS.md): a guest-writable ./.augur.conf
# cannot widen the egress policy — every project line is validated (conf_line_valid),
# only sanitized LDH patterns reach the MERGED allowlist, and that allowlist is written
# HOST-SIDE (under ~/.augur), never inside the project tree.
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/lib.sh"
AUGUR="$REPO/augur"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# Extract the egress-allowlist helpers BY NAME (no line numbers, no markers) and source
# them in isolation — augur's entry-point dispatch never runs. Same technique as
# 30_macos_vm.sh's `awk` function slicing.
helpers="$WORK/helpers.sh"
grep -E '^proxy_allowlist\(\) \{' "$AUGUR" > "$helpers"          # one-liner
for f in write_merged_allowlist conf_line_valid project_conf_domains project_conf_invalid_count; do
  awk -v n="$f" 'index($0, n"()")==1 {f=1} f{print} f&&/^}/{exit}' "$AUGUR" >> "$helpers"
  echo >> "$helpers"
done
workspace_slug() { echo testslug; }   # stub the only external call the helpers make
AUGUR_PROXY_DIR="$WORK/proxy"
AUGUR_BASELINE_CONF="$WORK/baseline.conf"
AUGUR_GLOBAL_CONF="$WORK/global.conf"
AUGUR_PROJECT_CONF="$WORK/project/.augur.conf"
mkdir -p "$WORK/project"
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

section "Tier 0 — merged allowlist is host-side and sanitized"
printf 'baseline.example.com\n' > "$AUGUR_BASELINE_CONF"
printf 'global.example.com\n'   > "$AUGUR_GLOBAL_CONF"
al="$(proxy_allowlist)"
has   "$al" "$AUGUR_PROXY_DIR" "allowlist path is under the host-side proxy dir (~/.augur)"
hasnt "$al" "$WORK/project"    "allowlist path is NOT inside the project tree"
out="$(write_merged_allowlist)"
eq "$al" "$out" "write_merged_allowlist writes to the host-side path"
merged="$(cat "$out")"
has   "$merged" "baseline.example.com" "baseline domain present"
has   "$merged" "global.example.com"   "global domain present"
has   "$merged" "good.example.com"     "sanitized project domain present"
hasnt "$merged" "bad;rm"               "guest junk never reaches the merged policy"
hasnt "$merged" "under_score"          "non-LDH guest line never reaches the merged policy"
hasnt "$merged" "evil .com"            "spaced guest line never reaches the merged policy"

finish
