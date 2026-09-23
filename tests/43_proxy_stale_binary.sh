#!/usr/bin/env bash
# Tier 1 — a running egress helper whose binary changed since it started (runs anywhere; stub
# binaries, no container/VM host). `bash install` overwrites ~/.augur/augur-proxy and
# augur-gvproxy but never stops running instances, and start_proxy/start_gvproxy used to reuse any
# live pid — so after an upgrade the OLD binary kept serving until an explicit `down`. Each launch
# now records the launched binary's sha256 next to the pidfile and the reuse path compares it:
#   • augur-proxy: same binary → reused; changed / unrecorded → old pid stopped, new one started.
#   • augur-gvproxy: changed → WARN only (its socket is the live VM's NIC), pid untouched.
#   • claude/shell (both modes) on an already-running guest: a live stale augur-proxy is replaced
#     on its original --listen; not stale / not running / egress off → left alone.
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/lib.sh"
AUGUR="$REPO/augur"

AUGUR_SOURCE_ONLY=1 source "$AUGUR"
set +e                                    # augur enables `set -e`; restore lib.sh assert-and-continue
TMPD="$(mktemp -d)"
cleanup() {
  local pf
  for pf in "$TMPD"/*.pid; do [[ -f "$pf" ]] && kill "$(cat "$pf")" 2>/dev/null; done
  kill $(jobs -p) 2>/dev/null; rm -rf "$TMPD"
}
trap cleanup EXIT
AUGUR_PROXY_DIR="$TMPD"                    # keep the test off the real ~/.augur/proxy
AUGUR_DIR="$TMPD/augurdir"; mkdir -p "$AUGUR_DIR"
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
AUGUR_PROXY_BIN="$TMPD/augur-proxy"
make_stub "$AUGUR_PROXY_BIN" v1
pidfile="$(proxy_pidfile)"; side="$(binsha_file "$pidfile")"

section "Tier 1 — file_sha256 is a content digest"
h1="$(file_sha256 "$AUGUR_PROXY_BIN")"
eq "64" "${#h1}" "file_sha256 prints a 64-hex digest"
file_sha256 "$TMPD/does-not-exist" >/dev/null; eq "1" "$?" "file_sha256 fails on a missing file"

section "Tier 1 — augur-proxy: first start records the binary's sha"
start_proxy 127.0.0.1 >/dev/null 2>&1
pid1="$(cat "$pidfile" 2>/dev/null)"
if [[ -n "$pid1" ]] && kill -0 "$pid1" 2>/dev/null; then ok "stub proxy started"; else fail "stub proxy did not start"; fi
eq "$h1" "$(cat "$side" 2>/dev/null)" "sidecar holds the launched binary's sha256"

section "Tier 1 — augur-proxy: same binary → reused"
out="$(start_proxy 127.0.0.1 2>&1)"
eq "$pid1" "$(cat "$pidfile")" "pid unchanged when the binary is unchanged"
has "$out" "already running" "reports reuse"
hasnt "$out" "restarting" "does not restart"

section "Tier 1 — augur-proxy: binary content changed → restarted"
make_stub "$AUGUR_PROXY_BIN" v2        # same path, new content (what `bash install` does)
h2="$(file_sha256 "$AUGUR_PROXY_BIN")"
out="$(start_proxy 127.0.0.1 2>&1)"
pid2="$(cat "$pidfile" 2>/dev/null)"
has "$out" "binary changed" "says why it restarts"
if kill -0 "$pid1" 2>/dev/null; then fail "old proxy still alive after a binary change" "the stale binary keeps serving"
else ok "old proxy pid was stopped"; fi
if [[ -n "$pid2" && "$pid2" != "$pid1" ]] && kill -0 "$pid2" 2>/dev/null; then ok "a new proxy pid is running"
else fail "no new proxy after the binary change" "pid1=$pid1 pid2=$pid2"; fi
eq "$h2" "$(cat "$side" 2>/dev/null)" "sidecar updated to the new binary's sha"

section "Tier 1 — augur-proxy: missing sidecar (pre-upgrade proxy) → restarted once"
rm -f "$side"
out="$(start_proxy 127.0.0.1 2>&1)"
pid3="$(cat "$pidfile" 2>/dev/null)"
if kill -0 "$pid2" 2>/dev/null; then fail "unrecorded proxy was not restarted"; else ok "unrecorded proxy was stopped"; fi
if [[ -n "$pid3" && "$pid3" != "$pid2" ]] && kill -0 "$pid3" 2>/dev/null; then ok "…and relaunched"; else fail "no relaunch after missing sidecar"; fi
out="$(start_proxy 127.0.0.1 2>&1)"
eq "$pid3" "$(cat "$pidfile")" "…exactly once: the next start reuses it"

section "Tier 1 — augur-proxy: unhashable binary → fall back to plain reuse (no restart loop)"
saved_sha_fn="$(declare -f file_sha256)"
file_sha256() { return 1; }
make_stub "$AUGUR_PROXY_BIN" v2-unhashable
out="$(start_proxy 127.0.0.1 2>&1)"
eq "$pid3" "$(cat "$pidfile")" "pid unchanged when the current binary cannot be hashed"
eval "$saved_sha_fn"

section "Tier 1 — stop_proxy removes the sidecar with the pidfile"
stop_proxy >/dev/null 2>&1
[[ -e "$pidfile" ]] && fail "pidfile left behind" || ok "pidfile removed"
[[ -e "$side" ]] && fail "sidecar left behind by stop_proxy" || ok "sidecar removed"

section "Tier 1 — augur-gvproxy: changed binary → WARN only, pid untouched"
AUGUR_GVPROXY_BIN="$TMPD/augur-gvproxy"
make_stub "$AUGUR_GVPROXY_BIN" gv1
gpf="$(gvproxy_pidfile)"; gside="$(binsha_file "$gpf")"
sleep 300 & gvp_proc=$!                 # stand-in for a gvproxy a live VM is attached to
echo "$gvp_proc" > "$gpf"
file_sha256 "$AUGUR_GVPROXY_BIN" > "$gside"
out="$(start_gvproxy 2>&1)"
hasnt "$out" "different" "same binary → no warning"
make_stub "$AUGUR_GVPROXY_BIN" gv2
out="$(start_gvproxy 2>&1)"
has "$out" "augur down --macos" "changed binary → warns with the VM-cycle command"
if kill -0 "$gvp_proc" 2>/dev/null; then ok "gvproxy was NOT killed (it is the VM's NIC)"; else fail "gvproxy was killed under a live VM"; fi
eq "$gvp_proc" "$(cat "$gpf")" "gvproxy pidfile untouched"
# The live-VM reconcile path reaches gvproxy only through warn_if_macos_egress_pinned.
out="$(warn_if_macos_egress_pinned augur-test-vm 2>&1)"
has "$out" "augur-gvproxy" "warn_if_macos_egress_pinned also reports the changed gvproxy binary"
rm -f "$gside"
out="$(start_gvproxy 2>&1)"
has "$out" "unrecorded" "missing sidecar → warns too"
if kill -0 "$gvp_proc" 2>/dev/null; then ok "…still without killing it"; else fail "gvproxy killed on missing sidecar"; fi
file_sha256 "$AUGUR_GVPROXY_BIN" > "$gside"
stop_gvproxy >/dev/null 2>&1
[[ -e "$gside" ]] && fail "sidecar left behind by stop_gvproxy" || ok "stop_gvproxy removes the sidecar"

section "Tier 1 — build-provisioning proxy mirrors start_proxy"
ppf="$(provision_proxy_pidfile)"; pside="$(binsha_file "$ppf")"
start_provision_proxy >/dev/null 2>&1
pp1="$(cat "$ppf" 2>/dev/null)"
eq "$(file_sha256 "$AUGUR_PROXY_BIN")" "$(cat "$pside" 2>/dev/null)" "provision proxy records its sha"
make_stub "$AUGUR_PROXY_BIN" v3
start_provision_proxy >/dev/null 2>&1
pp2="$(cat "$ppf" 2>/dev/null)"
if [[ -n "$pp2" && "$pp2" != "$pp1" ]] && ! kill -0 "$pp1" 2>/dev/null; then ok "provision proxy restarted on a binary change"
else fail "provision proxy not restarted" "pp1=$pp1 pp2=$pp2"; fi
stop_provision_proxy >/dev/null 2>&1
[[ -e "$pside" ]] && fail "sidecar left behind by stop_provision_proxy" || ok "stop_provision_proxy removes the sidecar"

# ── claude/shell on an ALREADY-RUNNING guest never reach `up`, so they call refresh_stale_proxy ──
# The REAL cmd_claude/cmd_shell(_macos) run here; only the engine/VM/guest side is stubbed. This
# stub keeps its argv visible to `ps` (no `exec sleep`), because refresh_stale_proxy relaunches on
# the --listen the OLD process was started with.
make_argv_stub() {   # $1 = path, $2 = content marker
  cat > "$1" <<EOF
#!/usr/bin/env bash
# stub augur-proxy, argv-preserving ($2)
pf=""
for ((i=1; i<=\$#; i++)); do [[ "\${!i}" == --pidfile ]] && { j=\$((i+1)); pf="\${!j}"; }; done
[[ -n "\$pf" ]] && echo \$\$ > "\$pf"
sleep 300 & c=\$!
trap 'kill \$c 2>/dev/null; exit 0' TERM
wait \$c
EOF
  chmod +x "$1"
}
alive() { [[ -n "$1" ]] && kill -0 "$1" 2>/dev/null; }
require_engine() { :; }; require_vz() { :; }
apply_guest_profile() { :; }; save_guest_history() { :; }; eng() { :; }; ssh_macos() { :; }
sync_macos_guest_clock() { :; }; sync_macos_guest_timezone() { :; }; ensure_macos_workspace() { :; }
ensure_macos_claude_projects() { :; }; ensure_macos_claude_agents() { :; }; ensure_macos_claude_profile() { :; }
ensure_macos_claude_bin() { :; }; warn_if_macos_egress_pinned() { :; }; macos_project_vm() { echo augur-test-vm; }
cmd_up() { echo "CMD_UP_CALLED"; }; cmd_up_macos() { echo "CMD_UP_MACOS_CALLED"; }
GUEST_UP=0
container_running() { [[ "$GUEST_UP" == 1 ]]; }; macos_vm_running() { [[ "$GUEST_UP" == 1 ]]; }
MACOS_MODE=false
pidfile="$(proxy_pidfile)"; side="$(binsha_file "$pidfile")"

section "Tier 1 — claude on a running container: not stale → untouched (hash compare only)"
make_argv_stub "$AUGUR_PROXY_BIN" c1
start_proxy 10.9.8.7 >/dev/null 2>&1          # an address no fallback would compute
c1="$(cat "$pidfile" 2>/dev/null)"
eq "10.9.8.7" "$(running_proxy_listen "$c1")" "running_proxy_listen reads the launched --listen from argv"
GUEST_UP=1
out="$(cmd_claude 2>&1)"
eq "$c1" "$(cat "$pidfile")" "same pid when the binary is unchanged"
hasnt "$out" "restarting" "no restart"
hasnt "$out" "CMD_UP_CALLED" "running container => cmd_up not called (no double work)"

section "Tier 1 — claude on a running container: stale binary → replaced on the SAME address"
make_argv_stub "$AUGUR_PROXY_BIN" c2
out="$(cmd_claude 2>&1)"
c2="$(cat "$pidfile" 2>/dev/null)"
has "$out" "binary changed" "says why it restarts"
alive "$c1" && fail "stale proxy still alive after claude" || ok "stale proxy stopped by claude"
if [[ "$c2" != "$c1" ]] && alive "$c2"; then ok "new proxy running"; else fail "no new proxy" "c1=$c1 c2=$c2"; fi
eq "10.9.8.7" "$(running_proxy_listen "$c2")" "relaunched on the old proxy's --listen"
eq "$(file_sha256 "$AUGUR_PROXY_BIN")" "$(cat "$side" 2>/dev/null)" "sidecar updated"
hasnt "$out" "CMD_UP_CALLED" "still no cmd_up"

section "Tier 1 — shell on a running container: stale binary → replaced too"
make_argv_stub "$AUGUR_PROXY_BIN" c3
out="$(cmd_shell 2>&1)"
c3="$(cat "$pidfile" 2>/dev/null)"
if [[ "$c3" != "$c2" ]] && alive "$c3" && ! alive "$c2"; then ok "cmd_shell replaced the stale proxy"; else fail "cmd_shell did not replace it" "c2=$c2 c3=$c3"; fi
eq "10.9.8.7" "$(running_proxy_listen "$c3")" "…on the same address"

section "Tier 1 — stale + unreadable argv → falls back to up's address computation"
make_argv_stub "$AUGUR_PROXY_BIN" c4
saved_rpl="$(declare -f running_proxy_listen)"
running_proxy_listen() { return 1; }
out="$(AUGUR_PROXY_LISTEN=0.0.0.0 cmd_claude 2>&1)"
eval "$saved_rpl"
c4="$(cat "$pidfile" 2>/dev/null)"
eq "0.0.0.0" "$(running_proxy_listen "$c4")" "fallback goes through start_egress_proxy (AUGUR_PROXY_LISTEN honoured)"

section "Tier 1 — stale but egress disabled → left alone"
make_argv_stub "$AUGUR_PROXY_BIN" c5
out="$(AUGUR_EGRESS=0 cmd_claude 2>&1)"
eq "$c4" "$(cat "$pidfile")" "no restart with AUGUR_EGRESS=0"

section "Tier 1 — stale and the new binary fails to start → claude errors out (start_proxy semantics)"
printf '#!/usr/bin/env bash\n# broken augur-proxy: exits without writing its pidfile\nexit 3\n' > "$AUGUR_PROXY_BIN"
out="$(cmd_claude 2>&1)"; rc=$?
[[ "$rc" != 0 ]] && ok "cmd_claude exits non-zero (rc=$rc)" || fail "cmd_claude continued with no proxy"
has "$out" "failed to start" "reports the start failure"
hasnt "$out" "Launching" "never reaches the agent launch"

section "Tier 1 — proxy NOT running → claude does not start one (reviving stays up's job)"
make_argv_stub "$AUGUR_PROXY_BIN" c6
stop_proxy >/dev/null 2>&1
out="$(cmd_claude 2>&1)"
[[ -e "$pidfile" ]] && fail "claude started a proxy that was not running" || ok "no proxy started"
GUEST_UP=0
out="$(cmd_claude 2>&1)"
has "$out" "CMD_UP_CALLED" "stopped container => cmd_up (which owns proxy bring-up)"

section "Tier 1 — claude/shell --macos on a running VM: stale binary → replaced on 127.0.0.1"
MACOS_MODE=true; GUEST_UP=1
pidfile="$(proxy_pidfile)"
start_proxy 127.0.0.1 >/dev/null 2>&1
m1="$(cat "$pidfile" 2>/dev/null)"
out="$(cmd_claude_macos 2>&1)"
eq "$m1" "$(cat "$pidfile")" "not stale → same pid"
hasnt "$out" "CMD_UP_MACOS_CALLED" "running VM => cmd_up_macos not called"
make_argv_stub "$AUGUR_PROXY_BIN" m2
out="$(cmd_claude_macos 2>&1)"
m2="$(cat "$pidfile" 2>/dev/null)"
if [[ "$m2" != "$m1" ]] && alive "$m2" && ! alive "$m1"; then ok "cmd_claude_macos replaced the stale proxy"; else fail "not replaced" "m1=$m1 m2=$m2"; fi
eq "127.0.0.1" "$(running_proxy_listen "$m2")" "…on 127.0.0.1"
make_argv_stub "$AUGUR_PROXY_BIN" m3
out="$(cmd_shell_macos 2>&1)"
m3="$(cat "$pidfile" 2>/dev/null)"
if [[ "$m3" != "$m2" ]] && alive "$m3" && ! alive "$m2"; then ok "cmd_shell_macos replaced the stale proxy"; else fail "not replaced" "m2=$m2 m3=$m3"; fi
stop_proxy >/dev/null 2>&1
out="$(cmd_shell_macos 2>&1)"
[[ -e "$pidfile" ]] && fail "shell --macos started a proxy that was not running" || ok "dead proxy not revived by shell --macos"
GUEST_UP=0
out="$(cmd_claude_macos 2>&1)"
has "$out" "CMD_UP_MACOS_CALLED" "stopped VM => cmd_up_macos"

finish
