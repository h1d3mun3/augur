#!/usr/bin/env bash
# Tier 1 — the shared-file cache refresh (issues #124 / #135). Runs anywhere; nothing is cloned,
# booted or really SSH'd, and the guest half is exercised for real against LOCAL files.
#
# The defect it exists for. A macOS guest's virtiofs client serves stale file DATA after a host-side
# edit, on every share, with no timeout — measured 904.9 s stale, then fresh 10.3 s after a forced
# vnode reclaim. `msync(MS_INVALIDATE)` on a PROT_READ mapping is the one guest-side lever that
# works; the host computes WHICH files to invalidate because the guest's own metadata is not
# reliably fresh either. See ADR-0016.
#
# What this file pins, and why each one is here rather than assumed:
#
#   • ORDER at the four call sites. The refresh must precede the wiring, because
#     ensure_macos_claude_profile `cp`s out of the profile share — wiring first copies stale bytes
#     and the copy stays wrong until the next attach. This is asserted on LINE NUMBERS inside each
#     function's own range, not with a substring search, because `has()` in lib.sh is an unanchored
#     substring match and would pass on a mention in a comment.
#   • The share inventory agrees with what `--dir=` actually mounts. A sixth share added to the argv
#     and not to macos_share_roots would silently never be refreshed.
#   • NUL separation end to end. Every shared path this project owns contains a space
#     ("/Volumes/My Shared Files/…"), and a space-split list is exactly how the earlier 105-arm
#     experiment lost ten arms to an output that could not distinguish two outcomes.
#   • The marker is promoted ONLY on success, and is stamped BEFORE the scan. Promoting on failure
#     would mark files as swept that were never invalidated — a silent, permanent hole.
#   • Best effort. A stale share is degraded, not uncontained; `up` must not die here.
#   • The guest program is run FOR REAL against local files: its retry loop, NUL parsing, error
#     classes and output format are behaviour, not text. It cannot reproduce virtiofs staleness
#     offline (nothing can), but everything else about it is testable and is tested.
#   • The program contains no single quote, because it is wrapped in one for the remote shell.
#   • `--share-refresh off` stops the sweep, and does so INSIDE refresh_macos_shares — one gate
#     covering all four attach sites and the loop, which is why the arm for it lives here. It must
#     leave no marker and no lock either: a mode that skipped the guest while promoting the marker
#     would record files as swept that were never invalidated.
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/lib.sh"
AUGUR="$REPO/augur"

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

export AUGUR_VM_BIN="$TMPD/no-such-augur-vm"     # boot-proofing, as tests/30/34/35/36 do
AUGUR_SOURCE_ONLY=1 source "$AUGUR"
set +e

HOME="$TMPD/home"; mkdir -p "$HOME/.config/gh"
AUGUR_DIR="$TMPD/augur"
AUGUR_PROXY_DIR="$TMPD/proxy"; mkdir -p "$AUGUR_PROXY_DIR"
unset ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN
WORKSPACE_DIR="$TMPD/ws"; mkdir -p "$WORKSPACE_DIR"
MACOS_SHARE="workspace-testslug"
VM=testvm

mkdir -p "$AUGUR_DIR/claude-projects/$VM" "$AUGUR_DIR/claude-agents/$VM" "$AUGUR_DIR/claude-profile"

SSHLOG="$TMPD/sshlog"       # the remote command string, one per call
STDINLOG="$TMPD/stdinlog"   # the NUL-separated path list it was fed
: > "$SSHLOG"; : > "$STDINLOG"
SSH_OUT="ok=3"; SSH_RC=0
ssh_macos() {                 # only ever driven with the piped `python3 -c` shape here
    printf '%s\n' "$*" >> "$SSHLOG"
    cat > "$STDINLOG"
    printf '%s' "$SSH_OUT"
    return "$SSH_RC"
}
fed() { tr '\0' '\n' < "$STDINLOG"; }               # the paths, one per line
nfed() { fed | grep -c . ; }

section "the guest program — run for real, against local files"

PROG="$TMPD/prog.py"; _macos_msync_program > "$PROG"
if ! grep -q "'" "$PROG"; then ok "the guest program contains no single quote (it is wrapped in one)"
else fail "the guest program contains no single quote" "$(grep -n "'" "$PROG" | head -3)"; fi

mkdir -p "$TMPD/real"
printf 'hello\n' > "$TMPD/real/a"
printf '' > "$TMPD/real/empty"
printf 'x' > "$TMPD/real/b"
out="$(printf '%s\0%s\0%s\0' "$TMPD/real/a" "$TMPD/real/empty" "$TMPD/real/b" | python3 "$PROG" 3 2>&1)"
if [[ "$out" == *"ok=2"* ]]; then ok "it msyncs real files and counts them (ok=2)"
else fail "it msyncs real files and counts them" "got '$out'"; fi
if [[ "$out" == *"empty=1"* ]]; then ok "a zero-length file is classified, not treated as a failure"
else fail "a zero-length file is classified" "got '$out'"; fi

# msync's return value must be CHECKED, not discarded. A failing msync that still reports ok= is
# precisely the silent failure this whole series exists to remove: the sweep would say it worked and
# the guest would keep reading stale bytes. Driven by making the syscall fail FOR REAL rather than by
# stubbing libc — POSIX requires EINVAL when the address is not a multiple of the page size, so a
# copy of the shipped program with the address nudged off alignment reaches the failure branch
# through the same code path everything else uses.
#
# NOT a zero length, which was the first attempt: macOS rejects that with EINVAL but Linux returns 0,
# so the arm passed here and failed on ubuntu-latest, where offline-tests actually runs. Page
# alignment is specified on both.
_probe_rc="$TMPD/rc.py"
sed 's/L.msync(ctypes.c_void_p(a),n,2)/L.msync(ctypes.c_void_p(a+1),n,2)/' "$PROG" > "$_probe_rc"
out="$(printf '%s\0' "$TMPD/real/a" | python3 "$_probe_rc" 3 2>&1)"
if [[ "$out" == *"msyncfail=1"* ]]; then ok "a FAILING msync is reported, not counted as ok"
else fail "a failing msync is reported" "got '$out' — a discarded return value means the sweep reports success while the guest stays stale"; fi

out="$(printf '%s\0' "$TMPD/real/does-not-exist" | python3 "$PROG" 3 2>&1)"
if [[ "$out" == *"gone=1"* ]]; then ok "a vanished path is reported as gone, not as a crash"
else fail "a vanished path is reported as gone" "got '$out'"; fi

# A path containing spaces must survive as ONE path. This is the failure that cost the earlier
# experiment ten arms.
mkdir -p "$TMPD/real/My Shared Dir"; printf 'z\n' > "$TMPD/real/My Shared Dir/f one"
out="$(printf '%s\0' "$TMPD/real/My Shared Dir/f one" | python3 "$PROG" 3 2>&1)"
if [[ "$out" == "ok=1" ]]; then ok "a path with spaces survives the NUL protocol intact"
else fail "a path with spaces survives the NUL protocol" "got '$out'"; fi

