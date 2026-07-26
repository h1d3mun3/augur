# augur security invariants (the contract)

This is a **contract** (properties that must always hold), not a description of the
current state. Where a [snapshot](./README.md) **describes** "how it works at a point
in time," this **prescribes** "what must never break." It changes rarely.

> **Foundational principle — augur is sudo-free.** It never requires root on a production
> path. That is *why* the invariants below are enforced with unprivileged mechanisms, and
> why some risks are documented-and-accepted rather than closed by taking privilege. Before
> proposing "just use sudo/`pf` here," read
> [`decisions/0001-sudo-free.md`](../decisions/0001-sudo-free.md).

## Operating rules

- A normal security fix only needs to **keep this contract green** — you do not edit
  the prose. Running the `Enforced by` tests with `swift test` (plus the boot
  `verify_egress_locked`) checks most of it **mechanically**.
- **Changing an invariant is a contract change**: update this file AND open a **new
  dated snapshot**. That is a "security-quality decision" the implementer owns, not
  "documentation cleanup."
- `Enforced by` legend: **✅ test** (enforced by a unit/self test) / **🟡 partial**
  (only partly tested) / **⚠ review-only** (prose only — can rot silently; a test candidate).

---

## Invariants

### I1. Egress fails closed on every engine  ✅ test
- **Rule:** Unreadable allowlist → refuse to start. Empty → deny all. Undecidable
  (no SNI / upstream unreachable) → deny. If the boot self-test fails, tear the **guest**
  down: on Apple Container the container (`verify_egress_locked`), on macOS the VM together
  with gvproxy and the proxy (`verify_macos_egress_locked`).
- **Why:** Prevent a misconfiguration or partial failure from "opening up." When it
  fails, it must fail to the closed side.
- **Enforced by:** `AllowlistTests.testEmptyConfDeniesEverything` / shell `verify_egress_locked()`
  (container) **and `verify_macos_egress_locked()`** (macOS VM, `augur`). Until the latter existed,
  "on every engine" held for the *policy* half on both engines but the boot tripwire was
  container-only: `verify_egress_locked` had exactly one call site (`finish_up`), which macOS mode
  never reaches, so no macOS production path ever probed the guest's network. The macOS peer now
  runs on **both** `up --macos` paths (fresh boot and the already-running reconcile) and tears the
  VM, gvproxy and the proxy down on a failure. Both self-tests are inherently live (they need a
  booted guest); the *wiring* — invoked on both paths, and a NOT-locked verdict exits non-zero with
  the teardown having run — is covered offline by `tests/36_macos_egress_selftest.sh`, and
  `tests/34_up_reconcile.sh` pins the **already-running** path on both engines (container reaches
  `finish_up`; macOS reaches `verify_macos_egress_locked`). `verify_egress_locked` itself has no
  offline peer at all — its live gate is `tests/22_egress_failclosed.sh`, and mutation testing
  confirms that deleting its fail-closed branch, or its call from `finish_up`, leaves the offline
  suite green. The two engines' halves of this invariant therefore rest on very unequal evidence.

### I2. Domain matching is label-boundary anchored  ✅ test
- **Rule:** `*.x` matches `a.x` but not `evilx`. `x` = apex only; `.x` = apex + subdomains.
- **Why:** Prevent an allowlist bypass via a suffix match (e.g. `evilgithub.com`).
- **Enforced by:** `AllowlistTests.{testWildcardSubdomainsOnly, testSubdomainBoundaryHelper, testExactHostOnly, testDotPrefixMatchesApexAndSubdomains}`

### I3. Hostnames must pass LDH validation (NUL-truncation defense)  ✅ test
- **Rule:** The allow decision and the `getaddrinfo` dial use the **same string**.
  `isValidHostname` enforces strict LDH and rejects NUL / whitespace / empty labels.
- **Why:** Prevent `evil.com\0.github.com` from being allowed by a suffix match yet dialed to a different host.
- **Enforced by:** `SecurityTests.{testHostnameValidation, testAllowlistRejectsNULInjection, testSNIRejectsNUL}`

