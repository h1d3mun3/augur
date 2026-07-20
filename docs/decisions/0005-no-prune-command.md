# ADR-0005 — augur does not ship a `prune`/cleanup command

- **Status:** Accepted.
- **Date:** 2026-07-20.
- **Applies to:** Apple Container mode and macOS VM mode.

## Decision

**augur does not maintain a bespoke command for reclaiming disk space in either backend.**
Where cleanup is a byproduct of normal, high-frequency operation (an image rebuild orphaning
its previous generation), augur handles it automatically, inline, with no new command surface.
Where cleanup is a rare, deliberate, on-demand action (a stray stopped container, the shared
BuildKit builder's cache, an orphaned macOS VM clone), augur documents the underlying tool's
own command directly (`container prune`, `container image prune --all`, `container builder
delete`, `augur-vm delete`) instead of wrapping it.

## Context

Investigating a user-reported ~86GB of reclaimed disk space (`container prune` +
`container image prune` + `container image prune --all`) traced the bulk of it to `augur
update`/`augur install-cert`: both rebuild the image and retag it onto the same name
(`update` also forces `--no-cache`), which orphans the previous generation's layers as
dangling — nothing cleaned that up, so it silently accumulated on every rebuild.

The first fix added two things:
1. Self-pruning (`container image prune`) inside `cmd_update`/`cmd_install_cert`, right after
   a successful rebuild — this is the actual root-cause fix and is **kept**.
2. A new `augur prune` command (+ an opt-in `--builder` flag, gated behind a TTY confirmation,
   to also delete the shared BuildKit builder and its separate build-cache directory) as a
   general on-demand escape hatch — this is what this ADR **reverses**.

Revisiting it, (2) doesn't earn its keep:
- The one scenario it existed to cover at scale — dangling layers from every `update` — is
  already prevented by (1). What's left (a stray stopped container from a crash, the one-time
  pre-fix backlog, the builder's own cache) is rare enough that most users will never run it.
- It duplicates command surface Apple Container's own CLI already provides one-for-one:
  `container prune`, `container image prune --all`, `container builder delete`. There's
  nothing for augur to add beyond forwarding the call.
- The `--builder` path needed its own confirmation flow (mirroring `confirm_cert_install`)
  because deleting the builder is machine-wide and can abort another project's in-flight
  build — real complexity (a help entry, an OPTIONS entry, a NOTES paragraph, a test file,
  an env-var escape hatch) purely to gate a command expected to be used rarely.
- It's asymmetric with macOS VM mode, which already declined the equivalent move.
  [`0004-no-special-worktree-support.md`](./0004-no-special-worktree-support.md) (§9,
  "What actually shipped") documents that a project VM clone orphaned by a directory rename
  is left in place rather than auto-cleaned — visible via `augur list --macos`, removable via
  `augur-vm delete <name>` directly, no augur-side bulk-removal tool. The same is true, and
  was undocumented until this ADR, of the per-clone `~/.augur/claude-projects/<vm>/` history
  directory: `cmd_destroy_macos` never removes it.

## Rationale

**Automate what's in the hot path; document what's a manual escape hatch.** `update`/
`install-cert` self-pruning is free to keep: it runs inside a command the user is already
invoking, adds one line, and prevents the exact accumulation pattern that prompted this
investigation. A `prune` command invoked rarely, wrapping subcommands that already exist
verbatim on the underlying CLI, carries help text / tests / confirmation-gating maintenance
cost disproportionate to how often it fires.

**A wrapper only earns its cost by adding something the underlying tool doesn't have** —
scoping, safety, or a materially better UX. `augur prune` added none of those: it called
`container prune`/`container image prune` unmodified, and `--builder` called `container
builder delete` unmodified behind a confirmation prompt a user could just as easily reason
through themselves before typing the real command. Forwarding calls 1:1 is not a
justification for a second command name to document, test, and keep working.

**Consistent operator model across both backends:** point the user at the underlying tool's
own vocabulary (`container prune`, `augur-vm delete`) rather than inventing augur's own for a
rare operation. This mirrors [ADR-0001](./0001-sudo-free.md)'s framing — is *this* the part of
augur's job that's worth owning? Sandboxing and lifecycle (`up`/`down`/`build`) are; ad hoc
disk reclamation, on either backend, is not.

## Consequences

- `cmd_update`/`cmd_install_cert` keep self-pruning the image (`container image prune`) right
  after a rebuild — no user action needed for the common case.
- Manual container-mode cleanup is documented in the README's "Disk cleanup" subsection
  (Container mode): `container prune`, `container image prune --all`, `container builder
  stop`/`delete`, run directly.
- Manual macOS-mode cleanup is documented in the README's "Disk cleanup" subsection (macOS VM
  mode): `augur list --macos` to find a stray/orphaned clone, `augur-vm stop`/`delete <name>`
  to remove it directly; the same applies to an abandoned `claude-projects/<vm>/` history
  directory, safe to `rm -rf` once its VM is confirmed gone.
- `augur prune` (and its `--builder` flag, `confirm_builder_delete`, and
  `AUGUR_ACCEPT_BUILDER_DELETE`) were implemented, tested, then removed in the same branch
  this ADR lands on. If the idea resurfaces, revisit this reasoning first rather than
  rebuilding it from scratch.

## Related

- [`0004-no-special-worktree-support.md`](./0004-no-special-worktree-support.md) — the
  precedent for accepting an orphaned-resource cost on the macOS VM side rather than building
  automation for it.
- [`0001-sudo-free.md`](./0001-sudo-free.md) — the "is this augur's job to own" framing this
  decision reuses.
- README, "Disk cleanup" subsections under Container mode and macOS VM mode.
