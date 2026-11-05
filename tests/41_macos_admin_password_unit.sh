#!/usr/bin/env bash
# Tier 0 — macOS VM admin credential and macOS 27 automated guest provisioning, pure-function slice.
# macos_admin_password() decides which credential every macOS-mode sudo/SSH call uses (see its
# comment in augur): a per-VM file inside the VM's bundle. macos_setup_flow() maps augur-vm's
# eligibility answer to a build flow, and the two flow functions own every flow-specific step. All
# of it is testable without a VM (augur-vm is stubbed); the real `augur-vm run --provision-*` /
# `provisioning-support` / `clone` behaviour is exercised live only
# (no free-runner CI can boot a VZ guest; see tests/README.md).
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/lib.sh"
AUGUR="$REPO/augur"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# The resolved $VM_CLI can never be a real augur-vm. Sourcing stops before the entry-point dispatch.
export AUGUR_VM_BIN="$WORK/no-such-augur-vm"
# shellcheck disable=SC1090
AUGUR_SOURCE_ONLY=1 source "$AUGUR"
set +e                                    # augur enables `set -e`; restore lib.sh assert-and-continue
# shellcheck disable=SC2034  # read by the sourced augur functions
AUGUR_DIR="$WORK/augur"

# Portable octal mode (GNU stat on the Linux runner, BSD stat on macOS).
file_mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }

section "Tier 0 — macos_admin_password: one credential per VM, stored in its bundle"
eq "$AUGUR_DIR/vms/testvm/admin-password" "$(macos_admin_password_file testvm)" \
  "the credential lives inside the VM's augur-vm bundle directory (so clone/delete carry it)"

mkdir -p "$AUGUR_DIR/vms/testvm"
out="$( macos_admin_password testvm 2>"$WORK/err" )"; rc=$?
eq "1" "$rc" "no stored credential: refuses (rc 1) instead of guessing a password"
eq "" "$out" "no stored credential: prints no password"
err="$(cat "$WORK/err")"
has "$err" "no stored admin password" "no stored credential: says what is missing"
has "$err" "augur build --macos" "no stored credential: names the base rebuild"
has "$err" "augur destroy --macos && augur up --macos" "no stored credential: names recreating the project VM"

out="$( macos_admin_password_stdin testvm 2>/dev/null )"; rc=$?
if [[ "$rc" -ne 0 ]]; then ok "no stored credential: macos_admin_password_stdin fails (the sudo pipeline fails under pipefail)"
else fail "no stored credential: macos_admin_password_stdin returned 0"; fi
eq "" "$out" "no stored credential: macos_admin_password_stdin feeds sudo nothing"

( require_macos_admin_password testvm ) 2>/dev/null; rc=$?
eq "1" "$rc" "no stored credential: require_macos_admin_password exits 1"

macos_store_admin_password testvm 'sUpErSecret123=='
eq "sUpErSecret123==" "$(macos_admin_password testvm)" "reads back the stored password"
eq "16" "$(wc -c < "$(macos_admin_password_file testvm)" | tr -d ' ')" "stored without a trailing newline"
eq "600" "$(file_mode "$(macos_admin_password_file testvm)")" "stored with mode 600"
eq "sUpErSecret123==" "$(macos_admin_password_stdin testvm)" "macos_admin_password_stdin feeds the stored password"
eq "1" "$(macos_admin_password_stdin testvm | wc -l | tr -d ' ')" "…as exactly one line"
( require_macos_admin_password testvm ); rc=$?
eq "0" "$rc" "stored credential: require_macos_admin_password passes"

# `>` into an existing file keeps its mode, so the store must chmod even when umask would not.
chmod 644 "$(macos_admin_password_file testvm)"
( umask 022; macos_store_admin_password testvm 'admin' )
eq "600" "$(file_mode "$(macos_admin_password_file testvm)")" "re-storing over a 644 file leaves it 600"
eq "admin" "$(macos_admin_password testvm)" "re-storing replaces the password (the manual flow's fixed one)"

