#!/usr/bin/env bash
# Tier 1 (offline) — shell completion. `augur __names` (the hidden, quiet name lister the completion
# scripts call) is driven for real against the `container` shim and a fake augur-vm; the bash
# completion function is then driven by setting COMP_WORDS/COMP_CWORD the way readline does, with a
# fake `augur` on PATH that answers `__names`. The zsh script cannot be exercised here (no zsh in the
# test environment); it is only syntax-checked when zsh is available.
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/lib.sh"
section "Tier 1 — augur __names (hidden name lister for completion)"

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
export HOME="$work/home"; mkdir -p "$HOME"
export AUGUR_TEST_SHIMLOG="$work/shim"
AUGUR="$REPO/augur"

out="$( PATH="$HERE/shims:$PATH" bash "$AUGUR" __names 2>&1 )"; rc=$?
eq "0" "$rc" "__names: exits 0"
eq $'augur-alpha-0011aabbccdd-swift-latest\naugur-beta-eeff22334455-swift-6-0' "$out" \
  "__names: bare augur container names only, one per line (running and stopped, no header, no colour)"

# No `container` CLI at all: nothing printed, and still success (a TAB press must never error).
if PATH="/usr/bin:/bin" command -v container >/dev/null 2>&1; then
  skip "__names without the container CLI" "a container CLI is installed in /usr/bin or /bin"
else
  out="$( PATH="/usr/bin:/bin" bash "$AUGUR" __names 2>&1 )"; rc=$?
  eq "0" "$rc" "__names: exits 0 when the container CLI is absent"
  eq ""  "$out" "__names: prints nothing when the container CLI is absent"
fi

cat > "$work/fake-augur-vm" <<'VM'
#!/usr/bin/env bash
[[ "${1:-}" == list ]] || exit 0
printf '%s\n' 'ID  NAME                              STATE'
printf '%s\n' '1   augur-macos-app-0123456789ab      stopped'
printf '%s\n' '2   not-an-augur-vm                   running'
VM
chmod +x "$work/fake-augur-vm"
out="$( AUGUR_VM_BIN="$work/fake-augur-vm" bash "$AUGUR" __names --macos 2>&1 )"; rc=$?
eq "0" "$rc" "__names --macos: exits 0"
eq "augur-macos-app-0123456789ab" "$out" "__names --macos: augur VM names only"

out="$( AUGUR_VM_BIN="$work/no-such-vm" bash "$AUGUR" __names --macos 2>&1 )"; rc=$?
eq "0" "$rc" "__names --macos: exits 0 when augur-vm is missing"
eq ""  "$out" "__names --macos: prints nothing when augur-vm is missing"

section "Tier 1 — bash completion function"

mkdir -p "$work/bin"
cat > "$work/bin/augur" <<'FAKE'
#!/usr/bin/env bash
[[ "${1:-}" == __names ]] || exit 0
if [[ "${2:-}" == --macos ]]; then printf '%s\n' augur-macos-m-0123456789ab
else printf '%s\n' augur-c1-0011aabbccdd-swift-latest augur-c2-eeff22334455-swift-6-0; fi
FAKE
chmod +x "$work/bin/augur"
export PATH="$work/bin:$PATH"
source "$REPO/completions/augur.bash"

# complete WORD...  — the last word is the one under the cursor (pass '' for an empty word).
complete_words() {
  COMP_WORDS=("$@"); COMP_CWORD=$(( $# - 1 )); COMPREPLY=()
  _augur
  printf '%s\n' "${COMPREPLY[@]}"
}

eq $'down\ndestroy' "$(complete_words augur d)" "subcommand: 'd' completes down/destroy"
has "$(complete_words augur '')" "destroy" "subcommand: empty word offers the subcommands"
eq "--macos" "$(complete_words augur destroy --ma)" "option: '--ma' completes --macos"
eq $'augur-c1-0011aabbccdd-swift-latest\naugur-c2-eeff22334455-swift-6-0' "$(complete_words augur destroy '')" \
  "destroy: offers the container names"
eq "augur-c2-eeff22334455-swift-6-0" "$(complete_words augur destroy augur-c2)" "destroy: filters names by the typed prefix"
eq "augur-macos-m-0123456789ab" "$(complete_words augur destroy --macos '')" "destroy --macos: offers the VM names instead"
eq "" "$(complete_words augur up '')" "up: offers no names"
eq "" "$(complete_words augur up --swift '')" "--swift: offers nothing (free-form value)"

if command -v zsh >/dev/null 2>&1; then
  zsh -n "$REPO/completions/augur.zsh" && ok "zsh completion: syntax ok" || fail "zsh completion: syntax error"
else
  skip "zsh completion syntax check" "zsh not installed"
fi

finish
