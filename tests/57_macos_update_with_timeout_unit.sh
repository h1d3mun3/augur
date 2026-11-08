#!/usr/bin/env bash
# Tier 0 — the time bound `update --macos` puts on the agent installer and on Homebrew.
# _with_timeout lives inside the guest script that cmd_update_macos sends over ssh. It must:
#   - kill a command (and the command's children) that outlives its time, and fail;
#   - return the command's own exit status otherwise;
#   - leave nothing behind once the command is done: no watchdog sleep, and nothing holding the
#     caller's stdout open. Over ssh, a process still holding the session's output keeps the
#     session, and augur, waiting until it exits.
# The helper text is extracted from augur itself, so this cannot drift from what the guest runs.
# It runs under bash and, when installed, zsh (the guest's login shell).
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/lib.sh"
AUGUR="$REPO/augur"

WORK="$(mktemp -d)"
# Distinctive sleep lengths, so a leftover is ours and can be found and cleaned up.
WATCH_SECS=61237; CHILD_SECS=31237
reap() { pkill -f "sleep ($WATCH_SECS|$CHILD_SECS)" 2>/dev/null; return 0; }
trap 'reap; rm -rf "$WORK"' EXIT

helper="$WORK/with_timeout.sh"
awk '/^        _with_timeout\(\) \{$/ {f=1} f {print} f && /^        \}$/ {exit}' "$AUGUR" > "$helper"
if ! grep -q '_with_timeout()' "$helper" || ! tail -n1 "$helper" | grep -q '^        }$'; then
  fail "the _with_timeout helper could not be extracted from augur" "$(cat "$helper")"
  finish; exit
fi

now_ms() { date +%s%3N; }
leftover() { pgrep -f "sleep ($WATCH_SECS|$CHILD_SECS)" >/dev/null; }

shells=(bash)
command -v zsh >/dev/null 2>&1 && shells+=(zsh) || skip "zsh runs of _with_timeout" "zsh not installed"

for sh in "${shells[@]}"; do
  section "$sh: _with_timeout"
  run() { "$sh" -c ". '$helper'; $1"; }

  # (a) A fast command: the reader of the helper's stdout sees EOF at once, and no sleep is left.
  reap
  t0="$(now_ms)"
  out="$(run "_with_timeout $WATCH_SECS echo done" | timeout 10 cat)"
  dt=$(( $(now_ms) - t0 ))
  eq "done" "$out" "$sh: a fast command's output comes through"
  [[ "$dt" -lt 2000 ]] && ok "$sh: the reader of its stdout gets EOF promptly (${dt} ms)" \
    || fail "$sh: the reader of its stdout waited ${dt} ms for EOF (something still holds it)"
  sleep 0.3
  leftover && fail "$sh: the watchdog's sleep outlived a finished command" "$(pgrep -af "sleep $WATCH_SECS")" \
    || ok "$sh: no watchdog sleep is left once the command is done"
  reap

  # (b) A slow command, with a child of its own: both are killed at the timeout, and it fails.
  t0="$(now_ms)"
  run "_with_timeout 1 bash -c 'sleep $CHILD_SECS; :'" </dev/null >/dev/null 2>&1; rc=$?
  dt=$(( $(now_ms) - t0 ))
  [[ "$rc" -ne 0 ]] && ok "$sh: a timed-out command fails (rc=$rc)" || fail "$sh: a timed-out command returned 0"
  [[ "$dt" -lt 5000 ]] && ok "$sh: it is stopped at the timeout (${dt} ms)" || fail "$sh: it ran ${dt} ms past a 1 s timeout"
  sleep 0.3
  leftover && fail "$sh: the timed-out command's child survived" "$(pgrep -af "sleep $CHILD_SECS")" \
    || ok "$sh: the timed-out command's child is killed too"
  reap

  # (c) A fast failing command: its own exit status is returned, without waiting for the timeout.
  t0="$(now_ms)"
  run "_with_timeout $WATCH_SECS sh -c 'exit 7'" </dev/null >/dev/null 2>&1; rc=$?
  dt=$(( $(now_ms) - t0 ))
  eq 7 "$rc" "$sh: a failing command's exit status is preserved"
  [[ "$dt" -lt 2000 ]] && ok "$sh: and returned at once (${dt} ms)" || fail "$sh: it took ${dt} ms"
  sleep 0.3
  leftover && fail "$sh: the watchdog's sleep outlived a failed command" || ok "$sh: no watchdog sleep is left after a failure"
  reap
done

finish