# A project VM cloned from an older base keeps that base's password after the base is rebuilt.
mkdir -p "$AUGUR_DIR/vms/old-clone" "$AUGUR_DIR/vms/new-base"
macos_store_admin_password old-clone 'oldBasePassword=='
macos_store_admin_password new-base 'newBasePassword=='
eq "oldBasePassword==" "$(macos_admin_password old-clone)" "each VM reads its own credential (old clone)"
eq "newBasePassword==" "$(macos_admin_password new-base)" "each VM reads its own credential (rebuilt base)"

section "Tier 0 — the commands write and check the credential where they must"
# Raw source, not `declare -f`, which reflows case arms and brace groups.
src_of() { awk -v n="$1" 'index($0, n"()")==1 {f=1} f{print} f&&/^}/{exit}' "$AUGUR"; }
auto="$(src_of macos_first_boot_automated)"
manual="$(src_of macos_first_boot_manual)"
has "$auto" 'macos_store_admin_password "$MACOS_BUILD_VM" "$password"' \
  "build, automated flow: stores the generated password in the build VM"
has "$manual" 'macos_store_admin_password "$MACOS_BUILD_VM" "$MACOS_MANUAL_SETUP_PASSWORD"' \
  "build, manual flow: stores the fixed password in the build VM (no 'file absent = admin' fallback)"
# line_of TEXT NEEDLE — first line number of NEEDLE in TEXT (fixed string), or empty.
line_of() { printf '%s\n' "$1" | grep -nF -- "$2" | head -n1 | cut -d: -f1; }
store_at="$(line_of "$auto" 'macos_store_admin_password "$MACOS_BUILD_VM"')"
run_at="$(line_of "$auto" '--provision-password-stdin')"
if [[ -n "$store_at" && -n "$run_at" && "$store_at" -lt "$run_at" ]]; then
  ok "build, automated flow: the password is stored before the provisioning boot"
else fail "build, automated flow: the password is not stored before the provisioning boot" "store@${store_at:-?} run@${run_at:-?}"; fi
store_at="$(line_of "$manual" 'macos_store_admin_password "$MACOS_BUILD_VM"')"
read_at="$(line_of "$manual" 'macos_admin_password_stdin "$MACOS_BUILD_VM"')"
if [[ -n "$store_at" && -n "$read_at" && "$store_at" -lt "$read_at" ]]; then
  ok "build, manual flow: the password is stored before the auto-login step reads it"
else fail "build, manual flow: the password is not stored before it is read" "store@${store_at:-?} read@${read_at:-?}"; fi
build="$(src_of cmd_build_macos)"
clone_at="$(printf '%s\n' "$build" | grep -n 'macos_save_scratch_as_base "$MACOS_BUILD_VM"' | cut -d: -f1)"
has "$(declare -f macos_save_scratch_as_base)" '"$VM_CLI" clone "$scratch" "$MACOS_BASE_VM"' "the save clones the scratch VM into the base VM"
if [[ -n "$clone_at" ]]; then ok "build: the base VM is a clone of the build VM (so it carries the credential)"
else fail "build: the base VM is no longer a clone of the build VM" "the credential would not reach the base"; fi
# up/update check the credential before booting anything.
up="$(declare -f cmd_up_macos)"
req_at="$(printf '%s\n' "$up" | grep -n 'require_macos_admin_password "$project_vm"' | tail -n1 | cut -d: -f1)"
set_at="$(printf '%s\n' "$up" | grep -n '"$VM_CLI" set "$project_vm"' | head -n1 | cut -d: -f1)"
if [[ -n "$req_at" && -n "$set_at" && "$req_at" -lt "$set_at" ]]; then
  ok "up --macos: checks the project VM's credential before set/run"
else fail "up --macos: does not check the project VM's credential before set/run" "require@${req_at:-?} set@${set_at:-?}"; fi
# The already-running branch returns early, so it needs its own check before that return.
running_branch="$(printf '%s\n' "$up" | awk '/if macos_vm_running "\$project_vm"; then/{f=1} f{print} f&&/return 0/{exit}')"
if [[ "$running_branch" == *'require_macos_admin_password "$project_vm"'* ]]; then
  ok "up --macos: the already-running branch checks the credential before returning"
