#!/usr/bin/env bash
# Tier 1 (live, real binary) — augur-proxy global connection cap: liveness under load +
# capacity observability. The automated counterpart to issue #36's "load-test with many
# simultaneous connections". The proxy runs on the host and the sandboxed agent is
# untrusted, so a global cap (--max-connections) bounds the ~2-threads-per-connection growth
# that once froze the proxy. This tier drives the REAL binary with a deliberately tiny cap
# and proves:
#   1. Liveness — many MORE simultaneous connections than the cap are all served (they queue
#      on the listen backlog) and the proxy neither wedges nor dies. This is the guarantee the
#      cap exists to provide, and it also exercises the checked-spawn slot release in serve()
#      and spliceBoth (a leaked slot would deadlock the accept loop → this tier would hang/fail).
#   2. Observability — when every slot is in use the proxy logs a single "reached capacity"
#      line to its STATUS channel (stderr-only), and a "recovered" line when it drains. That
#      line must NOT land in the greppable DENY log file.
#
# Needs the augur-proxy binary (built by `make unit` / `bash install`); self-skips cleanly when
# it is absent or is a stale cross-arch build that can't exec here (same contract as tier 23).
# Only binds 127.0.0.1 (no second loopback alias needed), so it runs on a stock macOS CI runner.
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/lib.sh"
AUGUR="$REPO/augur"
section "Tier 1 — augur-proxy connection cap: liveness under load + capacity gauge (#36)"

AUGUR_SOURCE_ONLY=1 source "$AUGUR"
set +e                                    # augur enables `set -e`; restore assert-and-continue

# Resolve the real proxy binary via augur's own logic; skip if it isn't a runnable build here
# (mirrors tier 23: a bare-name fallback or a cross-arch Mach-O left in .build/release would
# otherwise turn a clean skip into a hang/failure).
bin="$(resolve_proxy_cli)"
if ! command -v "$bin" >/dev/null 2>&1 && [[ ! -f "$bin" || ! -x "$bin" ]]; then
  skip "proxy concurrency" "augur-proxy not built (run: bash install, or make unit)"; finish; exit $?
fi
if ! "$bin" --help >/dev/null 2>&1; then
  skip "proxy concurrency" "resolved augur-proxy ($bin) is not runnable on this host (stale or cross-arch build?)"; finish; exit $?
fi

CAP=4
ADDR=127.0.0.1
TMPD="$(mktemp -d)"
# A one-line allowlist that our probe hosts never match, so every CONNECT is DENIED (403) and
# no real upstream is needed — the cap/liveness behaviour is independent of the allow decision.
echo "allowed.invalid" > "$TMPD/allow.conf"

proxy_pid=""
cleanup() { [[ -n "$proxy_pid" ]] && kill -9 "$proxy_pid" 2>/dev/null; rm -rf "$TMPD"; }
trap cleanup EXIT

# probe: can we open a TCP connection to ADDR:port? (bash /dev/tcp — no nc dependency)
probe() { (exec 3<>"/dev/tcp/$1/$2") 2>/dev/null && { exec 3>&- 3<&-; return 0; } || return 1; }

# Start the proxy on a free high port pair, retrying a few times to dodge a busy port. Both the
# HTTP and SOCKS ports must be free (the binary binds both). Returns with $HP/$SP set and the
# proxy listening, or fails the tier.
HP=""; SP=""
for _try in 1 2 3 4 5; do
  cand=$(( 40000 + RANDOM % 20000 ))
  probe "$ADDR" "$cand" && continue                 # HTTP port busy
  probe "$ADDR" "$(( cand + 1 ))" && continue        # SOCKS port busy
  "$bin" --allowlist "$TMPD/allow.conf" --listen "$ADDR" \
         --http-port "$cand" --socks-port "$(( cand + 1 ))" \
         --max-connections "$CAP" --log "$TMPD/proxy.log" 2>"$TMPD/stderr.log" &
  proxy_pid=$!
  # Wait up to ~3s for it to listen.
  for _ in $(seq 1 30); do probe "$ADDR" "$cand" && { HP=$cand; SP=$(( cand + 1 )); break; }; sleep 0.1; done
  [[ -n "$HP" ]] && break
  kill -9 "$proxy_pid" 2>/dev/null; proxy_pid=""
