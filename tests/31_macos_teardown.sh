#!/usr/bin/env bash
# Tier 1 — macOS VM teardown (runs anywhere; no container/VM host needed).
# Guards the fix for the base/build VM "silent hang on teardown": a backgrounded
# `augur-vm run` masks SIGTERM (it asks the guest for a graceful ACPI shutdown that
# never completes mid-boot), so a raw `kill "$vm_pid"; wait "$vm_pid"` on it blocks
# forever. All such teardown must route through stop_and_reap_macos_vm, which calls the
# bounded `augur-vm stop` (SIGTERM → SIGKILL after 30s) BEFORE reaping.
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/lib.sh"
AUGUR="$REPO/augur"

section "Tier 1 — teardown source guards (run anywhere)"

# No function may reintroduce the raw kill-then-wait-on-vm_pid hang pattern.
hasnt "$(cat "$AUGUR")" 'kill "$vm_pid"' "no raw 'kill \"\$vm_pid\"' anywhere in augur (the hang pattern)"

# The two functions that background `augur-vm run` must reap via the shared helper.
build_macos="$(awk '/^cmd_build_macos\(\)/{f=1} f{print} f&&/^}/{exit}' "$AUGUR")"
update_macos="$(awk '/^cmd_update_macos\(\)/{f=1} f{print} f&&/^}/{exit}' "$AUGUR")"
has  "$build_macos"  'stop_and_reap_macos_vm' "cmd_build_macos reaps via stop_and_reap_macos_vm"
hasnt "$build_macos"  'kill "$vm_pid"'        "cmd_build_macos has no raw kill;wait teardown"
has  "$update_macos" 'stop_and_reap_macos_vm' "cmd_update_macos reaps via stop_and_reap_macos_vm"
hasnt "$update_macos" 'kill "$vm_pid"'        "cmd_update_macos has no raw kill;wait teardown"

# The helper itself must stop (bounded) BEFORE it waits — that ordering is the whole point.
helper="$(awk '/^stop_and_reap_macos_vm\(\)/{f=1} f{print} f&&/^}/{exit}' "$AUGUR")"
has "$helper" '"$VM_CLI" stop' "helper calls the bounded 'augur-vm stop'"
stop_ln="$(grep -n '"\$VM_CLI" stop' <<<"$helper" | head -1 | cut -d: -f1)"
wait_ln="$(grep -n 'wait "\$pid"'    <<<"$helper" | head -1 | cut -d: -f1)"
if [[ -n "$stop_ln" && -n "$wait_ln" && "$stop_ln" -lt "$wait_ln" ]]; then
  ok "helper stops before it waits (stop@$stop_ln < wait@$wait_ln)"
else
  fail "helper must call stop before wait" "stop@'$stop_ln' wait@'$wait_ln'"
fi

section "Tier 1 — stop_and_reap_macos_vm behaviour (fake augur-vm, run anywhere)"

TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT
calls="$TMPD/calls.log"; : > "$calls"
# Fake augur-vm: log every call; `stop` force-kills the stand-in (like the real bounded
# stop's SIGKILL escalation) so the helper's `wait` returns.
cat > "$TMPD/augur-vm" <<SHIM
#!/usr/bin/env bash
echo "\$*" >> "$calls"
if [[ "\$1" == stop && -n "\${AUGUR_TEST_REAP_PID:-}" ]]; then kill -9 "\$AUGUR_TEST_REAP_PID" 2>/dev/null || true; fi
SHIM
chmod +x "$TMPD/augur-vm"

# Pull the real helper out of augur without running its dispatch tail (AUGUR_SOURCE_ONLY seam),
# so this can never drift from the shipped function.
AUGUR_SOURCE_ONLY=1 source "$AUGUR"
set +e                                    # augur enables `set -e`; restore lib.sh assert-and-continue
VM_CLI="$TMPD/augur-vm"

# Stand-in for the masked-SIGTERM `run` process: it IGNORES SIGTERM, so a raw kill cannot reap it —
# only the bounded `augur-vm stop` (which our shim maps to SIGKILL) will.
bash -c 'trap "" TERM; while :; do sleep 0.2; done' & fake_pid=$!
export AUGUR_TEST_REAP_PID="$fake_pid"
# Safety net: never let a regressed (hanging) helper wedge CI — free the stand-in after 5s.
( sleep 5; kill -9 "$fake_pid" 2>/dev/null ) & safety=$!

t0=$SECONDS
stop_and_reap_macos_vm testvm "$fake_pid"
elapsed=$(( SECONDS - t0 ))
kill "$safety" 2>/dev/null; wait "$safety" 2>/dev/null

has "$(cat "$calls")" 'stop testvm' "helper routes teardown through 'augur-vm stop testvm'"
if (( elapsed < 3 )); then
  ok "helper reaps promptly (~${elapsed}s) — no hang on a SIGTERM-ignoring process"
else
  fail "helper hung (~${elapsed}s)" "teardown not bounded — only the 5s safety net freed it"
fi

finish
