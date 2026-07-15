#!/usr/bin/env bash
# Tier 0 — setup-token persistence hardening (pure function, runs anywhere).
#
# C3: save_oauth_token is the sole credential validator today. Before it writes the
#     captured `claude setup-token` value to the host token file augur replays into
#     every guest, it enforces a conservative shape: the sk-ant- prefix, a 20–500
#     length window, and only token-safe chars [A-Za-z0-9._-] (no spaces / control
#     bytes / quotes). A rejected token must leave NOTHING on disk; an accepted one
#     lands 0600. See docs §4 C3 / addendum A2.
#
# Same slice-by-name technique as 02_resource_secret_unit.sh: augur's entry-point never runs.
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/lib.sh"
AUGUR="$REPO/augur"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

helpers="$WORK/helpers.sh"; : > "$helpers"
for f in save_oauth_token; do
  awk -v n="$f" 'index($0, n"()")==1 {f=1} f{print} f&&/^}/{exit}' "$AUGUR" >> "$helpers"
  echo >> "$helpers"
done
# Stub augur's loggers so the sliced helper runs standalone (it calls error/success/info).
error()   { :; }
warn()    { :; }
success() { :; }
info()    { :; }
# The success message interpolates these color vars; define them empty under set -u.
BOLD=''
RESET=''
# shellcheck disable=SC1090
source "$helpers"

# Redirect the write into the sandbox: dest is "$HOME/.claude_code_oauth_token".
export HOME="$WORK/home"; mkdir -p "$HOME"
dest="$HOME/.claude_code_oauth_token"

# reject T NAME — assert save_oauth_token refuses T (nonzero) AND writes no file.
reject() {
  local t="$1" name="$2"
  rm -f "$dest"
  if save_oauth_token "$t"; then fail "$name — returned 0 (should reject)"; else ok "$name — rejected"; fi
  [[ -e "$dest" ]] && fail "$name — wrote a file on reject" || ok "$name — no file written"
}

# ── Accept a valid token ──────────────────────────────────────────────────────
section "accepts a well-formed sk-ant- token and writes it 0600"
rm -f "$dest"
valid="sk-ant-oat01-AbC_def.123-XYZ"
if save_oauth_token "$valid"; then ok "returns 0 for a valid token"; else fail "returns 0 for a valid token"; fi
[[ -e "$dest" ]] && ok "dest file exists" || fail "dest file exists"
eq "$valid" "$(cat "$dest")" "dest content equals the token exactly"
# Portable perms check (Linux CI + macOS): first field of `ls -l` — no stat -c.
eq "-rw-------" "$(ls -l "$dest" | awk 'NR==1{print $1}')" "dest permissions are 600"

# ── Reject malformed tokens (nothing must be written) ─────────────────────────
section "rejects malformed tokens and writes nothing"
reject ""                                 "empty token"
reject "nope-ant-abcdefghijklmno"         "wrong prefix"
reject "sk-ant-1"                          "too short (<20)"
reject "sk-ant-$(printf 'a%.0s' {1..600})" "too long (>500)"
reject "sk-ant-with space here more"       "contains a space"
reject $'sk-ant-abc\x01defghijkl'          "contains a control byte"
reject "sk-ant-abc'defghijklmno"           "contains a single quote"

finish
