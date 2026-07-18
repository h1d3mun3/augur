# Decisions (ADRs)

Architecture / design **decision records** — "why augur did (or deliberately did *not* do)
something," kept as durable references so a settled choice does not get re-litigated one feature
at a time. A human or an agent that is about to propose "why don't we just…" should be able to
find the standing answer here.

This is distinct from the two neighbours:

- [`../security-reviews/`](../security-reviews/) — dated, **immutable** point-in-time posture
  snapshots (a ledger, superseded by new files, never edited).
- [`../security-reviews/INVARIANTS.md`](../security-reviews/INVARIANTS.md) — the **testable
  contract** (properties that must always hold, enforced by tests).

An ADR here is none of those: it is the standing *rationale* behind a decision.

## Operating rules

- New decisions land in this directory as `NNNN-title.md`.
- A record captures the **decision + why**, and is updated in place when the decision genuinely
  changes (unlike the immutable review snapshots).
- **Redirect stubs:** the earlier records (0002–0004) were moved here from `docs/`. Two of them
  are linked by **immutable dated security snapshots** (which are never edited by rule), so a
  one-line redirect stub is kept at each old `docs/…` path to keep those historical links
  resolving. Live references (the `augur` script, tests, README) were repointed here directly.

## Index

| ADR | Decision |
|---|---|
| [0001](./0001-sudo-free.md) | **augur is sudo-free** — never require root on a production path; document residuals instead of taking privilege to close them. |
| [0002](./0002-per-run-agent-llm-profiles.md) | **Per-run agent/LLM profiles (local Ollama)** — explored, *not* shipped; kept as a design + SSRF-guard lessons record. |
| [0003](./0003-swappable-agent-abstraction.md) | **Swappable-agent ACL seam** — do *not* add a second agent now; insert an anti-corruption seam so Claude Code can be peeled off later. |
| [0004](./0004-no-special-worktree-support.md) | **No special `--worktree` support** — deliberate non-fix; the history-mount trade-off is documented instead. |

> Numbering: 0001 is the foundational principle (recorded latest but conceptually first);
> 0002–0004 follow their original decision dates.
