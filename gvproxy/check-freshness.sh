#!/usr/bin/env bash
# gvproxy/check-freshness.sh
#
# Detect whether augur's pinned gvproxy fork base has fallen behind upstream in a
# way that MATTERS — not raw commit count (that is mostly tools/vendor churn), but:
#   - the augur patch no longer applies cleanly to upstream main, or
#   - it applies, but the patched tree no longer type-checks or passes its tests
#     (`go vet` for darwin/arm64 and native `go test` on every package the patch
#     touches — see patched_tests()), or
#   - upstream's own code that is compiled into the shipped binary changed, or
#   - a dependency that is linked into the shipped binary moved, or
#   - a go.mod setting that changes how the binary is built moved.
#
# "Shipped" is whatever `go list -deps ./cmd/gvproxy` (darwin/arm64, with the augur
# patch applied) reaches, at the pin or at main:
#   - upstream's own files count when they sit in a package directory it reaches (or
#     are embedded by one) — see shipped_code(). A new directory such as internal/
#     is covered as soon as gvproxy imports it; test/, contrib/, tools/ never are.
#   - a dependency counts when its module is in the graph — see build_graph().
#     Test-only and tooling modules (gomega, ginkgo, linters) sit in vendor/ but never
#     reach the binary, so their bumps are noise. Comparing module versions of the
#     whole graph, not just "which module did the commit bump", also catches a
#     test-only bump that drags a shared module (e.g. golang.org/x/net) along.
#
# Prints a human report, writes a Markdown issue body to $BODY_FILE, and exits
# non-zero when action is warranted so a daily GitHub Actions cron can open/refresh
# a tracking issue. Severities are TEXT (no emoji — some renderers drop glyphs):
#
#   ACTION   patch no longer applies cleanly to main, or applies
#            but the patched tree fails go vet / go test where
#            unpatched main passes                               (exit 1)
#   REVIEW   security/code/dependency change in the shipped tree (exit 1)
#   NOISE    behind, but nothing that reaches the shipped binary (exit 0)
#   CURRENT  pin is at upstream main                             (exit 0)
#
# Usage:   bash gvproxy/check-freshness.sh [--run-patched-tests | --use-patched-tests-result]
#
#   (no option)                 Everything in one process: the drift check AND the
#                               patched-tree go vet/go test. For a local run. go test
#                               executes upstream's unreviewed test code with your
#                               privileges.
#   --run-patched-tests         Only the patched-tree go vet/go test, for a job that holds
#                               no token: resolves upstream main with `git ls-remote` (no
#                               gh), writes the go output to $TESTS_LOG_FILE (default
#                               ./gvproxy-patched-tests.log), prints and, with
#                               GITHUB_OUTPUT, emits `state=` and `sha=` (the upstream
#                               commit tested). Always exits 0: the state is the result.
#   --use-patched-tests-result  The drift check without running go vet/go test: takes the
#                               result of a --run-patched-tests run as plain data from
#                               TESTS_STATE, TESTS_SHA and TESTS_LOG_FILE. A state that is
#                               not one patched_tests() prints, or a commit other than the
#                               upstream main this run resolved, counts as `unavailable`.
#
# Requires: gh (authenticated: GH_TOKEN or `gh auth login`), git, go; --run-patched-tests
#           needs only git and go.
#           Without a working go the build graph is skipped: any change under
#           cmd/gvproxy/ or pkg/, and any go.mod/go.sum/vendor change, counts as
#           shipped (fails toward REVIEW). The patched-tree vet/test is skipped
#           too, and the issue body says it did not run.
# Honors:   BODY_FILE  (where to write the Markdown issue body; default ./gvproxy-freshness-body.md)
#           GITHUB_OUTPUT (if set, writes severity=/title= for the workflow)
set -euo pipefail

MODE=all
case "${1:-}" in
  "")                         ;;
  --run-patched-tests)        MODE=run-tests ;;
  --use-patched-tests-result) MODE=use-result ;;
  *) echo "usage: check-freshness.sh [--run-patched-tests | --use-patched-tests-result]" >&2; exit 2 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_SH="$SCRIPT_DIR/build.sh"
PATCH="$SCRIPT_DIR/augur-egress.patch"
BODY_FILE="${BODY_FILE:-$PWD/gvproxy-freshness-body.md}"

