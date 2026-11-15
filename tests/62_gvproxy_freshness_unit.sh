#!/usr/bin/env bash
# Tier 0 — gvproxy/check-freshness.sh grades a patch that applies cleanly but leaves the patched
# tree failing `go vet` or `go test` as ACTION, with its own title, an issue-body line saying so and
# a bounded excerpt of the failure. No network, no real Go: the script runs from a scratch copy
# whose build.sh points REPO at a local fixture repository (fetched over file://), with `gh` and
# `go` stubs on PATH. The go stub records each call's environment and arguments.
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/lib.sh"
section "Tier 0 — gvproxy freshness check: patched-tree go vet / go test"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
g() { git -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false "$@"; }

# --- fixture upstream: pin, a main the patch applies to, and a main it conflicts with ----------
UP="$T/upstream"
g init --quiet "$UP"
g -C "$UP" config uploadpack.allowAnySHA1InWant true
mkdir -p "$UP/cmd/gvproxy" "$UP/pkg/a" "$UP/vendor"
printf 'module example.invalid/gtv\n\ngo 1.22\n' > "$UP/go.mod"
: > "$UP/vendor/modules.txt"
printf 'package main\n\nfunc main() {}\n' > "$UP/cmd/gvproxy/main.go"
printf 'package a\n\nfunc F() int {\n\treturn 1\n}\n' > "$UP/pkg/a/a.go"
g -C "$UP" add -A && g -C "$UP" commit --quiet -m pin
PIN="$(g -C "$UP" rev-parse HEAD)"

printf 'package a\n\nimport "testing"\n\nfunc TestF(t *testing.T) { F() }\n' > "$UP/pkg/a/a_test.go"
g -C "$UP" add -A && g -C "$UP" commit --quiet -m 'add a test'
MAIN_OK="$(g -C "$UP" rev-parse HEAD)"

g -C "$UP" checkout --quiet "$PIN"
printf 'package a\n\nfunc F() int {\n\treturn 3\n}\n' > "$UP/pkg/a/a.go"
g -C "$UP" commit --quiet -am 'change F'
MAIN_CONFLICT="$(g -C "$UP" rev-parse HEAD)"

# --- scratch copy of the gvproxy dir: the real script, a build.sh and a patch for the fixture --
GV="$T/gv"; mkdir -p "$GV"
cp "$REPO/gvproxy/check-freshness.sh" "$GV/"
printf 'PIN="%s"\nREPO="file://%s"\n' "$PIN" "$UP" > "$GV/build.sh"
cat > "$GV/augur-egress.patch" <<'EOF'
diff --git a/pkg/a/a.go b/pkg/a/a.go
--- a/pkg/a/a.go
+++ b/pkg/a/a.go
@@ -1,5 +1,5 @@
 package a

 func F() int {
-	return 1
+	return 2
 }
EOF

