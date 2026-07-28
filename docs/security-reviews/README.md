# Security reviews

A ledger of augur security reviews kept as **dated snapshots**. Each file records
"the result of a review at a point in time" — it is not a living spec kept
continuously up to date.

## Operating rules

- **Each snapshot is immutable.** Once committed it is never edited (mistakes or
  stale statements are superseded by a *new* snapshot, not patched in place). That is
  what keeps each file from drifting.
- File names are `YYYY-MM-DD-<scope>.md`. **The directory listing is the history.**
- A review is **not a per-PR obligation.** Run one pass at a natural boundary
  (before a release, or when the egress core — `augur` / `augur-proxy/` / `gvproxy/`
  / `augur.conf` — has changed enough) and **add a new file**.
- **To learn the current state, read the newest snapshot.** The newest snapshot is
  responsible for carrying forward any still-valid "do not re-investigate (checked &
  refuted) / accepted residual risks." That carry-forward is part of the review work,
  not the implementer's job.
- **This index is a TOC only.** It holds no findings (so the index itself can't rot).

> The person landing a security fix is responsible for "the defense actually works,"
> not for keeping a prose description of the posture current. The former (the
> invariants — the contract) and the latter (these snapshots) have different owners
> and cadences, so we keep them separate. For the invariants, see
> [`INVARIANTS.md`](./INVARIANTS.md).

## Snapshots

Newest on top.

| Date | Scope | File |
|---|---|---|
| 2026-07-28 | Current-state review focused on egress control (re-baseline — the #124/#135 virtiofs-staleness stack, PR #152: a host-computed `find -newer` set invalidated in the guest via `msync(MS_INVALIDATE)`, at four attach points plus a 5 s host-side loop (ADR-0016); `7c5120a` strengthens I1's macOS half with a transport pre-check, closing a path where `ssh_macos`'s `exit 1` jumped over the fail-closed teardown; the `gh-config` share is removed (#144). **Not a contract change** — `INVARIANTS.md` is byte-untouched and the series asserts no invariant on purpose. Also corrects the gvproxy freshness grade (`NOISE` since 2026-07-22, not `CURRENT`) and five statements in 2026-07-26 and 2026-07-23, both immutable) | [2026-07-28-egress.md](./2026-07-28-egress.md) |
| 2026-07-26 | Current-state review focused on egress control (re-baseline — the nine-PR security series #125–#133; **contract change**: I7's rule text now scopes every per-project egress host-state file to the full workspace path (#127); I1's boot tripwire reaches the macOS engine (#131) and every `up` including the already-running reconcile (#128); a workspace containing augur's own control plane is refused (#126); I5 / I9 `Enforced by` follow-ups; macOS lifecycle fixes #129/#130/#132/#133. Also corrects three false statements in 2026-07-23, which is immutable) | [2026-07-26-egress.md](./2026-07-26-egress.md) |
| 2026-07-23 | Current-state review focused on egress control (re-baseline — Apple Container persist-and-reconcile (#114) with the boot self-test now gating the reuse path (PATH-pinned probes); idle timeout on established tunnels (#101, closes the prior residual); I7 TOCTOU closed (honor the approved snapshot); I8 SSRF v6 guard extended (6to4/Teredo/site-local); per-project `~/.claude/agents` mount (#115); structural macOS-VM E2E release gate. No invariant text changed) | [2026-07-23-egress.md](./2026-07-23-egress.md) |
| 2026-07-20 | Current-state review focused on egress control (re-baseline — SOCKS deny-log injection fix (#37), connection-cap slot-leak fix (#36→#101), exfiltration ceiling closed by ADR-0008, `install-cert` confirmed inert to the egress boundary) | [2026-07-20-egress.md](./2026-07-20-egress.md) |
| 2026-07-10 | Current-state review focused on egress control (re-baseline — Docker removed, two engines; elevates the RW-workspace `.git/hooks` host-reach risk) | [2026-07-10-egress.md](./2026-07-10-egress.md) |
| 2026-07-08 | Current-state review focused on egress control (re-baseline — covers base-image custom provisioning, PR #78) | [2026-07-08-egress.md](./2026-07-08-egress.md) |
| 2026-07-02 | Current-state review focused on egress control (re-baseline) | [2026-07-02-egress.md](./2026-07-02-egress.md) |
| 2026-06-30 | Current-state review focused on egress control | [2026-06-30-egress.md](./2026-06-30-egress.md) |
| 2026-06-28 | Full review of isolation / egress / credentials + Guest→Host (Axis B) audit | [2026-06-28-full-review.md](./2026-06-28-full-review.md) |
