# augur security invariants (the contract)

This is a **contract** (properties that must always hold), not a description of the
current state. Where a [snapshot](./README.md) **describes** "how it works at a point
in time," this **prescribes** "what must never break." It changes rarely.

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
  (no SNI / upstream unreachable) → deny. If the boot self-test `verify_egress_locked`
  fails, tear the container down.
- **Why:** Prevent a misconfiguration or partial failure from "opening up." When it
  fails, it must fail to the closed side.
- **Enforced by:** `AllowlistTests.testEmptyConfDeniesEverything` / shell `verify_egress_locked()` (`augur`)

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
- **Rule:** Keep "resolvable == connectable." Docker points the resolver at an
  unreachable TEST-NET address (`192.0.2.1`), Apple Container uses `--no-dns`, and the
  macOS VM uses gvproxy's `--dns-allowlist` (NXDOMAIN for non-allowlisted; rejects
  record types other than A/AAAA).
- **Why:** Prevent exfiltration by smuggling data in DNS queries.
- **Enforced by:** the DNS probe in shell `verify_egress_locked()` (`augur`) / macOS relies on the gvproxy integration (🟡 review)

### I6. Hot reload never falls open  🟡 partial
- **Rule:** If a reload of the allowlist is readable (even empty/garbage → deny all)
  it is swapped in atomically. **If it is unreadable, the previous policy is kept.** An
  in-flight request never sees a partial or widened policy.
- **Why:** Prevent egress from accidentally opening on file corruption or a transient read failure.
- **Enforced by:** `SNIAndFilterTests.testHotReloadSwapsPolicy` (the swap is ✅; "keep old policy when unreadable" is ⚠ review-only)

### I7. The guest cannot widen its own allowlist  ⚠ review-only
- **Rule:** The merged allowlist is written host-side at `~/.augur/proxy/<slug>.allowlist`
  (**outside the project tree**). A `./.augur.conf` is merged only after TOFU approval
  and only its sanitized domains (via `conf_line_valid`).
- **Why:** Prevent root-in-guest from rewriting the egress policy mid-session.
- **Enforced by:** review only for now. `write_merged_allowlist` / `check_project_conf_approved` (`augur`). → test candidate.

### I8. Keep the private-IP dial guard always armed  ⚠ review-only
- **Rule:** Never pass `--allow-private` to `augur-proxy` on a production path. Before
  dialing, re-check the resolved `sockaddr` and block private / loopback / link-local
  / metadata destinations.
- **Why:** Prevent SSRF where an allowlisted name resolves to a LAN / host / metadata IP.
- **Enforced by:** review only for now (addendum A6). `Sock`/`isPrivate` (`SocketIO.swift`). → test candidate.

### I9. macOS guest network isolation  ⚠ review-only
- **Rule:** The guest's NIC is a **single** host-owned socket (`VZFileHandleNetworkDeviceAttachment`).
  No NAT/bridged device and no second NIC is added. The only entitlement is
  `com.apple.security.virtualization`. The gvproxy patch drops UDP/ICMP and forces all TCP
  through the SOCKS allowlist.
- **Why:** Physically remove any path for the guest to bypass the proxy.
- **Enforced by:** configuration review only for now. `augur-vm` (NetworkAttachment) / `augur-vm.entitlements` / gvproxy patch.

### I10. Do not expose credentials on argv  ⚠ review-only
- **Rule:** On macOS the token is written to `~/.augur-env` (chmod 600) via SSH stdin,
  never placed on a command line.
- **Why:** Prevent a co-resident process from reading credentials via `ps` / `/proc`.
- **Note:** The `docker run` argv exposure on the Docker path is a **known residual risk**
  (M1, accepted under the single-user-host premise). It resurfaces if moved to a shared host.
- **Enforced by:** review only (M1) for now.

---

> Of the 10, I1–I5 are enforced by tests/self-tests, I6 is partial, and I7–I10 are
> review-only. The 4 review-only items are the ones "not guarded by tests and able to
> rot silently" — the priority candidates for adding tests (a separate task). For
> background on each item, see the newest [review snapshot](./README.md).