# The retry bound must come from the ARGUMENT, not be hardcoded. With 0 tries the loop body never
# runs, so every path must fall through to "unstable"; a program that ignores argv[1] and loops a
# fixed number of times would report ok=1 here and the silent-truncation guard would be unpinned.
out="$(printf '%s\0' "$TMPD/real/a" | python3 "$PROG" 0 2>&1 | head -1)"
if [[ "$out" == "unstable=1" ]]; then ok "the retry bound is taken from the argument, not hardcoded"
else fail "the retry bound is taken from the argument" "with 0 tries expected the summary unstable=1, got '$out'"; fi
out="$(printf '%s\0' "$TMPD/real/a" | python3 "$PROG" 1 2>&1 | head -1)"
if [[ "$out" == "ok=1" ]]; then ok "…and one try is enough for a file whose size is stable"
else fail "one try is enough for a stable file" "got '$out'"; fi

out="$(printf '\0\0' | python3 "$PROG" 3 2>&1)"
if [[ -z "${out// /}" ]]; then ok "an empty list is a clean no-op"
else fail "an empty list is a clean no-op" "got '$out'"; fi

section "failures are NAMED, not just counted"

# Counts answer "is one file wrong or are hundreds?" — which changes how alarmed to be. They do not
# answer "which one", which is what decides whether to care at all: `unstable` on a build artefact
# while a host-side build runs is expected; the same verdict on a source file is not. The remedy is
# identical either way, so this is diagnosis, and it is bounded for that reason.
mkdir -p "$TMPD/many"
for _i in 1 2 3 4 5 6 7 8; do printf 'x\n' > "$TMPD/many/f$_i"; done
_all_fail="$TMPD/allfail.py"
sed 's/L.msync(ctypes.c_void_p(a),n,2)/L.msync(ctypes.c_void_p(a+1),n,2)/' "$PROG" > "$_all_fail"
out="$(for _i in 1 2 3 4 5 6 7 8; do printf '%s\0' "$TMPD/many/f$_i"; done | python3 "$_all_fail" 3 5 2>&1)"

if [[ "$(printf '%s\n' "$out" | head -1)" == "msyncfail=8" ]]; then ok "the counts stay on the FIRST line"
else fail "the counts stay on the first line" "the host reads line 1 as the summary; got '$(printf '%s\n' "$out" | head -1)'"; fi
if [[ "$(printf '%s\n' "$out" | grep -c '^msyncfail /')" == "5" ]]; then ok "it names the failures, capped at the requested 5"
else fail "it names the failures, capped at 5" "got $(printf '%s\n' "$out" | grep -c '^msyncfail /')"; fi
if printf '%s\n' "$out" | grep -qx "and 3 more"; then ok "…and says how many it did not name"
else fail "…and says how many it did not name" "silent truncation is the failure class this series removes: $out"; fi

out="$(printf '%s\0%s\0' "$TMPD/many/f1" "$TMPD/many/f2" | python3 "$PROG" 3 5 2>&1)"
if [[ "$(printf '%s\n' "$out" | grep -c .)" == "1" ]]; then ok "a clean sweep prints the summary and nothing else"
else fail "a clean sweep prints only the summary" "got: $(printf '%s\n' "$out" | tr '\n' '|')"; fi

# A filename may contain a newline on macOS. Unsanitised it would split one failure across two
# output lines and the host would print half a path as if it were a second failure.
mkdir -p "$TMPD/nl"; printf 'x\n' > "$TMPD/nl/we
ird"
out="$(printf '%s\0' "$TMPD/nl/we
ird" | python3 "$_all_fail" 3 5 2>&1)"
if [[ "$(printf '%s\n' "$out" | grep -c .)" == "2" ]]; then ok "a filename containing a newline stays on ONE detail line"
else fail "a filename with a newline stays on one line" "$(printf '%s\n' "$out" | tr '\n' '|')"; fi

section "the host surfaces the named failures"

sleep 1; printf 'edited\n' > "$WORKSPACE_DIR/one"
SSH_OUT="ok=2 unstable=1
unstable /Volumes/My Shared Files/workspace-testslug/src/main.swift
and 7 more"
out="$( refresh_macos_shares "$VM" 2>&1 )"
SSH_OUT="ok=3"
if [[ "$out" == *"(ok=2 unstable=1)"* ]]; then ok "the summary line is used for the headline, not the whole blob"
else fail "the summary line is used for the headline" "$out"; fi
if [[ "$out" == *"unstable /Volumes/My Shared Files/workspace-testslug/src/main.swift"* ]]; then ok "the named file reaches the operator"
else fail "the named file reaches the operator" "$out"; fi
if [[ "$out" == *"and 7 more"* ]]; then ok "…so does the truncation notice"
else fail "…so does the truncation notice" "$out"; fi

section "the share inventory matches what --dir= actually mounts"

roots="$(macos_share_roots "$VM")"
n_roots="$(printf '%s\n' "$roots" | grep -c .)"
# Count only the macOS argv: container mode uses -v, not --dir, so this is unambiguous.
n_dirs="$(grep -c '^\s*--dir="' "$AUGUR")"
if [[ "$n_roots" == "$n_dirs" ]]; then ok "macos_share_roots covers every --dir= share ($n_roots)"
else fail "macos_share_roots covers every --dir= share" "roots=$n_roots but --dir= lines=$n_dirs — a share was added to one and not the other"; fi
# gh-config is deliberately NOT here: macOS mode does not share it (it was mounted and never wired
# to ~/.config/gh, so it was exposure without a feature). Container mode still mounts it at the real
# path. If it is ever wired properly for macOS it must reappear in BOTH the argv and the inventory,
# which the count assertion above enforces.
for _s in "$MACOS_SHARE" claude-projects claude-agents claude-profile; do
    if printf '%s\n' "$roots" | cut -f1 | grep -qx "$_s"; then ok "share '$_s' is in the inventory"
    else fail "share '$_s' is in the inventory" "$roots"; fi
done
if printf '%s\n' "$roots" | grep -q "claude-projects	${AUGUR_DIR}/claude-projects/${VM}"; then
    ok "the per-VM shares resolve to their per-VM host directory"
else fail "the per-VM shares resolve to their per-VM host directory" "$roots"; fi

section "first sweep: no marker means sweep everything"

printf 'a\n' > "$WORKSPACE_DIR/one"; printf 'b\n' > "$WORKSPACE_DIR/two"
printf 'p\n' > "$AUGUR_DIR/claude-profile/prof"
: > "$SSHLOG"; : > "$STDINLOG"
refresh_macos_shares "$VM" >/dev/null 2>&1
if [[ "$(nfed)" == "3" ]]; then ok "with no marker, every file in every share is swept (3)"
else fail "with no marker, every file is swept" "fed $(nfed): $(fed | tr '\n' ' ')"; fi
if fed | grep -qx "/Volumes/My Shared Files/${MACOS_SHARE}/one"; then ok "host paths are mapped to guest share paths"
else fail "host paths are mapped to guest share paths" "$(fed | tr '\n' ' ')"; fi
if fed | grep -qx "/Volumes/My Shared Files/claude-profile/prof"; then ok "the :ro profile share is swept too (it is stale as well)"
else fail "the :ro profile share is swept too" "$(fed | tr '\n' ' ')"; fi
if [[ -f "$(macos_share_sweep_marker "$VM")" ]]; then ok "the marker is promoted after a successful sweep"
else fail "the marker is promoted after a successful sweep"; fi
if [[ ! -f "$(macos_share_sweep_marker "$VM").pending" ]]; then ok "no pending marker is left behind"
else fail "no pending marker is left behind"; fi