else fail "up --macos: the already-running branch returns without checking the credential" "${running_branch:0:80}"; fi
update="$(declare -f cmd_update_macos)"
req_at="$(printf '%s\n' "$update" | grep -n 'require_macos_admin_password "$MACOS_BASE_VM"' | head -n1 | cut -d: -f1)"
run_at="$(printf '%s\n' "$update" | grep -n 'macos_boot_scratch_vm_nat' | head -n1 | cut -d: -f1)"
if [[ -n "$req_at" && -n "$run_at" && "$req_at" -lt "$run_at" ]]; then
  ok "update --macos: checks the base VM's credential before booting it"
else fail "update --macos: does not check the base VM's credential before booting it" "require@${req_at:-?} run@${run_at:-?}"; fi

section "Tier 0 — cmd_build_macos: one decision, one flow function, then one shared path"
# All flow-specific work (boot, SSH wait, credential, auto-login) lives in the two flow functions;
# cmd_build_macos only picks one and must not grow its own per-flow branches again.
flow_at="$(line_of "$build" 'flow="$(macos_setup_flow "$MACOS_BUILD_VM" "$manual_setup")"')"
create_at="$(line_of "$build" '"$VM_CLI" create "$MACOS_BUILD_VM"')"
auto_at="$(line_of "$build" 'automated) macos_first_boot_automated ;;')"
manual_at="$(line_of "$build" 'manual)    macos_first_boot_manual ;;')"
key_at="$(line_of "$build" 'Setting up SSH key authentication')"
if [[ -n "$create_at" && -n "$flow_at" && -n "$auto_at" && -n "$manual_at" && -n "$key_at" \
      && "$create_at" -lt "$flow_at" && "$flow_at" -lt "$auto_at" && "$flow_at" -lt "$manual_at" \
      && "$auto_at" -lt "$key_at" && "$manual_at" -lt "$key_at" ]]; then
  ok "build: create → macos_setup_flow → macos_first_boot_<flow> → shared SSH-key setup"
else
  fail "build: the flow dispatch is missing or out of order" \
    "create@${create_at:-?} decide@${flow_at:-?} auto@${auto_at:-?} manual@${manual_at:-?} key@${key_at:-?}"
fi
known_at="$(line_of "$build" 'rm -f "$(vm_known_hosts_file "$MACOS_BUILD_VM")"')"
if [[ -n "$known_at" && -n "$auto_at" && "$known_at" -lt "$auto_at" && "$known_at" -lt "$manual_at" ]]; then
  ok "build: the stale host key is discarded before either flow's first SSH connection"
else fail "build: the stale host key is not discarded before the flows SSH in" "rm@${known_at:-?} auto@${auto_at:-?}"; fi
has "$build" '"$MACOS_BUILD_VM_IP"' "build: the shared path uses the IP the flow handed back"
has "$build" 'MACOS_SCRATCH_VM_PID="$MACOS_BUILD_VM_PID"' "build: the shared path reaps the pid the flow handed back"
for needle in '--provision-' 'kcpassword' 'Setup Assistant (manual)' 'macos_store_admin_password' 'openssl rand'; do
  hasnt "$build" "$needle" "build: no flow-specific step left inline ($needle)"
done
for fn in macos_first_boot_automated macos_first_boot_manual; do
  body="$(src_of "$fn")"
  has "$body" 'MACOS_BUILD_VM_PID=$!' "$fn: hands back the backgrounded run's pid in the main shell"
  has "$body" 'MACOS_BUILD_VM_IP="$(macos_vm_ip "$MACOS_BUILD_VM"' "$fn: hands back the guest IP"
  has "$body" 'macos_wait_for_ssh "$MACOS_BUILD_VM_IP"' "$fn: returns only once SSH accepts connections"
done
has "$auto" '--no-graphics' "automated flow: boots headless"
has "$manual" "xxd -r -p > /etc/kcpassword" "manual flow: writes /etc/kcpassword (auto-login lands in the base image)"
has "$manual" '${MACOS_MANUAL_SETUP_KCPASSWORD}' "manual flow: writes the named kcpassword constant, not inline bytes"
has "$manual" 'autoLoginUser ${MACOS_SSH_USER}' "manual flow: names the auto-login user"
has "$manual" '${MACOS_MANUAL_SETUP_PASSWORD}' "manual flow: tells the operator the named fixed password"

