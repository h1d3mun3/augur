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
out="$(printf '%s\0' "$TMPD/real/a" | python3 "$PROG" 0 2>&1)"
if [[ "$out" == "unstable=1" ]]; then ok "the retry bound is taken from the argument, not hardcoded"
else fail "the retry bound is taken from the argument" "with 0 tries expected unstable=1, got '$out'"; fi
out="$(printf '%s\0' "$TMPD/real/a" | python3 "$PROG" 1 2>&1)"
if [[ "$out" == "ok=1" ]]; then ok "…and one try is enough for a file whose size is stable"
else fail "one try is enough for a stable file" "got '$out'"; fi

out="$(printf '\0\0' | python3 "$PROG" 3 2>&1)"
if [[ -z "${out// /}" ]]; then ok "an empty list is a clean no-op"
else fail "an empty list is a clean no-op" "got '$out'"; fi

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
if tail -1 "$SSHLOG" | grep -q " ${_MACOS_SWEEP_TRIES}$"; then ok "the configured retry count is the final argument"
else fail "the configured retry count is the final argument" "$(tail -1 "$SSHLOG")"; fi

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

finish
