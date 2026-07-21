#!/usr/bin/env bash
# Tier 1 (live, real binary) — augur-proxy idle-timeout on ESTABLISHED tunnels (issue #101).
#
# The connection cap (#36, tier 24) bounds how many tunnels exist, but an established-but-idle
# tunnel could still pin a slot forever. This tier proves the idle timeout added for #101 against
# the REAL binary:
#   A+D. an established idle tunnel is torn down within the window AND its connectionCap slot is
#        released — proven through a cap of 1, so a leaked/stranded slot (the #36 deadlock one
#        layer down that the joint teardown prevents) would starve a later cycle;
#   B.   a low-traffic stream (a byte every second — the SSE / long-poll shape) is PRESERVED past
#        the window, because activity in EITHER direction resets the shared idle clock, then is
#        torn down once it goes quiet;
#   C.   --idle-timeout 0 restores the pre-#101 behavior (an idle tunnel stays open);
#   E.   a normal client half-close does NOT truncate the in-flight opposite direction (the idle
#        change made teardown branch: idle-expiry shuts both fds, but a normal EOF stays a single
#        half-close — else it would truncate a legit response the other way).
#
# To exercise an ESTABLISHED tunnel we need a reachable upstream. augur-proxy denies IP-literals
# (I4) and refuses non-public addresses (I8), so we allowlist the NAME `localhost`, run a tiny
# loopback sink, and start the proxy with --allow-private (TEST-ONLY: it lets the proxy dial the
# 127.0.0.1 sink; production never passes it — that guard stays covered by AddressPolicy/I8).
#
# Needs the augur-proxy binary (built by `make unit` / `bash install`) and `perl` for the sink;
# self-skips cleanly when either is absent or the binary can't exec here (same contract as tier 24),
# so it's a no-op on this Linux checkout's cross-arch build and runs for real on the macOS CI runner.
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/lib.sh"
AUGUR="$REPO/augur"
section "Tier 1 — augur-proxy idle-timeout on established tunnels (#101)"

AUGUR_SOURCE_ONLY=1 source "$AUGUR"
set +e                                    # augur enables `set -e`; restore assert-and-continue

bin="$(resolve_proxy_cli)"
if ! command -v "$bin" >/dev/null 2>&1 && [[ ! -f "$bin" || ! -x "$bin" ]]; then
  skip "proxy idle-timeout" "augur-proxy not built (run: bash install, or make unit)"; finish; exit $?
fi
if ! "$bin" --help >/dev/null 2>&1; then
  skip "proxy idle-timeout" "resolved augur-proxy ($bin) is not runnable on this host (stale or cross-arch build?)"; finish; exit $?
fi
if ! command -v perl >/dev/null 2>&1; then
  skip "proxy idle-timeout" "perl not present (needed for the loopback upstream sink)"; finish; exit $?
fi

ADDR=127.0.0.1
TMPD="$(mktemp -d)"
echo "localhost" > "$TMPD/allow.conf"     # the CONNECT target must be a NAME (I4 denies IP-literals)

proxy_pid=""; sink_pid=""; resp_pid=""
# kill AND reap, so bash doesn't later print an async "Killed" job-control line to stderr.
reap() { local p; for p in "$@"; do [[ -n "$p" ]] && { kill -9 "$p" 2>/dev/null; wait "$p" 2>/dev/null; }; done; }
cleanup() { reap "$proxy_pid" "$sink_pid" "$resp_pid"; rm -rf "$TMPD"; }
trap cleanup EXIT

probe() { (exec 3<>"/dev/tcp/$1/$2") 2>/dev/null && { exec 3>&- 3<&-; return 0; } || return 1; }

# ── Loopback TCP sink (upstream). Accepts, DRAINS, and never closes first: only the proxy's idle
#    teardown ends a live tunnel, which is exactly what we measure. Prints its port on stdout. ──
perl -e '
  use IO::Socket::INET; use IO::Select; $| = 1;
  my $srv = IO::Socket::INET->new(LocalAddr=>"127.0.0.1", LocalPort=>0, Listen=>32, ReuseAddr=>1, Proto=>"tcp") or die $!;
  print $srv->sockport(), "\n";
  my $sel = IO::Select->new($srv);
  while (1) { for my $h ($sel->can_read) {
    if ($h == $srv) { my $c = $srv->accept; $sel->add($c) if $c; }
    else { my $n = sysread($h, my $b, 65536); if (!defined $n || $n == 0) { $sel->remove($h); close($h); } }
  } }
