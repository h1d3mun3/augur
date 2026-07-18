# ADR-0001 — augur is sudo-free

- **Status:** Accepted · foundational (this is the design spine, recorded here so it stops
  being re-litigated one feature at a time).
- **Date:** 2026-07-17 (the principle predates this record; it has held since the first design).
- **Applies to:** all of augur — the `augur` CLI, `augur-proxy`, the `gvproxy` fork, `augur-vm`.

## Decision

**augur never requires `sudo` / root on any production path.** Every mechanism it relies on —
host-only container networking, the egress proxy, the VM's single NIC, credential handling —
runs as the ordinary invoking user. When closing a gap would require elevated privilege, augur
**declines and documents the residual** instead of taking the privilege.

## Context

augur's whole job is to run an **untrusted** coding agent (Claude Code, assume it can be
prompt-injected or fed a malicious dependency) and contain it. So augur is itself a **security
tool**. Security tools attract a recurring temptation: "just use sudo and you could close this
hole." Concrete instances that have come up:

- Use host `pf` to stop a container reaching host services bound to `0.0.0.0` (the host-only
  network residual).
- Use `sudo lsof` to attribute every listening process when surfacing that residual.
- Reach for privileged/bridged networking or a root daemon for "stronger" isolation.

Each looks like a convenience. This ADR records why augur says no.

## Rationale

**Privilege is not capability — it is blast radius.** Adding sudo does not make augur "more able
to protect you." It makes augur's *failures* able to hurt you more. Sudo-free, the worst an
augur bug / compromise / malicious input can do is bounded by *what your user account can do*.
With sudo, that ceiling becomes *anything*.

**A security tool that needs root turns every one of its own bugs into a privilege-escalation
bug.** For an ordinary app, a bug means the app breaks. For a root-privileged security tool, a
bug means the thing you installed *to protect you* hands full control to the very agent it was
containing. The safety boundary becomes the single largest liability. This is the core reason;
the rest follow from it.

**Bounded worst-case is the only basis for honest guarantees.** Because the privilege ceiling is
fixed, [`INVARIANTS.md`](../security-reviews/INVARIANTS.md) and the dated
[security reviews](../security-reviews/) can make *categorical* statements. The moment sudo
enters, every one of those statements needs an asterisk ("...unless the root-privileged part
misbehaves"), and the ability to reason cleanly about the worst case — a security tool's most
valuable property — is gone.

**Privilege is a one-way ratchet.** It looks like a one-time convenience, but it is sticky and
expansive: other features start assuming it, removing it later becomes a breaking change, and
each new use is a new place where a bug equals root compromise. Benefit is front-loaded; cost is
deferred and compounding.

**Lower trust-to-run, smaller supply-chain blast radius.** A tool you can install and invoke
without granting root is one a careful person can actually adopt — and a supply-chain compromise
of augur itself cannot directly root the host.

**The constraint is a forcing function.** Because augur *cannot* reach for root, it found
genuinely better, more contained, more portable architectures than the privileged shortcut
would have been:

- host-only **vmnet** networking instead of `pf` firewall rules;
- the **gvproxy** user-space netstack instead of the privileged bridged-networking entitlement;
- a **user-space allowlist proxy** instead of a kernel firewall.

Sudo would have permitted shortcuts that are *both* lazier *and* less contained.

## The honest boundary (so this is a principle, not a dogma)

Sudo is not always wrong. A real firewall / EDR genuinely needs kernel privilege — but for those
tools the **privilege is the product**, designed rigorously with all their engineering poured
into it. augur's temptations are the opposite: privilege as a **secondary "while we're at it"**
to patch a residual. That kind of tacked-on privilege is exactly the kind that is never
carefully designed, and is where a tool trips over its own feet.

The test: **is the privilege this tool's main function?** If not — avoid it, or accept and
document the residual. augur is never the "privilege is the product" case.

## Consequences

- Some residuals stay **open and documented** rather than enforced. The load-bearing example:
  in Apple Container mode the guest can reach host services bound to `0.0.0.0` over the host-only
  network (raw TCP, not proxy-mediated). Closing it needs host `pf`/sudo, so augur documents it
  and hands the user the sudo-free remedy (bind such services to `127.0.0.1`, or stop them). See
  the "accepted residuals" section of the newest [security review](../security-reviews/).
- A proposed **`augur up` warning** for that residual was prototyped and **measured, then
  declined**: on a real machine the reachable set is dominated by unavoidable, non-actionable
  macOS/system daemons, so any warning is anxiety, not action — and the "fix it properly" version
  would have needed sudo, which this ADR rejects. The measurement POC lives on branch
  `poc/host-exposure-scan`; it intentionally shipped nothing.
- augur consistently selects sudo-free architectures (see the forcing-function list above), even
  when they cost more design effort than the privileged path.

## Related

- [`../security-reviews/INVARIANTS.md`](../security-reviews/INVARIANTS.md) — the testable egress
  contract that this principle keeps auditable.
- The dated [security reviews](../security-reviews/) — where accepted residuals (the price of
  staying sudo-free) are recorded.
