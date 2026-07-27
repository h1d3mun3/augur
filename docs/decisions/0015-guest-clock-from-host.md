# ADR-0015 — the macOS guest's clock is set from the host, not by opening NTP

- **Status:** Accepted.
- **Date:** 2026-07-26.
- **Applies to:** macOS VM mode only (`--macos`). Container mode's guest shares the host kernel's
  clock and has never had this problem.
- **Builds on:** [`0001`](./0001-sudo-free.md) (whose sudo-free rule is about the **host**, and is
  untouched here), [`0007`](./0007-macos-build-fixed-credential.md) (the fixed guest credential this
  uses to reach `sudo`), [`0006`](./0006-macos-vm-clone-persistence.md)/[`0010`](./0010-container-persistence.md)
  (clones outlive `down`, which is why one correction per boot is not enough).

## Decision

**augur pushes the host's wall-clock time into the macOS guest over `ssh_macos` and verifies it
landed.** `sync_macos_guest_clock` runs from four sites — `cmd_up_macos`'s fresh bring-up path,
`cmd_up_macos`'s already-running reconcile branch, `cmd_claude_macos` and `cmd_shell_macos` — reads
the guest's clock first, corrects it only when it is more than `_MACOS_CLOCK_TOLERANCE_S` (5 s) out,
reads it back to confirm, and **warns rather than fails** at every step.

**augur does not, and will not, open a UDP path so the guest can run NTP.** That is the alternative
this record exists to close.

## Context — the measurement

