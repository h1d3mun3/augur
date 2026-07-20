# ADR-0008 — The egress allowlist's exfiltration ceiling is accepted, not mitigated

- **Status:** Accepted.
- **Date:** 2026-07-20.
- **Applies to:** augur's threat model generally — the egress allowlist's scope (README
  "Egress allowlist § Scope"), and any future proposal to narrow the residual described below.

## Decision

augur will **not** add any exfiltration-hardening feature beyond what the egress allowlist
already provides (reachability control, documented in the README "Scope" note) — **not as a
default, and not as an opt-in.** This closes [issue #24](https://github.com/h1d3mun3/augur/issues/24)
by selecting its option 1 ("document the ceiling and stop"). Concretely, augur declines to
build, by default or opt-in:

- TLS interception / MITM or any other content inspection (DLP).
- Per-service, operation-level authorization (e.g. distinguishing a legitimate `git push` from
  an exfiltrating one).
- Lighter least-privilege helpers floated in #24 as a middle ground — a `--no-token` /
  credential-scoping flag, a read-only-workspace mount option, allowlist-hygiene warnings.

## Context

The egress allowlist controls **reachability** (which domains the guest may connect to), not
**data** (what leaves over an allowed connection) — it never terminates TLS, only peeks the SNI
/ HTTP Host. So a compromised or prompt-injected guest can still exfiltrate through a
destination augur allowed:

- An allowlisted, **writable**, **credentialed** service — the big one: `github.com` is
  allowlisted and `GH_TOKEN` is injected, so a malicious agent can push data to an
  attacker-controlled repo, and the proxy cannot distinguish that from a legitimate push.
- Broad wildcards / shared infra (`*.amazonaws.com`, `*.github.io`, …).
- Data encoded into requests (path/query/header/body) to an allowed, attacker-observable
  endpoint.
- The shared workspace mount itself (not network egress, but a data boundary).

This is documented today as accepted residual #1 in the newest
[security review](../security-reviews/) and in the README's "Scope" callout. Issue #24 was
opened to decide, deliberately, how far augur should go on mitigating it — the three options on
the table were (1) document and stop, (2) add opt-in least-privilege helpers, (3) something in
between.

## Rationale

**Fully closing the ceiling requires a fundamentally heavier class of control than augur is.**
The only way to observe *what* leaves over an allowed connection — not just *where* it goes — is
to terminate and inspect the traffic (TLS MITM) or add per-service operation-level
authorization. Either is a different kind of product: a lightweight, dependency-free, sudo-free
allowlist proxy would become a traffic-inspecting security appliance. That is a large jump in
scope, complexity, and trust surface for the tool to carry.

**Even a full build-out caps out at detection, not prevention — a weak return for the scope
taken on.** MITM/DLP does not stop a determined exfiltration path so much as let you notice it
happened (audit the intercepted traffic after the fact). That is a materially weaker guarantee
than what the existing allowlist already delivers unconditionally (the guest cannot *reach*
anything unlisted at all). Taking on TLS interception's cost and risk to buy "detectable after
the fact" is a bad trade.

**This is a real need, but it belongs outside augur, not inside it.** Organizations that require
exfiltration control at this level already have the tooling for it — DLP, CASB, enterprise
egress proxies/firewalls — designed and hardened specifically for that job, operating as a
separate layer. Duplicating a worse version of that inside augur doesn't serve them better; it
serves them worse while bloating augur for everyone who doesn't need it. If a user needs this,
they should sit augur behind (or alongside) a real security product, not expect augur to become
one.

**This doesn't warrant retiring augur's founding scope.** augur started as *"a lightweight,
personal isolation environment for an AI coding agent"* (enterprise use explicitly out of
scope). #24 raised a fair question — augur has grown to virtualize full macOS (Xcode,
simulators), which raises the value of what a compromised guest might touch — but a richer guest
environment doesn't by itself obligate a richer *data-exfiltration* threat model. The allowlist
already removes the "beacon / bulk-dump to anywhere" risk, which is the risk augur's founding
scope was actually about.

**Even the opt-in middle ground (option 2) isn't worth carrying as a default-shipped feature.**
augur is MIT-licensed. Anyone who genuinely needs a `--no-token` mode or a read-only-workspace
option can add it in a fork or local patch — that's a small, well-scoped change against the
existing seams (`agent_auth_specs`, the mount construction in `cmd_up`/`cmd_up_macos`). Shipping
it as a maintained, tested, documented default-available flag is a different, ongoing commitment
augur doesn't need to take on to serve its actual audience.

## Consequences

- Issue #24 is closed by this decision, not implemented.
- The README's existing "Scope" callout (Egress allowlist § "Scope") already states this
  boundary in user-facing terms; it now points to this ADR for the reasoning, so a future reader
  (or a future "why don't we just add TLS inspection" proposal) finds the settled answer instead
  of re-opening the debate — the same pattern [ADR-0001](./0001-sudo-free.md) established for
  the sudo question.
- Accepted residual #1 in the security-review ledger (in-policy exfil via an allowlisted
  credentialed host) is unchanged and stays accepted, not scheduled for mitigation.
- A future contributor proposing TLS MITM, DLP, per-service authorization, or an opt-in
  exfiltration-hardening flag should treat this as a closed question and bring a *new* ADR that
  explicitly argues why the calculus above has changed, rather than re-implementing directly.

## Related

- [Issue #24](https://github.com/h1d3mun3/augur/issues/24) — the discussion this ADR resolves.
- README, "Egress allowlist § Scope".
- [ADR-0001](./0001-sudo-free.md) — same shape of decision: a gap is documented and declined
  rather than closed, because closing it would require a kind of privilege/scope augur has
  chosen not to carry.
- The dated [security reviews](../security-reviews/) — accepted residual #1.