if [ "$MODE" != run-tests ]; then
  command -v gh >/dev/null || { echo "check-freshness: gh not found" >&2; exit 2; }
fi
command -v git >/dev/null || { echo "check-freshness: git not found" >&2; exit 2; }

PIN="$(grep -E '^PIN=' "$BUILD_SH" | head -1 | cut -d'"' -f2)"
REPO_URL="$(grep -E '^REPO=' "$BUILD_SH" | head -1 | cut -d'"' -f2)"
SLUG="${REPO_URL#https://github.com/}"; SLUG="${SLUG%.git}"
[ -n "$PIN" ] && [ -n "$SLUG" ] || { echo "check-freshness: could not read PIN/REPO from $BUILD_SH" >&2; exit 2; }

emit() {  # severity  title
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    { echo "severity=$1"; echo "title=$2"; } >> "$GITHUB_OUTPUT"
  fi
}

fetch_tree() {  # dir sha — shallow checkout of one upstream commit
  git init --quiet "$1" &&
    git -C "$1" fetch --quiet --depth 1 "$REPO_URL" "$2" &&
    git -C "$1" checkout --quiet FETCH_HEAD
}

# Modules linked into the shipped binary, one "path@version[ => replacement]" per line.
# Leaves out the main module itself; its files are matched by shipped_code().
build_graph() {  # dir
  list_deps "$1" '{{with .Module}}{{if not .Main}}{{.Path}}@{{.Version}}{{with .Replace}} => {{.Path}}@{{.Version}}{{end}}{{end}}{{end}}' | sort -u
}

# Upstream's own files that go into the binary, repo-relative: "D <dir>" for every
# main-module package the build reaches, "F <file>" for each file such a package
# embeds (//go:embed can reach into subdirectories).
shipped_code() {  # dir
  list_deps "$1" '{{with .Module}}{{if .Main}}{{.Path}} {{$.ImportPath}}{{range $.EmbedFiles}} {{.}}{{end}}{{end}}{{end}}' |
    awk 'NF >= 2 {
      rel = ($2 == $1) ? "." : substr($2, length($1) + 2)
      print "D " rel
      for (i = 3; i <= NF; i++) print "F " (rel == "." ? $i : rel "/" $i)
    }' | sort -u
}

# `go list -deps ./cmd/gvproxy` with a template, for the darwin/arm64 build (what augur
# ships, matching build.sh) whatever the host OS. go list only reads upstream's sources and
# module files and runs none of its code, so the drift check runs it where the token is.
list_deps() {  # dir template
  ( cd "$1" &&
      GOTOOLCHAIN=auto GOFLAGS=-mod=vendor GOOS=darwin GOARCH=arm64 CGO_ENABLED=1 \
      go list -deps -f "$2" ./cmd/gvproxy )
}

# go.mod minus its require lines: the go/toolchain/godebug/replace/exclude settings
# that change the build without any import changing. Requires are covered by
# build_graph().
build_settings() {  # go.mod
  awk '
    /^require[ \t]*\(/ { inreq = 1; next }
    inreq && /^\)/     { inreq = 0; next }
    inreq              { next }
    /^require[ \t]/    { next }
    /^[ \t]*(\/\/.*)?$/ { next }
    { print }
  ' "$1"
}

# "path version" for every vendored module, to name the bumps that stay out of the binary.
vendored_modules() {  # dir
  awk '/^# / { print $2, $3 }' "$1/vendor/modules.txt" | LC_ALL=C sort -u
}

# Package directories the augur patch touches, as "./dir" (or "."), one per line: the
# directory of every .go file named by a `diff --git` header (new, changed and
# deleted files alike, so a package whose test file the patch edits is included).
patched_pkgs() {
  sed -n 's|^diff --git a/.* b/\(.*\.go\)$|\1|p' "$PATCH" |
    awk '{ d = $0; if (!sub(/\/[^\/]*$/, "", d)) d = "."; print (d == "." ? "." : "./" d) }' |
    sort -u
}

