#!/usr/bin/env bash
# Tier 1 (offline) — misplaced global flags and stray arguments are refused, not ignored.
# The global flags (--macos/--gui/--egress/--no-egress/--swift) are read only directly after the
# command, so a later one would otherwise be dropped silently and the command would act on the
# wrong mode: `augur down extra --macos` stopping the container, `augur build --ipsw X --xcode-xip
# Y --macos` building the container image. Drives the real dispatch with a shimmed `container`;
# every refusal must exit 1 with a hint and before any engine call that builds, inspects or deletes.
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/lib.sh"
AUGUR="$REPO/augur"

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
export HOME="$work/home"; mkdir -p "$HOME"
proj="$work/proj";        mkdir -p "$proj"
export AUGUR_TEST_SHIMLOG="$work/shim"
export PATH="$HERE/shims:$PATH"
export AUGUR_TEST_CONTAINER_RUNNING=1
# No real augur-vm can ever be reached from here.
export AUGUR_VM_BIN="$work/no-such-augur-vm"
printf -- '-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n' > "$proj/c.crt"
vm="augur-macos-app-0123456789ab"

run_augur() {   # run_augur <args…> — sets $out/$rc/$trace
    rm -f "$AUGUR_TEST_SHIMLOG.trace"
    out="$( cd "$proj" && bash "$AUGUR" "$@" 2>&1 </dev/null )"; rc=$?
    out="$(printf '%s\n' "$out" | sed $'s/\033\\[[0-9;]*m//g')"
    trace="$(cat "$AUGUR_TEST_SHIMLOG.trace" 2>/dev/null)"
}

refused() {   # refused <hint> <args…>
    local hint="$1"; shift
    local label="augur $*"
    run_augur "$@"
    eq 1 "$rc" "$label: refused with exit 1"
    has "$out" "$hint" "$label: says '$hint'"
    if grep -Eq '^container (build|delete|inspect|image|run|exec|stop|network)' <<<"$trace"; then
        fail "$label: reached the engine before refusing" "$trace"
    else
        ok "$label: refused before any engine call"
    fi
}

section "Tier 1 — a global flag after another word is refused, with where it goes"
refused "Put --macos right after the command: augur build --macos" build --ipsw X --xcode-xip Y --macos
refused "Put --macos right after the command: augur down --macos"  down extra --macos
refused "Put --macos right after the command: augur claude --macos" claude x --macos
refused "Put --swift right after the command: augur install-cert --swift <version>" install-cert c.crt --swift 6.0
refused "Put --macos right after the command: augur destroy --macos" destroy "$vm" --macos
refused "Put --no-egress right after the command: augur up --no-egress" up --macos foo --no-egress
refused "Put --gui right after the command: augur up --gui" up x --gui
refused "Put --egress right after the command: augur shell --egress" shell x --egress

section "Tier 1 — macOS build options without --macos are refused"
refused "augur build --macos --ipsw <path> --xcode-xip <path>" build --ipsw X
refused "augur build --macos --ipsw <path> --xcode-xip <path>" build --swift 6.0 --xcode-xip Y
refused "augur build --macos --ipsw <path> --xcode-xip <path>" build --manual-setup

section "Tier 1 — a command that takes no arguments refuses one"
for c in up claude shell setup-token down status init-conf list __names update version build; do
  refused "augur $c takes no arguments (got: extra)" "$c" extra
done
refused "augur down takes no arguments (got: --macos-typo)" down --macos-typo
refused "augur up takes no arguments (got: foo bar)" up --macos foo bar

section "Tier 1 — --help / -h after a command prints the usage and runs nothing"
run_augur --help
usage_top="$out"
for args in "up --help" "build -h" "down --help" "status -h" "install-cert --help" "destroy -h" "up --macos --help" "build --macos -h" "up foo --help"; do
  run_augur $args
  eq 0 "$rc" "augur $args: exit 0"
  eq "$usage_top" "$out" "augur $args: prints the same usage as the top-level help"
  hasnt "$out" "takes no arguments" "augur $args: no stray-argument refusal"
  eq "" "$trace" "augur $args: no engine call"
done

section "Tier 1 — correct command lines are not refused"
notrefused() {   # notrefused <args…>
    run_augur "$@"
    hasnt "$out" "Put --" "augur $*: no placement refusal"
    hasnt "$out" "takes no arguments"     "augur $*: no stray-argument refusal"
    hasnt "$out" "option of the macOS base-VM build" "augur $*: no build-option refusal"
}
notrefused build
eq 0 "$rc" "augur build: exits 0"
notrefused build --swift 6.0
eq 0 "$rc" "augur build --swift 6.0: exits 0"
has "$trace" "augur:swift-6.0" "augur build --swift 6.0: builds the 6.0 tag"
notrefused __names --macos
eq 0 "$rc" "augur __names --macos (what the completions run): exits 0"
notrefused __names
eq 0 "$rc" "augur __names: exits 0"
notrefused help
eq 0 "$rc" "augur help: exits 0"
notrefused help x
eq 0 "$rc" "augur help x: extra words after help are still ignored"
notrefused install-cert --macos c.crt
notrefused destroy --macos "$vm"
notrefused build --macos --ipsw X --xcode-xip Y   # its own parser (fails on Linux at require_vz)
# An unknown command is still reported as one, not as a stray argument.
run_augur bogus extra
eq 1 "$rc" "augur bogus extra: exit 1"
has "$out" "Unknown command: 'bogus'" "augur bogus extra: reported as an unknown command"

finish
