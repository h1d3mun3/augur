#!/usr/bin/env bash
# Tier 0 — the shell scripts augur runs on a Mac stay parseable by macOS's /bin/bash 3.2. No
# container, no VM; runs anywhere.
#
# bash 3.2 reads a command substitution "$(...)" by counting parentheses, without parsing the case
# statements or heredocs inside it, so the `)` that ends a case pattern written without a leading
# `(` ends the substitution early and the rest of the file fails to parse. bash 4+ parses it fine,
# so Linux CI cannot see it. This is a static check for that one shape: a case pattern with no
# leading `(` inside
#   - a heredoc opened on a line after a "$(" (as in `x="$(cat <<EOF`),
#   - a multi-line "$(" region (a line ending in "$(", up to a line starting with ")"),
#   - or the rest of a line after a "$(".
# The fix is a leading `(` on every pattern (`(/*)`), or, better, moving the code out of the
# substitution (a function that prints the heredoc, called as "$(fn)").
# Known gap: it is line-based. A substitution opened mid-line that runs over several lines without
# a heredoc, or backquotes, are not scanned.
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/lib.sh"

# comsub_case_hits FILE: print FILE:LINE: TEXT for every hit.
comsub_case_hits() {
    awk -v q="'" '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    function hit() { printf "%s:%d: %s\n", FILENAME, FNR, $0 }
    # pat S: S starts a case pattern list; a `)` with no leading `(` is a hit.
    function pat(s) { s = trim(s); if (s != "" && substr(s, 1, 1) != "(" && index(s, ")")) hit() }
    # scan S: one line of text inside a substitution, keeping the case state across lines.
    function scan(s,    t, i, rest) {
        t = trim(s)
        if (t == "" || substr(t, 1, 1) == "#") return
        if (match(s, /(^|[^A-Za-z0-9_])case[ \t]/)) {
            rest = substr(s, RSTART + RLENGTH)
            if (match(rest, /[ \t]in([ \t]|$)/)) {
                incase = 1; expect = 0
                rest = substr(rest, RSTART + RLENGTH)
                if (trim(rest) == "") expect = 1; else pat(rest)
                s = rest
            }
        } else if (incase) {
            if (t ~ /^esac([^A-Za-z0-9_]|$)/) { incase = 0; expect = 0; return }
            if (expect) { pat(t); expect = 0 }
        }
        if (!incase) return
        rest = s
        while ((i = index(rest, ";;")) > 0) {
            rest = substr(rest, i + 2)
            t = trim(rest)
            if (t == "") { expect = 1; break }
            if (t ~ /^esac([^A-Za-z0-9_]|$)/) { incase = 0; expect = 0; break }
            pat(t)
        }
    }
    FNR == 1 { doc = ""; multi = 0; incase = 0; expect = 0 }
    doc != "" {
        t = $0; if (dash) sub(/^\t+/, "", t)
        if (t == doc) { doc = ""; if (!multi) incase = 0; next }
        if (comsub_doc) scan($0)
        next
    }
    {
        line = $0
        # A heredoc opened on this line: is it inside a "$(" that opens earlier on the line?
        if (match(line, "<<-?[ \t]*[\"" q "]?[A-Za-z_][A-Za-z0-9_]*[\"" q "]?")) {
            w = substr(line, RSTART, RLENGTH); before = substr(line, 1, RSTART - 1)
            dash = (substr(w, 3, 1) == "-")
            sub(/^<<-?[ \t]*/, "", w); gsub("[\"" q "]", "", w)
            doc = w; comsub_doc = multi || index(before, "$(") > 0
            if (index(before, "$(")) scan(substr(before, index(before, "$(") + 2))
            next
        }
        if (multi) {
            if (trim(line) ~ /^\)/) { multi = 0; incase = 0; next }
            scan(line); next
        }
        if (line ~ /\$\([ \t]*$/) { multi = 1; incase = 0; next }
        if (index(line, "$(")) { oneline(line); incase = 0 }
    }
    # oneline S: scan S from the first `case` that sits inside a "$(" still open at that point.
    # Single-quoted text is skipped, as bash 3.2 skips it while counting.
    function oneline(s,    n, i, c, depth, sq) {
        n = length(s); depth = 0; sq = 0
        for (i = 1; i <= n; i++) {
            c = substr(s, i, 1)
            if (sq) { if (c == q) sq = 0; continue }
            if (c == "\\") { i++; continue }
            if (c == q && depth > 0) { sq = 1; continue }
            if (c == "$" && substr(s, i + 1, 1) == "(") { depth++; i++; continue }
            if (depth > 0 && c == "(") depth++
            else if (depth > 0 && c == ")") depth--
            else if (depth > 0 && substr(s, i, 4) == "case" && substr(s, i + 4, 1) ~ /[ \t]/ \
                     && (i == 1 || substr(s, i - 1, 1) !~ /[A-Za-z0-9_]/)) { scan(substr(s, i)); return }
        }
    }
    ' "$1"
}

section "Tier 0 — the detector"
_tmp="$(mktemp -d)"; trap 'rm -rf "$_tmp"' EXIT
_bad=(
    'x="$(cat <<EOF
for p in $PATH; do case "$p" in /*) echo "$p" ;; esac; done
EOF
)"'
    'x=$(case "$a" in b) echo b ;; esac)'
    'x="$(
    case "$a" in
        b|c) echo b ;;
    esac
)"'
    'x="$(cat <<-"EOF"
	case "$a" in
	    (b) echo b ;;
	    *) echo other ;;
	esac
	EOF
)"'
)
_good=(
    'x="$(cat <<EOF
for p in $PATH; do case "$p" in (/*) echo "$p" ;; esac; done
EOF
)"'
    'f() {
    cat <<EOF
case "$p" in /*) echo "$p" ;; esac
EOF
}
x="$(f)"'
    'case "$(uname)" in Darwin) echo mac ;; esac'
    'x="$(uname)"
case "$x" in
    Darwin) echo mac ;;
esac'
    'x=$(case "$a" in (b) echo b ;; (*) echo c ;; esac)'
)
_i=0
for _s in "${_bad[@]}"; do
    _i=$((_i + 1)); printf '%s\n' "$_s" > "$_tmp/bad$_i"
    if [[ -n "$(comsub_case_hits "$_tmp/bad$_i")" ]]; then ok "flags bad sample $_i"
    else fail "does not flag bad sample $_i" "$_s"; fi
done
_i=0
for _s in "${_good[@]}"; do
    _i=$((_i + 1)); printf '%s\n' "$_s" > "$_tmp/good$_i"
    eq "" "$(comsub_case_hits "$_tmp/good$_i")" "passes good sample $_i"
done

section "Tier 0 — no case pattern without a leading ( inside a \$(...) in the scripts a Mac runs"
cd "$REPO" || exit 1
for _f in augur install agents/*.sh completions/augur.bash tests/*.sh; do
    [[ "$_f" == "tests/${0##*/}" ]] && continue   # its own samples are bad on purpose
    [[ -f "$REPO/$_f" ]] || { fail "$_f exists"; continue; }
    eq "" "$(comsub_case_hits "$_f")" "$_f"
done

finish