section "second sweep: incremental"

: > "$SSHLOG"; : > "$STDINLOG"
refresh_macos_shares "$VM" >/dev/null 2>&1
if [[ ! -s "$SSHLOG" ]]; then ok "nothing changed → no guest round trip at all"
else fail "nothing changed → no guest round trip" "$(cat "$SSHLOG")"; fi

sleep 1; printf 'CHANGED\n' > "$WORKSPACE_DIR/two"
: > "$SSHLOG"; : > "$STDINLOG"
refresh_macos_shares "$VM" >/dev/null 2>&1
if [[ "$(nfed)" == "1" ]]; then ok "only the changed file is swept"
else fail "only the changed file is swept" "fed $(nfed): $(fed | tr '\n' ' ')"; fi
if fed | grep -qx "/Volumes/My Shared Files/${MACOS_SHARE}/two"; then ok "…and it is the right one"
else fail "…and it is the right one" "$(fed | tr '\n' ' ')"; fi

section "the wire protocol really is NUL-separated"

sleep 1; mkdir -p "$WORKSPACE_DIR/a dir"; printf 's\n' > "$WORKSPACE_DIR/a dir/a file"
: > "$STDINLOG"; refresh_macos_shares "$VM" >/dev/null 2>&1
if fed | grep -qx "/Volumes/My Shared Files/${MACOS_SHARE}/a dir/a file"; then ok "a host path with spaces arrives as one path"
else fail "a host path with spaces arrives as one path" "$(fed | tr '\n' ' ')"; fi
if [[ "$(nfed)" == "1" ]]; then ok "…and as exactly one entry, not three"
else fail "…and as exactly one entry" "fed $(nfed)"; fi

# Spaces alone do NOT pin the protocol: a newline-separated list carries a path with spaces just
# fine, so the two are indistinguishable to every assertion above. Measured — swapping the \0 for a
# \n in the producer left this file completely green. Two things actually discriminate:
#   (a) the bytes on the wire contain NUL at all;
#   (b) a path containing a NEWLINE survives as ONE path.
# (b) is the behavioural form and is the reason NUL was chosen; macOS permits newlines in filenames.
if [[ "$(tr -dc '\0' < "$STDINLOG" | wc -c | tr -d ' ')" -gt 0 ]]; then ok "the wire bytes actually contain NUL separators"
else fail "the wire bytes actually contain NUL separators" "a newline-separated list would pass every other assertion here"; fi

sleep 1; printf 'n\n' > "$WORKSPACE_DIR/we
ird"
: > "$STDINLOG"; refresh_macos_shares "$VM" >/dev/null 2>&1
_nulcount="$(tr -dc '\0' < "$STDINLOG" | wc -c | tr -d ' ')"
if [[ "$_nulcount" == "1" ]]; then ok "a filename containing a NEWLINE crosses as exactly one path"
else fail "a filename containing a newline crosses as one path" "expected 1 NUL-terminated entry, saw $_nulcount"; fi
rm -f "$WORKSPACE_DIR/we
ird"

section "failure is best-effort, and must not advance the marker"

sleep 1; printf 'MORE\n' > "$WORKSPACE_DIR/one"
# A reference stamped AFTER the edit and BEFORE the sweep. The pending marker is created later
# still, so a marker promoted by the sweep is necessarily newer than this; one left alone is not.
# `-nt` is a bash builtin and behaves the same on both CI platforms — `stat -f %m` does not: on
# macOS it prints the mtime, on GNU coreutils `-f` selects FILESYSTEM status and the arm silently
# compared two error strings. It failed on ubuntu-latest while passing here.
: > "$TMPD/ref-before-failure"
sleep 1        # `-nt` compares whole seconds on this bash; without the gap a promoted marker and
               # the reference land in the same second and the assertion cannot fire. Measured.
SSH_RC=1; SSH_OUT="boom"
: > "$SSHLOG"
out="$( refresh_macos_shares "$VM" 2>&1 )"; rc=$?
SSH_RC=0; SSH_OUT="ok=3"
# Self-diagnosis first: if the sweep found nothing to do, it took the early-return path, never
# reached the guest, and every assertion below would be about a sweep that did not happen.
if [[ -s "$SSHLOG" ]]; then ok "the failing sweep actually had work and reached the guest"
else fail "the failing sweep actually had work and reached the guest" "no guest call was made — the arm below would prove nothing"; fi
if [[ $rc -eq 0 ]]; then ok "a guest-side failure still returns 0 (bring-up continues)"
else fail "a guest-side failure still returns 0" "rc=$rc"; fi
if [[ "$out" == *"Could not refresh"* ]]; then ok "…and says so"
else fail "…and says so" "$out"; fi
if [[ ! "$(macos_share_sweep_marker "$VM")" -nt "$TMPD/ref-before-failure" ]]; then
    ok "the marker is NOT advanced on failure (the file is retried next time)"
else fail "the marker is NOT advanced on failure" "the marker moved forward despite the guest failing"; fi
if [[ ! -f "$(macos_share_sweep_marker "$VM").pending" ]]; then ok "the pending marker is cleaned up after a failure"
else fail "the pending marker is cleaned up after a failure"; fi
: > "$STDINLOG"; refresh_macos_shares "$VM" >/dev/null 2>&1
if fed | grep -qx "/Volumes/My Shared Files/${MACOS_SHARE}/one"; then ok "the file skipped by the failed sweep IS swept on the next one"
else fail "the file skipped by the failed sweep is swept on the next one" "$(fed | tr '\n' ' ')"; fi

section "reported problems are named, not swallowed"

sleep 1; printf 'q\n' > "$WORKSPACE_DIR/one"
SSH_OUT="ok=1 unstable=1"
out="$( refresh_macos_shares "$VM" 2>&1 )"
SSH_OUT="ok=3"
if [[ "$out" == *"unstable=1"* && "$out" == *"may still read stale"* ]]; then ok "an 'unstable' verdict is surfaced to the operator"
else fail "an 'unstable' verdict is surfaced" "$out"; fi

section "the retry count reaches the guest"

# The recorded command spans many lines (the program is multi-line), so this is two checks:
# the invocation shape on the first line, and the retry count as the final argument on the last.
if head -1 "$SSHLOG" | grep -q "python3 -c "; then ok "the guest is invoked as \`python3 -c\`"
else fail "the guest is invoked as \`python3 -c\`" "$(head -1 "$SSHLOG")"; fi
# Both tuning arguments, in order: a swap would silently give 5 retries and name 3 failures.
if tail -1 "$SSHLOG" | grep -q " ${_MACOS_SWEEP_TRIES} ${_MACOS_SWEEP_DETAIL}$"; then
    ok "the retry count and the detail cap are passed, in that order"
else fail "the retry count and the detail cap are passed, in that order" "$(tail -1 "$SSHLOG")"; fi