# Patched package directories that hold Go files in tree $1 (a directory the patch
# names but upstream has emptied or removed is left out).
existing_pkgs() {  # dir
  local p f
  while IFS= read -r p; do
    for f in "$1/$p"/*.go; do
      if [ -e "$f" ]; then echo "$p"; fi
      break
    done
  done < <(patched_pkgs)
}

# One step of the patched-tree check in tree $1: `vet` type-checks, test files included,
# for the darwin/arm64 build augur ships; `test` runs the tests natively. Same vendored
# build and toolchain selection as list_deps().
# `go test` executes upstream main's unreviewed test code with this process's privileges,
# network and filesystem, and it can read its parent processes' environment. So in CI it
# runs only under --run-patched-tests, in a job with no token, no permissions and no
# persisted credentials, whose result the job that files the issue reads as data. Unsetting
# the token variables below is defense in depth only, not a boundary.
# Accepted trade-off: vet runs with CGO_ENABLED=0. Cross-type-checking with cgo on a Linux
# runner would need a darwin C toolchain; the packages the patch touches are pure Go, and
# the shipped binary is still built and tested on a Mac before a re-pin.
go_step() {  # dir vet|test pkg...
  local dir="$1" step="$2"; shift 2
  ( cd "$dir" || exit 1
    unset GH_TOKEN GITHUB_TOKEN GITHUB_OUTPUT
    export GOTOOLCHAIN=auto GOFLAGS=-mod=vendor
    case "$step" in
      vet)  GOOS=darwin GOARCH=arm64 CGO_ENABLED=0 go vet "$@" ;;
      # -timeout bounds each test binary, so a hung test fails the run instead of stalling it.
      test) go test -count=1 -timeout 10m "$@" ;;
    esac )
}

# Does patched tree $1 still type-check and pass its tests? The patch can apply cleanly
# yet break a call site or a test upstream added since the pin, which `go list` alone
# never compiles. Runs `vet`, then `test`, on every package the patch touches; writes the
# go output to $2 and prints one of:
#   pass                       both steps passed
#   fail-vet | fail-test       that step fails on the patched tree only
#   upstream-vet|upstream-test that step fails on unpatched main too, so the failure is
#                              not the patch's (a new vet check in a newer Go, a flaky or
#                              runner-dependent upstream test)
#   none                       no package the patch touches has Go files any more
#   unavailable                go cannot run in the tree (e.g. GOTOOLCHAIN=auto could not
#                              fetch the Go that go.mod asks for)
# Accepted trade-off: a failure the patch causes in a step that unpatched main already
# fails is reported as upstream-*, not graded; it shows once upstream is fixed.
patched_tests() {  # dir log
  local pkgs=() base=() p step
  while IFS= read -r p; do pkgs+=("$p"); done < <(existing_pkgs "$1")
  : > "$2"
  if [ "${#pkgs[@]}" -eq 0 ]; then echo none; return 0; fi
  if ! ( cd "$1" && GOTOOLCHAIN=auto GOFLAGS=-mod=vendor go version ) >/dev/null 2>&1; then
    echo unavailable; return 0
  fi
  for step in vet test; do
    if ! go_step "$1" "$step" "${pkgs[@]}" >> "$2" 2>&1; then
      # Same step on an unpatched checkout of the same commit.
      if git -C "$1" worktree add --quiet --detach "$WORK/base" HEAD >/dev/null 2>&1; then
        while IFS= read -r p; do base+=("$p"); done < <(existing_pkgs "$WORK/base")
        if [ "${#base[@]}" -gt 0 ] && ! go_step "$WORK/base" "$step" "${base[@]}" >/dev/null 2>&1; then
          echo "upstream-$step"; return 0
        fi
      fi
      echo "fail-$step"; return 0
    fi
  done
  echo pass
}

# The failing part of a patched_tests() log for the issue body: no "ok"/"no test files"
# lines, at most 40 lines of at most 200 characters, control characters blanked and every
# backtick turned into a quote so the excerpt cannot close its code block. Reads at most
# 1 MiB of the log. awk reads all of what head passes it, so a long log cannot end the
# pipeline early under pipefail. The log may come from the tokenless test job, so this is
# the trusted side's own sanitizing; it does not rely on that job's.
failure_excerpt() {  # log
  head -c 1048576 "$1" |
    awk '/^(ok |\?   )/ { next } n < 40 { gsub(/[[:cntrl:]]/, " "); gsub(/`/, "\047"); print substr($0, 1, 200); n++ }'
}

# --use-patched-tests-result: take the tokenless job's result (IN_TESTS_*) as data. Sets
# TESTS_STATE to one of the values patched_tests() prints, or to unavailable (with
# TESTS_NOTE saying why) when the state is not one of them or the commit tested is not
# the upstream main this run resolved (main moved between the jobs, or the job failed).
# Uses the log only when it is a regular file, never a symlink.
check_tests_result() {
  case "$IN_TESTS_STATE" in
    pass|fail-vet|fail-test|upstream-vet|upstream-test|none|unavailable) ;;
    *) TESTS_STATE=unavailable; TESTS_NOTE="the test job's result is missing or not a known state"; return 0 ;;
  esac
  if [ "$IN_TESTS_SHA" != "$MAIN_SHA" ]; then
    TESTS_STATE=unavailable
    if printf '%s' "$IN_TESTS_SHA" | grep -qE '^[0-9a-f]{40}$'; then
      TESTS_NOTE="the test job tested upstream \`${IN_TESTS_SHA:0:8}\`, not \`$SHORT_MAIN\`"
    else
      TESTS_NOTE="the test job did not report a valid upstream commit"
    fi
    return 0
  fi
  TESTS_STATE="$IN_TESTS_STATE"
  if [ "$TESTS_STATE" = unavailable ]; then TESTS_NOTE="no working go in the test job"; fi
  if [ -n "$IN_TESTS_LOG" ] && [ -f "$IN_TESTS_LOG" ] && [ ! -L "$IN_TESTS_LOG" ]; then
    TESTS_LOG="$IN_TESTS_LOG"
  fi
}

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# --run-patched-tests: patch upstream main and run patched_tests() on it, nothing else.
# This is the only part of the check that executes upstream code, so the workflow runs
# it in a job with no token and no permissions; it reports back only data.
if [ "$MODE" = run-tests ]; then
  log="${TESTS_LOG_FILE:-$PWD/gvproxy-patched-tests.log}"
  : > "$log"
  state=unavailable
  sha="$(git ls-remote "$REPO_URL" refs/heads/main 2>/dev/null | awk 'NR == 1 { print $1 }')"
  if printf '%s' "$sha" | grep -qE '^[0-9a-f]{40}$' && fetch_tree "$WORK/main" "$sha" 2>/dev/null; then
    if ! git -C "$WORK/main" apply "$PATCH" 2>/dev/null; then
      state=skipped
    elif command -v go >/dev/null; then
      state="$(patched_tests "$WORK/main" "$log")"
    fi
  else
    sha=""
  fi
  echo "patched tests: $state   upstream main: ${sha:-unresolved}   log: $log"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    { echo "state=$state"; echo "sha=$sha"; } >> "$GITHUB_OUTPUT"
  fi
  exit 0
fi

# Inputs for --use-patched-tests-result (data from the tokenless job; see check_tests_result()).
IN_TESTS_STATE="${TESTS_STATE:-}"; IN_TESTS_SHA="${TESTS_SHA:-}"; IN_TESTS_LOG="${TESTS_LOG_FILE:-}"

read -r MAIN_SHA MAIN_DATE < <(gh api "repos/$SLUG/commits/main" --jq '"\(.sha) \(.commit.committer.date[0:10])"')
PIN_DATE="$(gh api "repos/$SLUG/commits/$PIN" --jq '.commit.committer.date[0:10]')"
SHORT_PIN="${PIN:0:8}"; SHORT_MAIN="${MAIN_SHA:0:8}"

# Already current — nothing moved.
if [ "$PIN" = "$MAIN_SHA" ]; then
  echo "SEVERITY: CURRENT — gvproxy pin $SHORT_PIN is at upstream main ($MAIN_DATE)."
  emit CURRENT ""
  exit 0
fi

CMP="repos/$SLUG/compare/$PIN...$MAIN_SHA"
AHEAD="$(gh api "$CMP" --jq '.ahead_by')"
# while-read rather than mapfile so this also runs on macOS's stock bash 3.2.
FILES=();   while IFS= read -r l; do FILES+=("$l");   done < <(gh api "$CMP" --jq '.files[].filename' 2>/dev/null || true)
COMMITS=(); while IFS= read -r l; do COMMITS+=("$l"); done < <(gh api "$CMP" --jq '.commits[] | "\(.sha[0:8])\t\(.commit.committer.date[0:10])\t\(.commit.message | split("\n")[0])"')

# Classify changed files: shipped code / shipped deps vs. dev-only noise. This is the
# path-based fallback; once the build graph is available, code vs. noise is
# re-decided from it below.
# ${a[@]+"${a[@]}"} expands an empty array without tripping bash 3.2's `set -u`.
code=(); dep=(); noise=()
for f in ${FILES[@]+"${FILES[@]}"}; do
  case "$f" in
    tools/*)                 noise+=("$f") ;;   # dev tooling (linters) — never shipped
    *_test.go)               noise+=("$f") ;;   # tests are never compiled into the binary
    cmd/gvproxy/*|pkg/*)     code+=("$f")  ;;
    go.mod|go.sum|vendor/*)  dep+=("$f")   ;;
    *)                       noise+=("$f") ;;
  esac
done

# Flag security-flavoured commit subjects (enriches the report; does not gate).
sec=()
for c in ${COMMITS[@]+"${COMMITS[@]}"}; do
  msg="${c#*$'\t'}"; msg="${msg#*$'\t'}"
  if printf '%s' "$msg" | grep -qiE 'secur|cve|vuln|overflow|panic|leak|bypass|out.of.bounds|(^| )oob( |$)|denial|dos'; then
    sec+=("$c")
  fi
done

# Does the augur patch still apply to current main? (highest-priority signal)
# git apply is all-or-nothing: on a conflict it leaves the tree untouched.
PATCH_STATE="unknown"
if fetch_tree "$WORK/main" "$MAIN_SHA" 2>/dev/null; then
  if git -C "$WORK/main" apply "$PATCH" 2>/dev/null; then PATCH_STATE="clean"; else PATCH_STATE="conflict"; fi
fi

# Does the patched main still type-check and pass its tests? Only meaningful once the
# patch applied; see patched_tests(). TESTS_LOG is the go output the excerpt is cut from,
# TESTS_NOTE says why the result is unavailable.
TESTS_STATE="skipped"; TESTS_LOG="$WORK/tests.log"; TESTS_NOTE="no working go"
: > "$TESTS_LOG"
if [ "$PATCH_STATE" = "clean" ]; then
  if [ "$MODE" = use-result ]; then
    check_tests_result
  elif command -v go >/dev/null; then
    TESTS_STATE="$(patched_tests "$WORK/main" "$TESTS_LOG")"
  else
    TESTS_STATE="unavailable"
  fi
fi

# Compare what actually goes into the binary at the pin vs. main, both with the augur
# patch applied (the patch adds imports of its own). On a conflicting patch, main is
# listed unpatched; the run is ACTION regardless.
GRAPH_STATE="unavailable"
graph_diff=""; settings_diff=""; other_bumps=""
if [ "$PATCH_STATE" != "unknown" ] && command -v go >/dev/null &&
   fetch_tree "$WORK/pin" "$PIN" 2>/dev/null &&
   git -C "$WORK/pin" apply "$PATCH" 2>/dev/null; then
  if build_graph  "$WORK/pin"  > "$WORK/graph.pin"  &&
     build_graph  "$WORK/main" > "$WORK/graph.main" &&
     shipped_code "$WORK/pin"  > "$WORK/code.pin"   &&
     shipped_code "$WORK/main" > "$WORK/code.main"; then
    GRAPH_STATE="ok"

    # Re-decide code vs. noise for upstream's own files: shipped if it is embedded, or
    # sits directly in a package directory the build reaches at the pin or at main (so
    # removed and newly added packages both count). Dependency files keep their
    # classification from above.
    printf '%s\n' ${FILES[@]+"${FILES[@]}"} > "$WORK/changed"
    code=(); noise=()
    while IFS=$'\t' read -r kind f; do
      if [ "$kind" = code ]; then code+=("$f"); else noise+=("$f"); fi
    done < <(awk '
      FILENAME ~ /code\.(pin|main)$/ { if ($1 == "D") dir[$2] = 1; else file[$2] = 1; next }
      $0 == "" || /^(go\.mod|go\.sum|vendor\/)/ { next }
      {
        d = $0; if (!sub(/\/[^\/]*$/, "", d)) d = "."
        shipped = ($0 in file) || ((d in dir) && $0 !~ /_test\.go$/)
        print (shipped ? "code" : "noise") "\t" $0
      }' "$WORK/code.pin" "$WORK/code.main" "$WORK/changed")

    # "- path: old -> new" per module whose version (or presence) differs.
    graph_diff="$(awk '
      { split($0, a, "@"); path = a[1]; ver = substr($0, length(path) + 2) }
      FNR == NR { old[path] = ver; next }
      { new[path] = ver }
      END {
        for (p in old) if (!(p in new))        printf "- `%s`: %s -> (removed)\n", p, old[p]
        for (p in new) if (!(p in old))        printf "- `%s`: (added) -> %s\n",   p, new[p]
                       else if (old[p] != new[p]) printf "- `%s`: %s -> %s\n",     p, old[p], new[p]
      }' "$WORK/graph.pin" "$WORK/graph.main" | sort)"
    settings_diff="$(diff <(build_settings "$WORK/pin/go.mod") <(build_settings "$WORK/main/go.mod") | grep '^[<>]' || true)"
    # Vendored modules that moved but are in neither build graph (test/dev-only).
    LC_ALL=C join -a 1 -a 2 -e '(none)' -o '0,1.2,2.2' \
      <(vendored_modules "$WORK/pin") <(vendored_modules "$WORK/main") > "$WORK/vendored"
    other_bumps="$(awk 'FILENAME ~ /graph\.(pin|main)$/ { sub(/@.*/, ""); ship[$0] = 1; next }
                        $2 != $3 && !($1 in ship) { printf "- `%s`: %s -> %s\n", $1, $2, $3 }' \
      "$WORK/graph.pin" "$WORK/graph.main" "$WORK/vendored")"
  fi
