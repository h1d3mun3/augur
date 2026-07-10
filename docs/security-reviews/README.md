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
| 2026-07-10 | Current-state review focused on egress control (re-baseline — Docker removed, two engines; elevates the RW-workspace `.git/hooks` host-reach risk) | [2026-07-10-egress.md](./2026-07-10-egress.md) |
| 2026-07-08 | Current-state review focused on egress control (re-baseline — covers base-image custom provisioning, PR #78) | [2026-07-08-egress.md](./2026-07-08-egress.md) |
| 2026-07-02 | Current-state review focused on egress control (re-baseline) | [2026-07-02-egress.md](./2026-07-02-egress.md) |
| 2026-06-30 | Current-state review focused on egress control | [2026-06-30-egress.md](./2026-06-30-egress.md) |
| 2026-06-28 | Full review of isolation / egress / credentials + Guest→Host (Axis B) audit | [2026-06-28-full-review.md](./2026-06-28-full-review.md) |