The guest's `CLOCK_REALTIME` runs behind the host's. Measured from inside a live project VM (the host
clock obtained by stamping a file through the virtiofs share, which the host's filesystem timestamps):

```
host clock (share mtime)         : 1785039613
kern.monotonicclock              : 1785039613   delta =     0 s   ← tracks the host exactly
guest CLOCK_REALTIME (date +%s)  : 1785033880   delta = -5733 s   ← 95.6 min behind

kern.monotoniclock_offset_usecs  = -5733425731
  · byte-identical across two different boots (boottime 1784977019 and 1785006496)
  · byte-identical again after a further 1h42m of uptime (7h36m total)
kern.sleeptime = kern.waketime = 0     ← the guest itself never slept
```

Three readings follow from this and settle a question two earlier investigations disagreed on:

1. **It is a constant, not drift.** The offset did not grow across 7h36m of uptime and survived a
   reboot unchanged. "Accumulated VM suspend time" is refuted by both facts, and by
   `kern.sleeptime`/`waketime` being zero.
2. **It is inherited, not per-boot chance.** A value that is byte-identical across boots is baked
   into the VM's persisted state — i.e. into the base VM image, and therefore into every thin clone
   `up --macos` makes of it.
3. **The guest's monotonic clock is right; only its realtime is wrong.** That is exactly why nobody
   noticed: anything measuring a *duration* (build times, timeouts, `ServerAliveInterval`) is
   correct. Only comparisons against an *absolute* instant are wrong.

### What breaks, worst first

- **Token validity.** The highest-impact case. A JWT minted on the host — `claude setup-token`,
  `gh auth token` — carries `iat`/`nbf`/`exp` in host time. A guest 95 minutes in the past can see a
  token issued *seconds ago* as **not yet valid**, and augur's whole macOS auth design is
  "the host resolves a credential and injects it into the guest" (`~/.augur-env`). The failure is
  opaque: the agent rejects the credential augur just handed it.
- **Git history.** Commits made in the guest are stamped 95 minutes early, permanently, in the
  operator's real repository through the read-write workspace share.
- **TLS validity windows.** Certificates are days wide, so this is usually invisible — but a
  certificate rotated within the last 95 minutes is *not yet valid* to this guest. Inside
  `verify_macos_egress_locked`'s positive half that reads as "allowlisted egress does not work",
  whose remedy is to tear the VM down. A clock bug that can destroy a healthy VM is worth fixing on
  its own.

## Why not NTP

The instinctive fix — let the guest keep its own time — cannot work in augur's datapath, and making
it work would be a security regression.

- **The allowlist is the wrong shape.** NTP is **UDP/123**. `augur.conf` is a list of **names** for a
  **SOCKS5/TCP** proxy. Adding `time.apple.com` to it forwards nothing; it is not a firewall rule.
- **There is no UDP forwarder to reach.** `gvproxy/augur-egress.patch` (`services.go`) registers the
  UDP and ICMP forwarders only when `--deny-direct` is off:

  ```go
  // augur egress mode: with DenyDirectEgress, do not register the UDP and ICMP
  // forwarders at all. They net.Dial directly (bypassing the SOCKS allowlist), so
  // leaving them registered would be an egress hole (e.g. QUIC/HTTP3 exfil, ICMP
  // tunneling). The gateway DNS server is a separate listener and still works.
  if !configuration.DenyDirectEgress {
      udpForwarder := forwarder.UDP(s, translation, &natLock, configuration.Ec2MetadataAccess)
      s.SetTransportProtocolHandler(udp.ProtocolNumber, udpForwarder.HandlePacket)
      icmpForwarder := forwarder.ICMP(s, translation, &natLock)
      s.SetTransportProtocolHandler(icmp.ProtocolNumber4, icmpForwarder.HandlePacket)
  }
  ```

  augur always passes `--deny-direct`, so the guest's UDP has **no path out at all**, allowlist or no
  allowlist.
- **Opening one fights an invariant that is now actively tested.** `INVARIANTS.md` **I9** states "The
  gvproxy patch drops UDP/ICMP and forces all TCP through the SOCKS allowlist," and
  `verify_macos_egress_locked` now *asserts* it on every `up --macos` — a direct `dig @1.1.1.1` that
  answers, or a `ping` that replies, is a detected leak that tears the VM down. A UDP hole for time
  would be a full-bandwidth, allowlist-free exfiltration channel (it is precisely why the forwarder
  was removed), and it would make augur's own boot self-test fail. **I9's rule text is not changed by
  this ADR** — nothing here weakens it; the point is that a clock fix must not.

So the fix has to use time augur **already has**, which means the host's clock.

## Why the host's clock and not the guest's own `kern.monotonicclock`

The guest *does* already hold a correct wall clock in `kern.monotonicclock`, and a purely in-guest
correction (`date` from `monotonicclock + 0`) needs no host round-trip and no transfer-accuracy
argument at all. It was rejected anyway:

- **`monotonicclock` is not specified as "the host's wall clock."** Its contract is a clock
  `settimeofday` cannot perturb. That it equals the host's time here is an artifact of *this*
  hypervisor seeding the guest timebase from the host's — not a documented property of
  Virtualization.framework, and not something a future macOS or a differently-built base VM is
  obliged to preserve.
- **A guest reading its own bad clock cannot notice.** If that seed were ever wrong (including
  seeded from the same stale persisted state that causes this bug), an in-guest fix would confidently
  write the wrong time and there would be no second opinion anywhere in the system. The host-push
  form has one by construction: the host reads its own clock, and the read-back compares two
  independent sources.
- **The host is already the authority for everything else.** augur's macOS mode pushes the host's
  credentials, the host's `~/.gitconfig`, the host's managed Claude Code policy and the host's egress
  allowlist into the guest. Time is the same kind of object, and the host is a real, NTP-synced Mac.

The cost of the host push is **transfer accuracy**: the value is stale by one SSH round-trip. That is
tens of milliseconds over gvproxy's loopback forward, bounded by the read-back at 5 s, and being
compared against a **5733 s** error — three orders of magnitude of margin. Nothing that consumes this
clock can tell 5 s from 0 (JWT windows are minutes, X.509 validity is days).

## Where it runs, and why there

`cmd_up_macos` calls it **immediately after `wait_for_macos_ssh` succeeds and immediately before
`verify_macos_egress_locked`** — i.e. it is the one step that precedes I1's boot tripwire.

That is deliberate and does not weaken I1. What the tripwire's placement protects is that a guest
whose egress is not contained must not be handed a **credential**; the host's wall-clock time is not
one, and the guest can already read it off the mtimes of the virtiofs share it is mounting (that is
how the measurement above was taken). Going second instead would leave the self-test's own TLS
handshakes — including the two load-bearing positive assertions — judging certificate windows 95
minutes early, i.e. able to tear down a healthy VM over a certificate rotated minutes ago.

Everything downstream of that point needs it: the `~/.augur-env` push (the token), the git credential
helper (the same token), and the agent itself.

## Why four call sites, not one

The measurement says the offset is boot-invariant, so **one correction per boot would fix the defect
as observed**. Three sites are for the shape of the failure, not the instance of it:

- **`cmd_claude_macos` / `cmd_shell_macos`** attach to a running VM *without going through*
  `cmd_up_macos` — the same reason `warn_if_macos_profile_stale` and `warn_if_macos_egress_pinned`
  are already called from exactly those two sites. `claude` is where a skewed clock costs the most.
- **The already-running reconcile branch** is the only place a long-lived guest gets re-corrected.
  `down --macos` keeps the clone (0006/0010), so macOS VMs are long-lived by design, and a VM paused
  while the *host* sleeps has its `CLOCK_REALTIME` frozen while the host's advances. **This is an
  assumption, stated as one:** it was not reproduced (the measured guest's realtime and monotonic
  clock advanced at the same rate throughout its uptime, and `kern.sleeptime`/`waketime` show the
  guest observed no sleep of its own). A re-correction on a path that already exists is cheap
  insurance against a mechanism that cannot be ruled out.

The call is **idempotent** — it reads first and writes only when it must — so the extra sites cost one
SSH round-trip each on a guest that is already right, and no `sudo` at all.

## Why `sudo` in the guest is not a new privilege

Setting `CLOCK_REALTIME` needs root in the guest. That is not what ADR-0001 forbids: **0001 is about
the host** — its examples are host `pf` rules, `sudo lsof` on the host, and the host bridged-networking
entitlement, and its argument is about augur's *host-side* blast radius. Nothing here asks the
operator for host privilege.

Inside the guest, augur already takes exactly this privilege by exactly this mechanism.
`install_macos_managed_settings` writes into root-owned `/Library` with:

```sh
ssh_macos "$vm" "echo '${MACOS_SSH_USER}' | sudo -S -p '' sh -c '…'"
```

`sudo -S` fed the documented fixed password (ADR-0007) — which works *whether or not* the build-time
`NOPASSWD` grant is present, and it is not: `cmd_build_macos` removes `/etc/sudoers.d/augur` before
saving the base VM precisely so the agent does not inherit root, and a project clone's
`/etc/sudoers.d/` is empty (verified in a live guest). So `sudo -S` with the fixed password is the
established — and the only — way augur runs a privileged command in a project guest, and this change
adds no new one.

`/bin/date` is called by absolute path for the same reason `verify_macos_egress_locked` pins `PATH`:
`~/.augur-env` puts `$HOME/.local/bin` first in every guest shell and the clone survives
`down --macos`, so a bare `date` is shadowable by a prior guest session. That is hygiene, not a
control — the clock is not a security boundary, and a guest that can shadow the set can also lie on
the read-back.

## Failure handling: best-effort, and a read-back

**Best-effort (`warn`, return 0), not fatal.** `verify_macos_egress_locked` fails hard because I1
makes an unverifiable datapath a *security* failure. A wrong clock is not that: it is a guest that
works and gets some absolute timestamps wrong. Aborting would also abort with the VM already cloned,
sized, booted and SSH-reachable — the stranded-guest shape the pre-clone credential check was added
to remove — in exchange for a condition every augur release before this one shipped with. So it warns
and names the consequence, like the profile wiring and the git credential helper.

**The clock is read back, not trusted.** The exit status of `echo <pw> | sudo -S /bin/date …` covers a
rejected password and a malformed stamp. It cannot cover the third case: `/usr/libexec/timed` is
running in the guest, and `systemsetup -getusingnetworktime` needs root even to *read*, so augur
cannot cheaply know whether network time is enabled. In augur's own datapath `timed` has no reference
to step back to (UDP/123 is dropped — measured: the offset held byte-identical for 7h36m with `timed`
live), and under `--no-egress` NAT it would converge on the same answer anyway. But "the command
exited 0 and the clock is still wrong" is exactly the silent case a read-back converts into a named
warning, for one extra round-trip on a path that already makes a dozen.

The guest's own network-time setting is deliberately **left alone** — no
`systemsetup -setusingnetworktime off`. It is another privileged mutation with a persistent effect,
it cannot be read back without a second `sudo`, and in the only mode where `timed` could reach a
server (`--no-egress`) its correction is the one wanted.

## Consequences

- `up --macos`, `claude --macos` and `shell --macos` each make one extra SSH round-trip against a
  correct guest, and three (read, set, verify) against a skewed one. A correction prints the measured
  drift and a confirmation; an in-tolerance guest prints nothing.
- Guests are corrected in place, so the **base VM keeps its bad offset**. That is intentional: the
  offset lives in saved VM state, fixing it there would mean re-saving the base image, and every
  clone is corrected on the way up anyway. `augur build`/`update --macos` are unchanged.
- Timestamps in the guest change by ~95 minutes the first time an operator upgrades. Anything in a
  guest that compared its own past timestamps against `now` sees one discontinuity.
- The guest gains no capability. It could already read the host's wall clock off the share.
- Not proven live in this change: the correction is exercised only through stubs
  (`tests/38_macos_guest_clock.sh` never sets a real clock, by design — doing so on a running
  session corrupts file mtimes and commit timestamps). The live effect is covered by the same
  AUGUR_TEST_LIVE-gated path as the rest of macOS mode.

## Alternatives considered

- **Allowlist a time server (`time.apple.com`) in `augur.conf`.** Rejected: NTP is UDP/123 and the
  allowlist is a SOCKS5/TCP name list. It would look like a fix and do nothing.
- **Register the UDP forwarder for :123 only.** Rejected: a security regression against I9 that
  `verify_macos_egress_locked` would flag as a leak on the next `up`. A per-port UDP exception is
  still an allowlist-free datapath, and the exfiltration argument that removed the forwarder does not
  get weaker because the port is 123.
- **Run NTP over TCP through the SOCKS proxy.** Rejected: no macOS system time client speaks it, so
  it would mean shipping a bespoke time client into the guest and wiring it to `sntp`-less plumbing —
  far more machinery than one `date` call, for a strictly worse reference than the host augur is
  already trusting.
- **Read the guest's own `kern.monotonicclock` instead.** Rejected; see the section above. Cheaper,
  but it trusts an unspecified property of the hypervisor's timebase with no second opinion.
- **Fix the base VM at build time.** Rejected as insufficient rather than wrong: the offset is in
  saved VM state and would have to be re-corrected before every save, it does nothing for base images
  already built, and it cannot address post-boot drift on a long-lived clone. The per-`up` correction
  subsumes it.
- **Fail `up --macos` when the clock cannot be set.** Rejected: it converts a degraded-but-working
  guest into an unusable one, and it aborts after the boot (see *Failure handling*).
- **Disable the guest's network time (`systemsetup -setusingnetworktime off`).** Rejected: an extra
  privileged, persistent mutation for a daemon that is provably inert in augur's datapath, and
  actively useful in the one mode where it is not.

## Related

- [`../security-reviews/INVARIANTS.md`](../security-reviews/INVARIANTS.md) — **I9** (UDP/ICMP dropped)
  is what makes in-guest NTP impossible; **I1** is the tripwire this correction is ordered against.
- [`0001`](./0001-sudo-free.md) — the sudo-free rule, and why it is about the host.
- [`0007`](./0007-macos-build-fixed-credential.md) — the fixed guest credential `sudo -S` uses.
- `tests/38_macos_guest_clock.sh` — the wiring, the ordering, the idempotence and every best-effort
  branch, all through stubs.