section "--share-refresh off stops the sweep — at every call site at once"

# `off` is enforced INSIDE refresh_macos_shares rather than by an `if` copied to the four attach call
# sites plus the loop, so this one arm covers all five and a sixth caller cannot escape it.
#
# "No round trip" is not the whole property. A mode that skipped the guest but still promoted the
# marker would silently record files as swept that were never invalidated — the permanent hole the
# marker arms above exist for — so the state is asserted too.
_saved_mode="$_MACOS_REFRESH_MODE"
sleep 1; printf 'OFFMARK\n' > "$WORKSPACE_DIR/one"
: > "$TMPD/ref-before-off"
sleep 1        # whole-second `-nt` granularity, same reason as the reference above
_MACOS_REFRESH_MODE=off
: > "$SSHLOG"; : > "$STDINLOG"
out="$( refresh_macos_shares "$VM" 2>&1 )"; rc=$?
if [[ ! -s "$SSHLOG" ]]; then ok "off: no guest round trip at all"
else fail "off: no guest round trip" "$(head -1 "$SSHLOG")"; fi
if [[ $rc -eq 0 ]]; then ok "…and it returns 0, so the bring-up continues (best effort, like every path here)"
else fail "off returns 0" "rc=$rc"; fi
if [[ -z "$out" ]]; then ok "…and says nothing (the launch-time warning already said it once)"
else fail "off says nothing" "$out"; fi
if [[ ! "$(macos_share_sweep_marker "$VM")" -nt "$TMPD/ref-before-off" ]]; then
    ok "…and does NOT advance the marker, so the edit is swept once the refresh is back on"
else fail "off does not advance the marker" "a promoted marker would drop this edit permanently"; fi
if [[ ! -d "$(macos_share_sweep_marker "$VM").lock" ]]; then ok "…and leaves no lock behind (it returns before taking one)"
else fail "off leaves no lock behind" "a wedged lock would block the next sweep for two minutes"; fi

# THE CONTROL. The same edit, the same fixture, with the mode restored to one that sweeps. Without
# it every assertion above would also pass on a sweep broken for a completely unrelated reason —
# and `attach` is the right control, because it must stop the LOOP and nothing else.
_MACOS_REFRESH_MODE=attach
: > "$SSHLOG"; : > "$STDINLOG"
refresh_macos_shares "$VM" >/dev/null 2>&1
if [[ -s "$SSHLOG" ]]; then ok "attach: the sweep still runs (that mode drops only the background loop)"
else fail "attach: the sweep still runs" "the mode gate is stopping more than off should"; fi
if fed | grep -qx "/Volumes/My Shared Files/${MACOS_SHARE}/one"; then ok "…and the file skipped while off is picked up"
else fail "…and the file skipped while off is picked up" "$(fed | tr '\n' ' ')"; fi
_MACOS_REFRESH_MODE="$_saved_mode"

section "call-site ORDER — the refresh must precede the wiring"

# Line numbers inside each function's own range. A substring search would pass on a comment.
fn_range() {  # fn_range <name> -> "start end"
    awk -v f="^$1\\\\(\\\\) \\\\{" 'BEGIN{s=0} $0 ~ f && s==0 {s=NR} s>0 && /^}/ {print s, NR; exit}' "$AUGUR"
}
first_in() {  # first_in <start> <end> <needle>
    awk -v a="$1" -v b="$2" -v n="$3" 'NR>=a && NR<=b && index($0,n)>0 && $0 !~ /^ *#/ {print NR; exit}' "$AUGUR"
}
for _fn in cmd_up_macos cmd_claude_macos cmd_shell_macos; do
    read -r _s _e <<<"$(fn_range "$_fn")"
    _r="$(first_in "$_s" "$_e" 'refresh_macos_shares "$project_vm"')"
    _c="$(first_in "$_s" "$_e" 'sync_macos_guest_clock "$project_vm"')"
    _w="$(first_in "$_s" "$_e" 'ensure_macos_workspace "$project_vm"')"
    if [[ -n "$_r" ]]; then ok "$_fn calls refresh_macos_shares"
    else fail "$_fn calls refresh_macos_shares" "range $_s-$_e"; fi
    if [[ -n "$_c" && -n "$_r" && "$_c" -lt "$_r" ]]; then ok "$_fn: refresh runs after the clock sync"
    else fail "$_fn: refresh runs after the clock sync" "clock=$_c refresh=$_r"; fi
    if [[ -n "$_w" ]]; then
        if [[ -n "$_r" && "$_r" -lt "$_w" ]]; then ok "$_fn: refresh runs BEFORE ensure_macos_workspace (the load-bearing order)"
        else fail "$_fn: refresh runs BEFORE ensure_macos_workspace" "refresh=$_r wiring=$_w"; fi
    fi
done
# cmd_up_macos holds two call sites: the fresh path and the already-running reconcile branch.
read -r _s _e <<<"$(fn_range cmd_up_macos)"
_n="$(awk -v a="$_s" -v b="$_e" 'NR>=a && NR<=b && index($0,"refresh_macos_shares \"$project_vm\"")>0 && $0 !~ /^ *#/ {c++} END{print c+0}' "$AUGUR")"
if [[ "$_n" == "2" ]]; then ok "cmd_up_macos refreshes on BOTH paths (fresh boot and reconcile)"
else fail "cmd_up_macos refreshes on both paths" "found $_n call sites, expected 2"; fi

section "destroy reaps the marker"

if grep -q 'rm -f "$(macos_share_sweep_marker "$project_vm")"' "$AUGUR"; then ok "cmd_destroy_macos removes the sweep marker"
else fail "cmd_destroy_macos removes the sweep marker" "a surviving marker would make the next clone's first sweep incremental against a cache that no longer exists"; fi

section "\`augur refresh --macos\` — a sweep on demand"

# THE GAP IT CLOSES. Every call site above is a side effect of doing something else: attaching, or a
# loop nobody watches. So with the loop stopped (`--share-refresh attach`, or `off`) the only ways to
# make a host-side edit visible in a running guest were to attach — `up`/`claude`/`shell`, all three
# of which put the operator INSIDE the guest — or to wait, which is the one thing #124 measures as
# not working. The dial's most useful setting was its least usable one.
#
# The subtle half, and what most of this section is about: the mode gate lives INSIDE
# refresh_macos_shares (see the `off` section above — one chokepoint for all five automatic callers
# instead of an `if` at each), so the manual command has to reach the sweep PAST that gate without
# opening it for anybody else. It does that through a second entry point, refresh_macos_shares_now,
# which cmd_refresh_macos alone calls. Two properties have to hold together or the change is wrong:
# the manual command sweeps under `off`, AND `refresh_macos_shares` still refuses to under `off`.
# They are asserted here as a PAIR, on the same edit and in the same mode, because either one alone
# passes on a version that got the other backwards.
_saved_up="$(declare -f cmd_up_macos)"
_saved_vz="$(declare -f require_vz)"
_saved_pvm="$(declare -f macos_project_vm)"
_saved_running="$(declare -f macos_vm_running)"
_saved_sshhost="$(declare -f macos_ssh_host)"
_saved_mode="$_MACOS_REFRESH_MODE"

