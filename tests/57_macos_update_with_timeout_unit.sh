#!/usr/bin/env bash
# Tier 0 — the time bound `update --macos` puts on the agent installer and on Homebrew.
# _with_timeout lives inside the guest script that cmd_update_macos sends over ssh. It must:
#   - return the command's own exit status when it finishes in time;
#   - when the time runs out, stop the command and everything it started (TERM, then KILL for
#     whatever ignores TERM), and return non-zero even if the command exits 0 on TERM;
#   - leave nothing behind: no watchdog sleep, and nothing holding the caller's stdout open.
#     Over ssh, a process still holding the session's output keeps the session, and augur,
#     waiting until it exits.
# The helper text is extracted from augur itself, so this cannot drift from what the guest runs.
# The wrapper is sourced under bash and, when installed, zsh (the guest's login shell); the body
# always runs in /bin/bash, as in the guest.
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/lib.sh"
AUGUR="$REPO/augur"

WORK="$(mktemp -d)"
# Distinctive sleep lengths, so a leftover is ours and can be found and cleaned up.
WATCH_SECS=61237; CHILD_SECS=31237
LEFT="sleep ($WATCH_SECS|$CHILD_SECS)"
reap() { pkill -KILL -f "$LEFT" 2>/dev/null; return 0; }
trap 'reap; rm -rf "$WORK"' EXIT

snippet="$WORK/with_timeout.sh"
awk '/^        _with_timeout_sh=\$\(cat <<"EOF"$/ {f=1} f {print} f && /^        _with_timeout\(\) \{/ {exit}' "$AUGUR" > "$snippet"
if ! grep -q '^EOF$' "$snippet" || ! tail -n1 "$snippet" | grep -q '_with_timeout() {.*/bin/bash'; then
  fail "the _with_timeout helper could not be extracted from augur" "$(cat "$snippet")"
  finish; exit
fi
[[ -x /bin/bash ]] || { skip "_with_timeout" "no /bin/bash on this host"; finish; exit; }

# Milliseconds since some fixed point; whole seconds where bash has no EPOCHREALTIME (bash 3.2).
now_ms() {
  if [[ -n "${EPOCHREALTIME:-}" ]]; then local t="${EPOCHREALTIME/[.,]/}"; echo "${t:0:${#t}-3}"
  else echo $(( SECONDS * 1000 )); fi
}
leftover() { pgrep -f "$LEFT" >/dev/null; }

# timed CAP ARGS... — run `_with_timeout ARGS...` with its stdout piped to a reader. Sets
# out (what the reader got), rc (the helper's status) and dt (ms until the reader saw EOF). A
# reader still open after CAP seconds is killed, and dt is then left at CAP*1000 or more.
timed() {
  local cap="$1"; shift
  rm -f "$WORK/rc" "$WORK/out"
  local t0; t0="$(now_ms)"
  { "$sh" -c '. "$1"; shift; _with_timeout "$@"' _ "$snippet" "$@" </dev/null 2>/dev/null; echo "$?" > "$WORK/rc"; } \
    | cat > "$WORK/out" &
  local p=$!
  while kill -0 "$p" 2>/dev/null && (( $(now_ms) - t0 < cap * 1000 )); do sleep 0.1; done
  dt=$(( $(now_ms) - t0 ))
  # A reader still open at CAP means something holds the pipe: cut it off, and kill what is
  # ours so a broken helper cannot hang this script (the result is a failure either way).
  if kill -0 "$p" 2>/dev/null; then kill -KILL "$p" 2>/dev/null; dt=$(( cap * 1000 )); reap; fi
  # The helper may still be running when its reader was cut off; wait for its status briefly.
  local i; for i in 1 2 3 4 5 6 7 8 9 10; do [[ -s "$WORK/rc" ]] && break; sleep 0.2; done
  out="$(cat "$WORK/out" 2>/dev/null)"; rc="$(cat "$WORK/rc" 2>/dev/null)"
}
# no_leftover NAME — nothing of ours survives (a short pause lets killed processes go).
no_leftover() {
  sleep 0.3
  if leftover; then fail "$1" "$(pgrep -fl "$LEFT" 2>/dev/null || pgrep -f "$LEFT")"; else ok "$1"; fi
  reap
}

shells=(bash)
if command -v zsh >/dev/null 2>&1; then shells+=(zsh)
else
  echo "  NOTE: zsh is not installed here, so the zsh-sourced wrapper (as the guest runs it) is not exercised."
  skip "zsh runs of _with_timeout" "zsh not installed; the body still runs in /bin/bash under the bash runs"
fi

for sh in "${shells[@]}"; do
  section "$sh: _with_timeout"
  reap

  # (a) A fast command: the reader of the helper's stdout sees EOF at once, and no sleep is left.
  timed 10 "$WATCH_SECS" echo done
  eq "done" "$out" "$sh: a fast command's output comes through"
  eq 0 "$rc" "$sh: a fast command's status 0 comes through"
  (( dt < 2000 )) && ok "$sh: the reader of its stdout gets EOF promptly (${dt} ms)" \
    || fail "$sh: the reader of its stdout waited ${dt} ms for EOF (something still holds it)"
  no_leftover "$sh: no watchdog sleep is left once the command is done"

  # (b) A slow command with a grandchild holding the same stdout: all of it is stopped at the
  # timeout, the reader sees EOF, and the helper reports the timeout.
  timed 20 1 bash -c "bash -c \"sleep $CHILD_SECS; :\"; :"
  [[ "$rc" == 124 ]] && ok "$sh: a timed-out command returns 124" || fail "$sh: a timed-out command returned [$rc]"
  (( dt < 5000 )) && ok "$sh: the reader sees EOF soon after the 1 s timeout (${dt} ms)" \
    || fail "$sh: the reader waited ${dt} ms for EOF after a 1 s timeout (a grandchild still holds it)"
  no_leftover "$sh: the timed-out command's grandchild is killed too"

  # (c) A fast failing command: its own exit status is returned, without waiting for the timeout.
  timed 10 "$WATCH_SECS" sh -c 'exit 7'
  eq 7 "$rc" "$sh: a failing command's exit status is preserved"
  (( dt < 2000 )) && ok "$sh: and returned at once (${dt} ms)" || fail "$sh: it took ${dt} ms"
  no_leftover "$sh: no watchdog sleep is left after a failure"

  # (d) A command that exits 0 on TERM still reports the timeout.
  timed 20 1 bash -c "trap 'exit 0' TERM; sleep $CHILD_SECS & wait"
  [[ "$rc" == 124 ]] && ok "$sh: a command that exits 0 on TERM still returns 124" \
    || fail "$sh: a command that exits 0 on TERM returned [$rc]"
  (( dt < 5000 )) && ok "$sh: and it is stopped at the timeout (${dt} ms)" || fail "$sh: it took ${dt} ms"
  no_leftover "$sh: nothing it started is left"

  # (e) A command that ignores TERM (and so do its children) is killed after the grace period.
  timed 30 1 bash -c "trap '' TERM; bash -c \"sleep $CHILD_SECS; :\"; :"
  [[ "$rc" == 124 ]] && ok "$sh: a command ignoring TERM returns 124" || fail "$sh: a command ignoring TERM returned [$rc]"
  (( dt >= 9000 && dt < 16000 )) && ok "$sh: it is killed after the grace period (${dt} ms)" \
    || fail "$sh: expected a KILL about 11 s in, the reader saw EOF at ${dt} ms"
  no_leftover "$sh: nothing that ignored TERM is left"
done

finish