section "Tier 0 — MACOS_MANUAL_SETUP_KCPASSWORD encodes MACOS_MANUAL_SETUP_PASSWORD"
# Decode with the kcpassword cipher (XOR with a cycling 11-byte key, stop at the encoded NUL).
kc_key=(0x7d 0x89 0x52 0x23 0xd2 0xbc 0xdd 0xea 0xa3 0xb9 0x1f)
decoded=""; terminated=false; hex="$MACOS_MANUAL_SETUP_KCPASSWORD"
for (( i = 0; i < ${#hex} / 2; i++ )); do
  byte=$(( 16#${hex:i*2:2} ^ kc_key[i % 11] ))
  (( byte == 0 )) && { terminated=true; break; }
  decoded+="$(printf "\\x$(printf '%02x' "$byte")")"
done
eq "$MACOS_MANUAL_SETUP_PASSWORD" "$decoded" "the kcpassword bytes decode to the manual-setup password"
$terminated && ok "the encoded password is NUL-terminated" || fail "the encoded password is NUL-terminated"
eq "0" "$(( ${#hex} / 2 % 12 ))" "the encoded blob is a multiple of 12 bytes"
eq "admin" "$MACOS_MANUAL_SETUP_PASSWORD" "the manual-setup password is still the fixed one the bytes were made for"
# The flow refuses to start if the password changes without the bytes.
out="$( MACOS_MANUAL_SETUP_PASSWORD=changed; macos_first_boot_manual 2>&1 </dev/null )"; rc=$?
eq "1" "$rc" "manual flow: refuses to run when the password no longer matches the bytes"
has "$out" "re-encode" "manual flow: says the kcpassword bytes need re-encoding"
hasnt "$out" "Setup Assistant (manual)" "manual flow: refuses before showing the operator anything"

section "Tier 0 — macos_setup_flow: augur-vm decides, augur maps the answer to a flow"
# Stub augur-vm: `provisioning-support <vm>` prints $FAKE_ANSWER and exits $FAKE_RC; it records
# its argv so the test can check it asked about the right VM.
cat > "$WORK/vm-cli-stub" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$FAKE_ARGV_LOG"
[[ -n "${FAKE_STDERR:-}" ]] && echo "$FAKE_STDERR" >&2
[[ -n "${FAKE_ANSWER:-}" ]] && echo "$FAKE_ANSWER"
exit "${FAKE_RC:-0}"
STUB
chmod +x "$WORK/vm-cli-stub"
VM_CLI="$WORK/vm-cli-stub"
export FAKE_ARGV_LOG="$WORK/argv"

# decide ANSWER RC MANUAL_FLAG — sets out (stdout), err (stderr), rc
decide() {
  : > "$FAKE_ARGV_LOG"
  out="$(FAKE_ANSWER="$1" FAKE_RC="$2" macos_setup_flow buildvm "$3" 2>"$WORK/flow-err")"; rc=$?
  err="$(cat "$WORK/flow-err")"
}

decide supported 0 false
eq "automated" "$out" "supported → automated"
eq "0" "$rc" "supported → succeeds"
eq "provisioning-support buildvm" "$(cat "$FAKE_ARGV_LOG")" "asks augur-vm provisioning-support about the given VM"
has "$err" "provisioning the admin account automatically" "supported → says it is going unattended (on stderr)"

for reason in host guest; do
  decide "$reason" 0 false
  eq "manual" "$out" "$reason → manual"
  eq "0" "$rc" "$reason → succeeds"
  eq "" "$err" "$reason → no warning (the OS pair simply does not qualify)"
done

decide sdk 0 false
eq "manual" "$out" "sdk → manual"
has "$err" "built against an SDK older than macOS 27" "sdk → never a silent downgrade: says the binary lacks the feature"
has "$err" "bash install" "sdk → names the fix (re-run bash install)"
has "$err" "Xcode 27" "sdk → names the Xcode needed"

decide "" 64 false
eq "manual" "$out" "augur-vm without the subcommand (usage-error exit 64) → manual"
eq "0" "$rc" "augur-vm without the subcommand → still succeeds"
has "$err" "bash install" "augur-vm without the subcommand → hints to re-run bash install"
eq "1" "$(printf '%s\n' "$err" | wc -l | tr -d ' ')" "augur-vm without the subcommand → a one-line hint"

decide "" 1 false
eq "1" "$rc" "augur-vm failing (e.g. VM missing, exit 1) → an error, not a silent manual flow"
eq "" "$out" "augur-vm failing → no flow printed"
has "$err" "provisioning-support buildvm" "augur-vm failing → names the failed command"

# augur-vm's own diagnostic reaches the operator on the failure path, and only on stderr.
: > "$FAKE_ARGV_LOG"
out="$(FAKE_STDERR="Error: No such VM: buildvm" FAKE_RC=1 macos_setup_flow buildvm false 2>"$WORK/flow-err")"; rc=$?
err="$(cat "$WORK/flow-err")"
eq "1" "$rc" "augur-vm failing with a message → an error"
has "$err" "augur-vm: Error: No such VM: buildvm" "augur-vm failing → shows augur-vm's own message"
eq "" "$out" "augur-vm failing with a message → stdout stays empty"
# Its stderr stays hidden when the answer is usable: stdout is only the flow name, stderr only augur's.
out="$(FAKE_STDERR="some augur-vm chatter" FAKE_ANSWER=host FAKE_RC=0 macos_setup_flow buildvm false 2>"$WORK/flow-err")"
eq "manual" "$out" "augur-vm chatter on a usable answer → stdout carries only the flow name"
hasnt "$(cat "$WORK/flow-err")" "some augur-vm chatter" "augur-vm chatter on a usable answer → not shown"
out="$(FAKE_STDERR="Error: Unknown subcommand" FAKE_RC=64 macos_setup_flow buildvm false 2>"$WORK/flow-err")"
hasnt "$(cat "$WORK/flow-err")" "Unknown subcommand" "augur-vm without the subcommand → its usage error is replaced by the hint"

decide "something-new" 0 false
eq "1" "$rc" "an unrecognised answer → an error, never guessed"

: > "$FAKE_ARGV_LOG"
out="$(FAKE_ANSWER=supported FAKE_RC=0 macos_setup_flow buildvm true 2>"$WORK/flow-err")"; rc=$?
eq "manual" "$out" "--manual-setup → manual even when automated is supported"
has "$(cat "$WORK/flow-err")" "--manual-setup given" "--manual-setup → says why"
eq "" "$(cat "$FAKE_ARGV_LOG")" "--manual-setup → does not need to ask augur-vm"

# No messages may leak onto stdout: cmd_build_macos captures it as the flow name.
out="$(FAKE_ANSWER=sdk FAKE_RC=0 macos_setup_flow buildvm false 2>/dev/null)"
eq "manual" "$out" "stdout carries only the flow name (messages go to stderr)"

section "Tier 0 — augur-vm provisioning-support (source guard; Virtualization cannot build here)"
ps_src="$REPO/augur-vm/Sources/augur-vm/ProvisioningSupportCommand.swift"
if [[ -f "$ps_src" ]]; then
  ps_txt="$(cat "$ps_src")"
  has "$ps_txt" 'commandName: "provisioning-support"' "the subcommand is named provisioning-support"
  has "$ps_txt" 'case supported, host, guest, sdk' "it answers with exactly the tokens augur maps"
  has "$ps_txt" '#available(macOS 27, *)' "host check: the same #available test RunSession applies"
  has "$ps_txt" 'guestOSMajorVersion' "guest check: the installed guest OS recorded at create"
  has "$ps_txt" '#if compiler(>=6.4)' "sdk check: the same compile-time gate as the run --provision-* options"
  hasnt "$ps_txt" 'func validate()' "a missing VM is a run() error (exit 1), not a validation error (exit 64)"
  has "$(cat "$REPO/augur-vm/Sources/augur-vm/AugurVM.swift")" 'ProvisioningSupportCommand.self' \
    "the subcommand is registered"
else
  fail "ProvisioningSupportCommand.swift present" "not found at $ps_src"
fi

finish
