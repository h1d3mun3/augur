#!/usr/bin/env bash
# Tier 0 — install-cert host-side validation + approval gate (pure + openssl, runs anywhere).
#
# validate_cert_file: fails CLOSED. A trusted CA is only installable from a file that exists,
#     ends in .crt, parses as PEM X.509, and holds EXACTLY ONE certificate. Any deviation (wrong
#     extension, two certs, garbage bytes, missing path, missing openssl) refuses the install.
# confirm_cert_install: because a trusted CA can MITM every allowlisted domain, the approval never
#     defaults to yes. AUGUR_ACCEPT_CERT_INSTALL=1 accepts non-interactively; otherwise it prompts
#     ONLY on a real TTY and REFUSES when stdin/stdout are not a terminal (our piped test case).
#
# Same slice-by-name technique as 02_resource_secret_unit.sh: augur's entry-point never runs.
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/lib.sh"
AUGUR="$REPO/augur"

# openssl underpins every assertion here (fixtures + validation); skip the tier if it's absent.
command -v openssl >/dev/null || { skip "install-cert unit" "openssl not available"; finish; exit $?; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

helpers="$WORK/helpers.sh"; : > "$helpers"
for f in validate_cert_file confirm_cert_install; do
  awk -v n="$f" 'index($0, n"()")==1 {f=1} f{print} f&&/^}/{exit}' "$AUGUR" >> "$helpers"
  echo >> "$helpers"
done
# Stub augur's loggers so the sliced helpers run standalone (they call error/warn/info/success).
error()   { :; }
warn()    { :; }
info()    { :; }
success() { :; }
# confirm_cert_install interpolates these color vars under `set -u`; define them empty.
BOLD=''; RESET=''; CYAN=''
# shellcheck disable=SC1090
source "$helpers"

# ── Fixtures: a valid single-cert .crt, plus three that must be rejected ───────
openssl req -x509 -newkey rsa:2048 -nodes -keyout /dev/null -out "$WORK/good.crt" -days 1 -subj "/CN=augur-test" 2>/dev/null
cp "$WORK/good.crt" "$WORK/good.pem"                       # right content, wrong extension
cat "$WORK/good.crt" "$WORK/good.crt" > "$WORK/two.crt"    # two certs in one file
printf 'this is not a certificate\n' > "$WORK/garbage.crt"

# ── validate_cert_file — fail-closed one-cert-per-file contract ────────────────
section "validate_cert_file accepts one valid .crt and refuses everything else"
if validate_cert_file "$WORK/good.crt";    then ok "accepts a valid single-cert .crt";        else fail "accepts a valid single-cert .crt"; fi
if validate_cert_file "$WORK/good.pem";    then fail "rejects the wrong extension (.pem)";     else ok "rejects the wrong extension (.pem)"; fi
if validate_cert_file "$WORK/two.crt";     then fail "rejects two certs in one file";          else ok "rejects two certs in one file"; fi
if validate_cert_file "$WORK/garbage.crt"; then fail "rejects a non-PEM-X.509 file";           else ok "rejects a non-PEM-X.509 file"; fi
if validate_cert_file "$WORK/nope.crt";    then fail "rejects a nonexistent path";              else ok "rejects a nonexistent path"; fi

# ── confirm_cert_install — approval never defaults to yes ──────────────────────
section "confirm_cert_install accepts only via env, and refuses non-interactively"
if AUGUR_ACCEPT_CERT_INSTALL=1 confirm_cert_install "$WORK/good.crt" "test guest"; then
  ok   "AUGUR_ACCEPT_CERT_INSTALL=1 accepts non-interactively"
else
  fail "AUGUR_ACCEPT_CERT_INSTALL=1 accepts non-interactively"
fi
# No env + non-TTY stdin/stdout (this harness runs piped) must fail closed. </dev/null pins stdin.
if confirm_cert_install "$WORK/good.crt" "test guest" </dev/null; then
  fail "refuses to install a CA non-interactively"
else
  ok   "refuses to install a CA non-interactively"
fi

finish
