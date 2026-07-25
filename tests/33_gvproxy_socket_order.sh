#!/usr/bin/env bash
# Tier 1 — start_gvproxy socket lifecycle (runs anywhere; no container/VM host needed).
# Guards the fix for the "guest boots with no NIC" bug: start_gvproxy unlinked the vfkit socket
# BEFORE its already-running check, so on the path where the VM is stopped but gvproxy is still
# alive (a `vm stop` issued outside augur, or a boot that died after gvproxy came up) `augur up
# --macos` deleted the LIVE gvproxy's socket path and returned 0 as if it had reused it. The
# `vm run --net-vfkit=<that path>` that follows then had nothing to attach to — and since an
# unlink does not tear down existing datagram connections, gvproxy stayed up, so the symptom was
# a NIC-less guest instead of a clean error.
#
# The `rm -f` itself must STAY: a stale socket file left by a crashed gvproxy would satisfy the
# `-S` startup wait at the end of start_gvproxy instantly. It just has to run only on the path
# that actually starts a new gvproxy. Both directions are asserted below, so neither reordering
# the unlink back up nor deleting it outright can pass.
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/lib.sh"
AUGUR="$REPO/augur"

# Pull the real start_gvproxy out of augur without running its dispatch tail (AUGUR_SOURCE_ONLY
# seam), so this can never drift from the shipped function.
AUGUR_SOURCE_ONLY=1 source "$AUGUR"
set +e                                    # augur enables `set -e`; restore lib.sh assert-and-continue
TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT
AUGUR_PROXY_DIR="$TMPD"                    # keep the test off the real ~/.augur/proxy

# Fake gvproxy: records the argv it was launched with. It never binds a real unixgram socket.
LAUNCHED="$TMPD/launched"
cat > "$TMPD/augur-gvproxy" <<SHIM
#!/usr/bin/env bash
echo "\$*" >> "$LAUNCHED"
SHIM
chmod +x "$TMPD/augur-gvproxy"

# Stubs go in AFTER the source: bash resolves function calls at call time, so these win over
# the definitions in augur.
resolve_gvproxy() { echo "$TMPD/augur-gvproxy"; }
GVPROXY_ALIVE=true                         # flipped per section; `true`/`false` are commands
gvproxy_running() { $GVPROXY_ALIVE; }

# Because the fake never binds a socket, the start path's `-S` wait times out and ends in
# `exit 1` — run start_gvproxy in a subshell so that cannot kill this script. The filesystem
# effects (the unlink, which is what is under test) are still observed out here.
run_start_gvproxy() { ( start_gvproxy ) >/dev/null 2>&1; }

sock="$(gvproxy_socket)"; pidfile="$(gvproxy_pidfile)"

section "Tier 1 — reusing a live gvproxy must not unlink its socket"

: > "$LAUNCHED"
: > "$sock"                                # stand-in for the live gvproxy's bound socket path
echo 4242 > "$pidfile"                     # ...and its pidfile
GVPROXY_ALIVE=true
run_start_gvproxy; rc=$?

eq 0 "$rc" "start_gvproxy returns 0 when gvproxy is already running"
if [[ -e "$sock" ]]; then
  ok "the live gvproxy's socket path survives (--net-vfkit still has something to attach to)"
else
  fail "start_gvproxy unlinked a LIVE gvproxy's socket" "the rm -f ran before the already-running early return"
fi
eq "" "$(cat "$LAUNCHED")" "no second gvproxy is launched onto the same socket"
eq 4242 "$(cat "$pidfile")" "the live gvproxy's pidfile is left untouched"

section "Tier 1 — a stale socket from a crashed gvproxy is still cleared"

rm -f "$pidfile"                           # no live gvproxy...
: > "$LAUNCHED"
: > "$sock"                                # ...but its socket file is still lying around
GVPROXY_ALIVE=false
run_start_gvproxy

if [[ -e "$sock" ]]; then
  fail "the stale socket file was not removed" "the -S startup wait would pass instantly against it"
else
  ok "the stale socket file is removed on the path that starts a new gvproxy"
fi
has "$(cat "$LAUNCHED")" "--listen-vfkit" "a new gvproxy is launched when none is running"

finish
