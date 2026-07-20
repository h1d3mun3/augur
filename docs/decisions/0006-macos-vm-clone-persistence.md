# ADR-0006 — `augur down --macos` keeps the project VM clone, not just for speed

- **Status:** Accepted.
- **Date:** 2026-07-20.
- **Applies to:** macOS VM mode only.

## Decision

**`augur down --macos` stops the project VM but deliberately keeps its clone** (`cmd_down_macos`
calls `vm stop`, never `vm delete`) rather than mirroring Container mode's `down`, which fully
removes the container. This asymmetry is intentional: macOS VM mode is *de facto* an
Xcode-exclusive mode, and the state that survives inside the kept clone — DerivedData, Simulator
runtime state, resolved SPM/CocoaPods dependencies — is expensive to rebuild from scratch, unlike
Container mode's generic, cheaply-recreated container.

## Context

The kept-clone behavior was implemented purely for a performance/disk-cost reason: the project
VM is an APFS `clonefile(2)` Copy-on-Write clone of `augur-macos-base`, so keeping it costs ~0
disk, and skipping re-clone on the next `up` makes restart fast (`augur:2183`, README.md's
`augur down --macos` line, commit `8dbaf25`'s original message). Nowhere in the repo was this
tied to a development-workflow reason — a repo-wide search for DerivedData/CocoaPods/SPM/
Simulator alongside the persistence discussion in
[`0004-no-special-worktree-support.md`](./0004-no-special-worktree-support.md) §7 turned up
nothing; that section discusses the VM disk surviving `down` only as a (later-corrected-to-moot)
factor in whether Claude Code's `--worktree` conversation history survives, not as its own topic.

Prompted by comparing this against Container mode's `down` (`cmd_down`, `augur:1370`: fully
removes the container via `engine_rm_force`, cheap to recreate from the shared, per-Swift-tag
`augur:swift-<tag>` image) the question was: should macOS VM mode's `down` be made symmetric and
delete the clone too? Reasoning it through: no — because
macOS VM mode exists almost entirely to run Xcode/Simulator workloads, and Xcode toolchains
recurringly pay a real, non-trivial cost the first time after a clean state (indexing, dependency
resolution, Simulator boot) that Container mode's arbitrary-toolchain containers don't have an
equivalent of. Discarding that state on every `down` would make the "fast restart" framing true
in the CoW-clone-cost sense while reintroducing exactly the slow-first-run cost the clone-reuse
was otherwise avoiding.

## Rationale

**The kept clone is worth its ~0 marginal disk cost because of what backend is exclusive to.**
Container mode's `down` fully discarding state is correct for *that* backend because it targets
arbitrary toolchains where a container's writable layer rarely holds anything expensive to
reproduce, and anything that does matter is bind-mounted explicitly. macOS VM mode has no
equivalent generic-toolchain framing — it exists to run Xcode — so the calculus that justifies
Container mode's disposability doesn't transfer.

**The known trade-off remains accepted, not newly introduced.** Keeping the clone across `down`
carries the same cross-leaf, no-isolation-within-one-VM exposure §7 of ADR-0004 already
documented and accepted independent of this question. This ADR does not change that trade-off;
it only records the *reason* the underlying clone-retention exists, so a future "why don't we
just delete it on `down` like Container mode" doesn't have to re-derive this from scratch.

## Consequences

- `cmd_down_macos` is unchanged: `vm stop`, clone kept, `augur destroy --macos` remains the
  explicit full-removal command.
- No action needed on Container mode's `down` either — its full-delete behavior is correct for
  its own, different, reason (cheap recreate, no toolchain-state cost worth preserving).
- If macOS VM mode is ever extended beyond Xcode-exclusive use, this rationale should be
  revisited — the calculus assumes the DerivedData/Simulator/SPM-CocoaPods cost is the norm, not
  an edge case.

## Related

- [`0004-no-special-worktree-support.md`](./0004-no-special-worktree-support.md) §7 — where the
  VM-disk-survives-`down` fact was first observed, in service of a different question (Claude
  history persistence), without this rationale attached.
- [`0005-no-prune-command.md`](./0005-no-prune-command.md) — the companion decision not to
  auto-clean an *orphaned* clone; this ADR is about why a live project's clone is kept at all.
