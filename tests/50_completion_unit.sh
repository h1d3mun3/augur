#!/usr/bin/env bash
# Tier 1 (offline) — shell completion. `augur __names` (the hidden, quiet name lister the completion
# scripts call) is driven for real against the `container` shim and a fake augur-vm; the bash
# completion function is then driven by setting COMP_WORDS/COMP_CWORD the way readline does, with a
# fake `augur` on PATH that answers `__names`; the augur-vm function likewise, with a fake `augur-vm`
# that answers `list`. The zsh script cannot be exercised here (no zsh in the test environment); it is
# only syntax-checked when zsh is available.
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

# Service stopped: nothing printed and a distinct exit 3 (the zsh script turns that into a hint),
# and `__names` must NOT have started the service (no `system start` reaches the CLI).
rm -f "$AUGUR_TEST_SHIMLOG.trace"
out="$( AUGUR_TEST_SERVICE_DOWN=1 PATH="$HERE/shims:$PATH" bash "$AUGUR" __names 2>&1 )"; rc=$?
eq "3" "$rc" "__names: exits 3 when the container service is not running"
eq ""  "$out" "__names: prints nothing when the container service is not running"
hasnt "$(cat "$AUGUR_TEST_SHIMLOG.trace" 2>/dev/null)" "system start" "__names: never starts the container service"

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
printf '%s\n' '3   augur-macos-base                  stopped'
printf '%s\n' '4   augur-macos-build-helper          stopped'
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
eq $'--macos\n--manual-setup' "$(complete_words augur build --ma)" "option: '--ma' completes --macos/--manual-setup"
eq "--macos" "$(complete_words augur destroy --mac)" "option: '--mac' completes --macos"
eq $'augur-c1-0011aabbccdd-swift-latest\naugur-c2-eeff22334455-swift-6-0' "$(complete_words augur destroy '')" \
  "destroy: offers the container names"
eq "augur-c2-eeff22334455-swift-6-0" "$(complete_words augur destroy augur-c2)" "destroy: filters names by the typed prefix"
eq "augur-macos-m-0123456789ab" "$(complete_words augur destroy --macos '')" "destroy --macos: offers the VM names instead"
eq "" "$(complete_words augur up '')" "up: offers no names"
eq "" "$(complete_words augur up --swift '')" "--swift: offers nothing (free-form value)"

section "Tier 1 — bash completion function for augur-vm"

# A fake augur-vm whose `list` prints the real layout: a header row, then `local <name> 0 0 <state>`.
cat > "$work/bin/augur-vm" <<'FAKE'
#!/usr/bin/env bash
[[ "${1:-}" == list ]] || exit 0
printf '%s\n' 'Source Name Disk Size State' 'local augur-macos-base 0 0 stopped' 'local augur-macos-app-0123456789ab 0 0 running'
FAKE
chmod +x "$work/bin/augur-vm"

complete_vm() {
  COMP_WORDS=("$@"); COMP_CWORD=$(( $# - 1 )); COMPREPLY=()
  _augur_vm
  printf '%s\n' "${COMPREPLY[@]}"
}
vm_names=$'augur-macos-base\naugur-macos-app-0123456789ab'

eq "delete" "$(complete_vm augur-vm d)" "augur-vm subcommand: 'd' completes delete"
eq $'provisioning-support' "$(complete_vm augur-vm pr)" "augur-vm subcommand: 'pr' completes provisioning-support"
eq $'--help\n--version' "$(complete_vm augur-vm --)" "augur-vm top level: '--' offers --help/--version"
eq "$vm_names" "$(complete_vm augur-vm delete '')" "augur-vm delete: offers the VM names"
eq "augur-macos-app-0123456789ab" "$(complete_vm augur-vm stop augur-macos-a)" "augur-vm stop: filters names by the typed prefix"
for c in set run ip provisioning-support stop clone; do
  eq "$vm_names" "$(complete_vm augur-vm "$c" '')" "augur-vm $c: offers the VM names"
done
eq "$vm_names" "$(complete_vm augur-vm run --no-graphics --dir a:/tmp '')" "augur-vm run: names after options and their values"
eq "$vm_names" "$(complete_vm augur-vm run --dir = a:/tmp '')" "augur-vm run: names after a --dir=value split at the ="
eq "" "$(complete_vm augur-vm run vm1 '')" "augur-vm run: nothing after the VM name"
eq "" "$(complete_vm augur-vm clone src '')" "augur-vm clone: the destination (a new name) offers nothing"
eq "" "$(complete_vm augur-vm create '')" "augur-vm create: a new name offers nothing"
eq "" "$(complete_vm augur-vm list '')" "augur-vm list: offers no names"
eq "--no-graphics" "$(complete_vm augur-vm run --no)" "augur-vm run: '--no' completes --no-graphics"
eq $'--net-vfkit\n--net-nat' "$(complete_vm augur-vm run vm1 --net)" "augur-vm run: '--net' completes both network options"
eq $'--cpu\n--memory\n--help' "$(complete_vm augur-vm set --)" "augur-vm set: offers only its own options"
eq "--help" "$(complete_vm augur-vm delete --)" "augur-vm delete: offers only --help"
hasnt "$(complete_vm augur-vm set --)" "--no-graphics" "augur-vm set: no run-only options"
eq "" "$(complete_vm augur-vm set vm1 --memory '')" "augur-vm --memory: offers nothing (free-form value)"
eq "" "$(complete_vm augur-vm create --disk-size '')" "augur-vm --disk-size: offers nothing (free-form value)"
touch "$work/macOS.ipsw"
eq "$work/macOS.ipsw" "$(complete_vm augur-vm create --from-ipsw "$work/mac")" "augur-vm create --from-ipsw: completes file paths"
hasnt "$(complete_vm augur-vm create --from-ipsw '')" "--disk-size" "augur-vm create --from-ipsw: offers no option words"
eq "$work/macOS.ipsw" "$(complete_vm augur-vm run vm1 --net-vfkit "$work/mac")" "augur-vm run --net-vfkit: completes file paths"
eq "delete" "$(complete_vm augur-vm help del)" "augur-vm help: offers the subcommands"

# No augur-vm on PATH: no names, no noise, no failure.
out="$( COMP_WORDS=(/no/such/augur-vm delete ''); COMP_CWORD=2; COMPREPLY=(); _augur_vm 2>&1; rc=$?; printf '%s' "${COMPREPLY[*]}"; exit $rc )"; rc=$?
eq "0" "$rc" "augur-vm missing: completion still succeeds"
eq ""  "$out" "augur-vm missing: no names and no error output"

if command -v zsh >/dev/null 2>&1; then
  zsh -n "$REPO/completions/augur.zsh" && ok "zsh completion: syntax ok" || fail "zsh completion: syntax error"
else
  skip "zsh completion syntax check" "zsh not installed"
fi

finish
