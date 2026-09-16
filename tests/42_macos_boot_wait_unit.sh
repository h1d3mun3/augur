#!/usr/bin/env bash
# Tier 0 — the two waits cmd_build_macos's automated path depends on (ADR-0018's amendment).
# Both are bounded polls, and both shipped broken in the original ADR-0018: the build treated a
# DHCP lease as "SSH is ready" (there was no macos_wait_for_ssh at all, so it SSH'd into a guest
# whose sshd had not started) and gave up on a fixed iteration count that could not be widened
# for a cold first boot. What must not regress is the pair of properties asserted here — a wait
# that actually ends, and a budget the caller can raise — because giving up early makes the
# caller tear down (SIGKILL) a VM that was still coming up, and never waiting reports a healthy
# guest as unreachable. The live paths are exercised only by a real build (see tests/README.md).
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/lib.sh"
AUGUR="$REPO/augur"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# Extract the two helpers BY NAME, same technique as 01_egress_allowlist_unit.sh — augur's
# entry-point dispatch never runs.
helpers="$WORK/helpers.sh"
for f in macos_vm_ip macos_wait_for_ssh; do
  awk -v n="$f" 'index($0, n"()")==1 {f=1} f{print} f&&/^}/{exit}' "$AUGUR" >> "$helpers"
  echo >> "$helpers"
done
# shellcheck disable=SC1090
source "$helpers"

section "Tier 0 — macos_wait_for_ssh (TCP reachability, not just an IP)"

# A port nothing listens on must END, non-zero, near its budget — never hang. (The last sleep
# can overshoot by one interval, so allow the budget plus a margin.)
start=$SECONDS
if macos_wait_for_ssh 127.0.0.1 9 6; then
  fail "gives up on a closed port" "unexpectedly reported the port reachable"
else
  ok "gives up on a closed port"
fi
elapsed=$(( SECONDS - start ))
if (( elapsed >= 4 && elapsed <= 12 )); then
  ok "honours the caller's budget (${elapsed}s for a 6s budget)"
else
  fail "honours the caller's budget" "took ${elapsed}s for a 6s budget"
fi

# The success path needs something actually listening. perl is the only socket-capable
# interpreter the offline tier can assume beyond bash itself; skip rather than fake it, since a
# stub would assert nothing about the /dev/tcp probe this function is built on.
if command -v perl &>/dev/null; then
  perl -e '
    use IO::Socket::INET;
    my $s = IO::Socket::INET->new(LocalAddr=>"127.0.0.1", Listen=>5, ReuseAddr=>1) or die $!;
    open(my $fh, ">", $ARGV[0]) or die $!; print $fh $s->sockport(); close $fh;
    $s->accept() for 1..3;
  ' "$WORK/port" &
  listener=$!
  for _ in $(seq 1 50); do [[ -s "$WORK/port" ]] && break; sleep 0.1; done
  port="$(cat "$WORK/port" 2>/dev/null || true)"
  if [[ -n "$port" ]]; then
    if macos_wait_for_ssh 127.0.0.1 "$port" 10; then
      ok "returns 0 as soon as the port accepts a connection"
    else
      fail "returns 0 as soon as the port accepts a connection" "port ${port} was listening"
    fi
  else
    skip "returns 0 as soon as the port accepts a connection" "listener did not start"
  fi
  kill "$listener" 2>/dev/null || true
  wait "$listener" 2>/dev/null || true
else
  skip "returns 0 as soon as the port accepts a connection" "no perl to open a listener"
fi

section "Tier 0 — macos_vm_ip (budget is the caller's, and the default is unchanged)"

# Stub the backend: never yields an address, so the loop runs to its deadline.
VM_CLI="false"
start=$SECONDS
if macos_vm_ip somevm 6; then
  fail "gives up when no lease ever appears" "unexpectedly printed an IP"
else
  ok "gives up when no lease ever appears"
fi
elapsed=$(( SECONDS - start ))
if (( elapsed >= 4 && elapsed <= 12 )); then
  ok "takes the caller's budget, not a fixed iteration count (${elapsed}s for 6s)"
else
  fail "takes the caller's budget, not a fixed iteration count" "took ${elapsed}s for a 6s budget"
fi

# An address available immediately is returned immediately — the default budget must not add
# latency to the common case.
printf '#!/usr/bin/env bash\necho 192.168.65.42\n' > "$WORK/vm-cli"
chmod +x "$WORK/vm-cli"
VM_CLI="$WORK/vm-cli"
start=$SECONDS
eq "192.168.65.42" "$(macos_vm_ip somevm)" "prints the leased address on success"
elapsed=$(( SECONDS - start ))
if (( elapsed <= 2 )); then
  ok "returns without waiting out the budget when the lease is already there"
else
  fail "returns without waiting out the budget when the lease is already there" "took ${elapsed}s"
fi

# The default has to stay generous enough for a cold boot: a caller that passes nothing must not
# inherit a budget shorter than the ~90s the original fixed 30×3s loop allowed.
default_budget="$(awk '/^macos_vm_ip\(\)/{f=1} f&&/max_secs=/{print; exit}' "$AUGUR")"
has "$default_budget" '${2:-90}' "keeps the historical ~90s default when no budget is passed"

finish
