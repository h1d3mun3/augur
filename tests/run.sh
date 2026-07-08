#!/usr/bin/env bash
# Orchestrator: run every tests/NN_*.sh in order, print a summary, exit nonzero iff
# any script reported a FAIL. Scripts self-skip tiers whose prerequisites (container, a
# macOS VM host) are absent, so this is safe to run anywhere — CI, the dev container,
# or a Mac. Pass a glob to run a subset:  tests/run.sh 10
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
if [[ -t 1 ]]; then B=$'\e[1m'; G=$'\e[32m'; R=$'\e[31m'; Z=$'\e[0m'; else B=''; G=''; R=''; Z=''; fi

filter="${1:-}"
fails=0; ran=0
for t in "$HERE"/[0-9][0-9]_*.sh; do
  [[ -n "$filter" && "$t" != *"$filter"* ]] && continue
  ran=$((ran+1))
  echo ""
  echo "${B}═══ ${t##*/} ═══${Z}"
  if bash "$t"; then :; else fails=$((fails+1)); fi
done

echo ""
if [[ $ran -eq 0 ]]; then echo "${R}no test scripts matched '${filter}'${Z}"; exit 2; fi
if [[ $fails -eq 0 ]]; then echo "${G}${B}ALL GREEN${Z} (${ran} script(s))"; exit 0
else echo "${R}${B}${fails}/${ran} script(s) FAILED${Z}"; exit 1; fi
