# ADR-0012 — augur no longer pre-trusts the mounted workspace

- **Status:** Accepted. Supersedes [`0011`](./0011-workspace-trust-seed.md) in full.
- **Date:** 2026-07-25.
- **Applies to:** Both modes (Apple Container + macOS VM).

## Decision

**augur no longer seeds `hasTrustDialogAccepted` for the mounted workspace.** Container mode's
`seed_workspace_trust` (called on `cmd_up`'s create path) is removed outright; macOS mode's
`cmd_up_macos` no longer writes any per-workspace trust key into the guest's `~/.claude.json`.
Claude Code's own folder-trust dialog now runs inside the guest exactly as it would on any other
machine — the guest is not special-cased to skip it.

The onboarding-only stub both modes seed (`{"hasCompletedOnboarding":true,"installMethod":"native"}`)
is unaffected: it carries no permission, hook, or trust semantics — it only skips the first-run
tutorial screen — and none of ADR-0011's reasoning against it applied in the first place.

## Context

ADR-0011 pre-trusted the workspace so `/agents` would surface user-level subagents immediately and
survive `destroy && up`, on the theory that augur's sandbox is itself the trust boundary the
folder-trust dialog exists to substitute for. Revisiting that trade after living with it:

**1. augur's actual usage is a casual, personal single-operator tool, not a hardened multi-tenant
platform.** ADR-0011's "the sandbox is the trust boundary" argument is sound as far as network
egress and filesystem isolation go, but it says nothing about the two concrete surfaces
folder-trust actually gates:

- **`permissions.allow`** in a repo's `.claude/settings.json` — a hostile or compromised repo's
  pre-approved tool permissions apply with zero operator review.
- **`hooks`** in the same file — unlike a subagent (which only runs when explicitly invoked), a
  hook fires **unconditionally** on tool-use/session events. This is the sharper edge of the two:
  pre-trust means a repo-shipped hook executes automatically, with no human ever having looked at
  it, the moment the sandbox boots.

Both are still bounded by the sandbox (no host network beyond the egress allowlist, no host
filesystem beyond the workspace mount, no `NET_ADMIN`), but the workspace mount is **RW** onto the
operator's real checkout — so a hook or auto-approved tool call that rewrites
`.claude/settings.local.json` or `.claude/commands/*.md` plants a file the operator's own,
un-sandboxed, host-side Claude Code will later execute. That escape hatch is accepted upstream
([`0008`](./0008-exfiltration-ceiling-accepted.md)), not eliminated by the sandbox argument.

**2. The cost of *not* seeding is recoverable; the cost of seeding is not, in kind.** ADR-0011's
motivating symptom — `/agents` looks empty after `destroy && up` until the operator accepts one
trust prompt inside `claude` — is a one-time, self-healing UX papercut. The subagent definitions
were never lost (they live on the host-mounted `claude-agents` dir regardless of trust state); the
dialog is a single keypress, and the guest is never left non-functional. Weighed against an
open-ended, silently-widening execution surface (see point 3), this is not a symmetric trade: a
recoverable inconvenience does not justify absorbing an unreviewed code-execution risk.

**3. The exposure is open-ended, not fixed.** ADR-0011 pinned a decision to what folder-trust
happened to gate on 2026-07-23. Nothing re-validates that as Claude Code evolves — any future
release that gates a new capability behind folder trust is silently inherited by every augur guest
the next time the operator updates the pinned binary (`augur update`/`build`), with no augur-side
review of what just got auto-approved. A one-time ADR cannot keep pace with an externally-evolving
gate it does not control.

**4. The dialog's marginal value against #1 is arguably close to zero, but that cuts against
pre-trusting, not for it.** In practice an operator accepting a folder-trust prompt is not auditing
`hooks` before clicking through. That weakens the case that *removing* pre-trust meaningfully
protects against a hostile repo's hooks — but it does not weaken the case *against* pre-trusting,
which unconditionally waives even that theoretical checkpoint. If the dialog is close to a no-op
protection either way, augur gains nothing by suppressing it and only forfeits the (small,
non-zero) chance an operator notices something odd.

None of this required Container mode's implementation to change beyond deleting
`seed_workspace_trust` — the writable-layer trust key it wrote is simply never written, and
Claude Code's own trust-less default (the Dockerfile stub, unchanged) is now the permanent state,
not a fallback pending a seed.

## The macOS bug this also fixes

Independent of the trust question, `cmd_up_macos` had a live bug exposed by
[`0006`](./0006-macos-vm-clone-persistence.md)/[`0010`](./0010-container-persistence.md)'s
persistence model: it scp'd the entire `.claude.json` stub **unconditionally on every `up`**,
including a plain restart of an already-provisioned, persisted VM clone. That was correct only
while a project VM was a throwaway clone re-made on each `up` (pre-0006); once `down --macos` began
keeping the clone, the same unconditional overwrite started silently destroying whatever Claude
Code had accumulated in that file since the last boot — prompt input history, guest-side MCP server
entries, caches, and (under ADR-0011) any trust the operator had granted since.

Dropping the trust key removes the only reason the stub needed to be path-specific (it encoded the
workspace's absolute path), which makes the fix immediate: the stub is now a fixed, generic
constant that `cmd_up_macos` writes **only when this `up` just cloned the VM** — i.e. gated on the
same `if ! macos_vm_exists "$project_vm"` branch that decides whether to `clone` in the first
place, tracked in a `_fresh_clone` flag — and never touches the file on the reuse path. A VM
booting for the first time (fresh clone, or a `destroy --macos` re-clone) gets the stub
unconditionally; every subsequent `up` on the same persisted clone is a no-op for this file, and
whatever the guest or the operator has since written to it survives restarts.

An earlier version of this fix keyed the write on the file's *absence* (`ssh_macos ... test -f`)
rather than on having just cloned. That is a weaker check masquerading as the same thing: it
assumes the base VM's disk is always clean, so "no file yet" and "freshly cloned" happen to
coincide. Live testing broke that assumption (see below) and reproduced the exact "stub missing"
symptom through a different path — the existence check found *a* file on the fresh clone and
correctly declined to overwrite it, except that file wasn't ours. Keying on `_fresh_clone` instead
removes the dependency on base-VM hygiene entirely: a brand-new project VM is guaranteed the
correct stub regardless of what the inherited disk happens to contain, while a reused VM is still
never touched.

### A second bug this surfaced: the base VM itself can leak a real account

Live testing on macOS turned up the problem that motivated the fix above: the base VM in use had a
real, authenticated `~/.claude.json` (an actual `userID`/`machineID`, `firstStartTime`, no
`hasCompletedOnboarding` key at all) baked into its disk, most likely from a human running `claude`
interactively inside it at some point (Setup Assistant verification, manual debugging) — neither
`cmd_build_macos` nor `cmd_update_macos` ever invokes `claude` interactively themselves. Every
project clone made from that base was silently inheriting a stranger's account instead of a clean
slate.

The `_fresh_clone` fix above makes any new project clone immune to this regardless of the base
VM's state, but the base VM carrying a real account on disk is a problem in its own right (see
*Security*), so both code paths that legitimately touch it as part of normal operation also scrub
`~/.claude.json` unconditionally before finishing, as defense in depth:

- `cmd_build_macos`, right after `run_base_provisioning` and before the base VM is saved.
- `cmd_update_macos`, right after `run_base_provisioning` and before the VM is stopped.

Because the leak vector is "a human touched the long-lived, mutable base VM by hand," it isn't
bounded to right after `build` — it can happen again at any point in the base VM's life. Fixing
only `build` would leave that base-VM-level invariant to decay until the next full rebuild (rare —
base VMs are rebuilt far less often than they're updated); putting the same scrub in `update` makes
it self-healing on every routine maintenance run instead.

## Security

- **Net change: strictly narrower.** Folder-trust in the guest now behaves exactly as it does on
  any other machine running Claude Code — no automatic waiver of the one-time review step for
  repo-supplied `permissions.allow` or `hooks`.
- **No egress invariant changes.** `INVARIANTS.md` I1–I10 are untouched: this is entirely about the
  agent-config layer, not the network/filesystem boundary.
- **The RW-workspace write-back exposure ([`0008`](./0008-exfiltration-ceiling-accepted.md)) is
  unchanged in kind but now requires an operator to click through Claude Code's own trust prompt
  first** — a smaller, not larger, attack surface than before.
- **The macOS fix has no security-negative effect**: it only stops overwriting guest state the
  operator or Claude Code itself produced; it does not change what is or isn't trusted.
- **The base-VM scrub is a privacy fix, not just a test-hygiene one.** A leaked account
  (`userID`/`machineID`) baked into the base VM was previously inherited by every project clone —
  every guest, and by extension the agent running in it, silently shared one human's real Claude
  account identity. Scrubbing it in `build`/`update` closes that regardless of how it got there.

## Consequences

- A brand-new project's first `augur up`, and every `up` immediately after `augur destroy`, now
  shows Claude Code's normal one-time folder-trust prompt before `/agents` and repo-scoped
  permissions become active. This is expected, matches non-augur Claude Code behavior, and is a
  single keypress.
- `agent_state_guest_config_file` and `seed_workspace_trust` are removed from the Container-mode
  AGENT_SEAM; there is no remaining per-container write to the guest's `~/.claude.json`.
- macOS mode's `.claude.json` seed becomes a true one-time write (gated on absence), fixing the
  clobber bug described above as a side effect of removing the path-specific trust payload.
- `cmd_build_macos` and `cmd_update_macos` both now scrub `~/.claude.json` from the base VM before
  finishing, so a base VM the operator has ever touched by hand cannot leak a real account into
  future project clones — self-healing on the next `update`, not just at the next full `build`.
- ADR-0011 remains on record for its rationale and is superseded, not deleted, per this
  repository's ADR convention (see [`0010`](./0010-container-persistence.md) superseding
  [`0006`](./0006-macos-vm-clone-persistence.md) for precedent).

## Alternatives considered

- **Keep pre-trusting Container mode, drop only the macOS per-up overwrite.** Rejected: the macOS
  fix does not require dropping trust (a gated write keyed on a trust marker, as opposed to file
  existence, would have worked too), but leaving Container mode pre-trusted would keep the
  hooks/permissions exposure this ADR is written to close, for no added benefit once the decision
  is that augur is a casual single-operator tool rather than a hardened platform.
- **Keep the seed but add a repo-settings scanner that flags `hooks`/`permissions.allow` before
  trusting.** Rejected as scope creep: augur has no general-purpose static analysis of a
  workspace's contents anywhere else, and a scanner narrow enough to be honest about what it
  checks would not meaningfully close point 3 (the open-ended future-gate risk) anyway.
