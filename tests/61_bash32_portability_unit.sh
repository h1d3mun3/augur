#!/usr/bin/env bash
# Tier 0 — the test scripts and augur's bash code avoid two bash-4 assumptions that break silently
# under macOS's /bin/bash (3.2). No container, no VM; runs anywhere.
#
#   1. $BASHPID does not exist in bash 3.2: it expands to nothing there, so `kill -INT $BASHPID`
#      signals nothing and a Ctrl-C test exercises no Ctrl-C at all.
#   2. `$(sh -c 'echo $PPID')` without `exec`: bash 3.2 forks a subshell for the command
#      substitution and runs sh as its child, so sh reports that short-lived subshell, not the
#      shell that asked. `$(exec sh -c 'echo "$PPID"')` names the calling shell on every bash
#      (see kill_self in tests/56_macos_session_credentials.sh).
#
# Comment lines are not scanned. This file is not scanned either: it has to name both patterns.
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/lib.sh"
section "Tier 0 — no bash-4-only process identification in tests or augur"

files=()
for f in "$REPO/augur" "$REPO/completions/augur.bash" "$HERE"/*.sh; do
  [[ "$f" == "$HERE/${0##*/}" ]] && continue
  files+=("$f")
done

# hits REGEX: every non-comment line of the scanned files matching REGEX, as "file:line: text".
hits() {
  local f
  for f in "${files[@]}"; do
    grep -nE -- "$1" "$f" | grep -vE '^[0-9]+:[[:space:]]*#' | sed "s|^|${f#"$REPO"/}:|"
  done
  return 0
}

out="$(hits 'BASHPID')"
eq "" "$out" "no \$BASHPID (empty under bash 3.2)"

out="$(hits '\$\([[:space:]]*sh[[:space:]]+-c[^)]*PPID')"
eq "" "$out" "no \$(sh -c ... PPID) without exec (names a throwaway subshell under bash 3.2)"

# The guard itself must see what it is guarding against.
probe="$(mktemp)"; trap 'rm -f "$probe"' EXIT
printf '%s\n' 'kill -INT $BASHPID' 'kill -INT "$(sh -c '"'"'echo $PPID'"'"')"' '# kill $BASHPID in a comment' > "$probe"
files=("$probe")
eq "1" "$(hits 'BASHPID' | wc -l | tr -d ' ')" "the scan finds a \$BASHPID line and skips a comment"
eq "1" "$(hits '\$\([[:space:]]*sh[[:space:]]+-c[^)]*PPID' | wc -l | tr -d ' ')" "the scan finds a \$(sh -c ... PPID) line"
printf '%s\n' 'kill -INT "$(exec sh -c '"'"'echo "$PPID"'"'"')"' > "$probe"
eq "0" "$(hits '\$\([[:space:]]*sh[[:space:]]+-c[^)]*PPID' | wc -l | tr -d ' ')" "the scan accepts \$(exec sh -c ... PPID)"

finish