# Stubs, saved and restored with `declare -f` — never `unset -f`, which would delete augur's own
# function and leave the rest of this file testing nothing.
BOOTLOG="$TMPD/bootlog"; : > "$BOOTLOG"
VMSTATE="$TMPD/vm-state"; echo running > "$VMSTATE"
SSHHOST="$TMPD/ssh-host"; echo 127.0.0.1 > "$SSHHOST"
cmd_up_macos()     { echo BOOTED >> "$BOOTLOG"; }   # a tripwire, not a stub: this must never run
require_vz()       { :; }                           # the suite runs on Linux CI too
macos_project_vm() { echo "$VM"; }                  # keep the marker on the path the fixture owns
macos_vm_running() { [[ "$(cat "$VMSTATE")" == running ]]; }
macos_ssh_host()   { cat "$SSHHOST"; }

_MACOS_REFRESH_MODE=continuous
sleep 1; printf 'MANUAL\n' > "$WORKSPACE_DIR/one"
: > "$SSHLOG"; : > "$STDINLOG"; : > "$BOOTLOG"
out="$( cmd_refresh_macos 2>&1 )"; rc=$?
if [[ -s "$SSHLOG" ]]; then ok "the command reaches the sweep and the guest"
else fail "the command reaches the sweep and the guest" "no round trip was made"; fi
if fed | grep -qx "/Volumes/My Shared Files/${MACOS_SHARE}/one"; then ok "…and it is the host-side edit that gets invalidated"
else fail "…and it is the host-side edit that gets invalidated" "$(fed | tr '\n' ' ')"; fi
if [[ $rc -eq 0 ]]; then ok "…and it exits 0 on a clean sweep"
else fail "…and it exits 0 on a clean sweep" "rc=$rc: $out"; fi
# It must NOT pass `quiet`. Only the loop does, and only because nobody is watching it. A human who
# typed this wants the count and — when the guest could not invalidate something — the names.
if [[ "$out" == *"Refreshed the guest's view of"* ]]; then ok "…and it REPORTS what it did (it does not pass \`quiet\`)"
else fail "…and it reports what it did" "a silent manual refresh is indistinguishable from one that did nothing: '$out'"; fi
if [[ ! -s "$BOOTLOG" ]]; then ok "…without going anywhere near cmd_up_macos"
else fail "…without going near cmd_up_macos" "it booted a VM on the path where one was already running"; fi
# The sweep is legitimately silent when nothing changed — it never contacts the guest — and a command
# whose whole job is this, printing nothing, is indistinguishable from one that never ran. So it says
# what it is about to do, before it does it. It is a LEAD-IN and not a claim of success, which is why
# every outcome below has a line of its own.
if [[ "$out" == *"Refreshing the guest's view"* ]]; then ok "…and it says what it is doing even when the sweep itself would be silent"
else fail "…and it says what it is doing" "with nothing changed, this command would print nothing at all: '$out'"; fi
: > "$SSHLOG"
out="$( cmd_refresh_macos 2>&1 )"; rc=$?  # immediately again: nothing has changed, so the sweep is silent
if [[ ! -s "$SSHLOG" ]]; then ok "a second run with nothing changed makes no round trip (the sweep's own early return)"
else fail "a second run with nothing changed makes no round trip" "$(head -1 "$SSHLOG")"; fi
# …and SAYS that, rather than leaving the operator to infer it from the absence of a report. "Nothing
# had changed" is the most common outcome of a manual run and the one most easily confused with a
# sweep that fell over, which is why the sweep hands it back as its own status rather than as 0.
if [[ "$out" == *"No shared file has changed"* ]]; then ok "…and says nothing had changed, rather than just falling silent"
else fail "…and says nothing had changed" "silence here reads exactly like a sweep that failed: '$out'"; fi
if [[ $rc -eq 0 ]]; then ok "…and that is a success, not a failure (rc=0)"
else fail "nothing-to-do exits 0" "rc=$rc: $out"; fi

# It must not BOOT one either. cmd_claude_macos and cmd_shell_macos fall back to cmd_up_macos because
# their job is to put the operator in the guest; "refresh" has no such job, a stopped guest holds no
# cache to invalidate, and the `up` that would start it sweeps on the way in anyway.
echo stopped > "$VMSTATE"
# A pending edit, so "no round trip" below is a real property and not an artefact of there being
# nothing to sweep: without the refusal this file WOULD be found and sent. Measured — without this
# line, deleting the refusal left two of the four arms below green.
sleep 1; printf 'STOPPED\n' > "$WORKSPACE_DIR/one"
: > "$SSHLOG"; : > "$BOOTLOG"
out="$( cmd_refresh_macos 2>&1 )"; rc=$?       # `exit 1` — contained by the subshell, so this file survives
if [[ $rc -eq 1 ]]; then ok "no VM running: it REFUSES (rc=1) instead of booting one"
else fail "no VM running: it refuses" "rc=$rc: $out"; fi
if [[ ! -s "$BOOTLOG" ]]; then ok "…and cmd_up_macos is never called"
else fail "…and cmd_up_macos is never called" "booting a VM as a side effect of \`refresh\` is a surprise, and there is nothing cached to invalidate"; fi
if [[ ! -s "$SSHLOG" ]]; then ok "…and no round trip is attempted at a VM that is not there"
else fail "…and no round trip is attempted" "$(head -1 "$SSHLOG")"; fi
if [[ "$out" == *"up --macos"* ]]; then ok "…and the refusal names the command that would start it"
else fail "…and the refusal names the remedy" "$out"; fi

# The transport, checked before the sweep: ssh_macos EXITS rather than returning when it cannot name
# a host (#137). Inside the sweep that exit is contained by the command substitution and becomes a
# warning under a SUCCESS status — right for a bring-up, wrong for a command whose only job is the
# round trip, and absent altogether when nothing changed and the guest is never contacted. The state
# is reachable: VM running, gvproxy down (tests/37's header; reproduced by `make e2e` 2026-07-26).
echo running > "$VMSTATE"; : > "$SSHHOST"
sleep 1; printf 'TRANSPORT\n' > "$WORKSPACE_DIR/one"   # same reason: something to sweep, if it tried
: > "$SSHLOG"
out="$( cmd_refresh_macos 2>&1 )"; rc=$?
if [[ $rc -eq 1 ]]; then ok "an unresolvable transport is refused up front (rc=1), not reported as a success"
else fail "an unresolvable transport is refused up front" "rc=$rc: '$out'"; fi
if [[ ! -s "$SSHLOG" ]]; then ok "…before any sweep is attempted"
else fail "…before any sweep is attempted" "$(head -1 "$SSHLOG")"; fi
if [[ "$out" == *"down --macos"* ]]; then ok "…naming the remedy for a VM whose datapath is gone"
else fail "…naming the remedy" "$out"; fi
# THE CONTROL for the two refusals above: with the VM running and a host that resolves, the same
# command sweeps. Without it both arms would pass on a cmd_refresh_macos that refused unconditionally.
echo 127.0.0.1 > "$SSHHOST"
sleep 1; printf 'CONTROL\n' > "$WORKSPACE_DIR/one"
: > "$SSHLOG"
cmd_refresh_macos >/dev/null 2>&1
if [[ -s "$SSHLOG" ]]; then ok "control: a running VM with a resolvable host still sweeps"
else fail "control: a running VM with a resolvable host still sweeps" "the two refusals above are refusing everything"; fi

