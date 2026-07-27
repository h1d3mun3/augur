#!/usr/bin/env bash
# Tier 1 — gvproxy socket lifecycle (runs anywhere; no container/VM host needed).
# Guards the fix for the "guest boots with no NIC" bug: both gvproxy start paths unlinked their
# vfkit socket BEFORE the already-running check, so the reuse path deleted the socket path of a
# LIVE gvproxy and returned 0 as if it had adopted it. The `vm run --net-vfkit=<that path>` that
# follows then had nothing to attach to — and since an unlink does not tear down existing
# datagram connections, gvproxy stayed up and reported nothing, so the symptom was a NIC-less
# guest instead of a clean error.
#
#   start_gvproxy            reached by `augur up --macos` when the VM is stopped but gvproxy is
#                            still alive (a `vm stop` issued outside augur, or a boot that died
#                            after gvproxy came up); cmd_up_macos returns early otherwise.
#   start_provision_gvproxy  reached by `augur build --macos` / `augur update --macos` via
#                            run_base_provisioning, which stops the NAT session and then hands
#                            `vm run --net-vfkit` the same socket path.
#
# The `rm -f` itself must STAY on both paths: each function ends in a `[[ -S "$sock" ]]` wait that
# a stale socket file left by a crashed gvproxy satisfies instantly. It just has to run only on
# the path that actually starts a new gvproxy. Both directions are asserted for both functions
# below, so neither reordering an unlink back up nor deleting one outright can pass.
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/lib.sh"
AUGUR="$REPO/augur"

# Pull the real start functions out of augur without running its dispatch tail (AUGUR_SOURCE_ONLY
# seam), so this can never drift from the shipped code.
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

# Stubs go in AFTER the source: bash resolves function calls at call time, so these win over the
# definitions in augur. One $ALIVE flag drives both running-checks — only one start function is
# under test at a time.
resolve_gvproxy() { echo "$TMPD/augur-gvproxy"; }
ALIVE=true                                 # `true`/`false` are commands, so $ALIVE is the check
gvproxy_running()           { $ALIVE; }
provision_gvproxy_running() { $ALIVE; }

# check_unlink_order LABEL START_FN SOCK PIDFILE
# Both start paths have the same shape (the provisioning one's own header says "Mirrors
# start_gvproxy") and the same -S wait, so both get the same two-direction proof.
#
# The fake gvproxy never binds a socket, so on the start path that -S wait times out and the
# function ends in `exit 1` — hence the subshell, which contains the exit while still letting the
# filesystem effect under test (the unlink) be observed out here.
check_unlink_order() {
  local label="$1" start_fn="$2" sock="$3" pidfile="$4" rc

  section "Tier 1 — ${label}: reusing a live gvproxy must not unlink its socket"
  : > "$LAUNCHED"
  : > "$sock"                              # stand-in for the live gvproxy's bound socket path
  echo 4242 > "$pidfile"                   # ...and its pidfile
  ALIVE=true
  ( "$start_fn" ) >/dev/null 2>&1; rc=$?

  eq 0 "$rc" "${label}: returns 0 when gvproxy is already running"
  if [[ -e "$sock" ]]; then
    ok "${label}: the live gvproxy's socket survives (--net-vfkit still has something to attach to)"
  else
    fail "${label}: unlinked a LIVE gvproxy's socket" "the rm -f ran before the already-running early return"
  fi
  eq "" "$(cat "$LAUNCHED")" "${label}: no second gvproxy is launched onto the same socket"
  eq 4242 "$(cat "$pidfile")" "${label}: the live gvproxy's pidfile is left untouched"

  section "Tier 1 — ${label}: a stale socket from a crashed gvproxy is still cleared"
  rm -f "$pidfile"                         # no live gvproxy...
  : > "$LAUNCHED"
  : > "$sock"                              # ...but its socket file is still lying around
  ALIVE=false
  ( "$start_fn" ) >/dev/null 2>&1

  if [[ -e "$sock" ]]; then
    fail "${label}: the stale socket file was not removed" "the -S startup wait would pass instantly against it"
  else
    ok "${label}: the stale socket file is removed on the path that starts a new gvproxy"
  fi
  has "$(cat "$LAUNCHED")" "--listen-vfkit" "${label}: a new gvproxy is launched when none is running"
}

# `up --macos` datapath.
check_unlink_order "start_gvproxy" start_gvproxy \
  "$(gvproxy_socket)" "$(gvproxy_pidfile)"
# `build --macos` / `update --macos` provisioning datapath.
check_unlink_order "start_provision_gvproxy" start_provision_gvproxy \
  "$(provision_gvproxy_socket)" "$(provision_gvproxy_pidfile)"

finish
