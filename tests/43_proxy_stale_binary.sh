#!/usr/bin/env bash
# Tier 1 — egress helpers whose binary is not verified as the installed one (runs anywhere; stub
# binaries, no container/VM host). `bash install` overwrites ~/.augur/augur-proxy and
# augur-gvproxy but never stops running instances. Each launch records the launched binary's
# sha256 next to the pidfile; a live helper is "fresh" iff that record exists, the current binary
# can be hashed, and the digests match. Asserted here:
#   • Guest NOT running: start_proxy / start_gvproxy reuse a fresh helper and silently replace one
#     that is not fresh (binary changed, no record, cannot hash).
#   • Guest RUNNING: up / claude / shell / setup-token, in BOTH modes, refuse (exit 1) while a live
#     helper is not fresh — naming the helper, the reason and the remedy — and leave it untouched.
#     A fresh helper lets them through without touching it.
#   • down / destroy / status / list are never gated; status shows the staleness.
#   • Build provisioning: the proxy is replaced, the gvproxy only warns.
#   • Every stop_* removes the sidecar with the pidfile.
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/lib.sh"
AUGUR="$REPO/augur"

AUGUR_SOURCE_ONLY=1 source "$AUGUR"
set +e                                    # augur enables `set -e`; restore lib.sh assert-and-continue
# Short on purpose: start_gvproxy binds a unix socket in here (104-byte sun_path limit).
TMPD="$(mktemp -d /tmp/augur43.XXXXXX)"
cleanup() {
  local pf
  for pf in "$TMPD"/*.pid; do [[ -f "$pf" ]] && kill "$(cat "$pf")" 2>/dev/null; done
  kill $(jobs -p) 2>/dev/null; rm -rf "$TMPD"
}
trap cleanup EXIT
AUGUR_PROXY_DIR="$TMPD"                    # keep the test off the real ~/.augur/proxy
AUGUR_DIR="$TMPD/augurdir"; mkdir -p "$AUGUR_DIR"
AUGUR_GLOBAL_CONF="$TMPD/none.conf"; AUGUR_PROJECT_CONF="$TMPD/none-project.conf"
CONTAINER_NAME="augur-test-ct"; MACOS_SHARE="workspace-test"; IMAGE_NAME="augur:test"
MACOS_MODE=false

if ! file_sha256 "$AUGUR" >/dev/null; then
  skip "stale-binary detection" "neither shasum nor sha256sum is available"; finish; exit $?
fi

# Stub augur-proxy: honour --pidfile the way the real one does (write own pid), then idle. `exec`
# keeps the pid, so the pidfile names the process that is actually running.
make_stub() {   # $1 = path, $2 = marker that makes the content (and so the sha) differ
  cat > "$1" <<EOF
#!/usr/bin/env bash
# stub augur-proxy ($2)
pf=""
while [[ \$# -gt 0 ]]; do [[ "\$1" == --pidfile ]] && { pf="\$2"; shift; }; shift; done
[[ -n "\$pf" ]] && echo \$\$ > "\$pf"
exec sleep 300
EOF
  chmod +x "$1"
}
alive() { [[ -n "$1" ]] && kill -0 "$1" 2>/dev/null; }
# gone PID — true once PID has exited (polls ~2s: a plain `kill` in stop_* does not wait).
gone() { local t=20; while ((t-- > 0)); do alive "$1" || return 0; sleep 0.1; done; return 1; }
# Pretend neither shasum nor sha256sum is on PATH: both functions that look for one fail, as they
# would for real (restored by no_hash_tool_off).
saved_tool_fns="$(declare -f sha256_tool_available file_sha256)"
no_hash_tool_on()  { sha256_tool_available() { return 1; }; file_sha256() { return 1; }; }
no_hash_tool_off() { eval "$saved_tool_fns"; }

AUGUR_PROXY_BIN="$TMPD/augur-proxy"
make_stub "$AUGUR_PROXY_BIN" v1
pidfile="$(proxy_pidfile)"; side="$(binsha_file "$pidfile")"

section "Tier 1 — file_sha256 / egress_helper_staleness basics"
h1="$(file_sha256 "$AUGUR_PROXY_BIN")"
eq "64" "${#h1}" "file_sha256 prints a 64-hex digest"
file_sha256 "$TMPD/does-not-exist" >/dev/null; eq "1" "$?" "file_sha256 fails on a missing file"
eq "unreadable" "$(egress_helper_staleness "$TMPD/does-not-exist" "$pidfile")" "missing binary → reason 'unreadable'"
eq "unreadable" "$(egress_helper_staleness "" "$pidfile")" "unresolved (empty) binary → reason 'unreadable'"
eq "no-record" "$(egress_helper_staleness "$AUGUR_PROXY_BIN" "$pidfile")" "no sidecar → reason 'no-record'"
no_hash_tool_on
eq "no-hash-tool" "$(egress_helper_staleness "$AUGUR_PROXY_BIN" "$pidfile")" "no shasum/sha256sum → reason 'no-hash-tool'"
no_hash_tool_off

# ── Guest NOT running: start_proxy reuses only a fresh proxy ──────────────────────────────────────
section "Tier 1 — start_proxy: first start records the binary's sha"
start_proxy 127.0.0.1 >/dev/null 2>&1
pid1="$(cat "$pidfile" 2>/dev/null)"
if alive "$pid1"; then ok "stub proxy started"; else fail "stub proxy did not start"; fi
eq "$h1" "$(cat "$side" 2>/dev/null)" "sidecar holds the launched binary's sha256"

section "Tier 1 — start_proxy: fresh → reused"
out="$(start_proxy 127.0.0.1 2>&1)"
eq "$pid1" "$(cat "$pidfile")" "pid unchanged when the binary is unchanged"
has "$out" "already running" "reports reuse"
hasnt "$out" "Replacing" "does not replace"

section "Tier 1 — start_proxy: binary changed → replaced"
make_stub "$AUGUR_PROXY_BIN" v2        # same path, new content (what `bash install` does)
h2="$(file_sha256 "$AUGUR_PROXY_BIN")"
out="$(start_proxy 127.0.0.1 2>&1)"
pid2="$(cat "$pidfile" 2>/dev/null)"
has "$out" "binary changed" "says why it replaces"
alive "$pid1" && fail "old proxy still alive after a binary change" || ok "old proxy pid was stopped"
if [[ "$pid2" != "$pid1" ]] && alive "$pid2"; then ok "a new proxy pid is running"
else fail "no new proxy after the binary change" "pid1=$pid1 pid2=$pid2"; fi
eq "$h2" "$(cat "$side" 2>/dev/null)" "sidecar updated to the new binary's sha"

section "Tier 1 — start_proxy: no sidecar (older augur) → replaced, then reused"
rm -f "$side"
out="$(start_proxy 127.0.0.1 2>&1)"
pid3="$(cat "$pidfile" 2>/dev/null)"
has "$out" "older augur" "says why it replaces"
alive "$pid2" && fail "unrecorded proxy was not replaced" || ok "unrecorded proxy was stopped"
if [[ "$pid3" != "$pid2" ]] && alive "$pid3"; then ok "…and relaunched"; else fail "no relaunch after missing sidecar"; fi
start_proxy 127.0.0.1 >/dev/null 2>&1
eq "$pid3" "$(cat "$pidfile")" "…once: the next start reuses it"

section "Tier 1 — start_proxy: cannot hash (no hash tool) → replaced, relaunched without a record"
no_hash_tool_on
out="$(start_proxy 127.0.0.1 2>&1)"
no_hash_tool_off
pid4="$(cat "$pidfile" 2>/dev/null)"
has "$out" "neither shasum nor sha256sum" "says why it replaces"
if [[ "$pid4" != "$pid3" ]] && alive "$pid4" && ! alive "$pid3"; then ok "replaced"; else fail "not replaced" "pid3=$pid3 pid4=$pid4"; fi
# record_launched_binsha removes the sidecar when the hash fails, so no stale digest survives.
[[ -e "$side" ]] && fail "sidecar written without a hash tool" || ok "no sidecar recorded (nothing to prove freshness)"

section "Tier 1 — start_proxy: binary missing → up fails, the old proxy is not replaced"
start_proxy 127.0.0.1 >/dev/null 2>&1            # replace pid4 (no record) with a recorded one
pid5="$(cat "$pidfile" 2>/dev/null)"
mv "$AUGUR_PROXY_BIN" "$TMPD/augur-proxy.away"
out="$(set -e; start_proxy 127.0.0.1 2>&1)"; rc=$?   # set -e as in augur: require_proxy_bin exits
[[ "$rc" != 0 ]] && ok "start_proxy exits non-zero (rc=$rc)" || fail "start_proxy succeeded with no binary"
has "$out" "augur-proxy was not found" "names the missing binary"
alive "$pid5" && ok "old proxy left as it was" || fail "old proxy killed although nothing can replace it"
mv "$TMPD/augur-proxy.away" "$AUGUR_PROXY_BIN"

section "Tier 1 — stop_proxy removes the sidecar with the pidfile"
stop_proxy >/dev/null 2>&1
[[ -e "$pidfile" ]] && fail "pidfile left behind" || ok "pidfile removed"
[[ -e "$side" ]] && fail "sidecar left behind by stop_proxy" || ok "sidecar removed"

# ── Guest NOT running: start_gvproxy reuses only a fresh gvproxy ──────────────────────────────────
AUGUR_GVPROXY_BIN="$TMPD/augur-gvproxy"
gpf="$(gvproxy_pidfile)"; gside="$(binsha_file "$gpf")"; gsock="$(gvproxy_socket)"
make_gv_stub() {   # $1 = marker; binds the --listen-vfkit unixgram socket like the real one
  cat > "$AUGUR_GVPROXY_BIN" <<EOF
#!/usr/bin/env bash
# stub augur-gvproxy ($1)
s=""
while [[ \$# -gt 0 ]]; do [[ "\$1" == --listen-vfkit ]] && { s="\${2#unixgram://}"; shift; }; shift; done
exec python3 -c 'import socket,sys,time
s=socket.socket(socket.AF_UNIX,socket.SOCK_DGRAM); s.bind(sys.argv[1]); time.sleep(300)' "\$s"
EOF
  chmod +x "$AUGUR_GVPROXY_BIN"
}
if command -v python3 &>/dev/null; then
  section "Tier 1 — start_gvproxy: fresh → reused; not fresh → replaced on the same socket"
  make_gv_stub gv1
  start_gvproxy >/dev/null 2>&1
  g1="$(cat "$gpf" 2>/dev/null)"
  if alive "$g1" && [[ -S "$gsock" ]]; then ok "stub gvproxy started and bound its socket"; else fail "stub gvproxy did not start"; fi
  eq "$(file_sha256 "$AUGUR_GVPROXY_BIN")" "$(cat "$gside" 2>/dev/null)" "gvproxy sidecar recorded"
  start_gvproxy >/dev/null 2>&1
  eq "$g1" "$(cat "$gpf")" "fresh → same pid"
  make_gv_stub gv2
  out="$(start_gvproxy 2>&1)"; rc=$?
  g2="$(cat "$gpf" 2>/dev/null)"
  eq 0 "$rc" "start_gvproxy succeeds after replacing"
  has "$out" "binary changed" "says why it replaces"
  if [[ "$g2" != "$g1" ]] && alive "$g2" && ! alive "$g1"; then ok "changed → old gvproxy stopped, new one running"
  else fail "gvproxy not replaced" "g1=$g1 g2=$g2"; fi
  [[ -S "$gsock" ]] && ok "the new gvproxy owns the socket" || fail "no socket after the replacement"
  rm -f "$gside"
  start_gvproxy >/dev/null 2>&1
  g3="$(cat "$gpf" 2>/dev/null)"
  if [[ "$g3" != "$g2" ]] && alive "$g3" && ! alive "$g2"; then ok "no record → replaced too"; else fail "unrecorded gvproxy not replaced"; fi
  stop_gvproxy >/dev/null 2>&1
else
  skip "start_gvproxy replacement" "python3 is needed for the stub's unix socket"
fi

section "Tier 1 — stop_gvproxy removes the sidecar"
sleep 300 & gvp_proc=$!; disown
echo "$gvp_proc" > "$gpf"; echo deadbeef > "$gside"
stop_gvproxy >/dev/null 2>&1
[[ -e "$gside" ]] && fail "sidecar left behind by stop_gvproxy" || ok "stop_gvproxy removes the sidecar"

# ── Build provisioning: proxy replaced, gvproxy warn-only ─────────────────────────────────────────
section "Tier 1 — build-provisioning proxy: not fresh → replaced"
ppf="$(provision_proxy_pidfile)"; pside="$(binsha_file "$ppf")"
start_provision_proxy >/dev/null 2>&1
pp1="$(cat "$ppf" 2>/dev/null)"
eq "$(file_sha256 "$AUGUR_PROXY_BIN")" "$(cat "$pside" 2>/dev/null)" "provision proxy records its sha"
start_provision_proxy >/dev/null 2>&1
eq "$pp1" "$(cat "$ppf")" "fresh → reused"
make_stub "$AUGUR_PROXY_BIN" v3
start_provision_proxy >/dev/null 2>&1
pp2="$(cat "$ppf" 2>/dev/null)"
if [[ -n "$pp2" && "$pp2" != "$pp1" ]] && ! alive "$pp1"; then ok "provision proxy replaced on a binary change"
else fail "provision proxy not replaced" "pp1=$pp1 pp2=$pp2"; fi
stop_provision_proxy >/dev/null 2>&1
[[ -e "$pside" ]] && fail "sidecar left behind by stop_provision_proxy" || ok "stop_provision_proxy removes the sidecar"

section "Tier 1 — build-provisioning gvproxy: not fresh → WARN only, pid untouched"
make_stub "$AUGUR_GVPROXY_BIN" pgv1
pgpf="$(provision_gvproxy_pidfile)"; pgside="$(binsha_file "$pgpf")"
sleep 300 & pg_proc=$!; disown                 # stand-in for another build's live provisioning gvproxy
echo "$pg_proc" > "$pgpf"
file_sha256 "$AUGUR_GVPROXY_BIN" > "$pgside"
out="$(start_provision_gvproxy 2>&1)"
hasnt "$out" "not verified" "fresh → no warning"
make_stub "$AUGUR_GVPROXY_BIN" pgv2
out="$(start_provision_gvproxy 2>&1)"; rc=$?
eq 0 "$rc" "returns 0 (reuses it)"
has "$out" "binary changed" "warns with the reason"
alive "$pg_proc" && ok "provisioning gvproxy NOT killed" || fail "provisioning gvproxy was killed"
eq "$pg_proc" "$(cat "$pgpf")" "pidfile untouched"
stop_provision_gvproxy >/dev/null 2>&1
[[ -e "$pgside" ]] && fail "sidecar left behind by stop_provision_gvproxy" || ok "stop_provision_gvproxy removes the sidecar"

# ── Guest RUNNING: the gate, driven through the REAL cmd_* functions ─────────────────────────────
# Only the engine / VM / guest side is stubbed. Every gated call runs in $(…), which contains the
# gate's `exit 1`.
require_engine() { :; }; require_engine_version() { :; }; require_vz() { :; }; ensure_image() { :; }
container_fingerprint_matches() { return 0; }   # the running container is current; only the gate is under test
apply_guest_profile() { :; }; save_guest_history() { :; }
eng() { [[ "$1" == exec ]] && echo "AGENT_LAUNCHED"; return 0; }
ssh_macos() { echo "AGENT_LAUNCHED"; }
sync_macos_guest_clock() { :; }; sync_macos_guest_timezone() { :; }; ensure_macos_workspace() { :; }
ensure_macos_claude_projects() { :; }; ensure_macos_claude_agents() { :; }; ensure_macos_claude_profile() { :; }
ensure_macos_claude_bin() { :; }; warn_if_macos_egress_pinned() { :; }; macos_project_vm() { echo augur-test-vm; }
check_project_conf_approved() { :; }; macos_vm_exists() { return 0; }
reconcile_running_container() { echo "RECONCILE_CALLED"; }
verify_macos_egress_locked() { echo "SELFTEST_CALLED"; }
agent_verify_integrity_engine() { return 1; }   # setup-token stops right after the gate, before any tty read
agent_verify_integrity_macos() { return 1; }
GUEST_UP=1
container_running() { [[ "$GUEST_UP" == 1 ]]; }; macos_vm_running() { [[ "$GUEST_UP" == 1 ]]; }
container_exists() { [[ "$GUEST_UP" == 1 ]]; }

# run_gated FN — run a gated command under augur's own `set -e`; sets $out and $rc.
run_gated() { out="$(set -e; "$@" 2>&1)"; rc=$?; }
# expect_refused LABEL PID REASON REMEDY
expect_refused() {
  [[ "$rc" != 0 ]] && ok "$1: exits non-zero (rc=$rc)" || fail "$1: was not refused"
  has "$out" "Refusing to attach" "$1: says it refuses"
  has "$out" "$3" "$1: names the reason"
  has "$out" "$4" "$1: gives the remedy"
  has "$out" "ends every running claude/shell session" "$1: says what down costs"
  hasnt "$out" "AGENT_LAUNCHED" "$1: the agent is NOT launched"
  hasnt "$out" "RECONCILE_CALLED" "$1: up's reconcile is NOT reached"
  hasnt "$out" "SELFTEST_CALLED" "$1: up's macOS reconcile is NOT reached"
  alive "$2" && ok "$1: the helper pid is untouched" || fail "$1: the helper was killed"
}

section "Tier 1 — container, guest running, fresh proxy → claude/shell/up/setup-token proceed"
MACOS_MODE=false
make_stub "$AUGUR_PROXY_BIN" c1
pidfile="$(proxy_pidfile)"; side="$(binsha_file "$pidfile")"
start_proxy 10.9.8.7 >/dev/null 2>&1
c1="$(cat "$pidfile" 2>/dev/null)"
cmd_up_real="$(declare -f cmd_up)"
cmd_up() { echo "CMD_UP_CALLED"; }
run_gated cmd_claude
eq 0 "$rc" "claude: exits 0"; has "$out" "AGENT_LAUNCHED" "claude: agent launched"
hasnt "$out" "CMD_UP_CALLED" "claude: running container ⇒ no up"
run_gated cmd_shell
has "$out" "AGENT_LAUNCHED" "shell: attached"; hasnt "$out" "CMD_UP_CALLED" "shell: no up"
run_gated cmd_setup_token
has "$out" "differs from the image" "setup-token: passes the gate (reaches its integrity check)"
eval "$cmd_up_real"
run_gated cmd_up
has "$out" "RECONCILE_CALLED" "up: reaches the running-guest reconcile"
eq "$c1" "$(cat "$pidfile")" "the fresh proxy is untouched (same pid)"

section "Tier 1 — container, guest running, binary changed → all four refused"
make_stub "$AUGUR_PROXY_BIN" c2
for c in cmd_claude cmd_shell cmd_up cmd_setup_token; do
  run_gated "$c"
  expect_refused "$c" "$c1" "binary changed since it started (${AUGUR_PROXY_BIN}" "augur down && augur up"
done
has "$out" "augur-proxy (pid ${c1})" "names the helper and its pid"
has "$out" "writable layer are kept" "says the container's writable layer is kept"
hasnt "$out" "differs from the image" "setup-token: never reaches its TTY flow"
eq "$c1" "$(cat "$pidfile")" "pidfile untouched"

section "Tier 1 — container, guest running, no record → refused"
rm -f "$side"
run_gated cmd_claude
expect_refused "claude/no-record" "$c1" "started by an older augur" "augur down && augur up"

section "Tier 1 — container, guest running, cannot hash → refused with the root cause"
file_sha256 "$AUGUR_PROXY_BIN" > "$side"           # fresh again, except for the hash tool
no_hash_tool_on
run_gated cmd_shell
no_hash_tool_off
expect_refused "shell/no-hash-tool" "$c1" "neither shasum nor sha256sum is on PATH" "augur down && augur up"
has "$out" "Fix that first" "points at the root cause"
mv "$AUGUR_PROXY_BIN" "$TMPD/augur-proxy.away"
run_gated cmd_claude
expect_refused "claude/missing-binary" "$c1" "is missing or unreadable" "augur down && augur up"
mv "$TMPD/augur-proxy.away" "$AUGUR_PROXY_BIN"

section "Tier 1 — container: no override, whatever this invocation's egress setting"
make_stub "$AUGUR_PROXY_BIN" c3
out="$(AUGUR_EGRESS=0 cmd_claude 2>&1)"; rc=$?
expect_refused "claude --no-egress" "$c1" "binary changed" "augur down && augur up"

section "Tier 1 — container, guest running + stale: status/list/down are not gated"
out="$(engine_toolchain_versions() { :; }; resolve_container_memory() { echo 1G; }; cmd_status 2>&1)"; rc=$?
eq 0 "$rc" "status exits 0"
has "$out" "stale: binary changed" "status shows the stale proxy"
out="$(cmd_list 2>&1)"; rc=$?
eq 0 "$rc" "list exits 0"
out="$(eng() { :; }; cmd_down 2>&1)"; rc=$?
eq 0 "$rc" "down exits 0"
gone "$c1" && ok "down stops the stale proxy (the way out)" || fail "down did not stop the stale proxy"
[[ -e "$side" ]] && fail "down left the sidecar" || ok "down removes the sidecar"

section "Tier 1 — container, guest NOT running + stale → claude goes through up (which replaces it)"
start_proxy 10.9.8.7 >/dev/null 2>&1
c4="$(cat "$pidfile" 2>/dev/null)"
make_stub "$AUGUR_PROXY_BIN" c5
GUEST_UP=0
cmd_up() { echo "CMD_UP_CALLED"; }
run_gated cmd_claude
eval "$cmd_up_real"
hasnt "$out" "Refusing" "not refused: nobody is attached"
has "$out" "CMD_UP_CALLED" "stopped container ⇒ up"
out="$(start_proxy 10.9.8.7 2>&1)"
alive "$c4" && fail "stale proxy survived up's start_proxy" || ok "up's start_proxy replaces it"
stop_proxy >/dev/null 2>&1

section "Tier 1 — structure: the gate sits before the running-vs-up branch; the way out is ungated"
gate_before() {   # FN RUNNING_CHECK — the gate line precedes the first running check
  local body gl rl
  body="$(declare -f "$1")"
  gl="$(grep -n 'require_fresh_egress_helpers' <<< "$body" | head -1 | cut -d: -f1)"
  rl="$(grep -n "$2" <<< "$body" | head -1 | cut -d: -f1)"
  if [[ -n "$gl" && -n "$rl" && "$gl" -lt "$rl" ]]; then ok "$1: gate before '$2'"; else fail "$1: gate missing or after '$2'" "gate=$gl running=$rl"; fi
}
gate_before cmd_up container_running
gate_before cmd_claude ensure_session_container   # container mode's claude/shell branch lives there
gate_before cmd_shell ensure_session_container
gate_before cmd_setup_token container_running
gate_before cmd_up_macos macos_vm_running
gate_before cmd_claude_macos macos_vm_running
gate_before cmd_shell_macos macos_vm_running
gate_before cmd_setup_token_macos macos_vm_running
for f in cmd_down cmd_destroy cmd_status cmd_list cmd_down_macos cmd_destroy_macos cmd_status_macos cmd_list_macos; do
  hasnt "$(declare -f "$f")" "require_fresh_egress_helpers" "$f is not gated"
done

# ── macOS VM mode ─────────────────────────────────────────────────────────────────────────────────
section "Tier 1 — macOS, VM running, fresh proxy + gvproxy → claude/shell/up/setup-token proceed"
MACOS_MODE=true; GUEST_UP=1
make_stub "$AUGUR_PROXY_BIN" m1
make_stub "$AUGUR_GVPROXY_BIN" mg1
pidfile="$(proxy_pidfile)"; side="$(binsha_file "$pidfile")"
start_proxy 127.0.0.1 >/dev/null 2>&1
m1="$(cat "$pidfile" 2>/dev/null)"
sleep 300 & mg1=$!; disown                   # stand-in for the gvproxy a live VM is attached to
echo "$mg1" > "$gpf"; file_sha256 "$AUGUR_GVPROXY_BIN" > "$gside"
cmd_up_macos_real="$(declare -f cmd_up_macos)"
cmd_up_macos() { echo "CMD_UP_MACOS_CALLED"; }
run_gated cmd_claude_macos
eq 0 "$rc" "claude --macos: exits 0"; has "$out" "AGENT_LAUNCHED" "claude --macos: agent launched"
hasnt "$out" "CMD_UP_MACOS_CALLED" "claude --macos: running VM ⇒ no up"
run_gated cmd_shell_macos
has "$out" "AGENT_LAUNCHED" "shell --macos: attached"; hasnt "$out" "CMD_UP_MACOS_CALLED" "shell --macos: no up"
run_gated cmd_setup_token_macos
has "$out" "not Anthropic-signed" "setup-token --macos: passes the gate (reaches its integrity check)"
eval "$cmd_up_macos_real"
run_gated cmd_up_macos
has "$out" "SELFTEST_CALLED" "up --macos: reaches the running-VM reconcile"
eq "$m1" "$(cat "$pidfile")" "fresh proxy untouched"
eq "$mg1" "$(cat "$gpf")" "fresh gvproxy untouched"

section "Tier 1 — macOS, VM running, augur-proxy binary changed → all four refused"
make_stub "$AUGUR_PROXY_BIN" m2
for c in cmd_claude_macos cmd_shell_macos cmd_up_macos cmd_setup_token_macos; do
  run_gated "$c"
  expect_refused "$c" "$m1" "augur-proxy (pid ${m1})" "augur down --macos && augur up --macos"
done
has "$out" "the VM clone are kept" "says the VM clone is kept"
hasnt "$out" "augur-gvproxy (pid" "a fresh gvproxy is not listed"
make_stub "$AUGUR_PROXY_BIN" m1; file_sha256 "$AUGUR_PROXY_BIN" > "$side"   # proxy fresh again

section "Tier 1 — macOS, VM running, augur-gvproxy not fresh → refused (gvproxy untouched)"
make_stub "$AUGUR_GVPROXY_BIN" mg2
for c in cmd_claude_macos cmd_shell_macos cmd_up_macos cmd_setup_token_macos; do
  run_gated "$c"
  expect_refused "$c" "$mg1" "augur-gvproxy (pid ${mg1})" "augur down --macos && augur up --macos"
done
has "$out" "binary changed since it started (${AUGUR_GVPROXY_BIN}" "names the changed gvproxy binary"
rm -f "$gside"
run_gated cmd_claude_macos
expect_refused "gvproxy/no-record" "$mg1" "started by an older augur" "augur down --macos"
AUGUR_GVPROXY_BIN="$TMPD/no-such-gvproxy"
run_gated cmd_shell_macos
expect_refused "gvproxy/not-found" "$mg1" "is missing or unreadable" "augur down --macos"
AUGUR_GVPROXY_BIN="$TMPD/augur-gvproxy"
no_hash_tool_on
run_gated cmd_up_macos
no_hash_tool_off
expect_refused "up --macos/no-hash-tool" "$mg1" "neither shasum nor sha256sum" "augur down --macos"
has "$out" "augur-proxy (pid ${m1})" "…lists every unverifiable helper"

section "Tier 1 — macOS, VM running + stale: status/list/down are not gated"
VM_CLI=true
out="$(resolve_macos_vm_cpu() { echo 4; }; resolve_macos_vm_memory_mb() { echo 8192; }; macos_ssh_host() { :; }; cmd_status_macos 2>&1)"; rc=$?
eq 0 "$rc" "status --macos exits 0"
has "$out" "stale: no record" "status --macos shows the stale gvproxy"
# With egress on the guest is reached through gvproxy's local forward and has no DHCP lease, so
# the Toolchain block must key off ssh_macos's host, not a lease lookup.
out="$(resolve_macos_vm_cpu() { echo 4; }; resolve_macos_vm_memory_mb() { echo 8192; }
       macos_vm_ip() { return 1; }; macos_ssh_host() { echo 127.0.0.1; }
       ssh_macos() { echo "    xcode:  Xcode 27.0"; }; cmd_status_macos 2>&1)"
has   "$out" "xcode:  Xcode 27.0" "status --macos reads the toolchain over the gvproxy forward (no DHCP lease)"
hasnt "$out" "VM not running"     "status --macos does not call a running gvproxy-mode VM 'not running'"
out="$(cmd_list_macos 2>&1)"; rc=$?
eq 0 "$rc" "list --macos exits 0"
out="$(macos_vm_exists() { return 1; }; cmd_down_macos 2>&1)"; rc=$?
eq 0 "$rc" "down --macos exits 0"
gone "$mg1" && ok "down --macos stops the stale gvproxy" || fail "down --macos did not stop the stale gvproxy"
gone "$m1" && ok "down --macos stops the proxy" || fail "down --macos did not stop the proxy"

section "Tier 1 — macOS, VM NOT running + stale → claude goes through up"
make_stub "$AUGUR_PROXY_BIN" m3
start_proxy 127.0.0.1 >/dev/null 2>&1
m3="$(cat "$pidfile" 2>/dev/null)"
make_stub "$AUGUR_PROXY_BIN" m4
GUEST_UP=0
cmd_up_macos() { echo "CMD_UP_MACOS_CALLED"; }
run_gated cmd_claude_macos
hasnt "$out" "Refusing" "not refused: nobody is attached"
has "$out" "CMD_UP_MACOS_CALLED" "stopped VM ⇒ up --macos"
alive "$m3" && ok "the gate itself leaves the proxy alone" || fail "the gate touched the proxy"
stop_proxy >/dev/null 2>&1

finish