# All three modes, and `off` is the one this command exists for.
for _m in continuous attach off; do
    _MACOS_REFRESH_MODE="$_m"
    sleep 1; printf 'MODE-%s\n' "$_m" > "$WORKSPACE_DIR/one"
    : > "$SSHLOG"; : > "$STDINLOG"
    out="$( cmd_refresh_macos 2>&1 )"; rc=$?
    if [[ -s "$SSHLOG" ]]; then ok "--share-refresh $_m: the manual sweep runs"
    else fail "--share-refresh $_m: the manual sweep runs" "the mode gate is stopping the one caller that is allowed past it"; fi
    if [[ $rc -eq 0 ]]; then ok "…and returns 0"
    else fail "…and returns 0" "rc=$rc: $out"; fi
done

# ── THE EXIT STATUS, which is the half `augur refresh --macos && run_tests` depends on ───────────
#
# The sweep returns 0 on every path by contract, because a bring-up must survive a stale share (a
# non-zero there would abort `up --macos` between "SSH is up" and the egress tripwire — the I1
# shape). For a command whose ONLY job is the round trip that contract is wrong, and it was the
# defect this section's own transport pre-check exists to remove, left in place for every failure
# except the one the pre-check covers. The manual entry point exists precisely so the manual path
# can differ; these arms are what make it differ, and each one is paired with the automatic
# contract asserted in the SAME fixture, because "the manual path reports it" and "the automatic
# path still swallows it" are two properties and a change can get either one backwards.
_MACOS_REFRESH_MODE=continuous

# 1. THE LOCK IS HELD. The sweep skips a tick it cannot lock, which is right for a LOOP — the holder
# is scanning the same trees against the same marker, so the work is covered. It is wrong for a
# one-shot: the holder stamped `pending` and ran its `find` BEFORE this edit, so this edit is in the
# NEXT sweep's list, and under `attach`/`off` this command IS the next sweep. Reachable from a
# `continuous` tick mid-sweep, a concurrent attach, or a wedged lock younger than two minutes.
sleep 1; printf 'LOCKED\n' > "$WORKSPACE_DIR/one"
mkdir -p "$(macos_share_sweep_marker "$VM").lock"
: > "$SSHLOG"
out="$( cmd_refresh_macos 2>&1 )"; rc=$?
if [[ $rc -eq 1 ]]; then ok "lock held: the manual sweep FAILS (rc=1) instead of reporting a success it did not have"
else fail "lock held: the manual sweep fails" "rc=$rc — it swept nothing and said so was fine: '$out'"; fi
if [[ "$out" == *"already in progress"* ]]; then ok "…and says another sweep holds the lock"
else fail "…and says another sweep holds the lock" "the lead-in line alone claims work that did not happen: '$out'"; fi
if [[ "$out" == *"Re-run"* ]]; then ok "…and names the remedy, which under \`attach\`/\`off\` is the only one there is"
else fail "…and names the remedy" "$out"; fi
if [[ ! -s "$SSHLOG" ]]; then ok "…having genuinely made no round trip (so the arms above are about a real skip)"
else fail "…having made no round trip" "$(head -1 "$SSHLOG")"; fi
# The automatic half, same lock, same edit: a bring-up must not die on a lock it lost a race for.
if refresh_macos_shares "$VM" >/dev/null 2>&1; then ok "…while the GATED entry still returns 0 on the same held lock (the bring-up contract)"
else fail "the gated entry still returns 0 on a held lock" "a lost lock race would now abort \`up --macos\` under set -e"; fi
rmdir "$(macos_share_sweep_marker "$VM").lock"

# 2. THE ROUND TRIP FAILS AT THE GUEST — sshd down, a wedged guest, a changed host key. The transport
# pre-check covers only "cannot NAME a host"; everything else lands here, and this is the common
# half. The file above is still pending (the locked run swept nothing), so there is real work.
SSH_RC=1; SSH_OUT="boom"
: > "$SSHLOG"
out="$( cmd_refresh_macos 2>&1 )"; rc=$?
if [[ -s "$SSHLOG" ]]; then ok "a failing round trip is actually attempted (the arms below are not vacuous)"
else fail "a failing round trip is actually attempted" "nothing was sent, so nothing below is about a failure"; fi
if [[ $rc -eq 1 ]]; then ok "…and the manual command exits 1, not 0-with-a-warning"
else fail "…and the manual command exits 1" "rc=$rc: \`augur refresh --macos && run_tests\` would run the tests: '$out'"; fi
if [[ "$out" == *"Could not refresh"* ]]; then ok "…still saying what went wrong, in the sweep's own voice"
else fail "…still saying what went wrong" "$out"; fi
if refresh_macos_shares "$VM" >/dev/null 2>&1; then ok "…while the GATED entry still returns 0 on the very same failure"
else fail "the gated entry still returns 0 on a failed round trip" "this is the I1 shape: \`up --macos\` would abort between SSH-is-up and the egress tripwire"; fi
SSH_RC=0

# 3. THE GUEST REFUSED TO INVALIDATE. The round trip worked and the mechanism did not: `msyncfail`
# and `nomap` mean named files may still read stale, which is exactly what the command was asked to
# prevent. `unstable` is NOT in that set — a file whose size kept moving across every retry is a
# live host-side writer, expected during a build, and it will be swept again when the writer stops.
sleep 1; printf 'MSYNCFAIL\n' > "$WORKSPACE_DIR/one"
SSH_OUT="ok=0 msyncfail=1"
out="$( cmd_refresh_macos 2>&1 )"; rc=$?
if [[ $rc -eq 1 ]]; then ok "msyncfail: the manual command exits 1 (the one thing it exists to do did not happen)"
else fail "msyncfail: the manual command exits 1" "rc=$rc: '$out'"; fi
if [[ "$out" == *"may still read stale"* ]]; then ok "…naming what is still stale, as before"
else fail "…naming what is still stale" "$out"; fi
sleep 1; printf 'UNSTABLE\n' > "$WORKSPACE_DIR/one"
SSH_OUT="ok=1 unstable=1"
out="$( cmd_refresh_macos 2>&1 )"; rc=$?
if [[ $rc -eq 0 ]]; then ok "unstable alone: reported, but exits 0 — a live host writer is not a refresh failure"
else fail "unstable alone exits 0" "rc=$rc — a running build would make every manual refresh 'fail': '$out'"; fi
if [[ "$out" == *"unstable=1"* ]]; then ok "…and is still surfaced, so the operator can judge it"
else fail "…and is still surfaced" "$out"; fi
SSH_OUT="ok=3"