# --- stubs ----------------------------------------------------------------------------------------
BIN="$T/bin"; NOGO="$T/nogo"; mkdir -p "$BIN" "$NOGO"
cat > "$NOGO/gh" <<'EOF'
#!/usr/bin/env bash
# Answers the four `gh api` queries check-freshness.sh makes.
case "$*" in
  *commits/main*)           echo "$FAKE_MAIN 2026-11-01" ;;
  *commits/*)               echo "2026-10-01" ;;
  *ahead_by*)               echo 1 ;;
  *files*)                  echo "pkg/a/a_test.go" ;;
  *commits*)                printf '%s\t%s\t%s\n' "${FAKE_MAIN:0:8}" 2026-11-01 "add a test" ;;
esac
EOF
cat > "$BIN/go" <<'EOF'
#!/usr/bin/env bash
# Records "[patched|unpatched] GOOS GOARCH CGO_ENABLED GOFLAGS GOTOOLCHAIN :: args" per call, and
# "secret" lines naming any token or workflow-output variable it can see. FAKE_GO_FAIL names the
# subcommand (version, vet, test) that fails, printing FAKE_GO_OUT first: on the patched tree
# only, or on both trees when FAKE_GO_FAIL_UNPATCHED is set.
tree=unpatched; grep -q 'return 2' pkg/a/a.go 2>/dev/null && tree=patched
echo "[$tree] ${GOOS:--} ${GOARCH:--} ${CGO_ENABLED:--} ${GOFLAGS:--} ${GOTOOLCHAIN:--} :: $*" >> "$GO_LOG"
for v in GH_TOKEN GITHUB_TOKEN GITHUB_OUTPUT; do
  if [ -n "${!v:-}" ]; then echo "secret $v visible to go $1" >> "$GO_LOG"; fi
done
if [ "${FAKE_GO_FAIL:-}" = "$1" ] && { [ "$tree" = patched ] || [ -n "${FAKE_GO_FAIL_UNPATCHED:-}" ]; }; then
  [ -n "${FAKE_GO_OUT:-}" ] && cat "$FAKE_GO_OUT"
  exit 1
fi
case "$1" in
  version) echo "go version go1.24.0 linux/arm64" ;;
  test)    echo "ok  	example.invalid/gtv/pkg/a	0.01s" ;;
esac
exit 0
EOF
cp "$NOGO/gh" "$BIN/gh"
chmod +x "$BIN/go" "$BIN/gh" "$NOGO/gh"

# run_check MAIN_SHA PATHDIR — run the script; sets rc, out, body, ghout, golog.
run_check() {
  local n="$T/run.$RANDOM"; mkdir -p "$n"; : > "$n/go.log"; : > "$n/ghout"
  out="$(cd "$n" && env -u GOOS -u GOARCH -u CGO_ENABLED -u GOFLAGS -u GOTOOLCHAIN \
           PATH="$2:/usr/bin:/bin" FAKE_MAIN="$1" GO_LOG="$n/go.log" \
           BODY_FILE="$n/body.md" GITHUB_OUTPUT="$n/ghout" GH_TOKEN=tok GITHUB_TOKEN=tok \
           bash "$GV/check-freshness.sh" 2>&1)"
  rc=$?
  body="$(cat "$n/body.md" 2>/dev/null)"; ghout="$(cat "$n/ghout")"; golog="$(cat "$n/go.log")"
}

# --- patched tree passes --------------------------------------------------------------------------
section "clean patch, patched tree passes vet and test"
unset FAKE_GO_FAIL FAKE_GO_OUT
run_check "$MAIN_OK" "$BIN"
eq 0 "$rc" "exit 0 (test-only drift is NOISE)"
has "$out" "tests  : pass" "summary reports tests: pass"
has "$ghout" "severity=NOISE" "workflow severity NOISE"
has "$body" 'the patched tree passes `go vet` (darwin/arm64) and `go test`' "body says the patched tree passes"
has "$golog" "darwin arm64 0 -mod=vendor auto :: vet ./pkg/a" "vet: darwin/arm64, cgo off, vendored, GOTOOLCHAIN=auto, on the patched package"
has "$golog" "- - - -mod=vendor auto :: test -count=1 -timeout 10m ./pkg/a" "test: native, vendored, GOTOOLCHAIN=auto, with a timeout"
has "$body" "go test -count=1 ./pkg/a" "runbook names go test on the patched packages"
eq "" "$(printf "%s\n" "$golog" | grep -E "visible to go (vet|test)")" "go vet/test see no GH_TOKEN, GITHUB_TOKEN or GITHUB_OUTPUT"
hasnt "$golog" "[unpatched]" "no baseline run when the patched tree passes"
has "$body" "or applies but the patched tree fails" "runbook's rebase step covers a failing patched tree"

# --- vet fails --------------------------------------------------------------------------------------
section "clean patch, patched tree fails go vet"
printf '# example.invalid/gtv/pkg/a\nvet: pkg/a/a_test.go:5:28: not enough arguments in call to F\n' > "$T/vet.out"
export FAKE_GO_FAIL=vet FAKE_GO_OUT="$T/vet.out"
run_check "$MAIN_OK" "$BIN"
eq 1 "$rc" "exit 1"
has "$out" "SEVERITY: ACTION" "severity ACTION"
has "$out" "tests  : fail-vet" "summary reports tests: fail-vet"
has "$ghout" "severity=ACTION" "workflow severity ACTION"
has "$ghout" "title=gvproxy: patch applies but the patched tree fails go vet/test (action required)" "distinct issue title"
has "$body" "applies cleanly" "body still says the patch applies"
has "$body" 'patched tree FAILS `go vet`' "body says the patched tree fails vet"
has "$body" "not enough arguments in call to F" "body carries the vet error"
hasnt "$golog" ":: test" "go test is not run after vet fails"

# --- test fails -------------------------------------------------------------------------------------
section "clean patch, patched tree fails go test"
printf -- '--- FAIL: TestF (0.00s)\nFAIL\texample.invalid/gtv/pkg/a\t0.01s\n' > "$T/test.out"
export FAKE_GO_FAIL=test FAKE_GO_OUT="$T/test.out"
run_check "$MAIN_OK" "$BIN"
eq 1 "$rc" "exit 1"
has "$out" "tests  : fail-test" "summary reports tests: fail-test"
has "$ghout" "severity=ACTION" "workflow severity ACTION"
has "$body" 'patched tree FAILS `go test`' "body says the patched tree fails test"
has "$body" "--- FAIL: TestF" "body carries the test failure"
has "$golog" "[unpatched] - - - -mod=vendor auto :: test -count=1 -timeout 10m ./pkg/a" "the failing step re-runs on unpatched main"
eq "" "$(printf "%s\n" "$golog" | grep -E "visible to go (vet|test)")" "go vet/test see no GH_TOKEN, GITHUB_TOKEN or GITHUB_OUTPUT (baseline included)"

# --- unpatched main fails the same way: not the patch's failure ------------------------------------
section "patched tree fails go vet, unpatched main fails it too"
export FAKE_GO_FAIL=vet FAKE_GO_OUT="$T/vet.out" FAKE_GO_FAIL_UNPATCHED=1
run_check "$MAIN_OK" "$BIN"
unset FAKE_GO_FAIL_UNPATCHED
eq 0 "$rc" "exit 0 (not ACTION)"
has "$out" "tests  : upstream-vet" "summary reports tests: upstream-vet"
hasnt "$ghout" "severity=ACTION" "workflow severity is not ACTION"
has "$body" 'but so does unpatched main' "body says unpatched main fails too"
has "$body" "not enough arguments in call to F" "body still carries the excerpt"

# --- excerpt is bounded and cannot break its code block ---------------------------------------------
section "failure excerpt is bounded"
xs="$(printf 'x%.0s' $(seq 1 300))"
{ for i in $(seq 1 2000); do printf 'line%03d ````` %s\n' "$i" "$xs"; done; } > "$T/long.out"   # ~600 KB: past any pipe buffer
export FAKE_GO_FAIL=vet FAKE_GO_OUT="$T/long.out"
run_check "$MAIN_OK" "$BIN"
excerpt="$(printf '%s\n' "$body" | awk '/^\*\*Patched-tree failure/ { f = 1; next } f && /^```$/ { if (++n == 2) exit; next } f && n == 1')"
eq 40 "$(printf '%s\n' "$excerpt" | grep -c .)" "at most 40 lines"
eq 0 "$(printf '%s\n' "$excerpt" | awk 'length > 200' | grep -c .)" "no line longer than 200 characters"
eq 2 "$(printf '%s\n' "$body" | grep -c '```')" "only the two fences carry triple backticks"
hasnt "$body" "line041" "lines past the bound are dropped"
has "$ghout" "severity=ACTION" "a log far past the pipe buffer still reaches the workflow as ACTION"
has "$out" "SEVERITY: ACTION" "and the summary is printed"

# --- go cannot run: never ACTION on its own ------------------------------------------------------
section "go present but the toolchain cannot run in the tree"
export FAKE_GO_FAIL=version; unset FAKE_GO_OUT
run_check "$MAIN_OK" "$BIN"
has "$out" "tests  : unavailable" "summary reports tests: unavailable"
hasnt "$ghout" "severity=ACTION" "a broken toolchain is not ACTION"
has "$body" 'could not run (no working go)' "body says vet/test did not run"
hasnt "$golog" ":: vet" "vet is not attempted"

section "no go on PATH"
unset FAKE_GO_FAIL
if PATH="$NOGO:/usr/bin:/bin" command -v go >/dev/null; then
  skip "no-go run" "a go sits in /usr/bin or /bin here"
else
  run_check "$MAIN_OK" "$NOGO"
  has "$out" "tests  : unavailable" "summary reports tests: unavailable"
  hasnt "$ghout" "severity=ACTION" "missing go is not ACTION"
  has "$body" 'could not run (no working go)' "body says vet/test did not run"
fi

# --- conflict keeps its own title and skips vet/test -----------------------------------------------
section "patch conflicts"
run_check "$MAIN_CONFLICT" "$BIN"
eq 1 "$rc" "exit 1"
has "$ghout" "title=gvproxy: patch no longer applies to upstream main (action required)" "conflict title unchanged"
has "$out" "tests  : skipped" "summary reports tests: skipped"
hasnt "$golog" ":: vet" "vet is not run on an unpatched tree"
hasnt "$body" "Patched-tree failure" "no failure excerpt"

# --- package list derived from the real patch ------------------------------------------------------
section "patched packages come from the real augur-egress.patch"
pkgs="$(PATCH="$REPO/gvproxy/augur-egress.patch" bash -c \
  "$(sed -n '/^patched_pkgs() {/,/^}/p' "$REPO/gvproxy/check-freshness.sh"); patched_pkgs" | tr '\n' ' ')"
eq "./cmd/gvproxy ./pkg/services/dns ./pkg/services/forwarder ./pkg/tap ./pkg/types ./pkg/virtualnetwork " \
  "$pkgs" "every directory with a patched .go file, test-only ones included"

finish