done
if [[ -z "$HP" ]]; then
  fail "proxy did not come up on $ADDR" "last stderr: $(tail -3 "$TMPD/stderr.log" 2>/dev/null)"; finish; exit $?
fi
ok "real augur-proxy listening on $ADDR:$HP (--max-connections $CAP)"

# One denied CONNECT; echoes the proxy's first response line. Bounded with bash's OWN
# `read -t` (a builtin) rather than GNU `timeout`, which macOS does not ship — so a stuck
# read still can't hang the tier, and the probe works identically on the Linux and macOS CI.
one_denied() {
  local line=""
  exec 3<>"/dev/tcp/$ADDR/$HP" 2>/dev/null || return 0
  printf 'CONNECT blocked.invalid:443 HTTP/1.1\r\nHost: blocked.invalid:443\r\n\r\n' >&3
  IFS= read -t 8 -r line <&3 2>/dev/null
  exec 3>&- 3<&-
  printf '%s' "$line"
}

# ── 1. Liveness: many more simultaneous connections than the cap are all served ──────────────
section "liveness — $(( CAP * 6 )) simultaneous connections through a cap of $CAP"
N=$(( CAP * 6 ))                          # 24: six times the cap, all at once
res="$TMPD/res"; : > "$res"
pids=()
for _ in $(seq 1 "$N"); do
  ( r="$(one_denied)"; case "$r" in *"403"*) echo ok;; *) echo "bad:[$r]";; esac >> "$res" ) &
  pids+=($!)
done
for p in "${pids[@]}"; do wait "$p" 2>/dev/null; done
good=$(grep -c '^ok$' "$res" 2>/dev/null); good=${good//[^0-9]/}
eq "$N" "${good:-0}" "all $N concurrent connections (>cap) were served 403 — excess queues, never wedges"

if kill -0 "$proxy_pid" 2>/dev/null; then ok "proxy process still alive after the burst"; else fail "proxy died under load"; fi
has "$(one_denied)" "403" "proxy still serves a fresh request after the burst (no deadlock)"

# ── 2. Observability: saturating the cap logs to the STATUS channel, not the DENY file ───────
section "capacity gauge — $(( CAP + 1 )) stalled handlers saturate a cap of $CAP"
# Each holder opens a connection, sends a PARTIAL request (no blank line), and keeps the socket
# open — so its handler blocks in readHTTPHead holding a cap slot until we close it.
hold=()
for _ in $(seq 1 $(( CAP + 1 ))); do
  ( exec 3<>"/dev/tcp/$ADDR/$HP" && printf 'CONNECT partial.invalid' >&3 && sleep 10 ) &
  hold+=($!)
done
seen=0; for _ in $(seq 1 60); do grep -q "reached capacity" "$TMPD/stderr.log" && { seen=1; break; }; sleep 0.1; done
eq 1 "$seen" "proxy logs 'reached capacity' when all $CAP slots are in use"
if grep -q "reached capacity" "$TMPD/proxy.log" 2>/dev/null; then
  fail "the capacity line leaked into the DENY log file" "it must be stderr-only (status channel), not skipFile:false"
else
  ok "capacity line stays OUT of the greppable DENY log file"
fi
# Release the holders → the episode clears → a single recovery line.
for p in "${hold[@]}"; do kill "$p" 2>/dev/null; done
rec=0; for _ in $(seq 1 120); do grep -q "recovered:" "$TMPD/stderr.log" && { rec=1; break; }; sleep 0.1; done
eq 1 "$rec" "proxy logs 'recovered' once the saturation clears"

finish
