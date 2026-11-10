# shellcheck shell=bash
# tests/lib.sh — minimal assert library. `source` me from a test script.

# Every test runs without a controlling terminal, as it does under CI. augur's setup-token reads the
# pasted token from /dev/tty, not stdin, so on a developer's terminal a test that reaches that
# prompt would wait, invisibly, for a paste; in a session with no terminal the open fails at once.
# So a test script that sources this file and still has a controlling terminal runs itself again in
# a new session (macOS has no setsid command; perl ships with it), with stdin, stdout and stderr
# unchanged. Only for a script sourcing this file directly (BASH_SOURCE[1] is $0), never for an
# interactive shell that sources it.
if [[ "${BASH_SOURCE[1]:-}" == "$0" ]]; then
  if [[ "${AUGUR_TEST_NO_CTTY:-}" != 1 ]] && { : </dev/tty; } 2>/dev/null; then
    export AUGUR_TEST_NO_CTTY=1
    if command -v perl >/dev/null 2>&1; then
      # The parent stays in the terminal's process group, passes Ctrl-C (and TERM/HUP) on to the
      # new session, which the terminal no longer signals, and exits with the test's status.
      exec perl -MPOSIX -e '
        my $pid = fork() // die "fork: $!\n";
        if ($pid == 0) { defined(POSIX::setsid()) or die "setsid: $!\n"; exec { $ARGV[0] } @ARGV; die "exec $ARGV[0]: $!\n"; }
        for my $sig (qw(INT TERM HUP)) { $SIG{$sig} = sub { kill($sig, -$pid) or kill($sig, $pid) } }
        my $r; do { $r = waitpid($pid, 0) } while ($r == -1 && $!{EINTR});
        exit(($? & 127) ? 128 + ($? & 127) : $? >> 8);
      ' "$BASH" "$0" ${1+"$@"}
    elif command -v setsid >/dev/null 2>&1; then
      exec setsid -w "$BASH" "$0" ${1+"$@"}
    fi
  fi
  # The guard behind it: a test that can still open /dev/tty does not run at all.
  if { : </dev/tty; } 2>/dev/null; then
    echo "tests/lib.sh: ${0##*/} still has a controlling terminal and cannot leave it (no perl or setsid); not running it." >&2
    exit 1
  fi
fi

# No `set -e`: a failed assertion records and continues so one script reports every check.
set -uo pipefail

# git_exec_path_without_keychain DIR — make DIR a git exec path (for GIT_EXEC_PATH) that holds only
# a stand-in for git-credential-osxkeychain, and print DIR. macOS's Apple git names that helper in a
# gitconfig of its own (in the Command Line Tools) that pointing GIT_CONFIG_SYSTEM elsewhere does
# not replace, so a test that runs `git credential approve` under a sandboxed $HOME otherwise
# reaches the real helper: it asks the login keychain to store the credential, finds no keychain
# under that $HOME, and macOS shows a "Keychain Not Found" dialog whose "Reset To Defaults" resets
# the operator's real login keychain. git looks a helper up in its exec path before PATH, so a PATH
# shim cannot stand in for it. The stand-in reads the request, appends its action to DIR/calls, and
# succeeds. Only for tests that run git builtins: other git-* programs are not in DIR.
git_exec_path_without_keychain() {
  mkdir -p "$1"
  printf '#!/bin/sh\necho "$1" >> "%s/calls"\ncat > /dev/null\n' "$1" > "$1/git-credential-osxkeychain"
  chmod +x "$1/git-credential-osxkeychain"
  printf '%s\n' "$1"
}

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