# Under `off` it must SAY so. An operator who watched a manual refresh succeed in silence could
# reasonably conclude that `off` had stopped applying — a freshness mechanism whose state the
# operator cannot see is #148's defect with a different cause. The line is run-scoped on purpose and
# must not claim anything about a loop an earlier `up` may still be running; `status --macos`
# measures that half.
_MACOS_REFRESH_MODE=off
sleep 1; printf 'OFFNOTE\n' > "$WORKSPACE_DIR/one"
out="$( cmd_refresh_macos 2>&1 )"
if [[ "$out" == *"off"* ]]; then ok "off: the manual run says the automatic refresh is still off"
else fail "off: the manual run says the automatic refresh is still off" "a silent success reads as \`off\` having lapsed: '$out'"; fi
if [[ "$out" == *"manual sweep"* ]]; then ok "…and that THIS run is the manual exception"
else fail "…and that this run is the manual exception" "$out"; fi
_MACOS_REFRESH_MODE=continuous
out="$( cmd_refresh_macos 2>&1 )"
if [[ "$out" != *"manual sweep"* ]]; then ok "continuous: no such line (it would be noise on the default path)"
else fail "continuous: no such line" "$out"; fi

# THE PAIR THAT MATTERS. Same mode, same edit, two entry points, opposite outcomes — this is the
# whole of "reach the sweep past the gate without punching a hole in it". Either arm alone passes on
# a version that got the other backwards: a manual command wired to the GATED entry point sweeps
# nothing under `off`, and a gate deleted to let it through re-enables all five automatic callers.
_MACOS_REFRESH_MODE=off
sleep 1; printf 'PAIRED\n' > "$WORKSPACE_DIR/one"
: > "$SSHLOG"
refresh_macos_shares "$VM" >/dev/null 2>&1
if [[ ! -s "$SSHLOG" ]]; then ok "off: the AUTOMATIC entry point is still gated (all five callers use it)"
else fail "off: the automatic entry point is still gated" "the gate was opened for everybody, not just the manual run"; fi
: > "$SSHLOG"; : > "$STDINLOG"
cmd_refresh_macos >/dev/null 2>&1
if [[ -s "$SSHLOG" ]]; then ok "…and the manual command sweeps the very same edit, in the very same mode"
else fail "…and the manual command sweeps the same edit" "the manual path is going through the gate, so \`off\` still has no way out"; fi
if fed | grep -qx "/Volumes/My Shared Files/${MACOS_SHARE}/one"; then ok "…and it is the edit the gated call refused, not some other file"
else fail "…and it is the edit the gated call refused" "$(fed | tr '\n' ' ')"; fi

# THE AUTOMATIC CALLERS, driven for real under `off` — the dynamic half of the count arms below.
# Everything above calls refresh_macos_shares DIRECTLY, so all of it would stay green on an augur
# whose attach commands had been rewired to the ungated entry point: the gate would be intact and
# nobody would be going through it. These two arms are the ones that would go red, because they run
# the command functions the operator actually types. (`up` is not among them: its two call sites sit
# inside a bring-up this suite may not run — the structural count below is what covers them, and it
# is why that count must match a bare name.)
_saved_clock="$(declare -f sync_macos_guest_clock)"
_saved_stop="$(declare -f stop_share_refresher)"
_saved_ws="$(declare -f ensure_macos_workspace)"
_saved_cp="$(declare -f ensure_macos_claude_projects)"
_saved_ca="$(declare -f ensure_macos_claude_agents)"
_saved_cprof="$(declare -f ensure_macos_claude_profile)"
_saved_wstale="$(declare -f warn_if_macos_profile_stale)"
_saved_wpin="$(declare -f warn_if_macos_egress_pinned)"
_saved_cbin="$(declare -f ensure_macos_claude_bin)"
sync_macos_guest_clock()        { :; }
stop_share_refresher()          { :; }
ensure_macos_workspace()        { :; }
ensure_macos_claude_projects()  { :; }
ensure_macos_claude_agents()    { :; }
ensure_macos_claude_profile()   { :; }
warn_if_macos_profile_stale()   { :; }
warn_if_macos_egress_pinned()   { :; }
ensure_macos_claude_bin()       { :; }
swept() { grep -q 'python3 -c' "$SSHLOG"; }   # the sweep's round trip, not the launch's
for _cmd in cmd_claude_macos cmd_shell_macos; do
    _MACOS_REFRESH_MODE=off
    sleep 1; printf 'ATTACH-OFF-%s\n' "$_cmd" > "$WORKSPACE_DIR/one"
    : > "$SSHLOG"
    "$_cmd" >/dev/null 2>&1
    if ! swept; then ok "off: $_cmd (VM already running) makes no sweep round trip"
    else fail "off: $_cmd makes no sweep round trip" "an automatic call site is reaching the sweep past the mode gate"; fi
    # THE CONTROL, in the same fixture: without it the arm above passes on a stub that never sweeps
    # in any mode, which is precisely how a whole section goes green while testing nothing.
    _MACOS_REFRESH_MODE=continuous
    : > "$SSHLOG"
    "$_cmd" >/dev/null 2>&1
    if swept; then ok "…and control: the same call sweeps under \`continuous\`"
    else fail "control: $_cmd sweeps under continuous" "the arm above is green because this path never sweeps at all"; fi
done
eval "$_saved_clock"; eval "$_saved_stop"; eval "$_saved_ws"; eval "$_saved_cp"; eval "$_saved_ca"
eval "$_saved_cprof"; eval "$_saved_wstale"; eval "$_saved_wpin"; eval "$_saved_cbin"

eval "$_saved_up"; eval "$_saved_vz"; eval "$_saved_pvm"
eval "$_saved_running"; eval "$_saved_sshhost"
_MACOS_REFRESH_MODE="$_saved_mode"

section "the ungated entry point has exactly two callers"

