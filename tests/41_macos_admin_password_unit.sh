#!/usr/bin/env bash
# Tier 0 — macOS 27 automated guest provisioning (ADR-0018), pure-function slice.
# macos_admin_password() decides which credential every macOS-mode sudo/SSH call uses
# (fixed admin/admin, ADR-0007, unless the base VM was built via automated provisioning,
# in which case a generated password is on disk); host_macos_major_version() is the host
# half of the eligibility check for that automated path. Both are pure enough to unit-test
# without a VM — the actual `augur-vm run --provision-*` / `guest-os-version` wiring is
# exercised live only (no free-runner CI can boot a VZ guest; see tests/README.md).
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/lib.sh"
AUGUR="$REPO/augur"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# Extract the two helpers BY NAME, same technique as 01_egress_allowlist_unit.sh — augur's
# entry-point dispatch never runs.
helpers="$WORK/helpers.sh"
for f in host_macos_major_version macos_admin_password; do
  awk -v n="$f" 'index($0, n"()")==1 {f=1} f{print} f&&/^}/{exit}' "$AUGUR" >> "$helpers"
  echo >> "$helpers"
done

# shellcheck disable=SC2034  # consumed by macos_admin_password() once sourced from $helpers below
MACOS_SSH_USER="admin"
MACOS_ADMIN_PASSWORD_FILE="$WORK/macos-admin-password"
# shellcheck disable=SC1090
source "$helpers"

section "Tier 0 — macos_admin_password (ADR-0018 credential resolution)"
eq "admin" "$(macos_admin_password)" "falls back to the fixed ADR-0007 credential when no override file exists"

printf 'sUpErSecret123==' > "$MACOS_ADMIN_PASSWORD_FILE"
eq "sUpErSecret123==" "$(macos_admin_password)" "reads the persisted password when the override file exists"

rm -f "$MACOS_ADMIN_PASSWORD_FILE"
eq "admin" "$(macos_admin_password)" "reverts to the fixed credential once the override file is removed"

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

finish
