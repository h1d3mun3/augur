# shellcheck shell=bash
# tests/lib.sh — minimal assert library. `source` me from a test script.
# No `set -e`: a failed assertion records and continues so one script reports every check.
set -uo pipefail

_T_PASS=0; _T_FAIL=0; _T_SKIP=0
if [[ -t 1 ]]; then _G=$'\e[32m'; _R=$'\e[31m'; _Y=$'\e[33m'; _B=$'\e[1m'; _0=$'\e[0m'
else _G=''; _R=''; _Y=''; _B=''; _0=''; fi

section() { echo ""; echo "${_B}# $1${_0}"; }
ok()   { _T_PASS=$((_T_PASS+1)); echo "  ${_G}ok${_0}   $1"; }
fail() { _T_FAIL=$((_T_FAIL+1)); echo "  ${_R}FAIL${_0} $1"; [[ -n "${2:-}" ]] && echo "         ↳ ${2}"; return 0; }
skip() { _T_SKIP=$((_T_SKIP+1)); echo "  ${_Y}skip${_0} $1${2:+  (${2})}"; }

# eq EXPECTED ACTUAL NAME — exact string equality
eq()  { if [[ "$1" == "$2" ]]; then ok "$3"; else fail "$3" "expected [$1], got [$2]"; fi; }
# has HAYSTACK NEEDLE NAME — substring presence
has() { case "$1" in *"$2"*) ok "$3";; *) fail "$3" "[$2] not found in: $1";; esac; }
# hasnt HAYSTACK NEEDLE NAME — substring absence
hasnt(){ case "$1" in *"$2"*) fail "$3" "[$2] unexpectedly present in: $1";; *) ok "$3";; esac; }

# finish — print this script's summary; exit nonzero iff something FAILED (skips are OK).
finish() {
  echo ""
  echo "${_B}── ${0##*/}: ${_T_PASS} passed · ${_T_FAIL} failed · ${_T_SKIP} skipped${_0}"
  [[ $_T_FAIL -eq 0 ]]
}
