#!/usr/bin/env bash
# Tier 0 — the time bound `update --macos` puts on the agent installer and on Homebrew.
# _with_timeout lives inside the guest script that cmd_update_macos sends over ssh. It must:
#   - return the command's own exit status when it finishes in time;
#   - when the time runs out, stop the command and everything it started (TERM, then KILL for
#     whatever ignores TERM), and return non-zero even if the command exits 0 on TERM;
#   - leave nothing behind: no watchdog sleep, no child the command left running, and nothing
#     holding the caller's stdout open, also when the helper itself is stopped by a signal.
#     Over ssh, a process still holding the session's output keeps the session, and augur,
#     waiting until it exits;
#   - put nothing of its own on stderr (no job notice), and say so when it has no temp dir.
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
# out (what the reader got), err (the helper's stderr), rc (its status) and dt (ms until the
# reader saw EOF). A reader still open after CAP seconds is killed, and dt is then CAP*1000.
timed() {
  local cap="$1"; shift
  rm -f "$WORK/rc" "$WORK/out" "$WORK/err"
  local t0; t0="$(now_ms)"
  { "$sh" -c '. "$1"; shift; _with_timeout "$@"' _ "$snippet" "$@" </dev/null 2>"$WORK/err"; echo "$?" > "$WORK/rc"; } \
    | cat > "$WORK/out" &
  local p=$!
  while kill -0 "$p" 2>/dev/null && (( $(now_ms) - t0 < cap * 1000 )); do sleep 0.1; done
  dt=$(( $(now_ms) - t0 ))
  # A reader still open at CAP means something holds the pipe: cut it off, and kill what is
  # ours so a broken helper cannot hang this script (the result is a failure either way).
  if kill -0 "$p" 2>/dev/null; then kill -KILL "$p" 2>/dev/null; dt=$(( cap * 1000 )); reap; fi
  # The helper may still be running when its reader was cut off; wait for its status briefly.
  local i; for i in 1 2 3 4 5 6 7 8 9 10; do [[ -s "$WORK/rc" ]] && break; sleep 0.2; done
  out="$(cat "$WORK/out" 2>/dev/null)"; rc="$(cat "$WORK/rc" 2>/dev/null)"; err="$(cat "$WORK/err" 2>/dev/null)"
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
# The guest runs the body in macOS's /bin/bash 3.2; say so when another version stands in for it.
bash_ver="$(/bin/bash -c 'echo "${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}"')"
if [[ "$bash_ver" != 3.2 ]]; then
  echo "  NOTE: /bin/bash here is $bash_ver, not 3.2, so the body is not exercised under the guest's bash 3.2."
  skip "bash 3.2 runs of the _with_timeout body" "/bin/bash is $bash_ver"
fi

for sh in "${shells[@]}"; do
  section "$sh: _with_timeout"
  reap

  # (a) A fast command: the reader of the helper's stdout sees EOF at once, and no sleep is left.
  timed 10 "$WATCH_SECS" echo done
  eq "done" "$out" "$sh: a fast command's output comes through"
  eq 0 "$rc" "$sh: a fast command's status 0 comes through"
  eq "" "$err" "$sh: nothing of the helper's own reaches stderr"
  (( dt < 2000 )) && ok "$sh: the reader of its stdout gets EOF promptly (${dt} ms)" \
    || fail "$sh: the reader of its stdout waited ${dt} ms for EOF (something still holds it)"
  no_leftover "$sh: no watchdog sleep is left once the command is done"
  # The watchdog is ended within moments of starting, many times over: none of its sleeps may
  # outlive it, however early the end comes.
  "$sh" -c '. "$1"; for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do _with_timeout "$2" true; done' \
    _ "$snippet" "$WATCH_SECS" </dev/null >/dev/null 2>&1
  no_leftover "$sh: no watchdog sleep is left after 20 instant commands"

  # (b) A slow command with a grandchild holding the same stdout: all of it is stopped at the
  # timeout, the reader sees EOF, and the helper reports the timeout.
  timed 20 1 bash -c "bash -c \"sleep $CHILD_SECS; :\"; :"
  [[ "$rc" == 124 ]] && ok "$sh: a timed-out command returns 124" || fail "$sh: a timed-out command returned [$rc]"
  eq "" "$err" "$sh: a timeout puts no job notice on stderr"
  (( dt < 5000 )) && ok "$sh: the reader sees EOF soon after the 1 s timeout (${dt} ms)" \
    || fail "$sh: the reader waited ${dt} ms for EOF after a 1 s timeout (a grandchild still holds it)"
  no_leftover "$sh: the timed-out command's grandchild is killed too"

  # (c) A fast failing command: its own status and stderr come through, without waiting.
  timed 10 "$WATCH_SECS" sh -c 'echo oops >&2; exit 7'
  eq 7 "$rc" "$sh: a failing command's exit status is preserved"
  eq "oops" "$err" "$sh: stderr holds exactly what the command printed"
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
  eq "" "$err" "$sh: a KILL after the grace puts no job notice on stderr"
  (( dt >= 9000 && dt < 16000 )) && ok "$sh: it is killed after the grace period (${dt} ms)" \
    || fail "$sh: expected a KILL about 11 s in, the reader saw EOF at ${dt} ms"
  no_leftover "$sh: nothing that ignored TERM is left"

  # (f) A command that exits in time but leaves a child running: the child is ended with the
  # step, the reader sees EOF at once, and the status is the command's own.
  timed 10 "$WATCH_SECS" bash -c "sleep $CHILD_SECS & echo started; exit 3"
  eq "started" "$out" "$sh: a command leaving a child: its output comes through"
  eq 3 "$rc" "$sh: a command leaving a child: its status is kept"
  eq "" "$err" "$sh: a command leaving a child: no job notice on stderr"
  # Under 1 s: the end of the group checks it again within moments, not a second later.
  (( dt < 1000 )) && ok "$sh: a child left running does not hold the reader (${dt} ms)" \
    || fail "$sh: a child left running held the reader for ${dt} ms"
  no_leftover "$sh: the child it left running is ended"

  # (g) The temp dir for the timeout cannot be created: a message of its own, and status 1.
  TMPDIR="$WORK/no-such-dir" timed 10 "$WATCH_SECS" echo never
  eq 1 "$rc" "$sh: no temp dir: the helper returns 1"
  eq "" "$out" "$sh: no temp dir: the command never runs"
  eq "augur: ERROR could not create a temp dir for the timeout" "$err" "$sh: no temp dir: says so on stderr"
  no_leftover "$sh: no temp dir: nothing is left"
done

# (h) The helper body itself is stopped by a signal mid-run: the groups of the command and of
# the watchdog are both gone, and its temp dir is removed. The body is run directly, so its pid
# is known (the wrapper only passes its arguments to /bin/bash).
section "/bin/bash: the helper stopped by a signal"
source "$snippet"
mkdir -p "$WORK/tmp"
for sig in TERM INT HUP; do
  # Started as a job of its own (set -m): a plain background job would have INT ignored, as
  # this script has no job control, and the guest runs the body in the foreground.
  set -m
  TMPDIR="$WORK/tmp" /bin/bash -c "$_with_timeout_sh" _with_timeout "$WATCH_SECS" bash -c "sleep $CHILD_SECS; :" \
    </dev/null >/dev/null 2>"$WORK/err" &
  body=$!
  set +m
  groups=""
  for i in 1 2 3 4 5 6 7 8 9 10; do
    groups="$(pgrep -P "$body" | tr '\n' ' ')"; [[ "$(wc -w <<<"$groups")" -ge 2 ]] && break; sleep 0.2
  done
  [[ "$(wc -w <<<"$groups")" -ge 2 ]] && ok "$sig: the command and the watchdog are running" \
    || fail "$sig: the helper did not start both processes" "children: [$groups]"
  [[ -n "$(ls -A "$WORK/tmp")" ]] && ok "$sig: its temp dir exists mid-run" || fail "$sig: no temp dir mid-run"
  kill "-$sig" "$body"; wait "$body"; rc=$?
  [[ "$rc" -gt 128 ]] && ok "$sig: the helper exits with a signal status ($rc)" || fail "$sig: the helper exited $rc"
  sleep 0.3
  alive=""; for g in $groups; do kill -0 -- "-$g" 2>/dev/null && alive+="$g "; done
  [[ -z "$alive" ]] && ok "$sig: both groups are gone" || fail "$sig: groups still alive: $alive"
  no_leftover "$sig: no sleep of the command or the watchdog is left"
  [[ -z "$(ls -A "$WORK/tmp")" ]] && ok "$sig: its temp dir is removed" || fail "$sig: temp dir left: $(ls -A "$WORK/tmp")"
  eq "" "$(cat "$WORK/err")" "$sig: nothing on stderr"
  rm -rf "${WORK:?}/tmp/"*
done

# (i) A signal that arrives before the pids of the command and the watchdog are known is acted
# on once they are: both groups end, nothing is left. A stand-in mktemp sends TERM to the helper
# while it creates its temp dir, which is before either is started. (The window between a fork
# and its pid assignment cannot be hit on purpose; this checks the same deferral.)
section "/bin/bash: a signal before the pids are known"
mkdir -p "$WORK/fakebin"
printf '#!/bin/sh\nwhile [ ! -s "%s" ]; do sleep 0.05; done\nkill -TERM "$(cat "%s")"\nexec "%s" "$@"\n' \
  "$WORK/body.pid" "$WORK/body.pid" "$(command -v mktemp)" > "$WORK/fakebin/mktemp"
chmod +x "$WORK/fakebin/mktemp"
set -m
PATH="$WORK/fakebin:$PATH" TMPDIR="$WORK/tmp" /bin/bash -c "$_with_timeout_sh" _with_timeout "$WATCH_SECS" \
  bash -c "sleep $CHILD_SECS; :" </dev/null >/dev/null 2>"$WORK/err" &
body=$!; echo "$body" > "$WORK/body.pid"
set +m
for i in $(seq 50); do kill -0 "$body" 2>/dev/null || break; sleep 0.2; done
if kill -0 "$body" 2>/dev/null; then
  fail "early TERM: the helper was still running 10 s later (the signal was never acted on)"
  kill -KILL "$body" 2>/dev/null
else
  wait "$body"; rc=$?
  eq 143 "$rc" "early TERM: the helper exits with the TERM status"
fi
no_leftover "early TERM: no sleep of the command or the watchdog is left"
[[ -z "$(ls -A "$WORK/tmp")" ]] && ok "early TERM: its temp dir is removed" || fail "early TERM: temp dir left: $(ls -A "$WORK/tmp")"
eq "" "$(cat "$WORK/err")" "early TERM: nothing on stderr"

finish
