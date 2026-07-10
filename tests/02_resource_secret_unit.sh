#!/usr/bin/env bash
# Tier 0 — resource-bound + secret-value hardening (pure functions, runs anywhere).
#
# F2: validate_secret_value rejects a single-quote / control-byte secret (the "C3" contract)
#     BEFORE it is interpolated into the macOS ~/.augur-env writer as export VAR='<value>'.
# F4: a guest-writable ./.augur/resources.conf CPU/MEMORY value is clamped to a sane range so a
#     hostile value (e.g. MEMORY=9999g) cannot over-commit / DoS the host on the next `augur up`.
#     An explicit AUGUR_* env override is operator intent and is deliberately NOT clamped.
#
# Same slice-by-name technique as 01_egress_allowlist_unit.sh: augur's entry-point never runs.
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/lib.sh"
AUGUR="$REPO/augur"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

helpers="$WORK/helpers.sh"; : > "$helpers"
for f in validate_secret_value clamp_resource_int clamp_container_memory_value \
         project_resource_value resolve_container_memory resolve_macos_vm_cpu resolve_macos_vm_memory_mb; do
  awk -v n="$f" 'index($0, n"()")==1 {f=1} f{print} f&&/^}/{exit}' "$AUGUR" >> "$helpers"
  echo >> "$helpers"
done
# Stub augur's loggers so the sliced helpers run standalone (they call error/warn).
error() { :; }
warn()  { :; }
source "$helpers"

# ── F2 — validate_secret_value ────────────────────────────────────────────────
section "F2 — validate_secret_value rejects quote/control-byte secrets (C3)"
validate_secret_value K 'sk-ant-abc123_.-'      && ok "accepts a normal token"                  || fail "accepts a normal token"
validate_secret_value K 'ghp_ABCdef0123456789'  && ok "accepts an alnum/underscore token"       || fail "accepts an alnum/underscore token"
validate_secret_value K "abc'def"               && fail "rejects a single quote"                 || ok "rejects a single quote"
validate_secret_value K $'abc\ndef'             && fail "rejects an embedded newline"            || ok "rejects an embedded newline"
validate_secret_value K $'abc\tdef'             && fail "rejects an embedded tab"                || ok "rejects an embedded tab"
validate_secret_value K $'abc\x01def'           && fail "rejects a control byte"                 || ok "rejects a control byte"

# ── F4 — resources.conf clamping ──────────────────────────────────────────────
section "F4 — guest-writable resources.conf values are clamped"
conf="$WORK/resources.conf"
export AUGUR_PROJECT_RESOURCES_CONF="$conf"
unset AUGUR_CONTAINER_MEMORY AUGUR_MACOS_VM_CPU AUGUR_MACOS_VM_MEMORY_MB

printf 'MEMORY=8g\n'      > "$conf"; eq "$(resolve_container_memory)" "8g"   "valid MEMORY=8g passes through"
printf 'MEMORY=512m\n'    > "$conf"; eq "$(resolve_container_memory)" "512m" "valid MEMORY=512m passes through"
printf 'MEMORY=9999g\n'   > "$conf"; eq "$(resolve_container_memory)" "4g"   "MEMORY=9999g (>128g) clamps to default"
printf 'MEMORY=evil;rm\n' > "$conf"; eq "$(resolve_container_memory)" "4g"   "malformed MEMORY falls back to default"

printf 'MACOS_CPU=8\n'    > "$conf"; eq "$(resolve_macos_vm_cpu)" "8"  "valid MACOS_CPU=8 passes through"
printf 'MACOS_CPU=9999\n' > "$conf"; eq "$(resolve_macos_vm_cpu)" "4"  "MACOS_CPU=9999 (>64) clamps to default"
printf 'MACOS_CPU=0\n'    > "$conf"; eq "$(resolve_macos_vm_cpu)" "4"  "MACOS_CPU=0 (<1) clamps to default"
printf 'MACOS_CPU=abc\n'  > "$conf"; eq "$(resolve_macos_vm_cpu)" "4"  "non-numeric MACOS_CPU falls back to default"

printf 'MACOS_MEMORY_MB=16384\n'    > "$conf"; eq "$(resolve_macos_vm_memory_mb)" "16384" "valid MACOS_MEMORY_MB passes through"
printf 'MACOS_MEMORY_MB=99999999\n' > "$conf"; eq "$(resolve_macos_vm_memory_mb)" "8192"  "MACOS_MEMORY_MB=99999999 (>256G) clamps to default"
printf 'MACOS_MEMORY_MB=64\n'       > "$conf"; eq "$(resolve_macos_vm_memory_mb)" "8192"  "MACOS_MEMORY_MB=64 (<512) clamps to default"

section "F4 — an explicit AUGUR_* env override is operator intent and stays UNclamped"
printf 'MACOS_CPU=8\n' > "$conf"
out="$(AUGUR_MACOS_VM_CPU=999 resolve_macos_vm_cpu)";        eq "$out" "999"    "env override bypasses the CPU clamp"
out="$(AUGUR_CONTAINER_MEMORY=9999g resolve_container_memory)"; eq "$out" "9999g" "env override bypasses the MEMORY clamp"

finish