### I4. IP-literal connects are denied unconditionally (fail-secure)  ✅ test
- **Rule:** An IP-literal destination is **never** matched by the allowlist. The pin
  table that could re-allow a recently-resolved IP is an unwired scaffold (no
  production datapath populates it — addendum A4), so the decision always falls to deny.
- **Why:** Prevent exfiltration via a direct IP-literal / ECH connection.
- **Enforced by:** `AllowlistTests.testIPLiteralsNeverMatch` / `SNIAndFilterTests.testFilterDeniesUnpinnedIPLiteral`

### I5. DNS fails closed (no DNS tunnel)  ✅ test
- **Rule:** Keep "resolvable == connectable." Apple Container uses `--no-dns` (no
  resolver in the guest), and the macOS VM uses gvproxy's `--dns-allowlist` (NXDOMAIN
  for non-allowlisted; rejects record types other than A/AAAA).
- **Why:** Prevent exfiltration by smuggling data in DNS queries.
- **Enforced by:** the DNS probe in shell `verify_egress_locked()` (container, `augur`) **and the two
  DNS probes in `verify_macos_egress_locked()`** (macOS, on both `up --macos` paths): a
  non-allowlisted name must NOT resolve through the guest's own resolver stack (`dscacheutil`, i.e.
  mDNSResponder → gvproxy's DNS), and the allowlisted `_SELFTEST_HOST` MUST resolve — the pair proves
  `--dns-allowlist` is armed **and discriminating**, not merely closed. Both are live (they need a
  booted guest); `tests/36_macos_egress_selftest.sh` pins offline that a resolving non-allowlisted
  name is treated as a leak and tears the VM down. ⚠ Neither engine's `--no-dns` / `--dns-allowlist`
  argv is asserted by any test (see I8's note).

### I6. Hot reload never falls open  ✅ test
- **Rule:** If a reload of the allowlist is readable (even empty/garbage → deny all)
  it is swapped in atomically. **If it is unreadable, the previous policy is kept.** An
  in-flight request never sees a partial or widened policy.
- **Why:** Prevent egress from accidentally opening on file corruption or a transient read failure.
- **Enforced by:** `SNIAndFilterTests.{testHotReloadSwapsPolicy, testFromFileReturnsNilOnUnreadable, testHotReloadKeepsPolicyWhenFileUnreadable}`. To make "unreadable → nil → keep old policy" testable, the file load was extracted into the core lib `Allowlist.fromFile`.

### I7. The guest cannot widen its own allowlist  ✅ test
- **Rule:** The merged allowlist is written host-side at
  `~/.augur/proxy/<slug>-<workspace-path-hash>.allowlist` (**outside the project tree**). A
  `./.augur/allowlist.conf` is merged only after TOFU approval and only its sanitized domains
  (via `conf_line_valid`); and every per-project egress host-state file — merged allowlist,
  proxy/gvproxy pidfiles, logs, vfkit socket — is keyed on the **FULL workspace path**, so an
  approval granted for one project can never reach another project's enforcement point.
- **Why:** Prevent root-in-guest from rewriting the egress policy mid-session. The path-keying
  clause covers the other direction: an approval is scoped to the project it was granted for, so
  a *second* project can neither inherit that approval nor donate its own to the first project's
  live proxy. Keyed on the basename alone, `~/work/app` and `~/archive/app` shared one merged
  allowlist, and whichever ran `up` last silently rewrote the other's live policy.
- **Enforced by:** `tests/01_egress_allowlist_unit.sh` (checks `conf_line_valid`'s grammar,
  `project_conf_domains` sanitization, that `write_merged_allowlist` drops guest-supplied junk and
  writes **outside the project tree**, and that two same-basename projects write **different**
  merged allowlists neither of which contains the other's approved domains) plus
  `tests/32_proxy_per_mode.sh` (every per-project host-state path differs between two
  same-basename projects while the slug is identical) plus `tests/11_construct_container.sh` and
  `tests/30_macos_vm.sh` (the workspace-containment guard `require_safe_workspace`, `augur:4951` —
  a workspace that CONTAINS `~/.augur` would put the merged allowlist itself inside the read-write
  share, which is the same widening this invariant forbids; refused on both engines from the shared
  dispatch tail, see `docs/decisions/0014-workspace-must-not-contain-augur.md`). The TOFU approval
  itself (`check_project_conf_approved`) is ⚠ review-only.

### I8. Keep the private-IP dial guard always armed  ✅ test
- **Rule:** Never pass `--allow-private` to `augur-proxy` on a production path. Before
  dialing, re-check the resolved `sockaddr` and block private / loopback / link-local
  / metadata destinations.
- **Why:** Prevent SSRF where an allowlisted name resolves to a LAN / host / metadata IP.
- **Enforced by:** `AddressPolicyTests` (the classification logic was extracted into the core
  lib `AddressPolicy.isPrivateV4`/`isPrivateV6` and tested directly: RFC1918, loopback, CGNAT,
  metadata 169.254.169.254, IPv4-mapped, etc. are classified non-public, while public IPs and
  each block boundary are classified public). Not passing `--allow-private` in production is a
  structural guarantee (addendum A6) — ⚠ **grep-only**: no test asserts `start_proxy`'s argv, and
  inserting the flag at `augur:1162` leaves the entire offline suite green. The same gap covers
  `start_gvproxy`'s `--socks-upstream` / `--dns-allowlist` / `--deny-direct` and `container run`'s
  `--no-dns`. A one-line source guard per call site — the shape `tests/30_macos_vm.sh:186` already
  uses — would close all five cheaply.

### I9. macOS guest network isolation  🟡 partial
- **Rule:** The guest's NIC is a **single** host-owned socket (`VZFileHandleNetworkDeviceAttachment`).
  No NAT/bridged device and no second NIC is added. The only entitlement is
  `com.apple.security.virtualization`. The gvproxy patch drops UDP/ICMP and forces all TCP
  through the SOCKS allowlist.
- **Why:** Physically remove any path for the guest to bypass the proxy.
- **Enforced by:** the entitlement set (does **not** request `com.apple.vm.networking` = no
  bridged networking) is checked by `tests/30_macos_vm.sh` (✅). The **gvproxy UDP/ICMP drop is now
  checked live on every `up --macos`** by `verify_macos_egress_locked`'s `dig @1.1.1.1` and `ping`
  probes — an answer or a reply is a leak and tears the VM down — with
  `tests/36_macos_egress_selftest.sh` pinning that verdict offline and
  `tests/38_macos_guest_clock.sh` pinning that the gvproxy patch still registers the UDP forwarder
  only in the absence of `--deny-direct`. The **live NIC count** still needs a real VM host and
  stays ⚠ review-only; nothing asserts `config.networkDevices = [network]`.

### I10. Do not expose credentials on argv  ⚠ review-only
- **Rule:** On macOS the token is written to `~/.augur-env` (chmod 600) via SSH stdin,
  never placed on a command line.
- **Why:** Prevent a co-resident process from reading credentials via `ps` / `/proc`.
- **Note:** The `container run -e` argv exposure on the container path is a **known residual
  risk** (M1, accepted under the single-user-host premise). It resurfaces if moved to a shared host.
- **Enforced by:** review only (M1) for now.

---

> Of the 10, I1–I8 are enforced by tests/self-tests; I9 is partial (entitlement only);
> I10 is review-only. The remaining review-only surface is I10 (credentials not on argv:
> macOS goes through a file, but the container-run argv is an accepted residual, M1) and the
> hardware-dependent part of I9 (the live NIC count — the gvproxy UDP/ICMP drop is now probed
> live on every `up --macos`). Note that "enforced by tests" does not extend to augur's own
> argv for I5 and I8: see their notes. For background on each item, see the newest
> [review snapshot](./README.md).
