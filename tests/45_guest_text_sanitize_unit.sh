#!/usr/bin/env bash
# Tier 0 — guest text never drives the operator's terminal.
# sanitize_guest_text() is what augur runs guest-returned text through before showing it (a
# failed guest `sudo` line, an ssh probe's stderr, VM log tails, resources.conf values), and
# info/warn/error print their message verbatim. Together they mean the only control bytes that
# reach the terminal are augur's own colour codes. Pure functions: no VM or container needed.
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/lib.sh"
AUGUR="$REPO/augur"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# Extract BY NAME, same technique as 01_egress_allowlist_unit.sh — augur's entry-point dispatch
# never runs. The colour variables and the one-line log helpers are pulled by their own lines.
helpers="$WORK/helpers.sh"
grep -E '^(RED|GREEN|YELLOW|CYAN|BOLD|RESET)=' "$AUGUR" >> "$helpers"
grep -E '^(info|success|warn|error)\(\) ' "$AUGUR" >> "$helpers"
for f in sanitize_guest_text sanitize_guest_lines clamp_resource_int clamp_container_memory_value; do
  awk -v n="$f" 'index($0, n"()")==1 {f=1} f{print} f&&/^}/{exit}' "$AUGUR" >> "$helpers"
  echo >> "$helpers"
done
# shellcheck disable=SC1090
source "$helpers"

# has_ctrl STRING — true iff STRING holds any byte in 0x01-0x1f or 0x7f.
has_ctrl() {
  local all kept
  all="$(printf '%s' "$1" | LC_ALL=C wc -c | tr -d ' ')"
  kept="$(printf '%s' "$1" | LC_ALL=C tr -d '\001-\037\177' | LC_ALL=C wc -c | tr -d ' ')"
  [[ "$all" != "$kept" ]]
}

section "Tier 0 — sanitize_guest_text (C0 controls + DEL become visible \\xNN)"

hostile=$'\e[2J\e[H[augur] fake ok\r'"$(printf '\t')"$'tab\x7fdel \\e[2J literal 日本語 my file.txt'
out="$(sanitize_guest_text "$hostile")"
if has_ctrl "$out"; then fail "no control byte survives" "$(printf '%s' "$out" | od -c | head -5)"
else ok "no control byte survives"; fi
has "$out" '\x1b[2J\x1b[H' "a real ESC sequence is shown as \\x1b, not executed"
has "$out" '\x0d' "a carriage return (overwrite-the-line trick) is shown as \\x0d"
has "$out" '\x09tab' "a tab is shown as \\x09"
has "$out" '\x7fdel' "DEL is shown as \\x7f"
has "$out" ' \\e[2J literal' "a guest-written literal backslash is doubled (stays distinct from a real ESC)"
has "$out" '日本語 my file.txt' "UTF-8 and spaces pass through unchanged"

# Every one of 0x01-0x1f and 0x7f, not just the handful above.
all=""
for i in $(seq 1 31) 127; do printf -v h '%02x' "$i"; printf -v c "\\x${h}"; all+="${c}"; done
out_all="$(sanitize_guest_text "$all")"
exp_all=""
for i in $(seq 1 31) 127; do printf -v h '%02x' "$i"; exp_all+="\\x${h}"; done
eq "$exp_all" "$out_all" "every C0 control byte and DEL maps to its \\xNN form"
eq "" "$(sanitize_guest_text "")" "empty input gives empty output"
eq 'a\\x1bb' "$(sanitize_guest_text 'a\x1bb')" "a guest-written literal \\x1b is not confused with a real ESC"

section "Tier 0 — sanitize_guest_lines (per line, newline-terminated)"
lines="$(printf 'one\033[31m\ntwo\r\nthree' | sanitize_guest_lines)"
eq $'one\\x1b[31m\ntwo\\x0d\nthree' "$lines" "each line is sanitised; a last line without a newline is kept"

section "Tier 0 — info/warn/error print the message verbatim"
w="$(warn 'a\nb' 2>&1)"
eq 1 "$(printf '%s\n' "$w" | wc -l | tr -d ' ')" "warn 'a\\nb' prints ONE line"
has "$w" 'a\nb' "…with the backslash-n shown literally"
eq "${YELLOW}[augur]${RESET} a\\nb" "$w" "warn output is exactly the colour prefix plus the message"
e="$(error "  printf '%s\\n' '<token>'" 2>&1)"
has "$e" "printf '%s\\n' '<token>'" "a printf format shown to the operator keeps its backslash"

# A hostile guest line through error(): after removing augur's own prefix, no ESC remains.
e="$(error "  | $(sanitize_guest_text "$hostile")" 2>&1)"
body="${e#"${RED}[augur]${RESET}"}"
[[ "$body" != "$e" ]] && ok "error() output starts with augur's own colour prefix" \
  || fail "error() output starts with augur's own colour prefix" "$e"
if has_ctrl "$body"; then fail "no control byte reaches the terminal beyond augur's own prefix" "$(printf '%s' "$body" | od -c | head -5)"
else ok "no control byte reaches the terminal beyond augur's own prefix"; fi
case "$RED$RESET" in *$'\e'*) ok "the colour codes are real ESC bytes (no escape interpretation needed)" ;;
  *) fail "the colour codes are real ESC bytes (no escape interpretation needed)" ;; esac

section "Tier 0 — a hostile .augur/resources.conf value is shown sanitised"
# The workspace (and so .augur/resources.conf) is guest-writable; a rejected value is echoed back.
for fn in "clamp_resource_int" "clamp_container_memory_value"; do
  if [[ "$fn" == clamp_resource_int ]]; then msg="$(clamp_resource_int $'4\e]52;c;ZWNobyBoaQ==\a' 1 64 4 MACOS_CPU 2>&1 >/dev/null)"
  else msg="$(clamp_container_memory_value $'4g\e[2K' 2>&1 >/dev/null)"; fi
  body="${msg#"${YELLOW}[augur]${RESET}"}"
  if has_ctrl "$body"; then fail "$fn: the rejected value reaches the terminal sanitised" "$(printf '%s' "$body" | od -c | head -5)"
  else ok "$fn: the rejected value reaches the terminal sanitised"; fi
  has "$body" '\x1b' "$fn: the ESC is shown as \\x1b"
done

section "Tier 0 — the guest-text sites go through the sanitiser"
# grep -F (not `has` on the whole script) so a failure names the site without dumping augur.
eq 1 "$(grep -cF "guest's clock (\${drift}s off the host's): \$(sanitize_guest_text \"\${setout%%\$'\\n'*}\")\"" "$AUGUR")" \
  "sync_macos_guest_clock sanitises the failed sudo's first line"
eq 1 "$(grep -cF "host is '\${host_tz}'): \$(sanitize_guest_text \"\${setout%%\$'\\n'*}\")\"" "$AUGUR")" \
  "sync_macos_guest_timezone sanitises the failed sudo's first line"
eq 2 "$(grep -c 'true 2>&1 | head -n 6 | sanitize_guest_lines | while' "$AUGUR")" \
  "both ssh-probe diagnostics (up --macos, update --macos) sanitise ssh output"
eq 0 "$(grep -E 'while IFS= read -r _l; do error ' "$AUGUR" | grep -vc 'sanitize_guest_lines |')" \
  "every log tail / probe echoed through error() is sanitised"
eq 0 "$(grep -E '^(info|success|warn|error)\(\) ' "$AUGUR" | grep -c 'echo -e')" \
  "no log helper interprets escapes (echo -e)"

finish
