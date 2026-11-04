#!/usr/bin/env bash
# Tier 0 — macOS VM admin credential and macOS 27 automated guest provisioning, pure-function slice.
# macos_admin_password() decides which credential every macOS-mode sudo/SSH call uses (see its
# comment in augur): a per-VM file inside the VM's bundle. host_macos_major_version() is the host
# half of the eligibility check for the automated path. All of it is testable without a VM — the
# actual `augur-vm run --provision-*` / `guest-os-version` / `clone` wiring is exercised live only
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
build="$(declare -f cmd_build_macos)"
has "$build" 'macos_store_admin_password "$MACOS_BUILD_VM" "$new_password"' \
  "build, automated flow: stores the generated password in the build VM"
has "$build" 'macos_store_admin_password "$MACOS_BUILD_VM" "$MACOS_SSH_USER"' \
  "build, manual flow: stores the fixed password in the build VM (no 'file absent = admin' fallback)"
store_at="$(printf '%s\n' "$build" | grep -n 'macos_store_admin_password "$MACOS_BUILD_VM" "$new_password"' | cut -d: -f1)"
run_at="$(printf '%s\n' "$build" | grep -n -- '--provision-password-stdin' | head -n1 | cut -d: -f1)"
if [[ -n "$store_at" && -n "$run_at" && "$store_at" -lt "$run_at" ]]; then
  ok "build, automated flow: the password is stored before the provisioning boot"
else fail "build, automated flow: the password is not stored before the provisioning boot" "store@${store_at:-?} run@${run_at:-?}"; fi
clone_at="$(printf '%s\n' "$build" | grep -n '"$VM_CLI" clone "$MACOS_BUILD_VM" "$MACOS_BASE_VM"' | cut -d: -f1)"
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
run_at="$(printf '%s\n' "$update" | grep -n '"$VM_CLI" run' | head -n1 | cut -d: -f1)"
if [[ -n "$req_at" && -n "$run_at" && "$req_at" -lt "$run_at" ]]; then
  ok "update --macos: checks the base VM's credential before booting it"
else fail "update --macos: does not check the base VM's credential before booting it" "require@${req_at:-?} run@${run_at:-?}"; fi

section "Tier 0 — host_macos_major_version (parses sw_vers -productVersion)"
shimdir="$WORK/bin"; mkdir -p "$shimdir"
cat > "$shimdir/sw_vers" <<'SHIM'
#!/usr/bin/env bash
[[ "$1" == "-productVersion" ]] && echo "$FAKE_PRODUCT_VERSION"
SHIM
chmod +x "$shimdir/sw_vers"

eq "27" "$(FAKE_PRODUCT_VERSION="27.0" PATH="$shimdir:$PATH" host_macos_major_version)" \
  "parses the major version out of a dotted productVersion (27.0 -> 27)"
eq "26" "$(FAKE_PRODUCT_VERSION="26.1.3" PATH="$shimdir:$PATH" host_macos_major_version)" \
  "parses the major version out of a three-component productVersion (26.1.3 -> 26)"

# No `sw_vers` on PATH at all (the Linux offline-tests runner, and defense in depth) must
# yield empty — never a false "eligible for macOS 27 provisioning".
empty_path_dir="$WORK/empty-bin"; mkdir -p "$empty_path_dir"
eq "" "$(PATH="$empty_path_dir" host_macos_major_version)" \
  "returns empty (never guesses) when sw_vers is unavailable"

section "Tier 0 — vm_cli_supports_provisioning (asks the binary, not the host's OS)"
# The automated path is compiled out of augur-vm when it is built against an SDK older than
# macOS 27, so the host reporting 27 is not evidence the binary can do it — an OS upgraded
# without re-running `bash install` is exactly that case. Stub `run --help` both ways.
cat > "$WORK/vm-cli-capable" <<'STUB'
#!/usr/bin/env bash
[[ "$1" == "run" && "$2" == "--help" ]] && cat <<'HELP'
USAGE: augur-vm run <name> [--no-graphics] [--provision-username <user>] [--provision-password-stdin]
HELP
STUB
cat > "$WORK/vm-cli-plain" <<'STUB'
#!/usr/bin/env bash
[[ "$1" == "run" && "$2" == "--help" ]] && cat <<'HELP'
USAGE: augur-vm run <name> [--no-graphics] [--dir <name:path>] [--net-nat]
HELP
STUB
chmod +x "$WORK/vm-cli-capable" "$WORK/vm-cli-plain"

VM_CLI="$WORK/vm-cli-capable"
if vm_cli_supports_provisioning; then
  ok "detects a binary whose run --help advertises --provision-password-stdin"
else
  fail "detects a binary whose run --help advertises --provision-password-stdin"
fi

VM_CLI="$WORK/vm-cli-plain"
if vm_cli_supports_provisioning; then
  fail "reports unsupported for a binary built without the feature" "matched a help text that lacks the flag"
else
  ok "reports unsupported for a binary built without the feature"
fi

# A binary that cannot even run (wrong arch, missing, unsigned) must read as "unsupported"
# rather than crashing the build decision — same fail-safe direction as the case above.
VM_CLI="$WORK/does-not-exist"
if vm_cli_supports_provisioning; then
  fail "reports unsupported when the binary cannot be run at all"
else
  ok "reports unsupported when the binary cannot be run at all"
fi

finish