' > "$TMPD/sink.port" 2>"$TMPD/sink.err" &
sink_pid=$!
UP=""
for _ in $(seq 1 30); do UP="$(head -1 "$TMPD/sink.port" 2>/dev/null)"; [[ -n "$UP" ]] && break; sleep 0.1; done
if [[ -z "$UP" ]]; then
  fail "loopback sink did not start" "perl stderr: $(tail -3 "$TMPD/sink.err" 2>/dev/null)"; finish; exit $?
fi
ok "loopback upstream sink listening on $ADDR:$UP"

# Start the proxy with a given idle timeout (and optional connection cap) on a free port pair.
# Sets $HP (http port) + $proxy_pid.  $1=idle secs  $2=log basename  $3=max-connections (optional).
start_proxy() {
  local idle="$1" logbase="$2" cap="${3:-}" cand cap_args=()   # ${3:-}: cap is optional (set -u safe)
  [[ -n "$cap" ]] && cap_args=(--max-connections "$cap")
  HP=""
  for _try in 1 2 3 4 5; do
    cand=$(( 40000 + RANDOM % 20000 ))
    probe "$ADDR" "$cand" && continue
    probe "$ADDR" "$(( cand + 1 ))" && continue
    "$bin" --allowlist "$TMPD/allow.conf" --listen "$ADDR" \
           --http-port "$cand" --socks-port "$(( cand + 1 ))" \
           --allow-private --idle-timeout "$idle" ${cap_args[@]+"${cap_args[@]}"} \
           --log "$TMPD/$logbase.log" 2>"$TMPD/$logbase.err" &
    proxy_pid=$!
    for _ in $(seq 1 30); do probe "$ADDR" "$cand" && { HP=$cand; break; }; sleep 0.1; done
    [[ -n "$HP" ]] && break
    reap "$proxy_pid"; proxy_pid=""
  done
  [[ -n "$HP" ]]
}

# Open an established CONNECT tunnel to the sink on fd 3 IN THE CURRENT SHELL, so the fd survives
# for the idle-behavior probes below. (A `$(open_tunnel)` command-substitution would open fd 3 in a
# throwaway subshell — the parent would never see it.) Sets $STATUS to the CONNECT response line.
STATUS=""
# NB: `exec 3<>… 2>/dev/null` as a bare redirection would permanently send the shell's stderr to
# /dev/null (hiding later errors + `set -x`). Scope the error-suppression to a brace group so only
# fd 3 persists.
open_tunnel() {
  STATUS=""
  { exec 3<>"/dev/tcp/$ADDR/$HP"; } 2>/dev/null || return 1
  printf 'CONNECT localhost:%s HTTP/1.1\r\nHost: localhost:%s\r\n\r\n' "$UP" "$UP" >&3
  IFS= read -t 8 -r STATUS <&3 2>/dev/null
}
close_tunnel() { { exec 3>&- 3<&-; } 2>/dev/null; }

# Did the tunnel on fd 3 stay OPEN for at least $1 whole seconds? The sink never sends data, so the
# read only returns early on EOF (the proxy closed the tunnel); otherwise it blocks. We measure by
# ELAPSED time, NOT read's exit code — bash 3.2 (macOS CI) returns a different `read -t` timeout
# status than bash 4+, so `rc > 128` is not portable; elapsed time is. The read cap is $1+3, three
# seconds ABOVE the compare threshold, so a genuinely-open tunnel always measures >= $1 despite
# `SECONDS`' one-second granularity (a full block can't come up short). "open" iff elapsed >= $1
# (stayed up at least $1s); "closed" iff it EOF'd earlier. Pick $1 so the real close time sits
# clear of $1 (>=2s below for the expect-closed calls; the expect-open calls survive well past $1).
tunnel_state() {
  local t0=$SECONDS
  IFS= read -t "$(( $1 + 3 ))" -d '' -r _ <&3 2>/dev/null
  if (( SECONDS - t0 >= $1 )); then echo open; else echo closed; fi
}