fi

# Without the build graph, fall back to treating any go.mod/go.sum/vendor change as
# shipped. Deliberately fails toward REVIEW: a missing Go must not hide a real bump.
if [ "$GRAPH_STATE" = "ok" ]; then
  dep_relevant=0
  if [ -n "$graph_diff" ] || [ -n "$settings_diff" ]; then dep_relevant=1; fi
else
  dep_relevant=${#dep[@]}
fi

relevant=$(( ${#code[@]} + dep_relevant ))
if [ "$PATCH_STATE" = "conflict" ]; then
  SEV="ACTION"; TITLE="gvproxy: patch no longer applies to upstream main (action required)"
elif [ "$TESTS_STATE" = "fail-vet" ] || [ "$TESTS_STATE" = "fail-test" ]; then
  SEV="ACTION"; TITLE="gvproxy: patch applies but the patched tree fails go vet/test (action required)"
elif [ "$relevant" -gt 0 ]; then
  SEV="REVIEW"; TITLE="gvproxy: upstream security/code update available (review)"
else
  SEV="NOISE";  TITLE=""
fi

PKG_LIST="$(patched_pkgs | tr '\n' ' ')"; PKG_LIST="${PKG_LIST% }"

# --- Markdown issue body ---------------------------------------------------
{
  echo "**gvproxy fork drift — $SEV**"
  echo
  echo "| | commit | date |"
  echo "|---|---|---|"
  echo "| pinned (\`build.sh\`) | \`$SHORT_PIN\` | $PIN_DATE |"
  echo "| upstream \`main\`     | \`$SHORT_MAIN\` | $MAIN_DATE |"
  echo
  echo "- **$AHEAD** commits ahead of the pin"
  case "$PATCH_STATE" in
    clean)    echo "- \`augur-egress.patch\` **applies cleanly** to main" ;;
    conflict) echo "- \`augur-egress.patch\` **NO LONGER APPLIES** to main — re-pin needs a manual rebase" ;;
    *)        echo "- patch apply-check could not run (clone failed)" ;;
  esac
  case "$TESTS_STATE" in
    pass)        echo "- the patched tree passes \`go vet\` (darwin/arm64) and \`go test\`" ;;
    fail-vet)    echo "- it applies, but the **patched tree FAILS \`go vet\`** (darwin/arm64, test files included) — re-pin needs a manual rebase" ;;
    fail-test)   echo "- it applies, but the **patched tree FAILS \`go test\`** — re-pin needs a manual rebase" ;;
    unavailable) echo "- patched-tree \`go vet\`/\`go test\` could not run ($TESTS_NOTE)" ;;
    none)        echo "- no package the patch touches has Go files on main; patched-tree \`go vet\`/\`go test\` did not run" ;;
    upstream-*)  echo "- the patched tree fails \`go ${TESTS_STATE#upstream-}\`, but so does unpatched main — not attributed to the patch, not graded" ;;
  esac
  echo
  case "$TESTS_STATE" in
    fail-*|upstream-*)
      echo "**Patched-tree failure (excerpt):**"
      echo '```'
      failure_excerpt "$TESTS_LOG"
      echo '```'
      echo ;;
  esac

  if [ "${#code[@]}" -gt 0 ]; then
    if [ "$GRAPH_STATE" = "ok" ]; then
      echo "**Shipped code changed (upstream packages compiled into \`cmd/gvproxy\`, darwin/arm64):**"
    else
      echo "**Code changed under \`cmd/gvproxy\`/\`pkg/\` — build-graph check could not run, so treated as shipped:**"
    fi
    printf '%s\n' "${code[@]}" | sort -u | sed 's/^/- `/; s/$/`/'
    echo
  fi
  if [ "$GRAPH_STATE" = "ok" ]; then
    if [ -n "$graph_diff" ]; then
      echo "**Modules linked into the shipped binary changed (\`cmd/gvproxy\`, darwin/arm64):**"
      printf '%s\n' "$graph_diff"
      echo
    fi
    if [ -n "$settings_diff" ]; then
      echo "**Build settings in \`go.mod\` changed (\`<\` pin, \`>\` main):**"
      echo '```'
      printf '%s\n' "$settings_diff"
      echo '```'
      echo
    fi
    if [ -n "$other_bumps" ]; then
      echo "**Other dependency bumps (not linked into gvproxy — no action needed):**"
      printf '%s\n' "$other_bumps"
      echo
    fi
  elif [ "${#dep[@]}" -gt 0 ]; then
    echo "**Dependency files changed (\`go.mod\`/\`vendor\`) — build-graph check could not run, so treated as shipped:**"
    printf '%s\n' "${dep[@]}" | sort -u | sed 's/^/- `/; s/$/`/'
    echo
  fi
  if [ "${#sec[@]}" -gt 0 ]; then
    echo "**Security-flavoured commits since the pin:**"
    printf '%s\n' "${sec[@]}" | while IFS=$'\t' read -r sha date subject; do
      echo "- \`$sha\` ($date) $subject"
    done
    echo
  fi

  echo "**Runbook**"
  echo "1. Bump \`PIN\` in \`gvproxy/build.sh\` to \`$MAIN_SHA\` (or a chosen newer commit)."
  echo "2. Re-apply \`augur-egress.patch\` and rebuild (\`bash gvproxy/build.sh\`)."
  echo "3. In a clone of upstream at the new pin with \`augur-egress.patch\` applied, run \`GOFLAGS=-mod=vendor GOOS=darwin GOARCH=arm64 CGO_ENABLED=0 go vet $PKG_LIST\` and \`GOFLAGS=-mod=vendor go test -count=1 $PKG_LIST\`."
  echo "4. Run the macOS egress E2E on Apple Silicon (allowlisted host reachable, blocked host denied, SSH via gvproxy)."
  echo "5. If the patch conflicted, or applies but the patched tree fails \`go vet\`/\`go test\`, rebase it against main first (fix the call sites and tests it breaks), then re-run this check."
  echo
  echo "_Filed automatically by \`gvproxy/check-freshness.sh\` (daily). Body refreshes in place; closes once nothing pending reaches the shipped binary._"
} > "$BODY_FILE"

# --- stdout human summary --------------------------------------------------
echo "SEVERITY: $SEV"
echo "  pinned : $SHORT_PIN ($PIN_DATE)"
echo "  main   : $SHORT_MAIN ($MAIN_DATE)   [$AHEAD ahead]"
echo "  patch  : $PATCH_STATE"
echo "  tests  : $TESTS_STATE"
echo "  graph  : $GRAPH_STATE"
if [ "$GRAPH_STATE" = "ok" ]; then
  echo "  shipped modules changed : $(printf '%s' "$graph_diff" | grep -c . || true)   build settings changed : $(printf '%s' "$settings_diff" | grep -c . || true)   other bumps : $(printf '%s' "$other_bumps" | grep -c . || true)"
fi
echo "  shipped code files : ${#code[@]}   dep files : ${#dep[@]}   security-flagged commits : ${#sec[@]}   (noise: ${#noise[@]})"
echo "  body   : $BODY_FILE"

emit "$SEV" "$TITLE"

case "$SEV" in
  ACTION|REVIEW) exit 1 ;;
  *)             exit 0 ;;
esac
