#!/usr/bin/env bash
# tests/39_no_stdin_block.sh — no offline test may block on the stdin it inherited.
#
# THE BUG THIS EXISTS FOR (measured, not hypothetical):
#
# augur pushes credentials by piping into the guest:
#     { … } | ssh_macos "$vm" "cat > ~/.augur-env && chmod 600 ~/.augur-env"
# and immediately afterwards runs a command that merely NAMES that file, unpiped:
#     ssh_macos "$vm" "grep -q '.augur-env' ~/.zshenv || echo … >> ~/.zshenv"
#
# A test stub matching `*".augur-env"*` catches BOTH and answers the piped one with
# `cat >/dev/null`. On the unpiped call that `cat` drains whatever stdin the SUITE inherited.
#
# Under CI and inside a subagent stdin is /dev/null, so `cat` sees EOF and the bug is invisible.
# On a developer's terminal stdin is the TTY: `make offline-tests` stops dead, printing a section
# header and nothing else, with no error and no timeout. Two files shipped in that state and the
# failure was only found by a maintainer running the suite by hand.
#
# So the guard cannot be a source grep — it has to reproduce the condition CI never has. Each
# candidate is re-run with stdin held OPEN (a fd that never reaches EOF) and must still finish.
#
# Candidates are discovered, not listed: any offline test that mentions `.augur-env` is stubbing
# that push and could regrow the pattern. A new test with the same shape is covered automatically.
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib.sh"
SELF="$(basename "$0")"

section "Tier 1 — no offline test blocks on an inherited (TTY-like) stdin"

# Generous: this bounds a HANG, not a slow machine. A passing file costs only its own runtime,
# because the poll breaks as soon as the process exits. The slowest candidate today is ~5 s.
LIMIT_S=45

# The stdin the candidate inherits must NEVER reach EOF — that is the TTY property being modelled.
# A FIFO with a writer held open here does that for free and, unlike `< <(sleep $LIMIT_S)`, cannot
# expire. That distinction is not academic: with a sleep whose duration equalled the timeout, a
# genuinely hung file was UNBLOCKED by its own holder a moment before the poll gave up, and this
# guard reported `ok` on a file that had blocked for the full window. Mutation-checked both ways.
FIFO_DIR="$(mktemp -d)"; trap 'exec 9>&-; rm -rf "$FIFO_DIR"' EXIT
mkfifo "$FIFO_DIR/stdin.fifo"
exec 9<>"$FIFO_DIR/stdin.fifo"    # parent keeps a writer open; readers block forever, never EOF

found=0
for f in "$HERE"/[0-9][0-9]_*.sh; do
    b="$(basename "$f")"
    [[ "$b" == "$SELF" ]] && continue
    grep -q 'augur-env' "$f" || continue          # not a credential-push stubber; nothing to guard
    found=$((found + 1))

    ( AUGUR_TEST_LIVE=0 bash "$f" >/dev/null 2>&1 < "$FIFO_DIR/stdin.fifo" ) &
    pid=$!
    waited=0
    while kill -0 "$pid" 2>/dev/null && (( waited < LIMIT_S )); do sleep 1; waited=$((waited + 1)); done

    if kill -0 "$pid" 2>/dev/null; then
        kill -9 "$pid" 2>/dev/null || true
        fail "$b completes with stdin held open" \
             "still running after ${waited}s — a stub is draining the caller's stdin (look for a \`cat\` on a pattern that also matches an UNPIPED command)"
    else
        ok "$b completes with stdin held open (${waited}s)"
    fi
    wait "$pid" 2>/dev/null || true
done

if (( found == 0 )); then
    fail "at least one candidate was checked" \
         "no offline test mentions .augur-env — the discovery rule has drifted from the code and this guard is now vacuous"
else
    ok "discovery found $found credential-push stubber(s) to check (the guard is not vacuous)"
fi

finish