# NOTE: the write-stall path (SO_SNDTIMEO: a guest that stops READING must not pin a slot via a
# blocked write) is covered by the classifyWrite unit tests + the joint-teardown wiring below;
# it is deliberately NOT a live case here (reliably filling a socket send buffer against a
# non-reading peer is buffer-size-dependent and flaky). The idle-reclaim it feeds into is proven
# below via the read-idle path, which shares the same shared-clock + joint-teardown machinery.

# ── A+D. idle tunnels are reclaimed AND release their slot — proven through a cap of 1 ────────
# With --max-connections 1 each tunnel holds the ONLY slot, so running several sequential
# open→idle-reclaim cycles then a fresh CONNECT proves BOTH that an idle tunnel is torn down AND
# that the idle-teardown path RELEASES its connectionCap slot every time. A leak/strand (the #36
# deadlock one layer down that the joint teardown prevents) would starve a later cycle: its CONNECT
# would get no 200. (idle 3s, poll = min(3,30) = 3s → reclaim within ~6s.)
section "A+D. idle tunnels are reclaimed AND release their slot (cap 1, --idle-timeout 3)"
if ! start_proxy 3 proxyAD 1; then
  fail "proxy did not come up on $ADDR" "last stderr: $(tail -3 "$TMPD/proxyAD.err" 2>/dev/null)"; finish; exit $?
fi
ok "real augur-proxy listening on $ADDR:$HP (--idle-timeout 3, --max-connections 1)"
open_tunnel; has "$STATUS" "200" "cycle 1: CONNECT localhost:$UP establishes (the one slot is free)"
start=$SECONDS
state="$(tunnel_state 12)"                  # idle 3s + poll 3s → expect close within ~6s
elapsed=$(( SECONDS - start ))
close_tunnel
eq "closed" "$state" "cycle 1: the idle tunnel was torn down (not held open forever)"
if (( elapsed <= 11 )); then ok "cycle 1: torn down promptly (${elapsed}s, within the ~idle+poll window)"; else fail "idle teardown too slow (${elapsed}s)"; fi
# Two more reclaim cycles through the SAME single slot: each open can only get 200 if the prior
# idle teardown actually released the slot — a leaked/stranded slot would hang the next CONNECT.
for c in 2 3; do
  open_tunnel; has "$STATUS" "200" "cycle $c: fresh CONNECT served — the prior idle teardown released the one slot"
  state="$(tunnel_state 12)"; close_tunnel
  eq "closed" "$state" "cycle $c: idle tunnel reclaimed"
done
reap "$proxy_pid"; proxy_pid=""

# ── B. a low-traffic stream survives the window, then closes when it goes quiet ───────────────
# Idle window 5s (poll = min(5,30) = 5s) gives the "still open" probe a wide, slow-CI-proof margin.
section "B. a low-traffic (SSE-style) stream is preserved, then reclaimed when it stops"
if ! start_proxy 5 proxyB; then
  fail "proxy (B) did not come up" "last stderr: $(tail -3 "$TMPD/proxyB.err" 2>/dev/null)"; finish; exit $?
fi
ok "real augur-proxy listening on $ADDR:$HP (--idle-timeout 5)"
open_tunnel; has "$STATUS" "200" "tunnel establishes"
# ~6s of 1-byte/s activity — longer than the 5s idle window, so a working shared clock is the only
# reason it survives (a per-direction clock would expire the silent upstream→client half mid-way).
# `sleep` THEN `printf` so the last byte is fresh when we probe (a full window of margin remains).
for _ in 1 2 3 4 5 6; do sleep 1; printf 'x' >&3 2>/dev/null; done
state_active="$(tunnel_state 2)"           # open iff it stays up ≥2s more (window ~5s left) — huge margin
eq "open" "$state_active" "the tunnel stayed open through 6s of low-traffic activity (shared clock reset by either direction)"
state_quiet="$(tunnel_state 15)"           # now silent → reclaimed (EOF) well before 15s → closed
close_tunnel
eq "closed" "$state_quiet" "once the stream went quiet, the idle tunnel was reclaimed"
reap "$proxy_pid"; proxy_pid=""