# The structural half of the pair above, and the one that catches the SIXTH call site — the failure
# this whole gate arrangement exists to prevent. A `force` argument on the gated function was
# rejected precisely so that a bypass has to be visible in the CALL: this is that check, and it is
# why the name matters more than the mechanism.
#
# It counts the BARE NAME, not `name "`. The first cut of this arm required the call to be followed
# by a space and a double quote, and a sixth caller written the way half this file's neighbours are
# written —
#     refresh_macos_shares_now $project_vm
# — was therefore not counted at all: inserted into cmd_up_macos's already-running branch it left
# this file at 101/101 green while `--share-refresh off` was silently bypassed on an automatic path.
# Measured, not deduced. shellcheck would flag the unquoted expansion (SC2086) and shellcheck is not
# installed and cannot be here, so this arm is the whole of the defence. The definition line is
# excluded by name; comments are excluded by the `^ *#` filter the counter already applies.
count_in() { awk -v a="$1" -v b="$2" -v n="$3" 'NR>=a && NR<=b && index($0,n)>0 && $0 !~ /^ *#/ {c++} END{print c+0}' "$AUGUR"; }
count_call_now() { awk -v a="$1" -v b="$2" '
    NR>=a && NR<=b && index($0,"refresh_macos_shares_now")>0 && $0 !~ /^ *#/ &&
    $0 !~ /refresh_macos_shares_now\(\)/ {c++} END{print c+0}' "$AUGUR"; }
_lines="$(wc -l < "$AUGUR")"
read -r _gs _ge <<<"$(fn_range refresh_macos_shares)"
read -r _cs _ce <<<"$(fn_range cmd_refresh_macos)"
if [[ -n "$_gs" && -n "$_cs" && "$_ge" -gt "$_gs" && "$_ce" -gt "$_cs" ]]; then
    ok "both functions are locatable (gate ${_gs}-${_ge}, command ${_cs}-${_ce})"
else fail "both functions are locatable" "gate=$_gs-$_ge command=$_cs-$_ce — every arm below would be vacuous"; fi
# Self-check on the counter itself, because an arm that counts nothing at all also reports "2" for
# nothing and would go green on a file that had lost both calls.
if [[ "$(count_call_now 1 "$_lines")" -gt 0 && "$(count_in 1 "$_lines" 'refresh_macos_shares_now')" -gt "$(count_call_now 1 "$_lines")" ]]; then
    ok "the call counter matches bare names and still excludes the definition and the comments"
else fail "the call counter matches bare names" "it found $(count_call_now 1 "$_lines") calls against $(count_in 1 "$_lines" 'refresh_macos_shares_now') total mentions — the needle is wrong, and every arm below is decoration"; fi
_all="$(count_call_now 1 "$_lines")"
if [[ "$_all" == "2" ]]; then ok "refresh_macos_shares_now is called exactly twice in the whole file"
else fail "refresh_macos_shares_now is called exactly twice" "found $_all — every extra call is a caller that skips \`--share-refresh off\` silently"; fi
if [[ "$(count_call_now "$_gs" "$_ge")" == "1" ]]; then ok "…once from the gate itself, which is what the five automatic callers reach"
else fail "…once from the gate itself" "lines $_gs-$_ge"; fi
if [[ "$(count_call_now "$_cs" "$_ce")" == "1" ]]; then ok "…and once from cmd_refresh_macos, the only caller allowed past the mode check"
else fail "…and once from cmd_refresh_macos" "lines $_cs-$_ce"; fi
# The gate must still be IN the gate. A wrapper that forgot the predicate would leave every arm above
# green while `off` did nothing at all, at all five automatic call sites.
if [[ "$(count_in "$_gs" "$_ge" 'share_refresh_enabled')" == "1" ]]; then ok "…and the mode check is still inside the gate, not moved out to the call sites"
else fail "the mode check is still inside the gate" "lines $_gs-$_ge"; fi
if [[ "$(count_in "$_cs" "$_ce" 'cmd_up_macos')" == "0" ]]; then ok "cmd_refresh_macos contains no path to cmd_up_macos at all"
else fail "cmd_refresh_macos contains no path to cmd_up_macos" "found $(count_in "$_cs" "$_ce" 'cmd_up_macos') — \`refresh\` must not boot a VM"; fi
if [[ "$(count_in "$_cs" "$_ce" 'quiet')" == "0" ]]; then ok "…and passes no \`quiet\`, so the operator gets the report"
else fail "…and passes no \`quiet\`" "only the unattended loop may suppress the sweep's own output"; fi
# The ADR-0014 containment guard. It is called from INSIDE this command rather than from the shared
# dispatch gate (the reasons are at the function and at that gate), which means the gate's own
# coverage arm cannot see it — so it is pinned here. Deleting the line left this file at 101/101.
if [[ "$(count_in "$_cs" "$_ce" 'require_safe_workspace')" == "1" ]]; then ok "…and it still calls require_safe_workspace itself, which nothing else does for it"
else fail "cmd_refresh_macos calls require_safe_workspace" "found $(count_in "$_cs" "$_ce" 'require_safe_workspace') — \`refresh\` is not in the dispatch-tail gate, so a missing call here is no guard at all"; fi

section "the command is wired in BOTH dispatch blocks"

# The macOS arm is structural, and deliberately so: the dynamic half would mean running `bash augur
# refresh --macos` as a subprocess, which the surrounding sections avoid for the macOS paths for the
# same reason tests/43 states — nothing in this suite may reach a VM backend. Both arms are anchored
# INSIDE the block they are about (`up)` is the landmark for each), so neither can pass on a comment
# or on the wrong case. The CONTAINER arm is dynamic as well as structural: that path is hermetic
# (it is reached before any engine check, and `refresh` is not in the dispatch-tail workspace gate),
# and a grep for the message text is exactly the kind of arm the brief warns about — deleting the
# `exit 1` beside it left this file at 101/101 green while `augur refresh` in container mode printed
# an error to stderr and exited 0. Measured.
_disp_m="$(awk 'index($0,"up)             cmd_up_macos ;;")>0 {print NR; exit}' "$AUGUR")"
_disp_c="$(awk 'index($0,"up)             cmd_up ;;")>0 {print NR; exit}' "$AUGUR")"
if [[ -n "$_disp_m" && -n "$_disp_c" && "$_disp_c" -gt "$_disp_m" ]]; then ok "both dispatch blocks are locatable (macOS ${_disp_m}, container ${_disp_c})"
else fail "both dispatch blocks are locatable" "macos=$_disp_m container=$_disp_c"; fi
_rd="$(awk 'index($0,"refresh)        cmd_refresh_macos ;;")>0 && $0 !~ /^ *#/ {print NR; exit}' "$AUGUR")"
if [[ -n "$_rd" && "$_rd" -gt "$_disp_m" && "$_rd" -lt "$_disp_c" ]]; then ok "\`refresh\` dispatches to cmd_refresh_macos, in the macOS block"
else fail "\`refresh\` dispatches to cmd_refresh_macos in the macOS block" "found at line ${_rd:-none}, macos=$_disp_m container=$_disp_c"; fi
# Container mode: a NAMED refusal, not "Unknown command: 'refresh'" — which would be true of that
# dispatch and false of augur. The defect is in the macOS guest's virtiofs CLIENT, not in virtiofs:
# a Linux container guest over the same kind of mount sees host edits live (ADR-0016 §1).
_rc2="$(awk -v a="${_disp_c:-0}" 'NR>a && index($0,"macOS VM mode only")>0 && $0 !~ /^ *#/ {print NR; exit}' "$AUGUR")"
if [[ -n "$_rc2" ]]; then ok "container mode refuses \`augur refresh\` by name and says where it lives"
else fail "container mode refuses \`augur refresh\` by name" "it would fall through to \"Unknown command\", which is not what is wrong"; fi
_cont="$( cd "$TMPD" && bash "$AUGUR" refresh 2>&1 )"; _crc=$?
if [[ $_crc -eq 1 ]]; then ok "…and REFUSES it: rc=1, not an error printed over a success"
else fail "container mode exits 1 on \`augur refresh\`" "rc=$_crc — a script that checks the status is told the refresh happened: '$_cont'"; fi
if [[ "$_cont" == *"--macos"* ]]; then ok "…naming the command line that does exist"
else fail "…naming the command line that does exist" "$_cont"; fi
if [[ "$_cont" != *"CONTAINER MODE"* ]]; then ok "…without printing the whole help over it (install-cert's voice)"
else fail "…without printing the whole help" "say what to type; the command list is not the answer to a one-line mistake"; fi
if grep -q 'augur ${CYAN}refresh${RESET} --macos' "$AUGUR"; then ok "…and \`--help\` lists it among the macOS commands"
else fail "…and \`--help\` lists it" "a command nobody can discover does not close the gap it was written for"; fi

finish