# ── C. --idle-timeout 0 restores the pre-#101 infinite-idle behavior ──────────────────────────
section "C. --idle-timeout 0 disables the timeout (idle tunnel stays open)"
if ! start_proxy 0 proxyC; then
  fail "proxy (idle 0) did not come up" "last stderr: $(tail -3 "$TMPD/proxyC.err" 2>/dev/null)"; finish; exit $?
fi
ok "real augur-proxy listening on $ADDR:$HP (--idle-timeout 0)"
open_tunnel; has "$STATUS" "200" "tunnel establishes with idle timeout disabled"
state0="$(tunnel_state 3)"                   # disabled: stays open the full read cap (6s) → open; any live window would have EOF'd
close_tunnel
eq "open" "$state0" "an idle tunnel stays open when --idle-timeout 0 (byte-for-byte pre-#101 behavior)"
reap "$proxy_pid"; proxy_pid=""

# ── E. a normal client half-close must NOT truncate the in-flight opposite direction ─────────
# The idle change made teardown branch: idle-expiry shuts BOTH fds (SHUT_RDWR), but a normal EOF
# must stay a single half-close (SHUT_WR) or it would truncate a legit in-flight response the
# other way. Prove it: a responder upstream replies ONLY AFTER the client half-closes its send
# side; if that client→upstream EOF wrongly tore down the whole tunnel, the reply never arrives.
# Run on an idle-DISABLED proxy so only the normal-EOF path is under test (no timeout interference).
section "E. a normal EOF half-close preserves the opposite direction (no truncation)"
perl -e '
  use IO::Socket::INET; $| = 1;
  my $srv = IO::Socket::INET->new(LocalAddr=>"127.0.0.1", LocalPort=>0, Listen=>8, ReuseAddr=>1, Proto=>"tcp") or die $!;
  print $srv->sockport(), "\n";
  while (my $c = $srv->accept) {
    while (1) { my $n = sysread($c, my $b, 65536); last if !defined $n || $n == 0; }  # drain until the client half-closes
    syswrite($c, "AUGUR-PONG");                                                        # reply AFTER that EOF
    close($c);
  }
' > "$TMPD/responder.port" 2>"$TMPD/responder.err" &
resp_pid=$!
UP2=""
for _ in $(seq 1 30); do UP2="$(head -1 "$TMPD/responder.port" 2>/dev/null)"; [[ -n "$UP2" ]] && break; sleep 0.1; done
if [[ -z "$UP2" ]]; then
  fail "responder sink did not start" "perl stderr: $(tail -3 "$TMPD/responder.err" 2>/dev/null)"
elif ! start_proxy 0 proxyE; then
  fail "proxy (E) did not come up" "last stderr: $(tail -3 "$TMPD/proxyE.err" 2>/dev/null)"
else
  ok "responder upstream on $ADDR:$UP2; proxy on $ADDR:$HP (--idle-timeout 0)"
  # perl client: CONNECT through the proxy, send a request, HALF-CLOSE its write side, then read
  # the full reply. It receives the sentinel only if upstream→client survived the client→upstream EOF.
  got="$(perl -e '
    use IO::Socket::INET;
    my ($ph,$pp,$up) = @ARGV;
    my $s = IO::Socket::INET->new(PeerAddr=>$ph, PeerPort=>$pp, Proto=>"tcp") or exit 2;
    syswrite($s, "CONNECT localhost:$up HTTP/1.1\r\nHost: localhost:$up\r\n\r\n");
    my $line=""; while (sysread($s, my $ch, 1)) { $line .= $ch; last if $ch eq "\n"; }
    exit 3 unless $line =~ /200/;
    while (sysread($s, my $ch, 1)) { last if $ch eq "\n"; }   # consume the header-terminating blank line
    syswrite($s, "PING");
    shutdown($s, 1);                                          # half-close OUR write side → EOF client→upstream
    my $resp=""; while (sysread($s, my $b, 65536)) { $resp .= $b; }
    print $resp;
  ' "$ADDR" "$HP" "$UP2" 2>/dev/null)"
  has "$got" "AUGUR-PONG" "the reply sent AFTER the client half-close reached the client (half-close teardown, not joint RDWR)"
fi
reap "$resp_pid"; resp_pid=""
reap "$proxy_pid"; proxy_pid=""

finish
