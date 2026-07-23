# ADR-0011 — augur pre-trusts the mounted workspace in the guest's Claude config

- **Status:** Accepted.
- **Date:** 2026-07-23.
- **Applies to:** Both modes (Apple Container + macOS VM).

## Decision

**augur marks the mounted workspace as folder-trusted in the *guest's own* `~/.claude.json`**
(`projects["<cwd>"].hasTrustDialogAccepted = true`) so Claude Code treats the sandbox workspace as
trusted from the very first `up` — no in-sandbox folder-trust prompt, and user-level subagents
(`~/.claude/agents`) surface via `/agents` immediately.

- **Container mode:** a new `seed_workspace_trust` runs on the **create path only** of `cmd_up`
  (right after `write_container_fingerprint`), doing a `container exec` that jq-merges the one key
  into `/home/dev/.claude.json`. It re-runs on every container *create*, so trust is present again
  after `augur destroy && augur up`. A reused (`down`→`up`) container already carries the flag in
  its persisted writable layer, so the fast reuse path skips it.
- **macOS VM mode:** the static `.claude.json` stub that `cmd_up_macos` already scp's on every
  `up` now includes the trust keys. Because the workspace is reached through a symlink
  (`~/<share>` → `/Volumes/My Shared Files/<share>`) and Claude Code keys trust on the *resolved*
  cwd, it seeds **both** paths; a path Claude doesn't use is a harmless no-op.

The seed is **synthetic and per-container** — augur still **never reads or mounts the host's real
`~/.claude.json`** (which enumerates every host repo and can hold third-party MCP keys). This
change does not touch that constraint (see the Dockerfile / `cmd_up_macos` seed comments and
`docs/host-env-exposure-review.md`).

## Context

`~/.claude.json` holds Claude Code's per-workspace folder-trust decision. In Container mode it is
only the generic image seed (`Dockerfile`), **not** a bind mount, so it lives in the container's
writable layer: `augur down` (stop) keeps it, but `augur destroy` drops the layer and the next
`up` reverts to the trust-less seed. Observed symptom: after `destroy` + `up`, `/agents` shows an
empty list until the operator runs `claude`, accepts the trust dialog (which rewrites
`hasTrustDialogAccepted`), and re-opens `/agents`. The subagent **definitions were never lost** —
they persist on the `claude-agents` host mount (ADR/PR #113/#115) — but Claude Code does not
surface them for an untrusted folder. macOS mode has the same latent gap, and worse: the VM clone
is re-seeded static on every `up`, so a trust flag there never survives a `destroy`/re-clone.

Why the seed is the *only* viable fix (verified against Claude Code behavior, 2026-07):

1. **Can't bake the path into the image.** `IMAGE_NAME=augur:swift-<tag>` is **shared by every
   project** on that Swift tag (only the *container name* is per-project). Folder-trust is
   per-workspace, so a single baked value can't encode it — it must be applied per container.
2. **Can't bind-mount `~/.claude.json`.** Claude Code writes it via atomic write-to-temp +
   `os.replace` (rename), which replaces the file's inode; a single-file bind mount then points at
   a stale inode and silently stops tracking guest writes (a known Docker/Apple-Container class of
   bug). Directory mounts are fine — which is exactly why `projects/` and `agents/` are mounted as
   dirs and `.claude.json` is not.
3. **`CLAUDE_CONFIG_DIR` is not a supported relocation** (and would move the whole `~/.claude`
   tree, colliding with the existing per-subdir mounts).
4. **There is no env var / settings key to pre-trust or disable the dialog.** Seeding
   `hasTrustDialogAccepted:true` for the path is the single documented mechanism.

## Security

Folder trust gates project-scoped `.claude/settings.json` `allow` rules (a repo pre-approving tool
permissions). Pre-trusting therefore lets a repo's own settings apply inside the guest without the
one-time prompt. That is acceptable **because the augur sandbox is itself the trust boundary**: the
agent already runs egress-filtered, with no host access beyond the bind-mounted workspace and
env-injected credentials, `NET_ADMIN` dropped, DNS failing closed. The trust dialog is Claude
Code's mitigation for the *un-sandboxed* case; augur provides a stronger, structural one, so the
operator's decision to run `augur` on this repo already *is* the trust decision. The blast radius
of auto-applied permissions is bounded by the sandbox, and none of the egress invariants
(`INVARIANTS.md` I1–I10) are affected. This is a security-quality decision the implementer owns
(per `INVARIANTS.md`'s operating rules); no numbered invariant changes.

## Consequences

- No repeated in-sandbox folder-trust prompt; `/agents` works immediately after `up`, including
  after `destroy && up`. Idempotent — the jq merge sets exactly one key and preserves any config
  the guest has since accumulated (e.g. prompt input history).
- **Pre-existing containers** created before this change get trust on their next *create*; a
  container reused across the upgrade keeps the old writable layer, so a one-time
  `augur destroy && augur up` re-seeds it (consistent with how other image/config changes are
  picked up).
- **Best-effort:** `seed_workspace_trust` never aborts `up` (runs under `set -e`); on any failure
  it warns and the operator simply sees the trust prompt once (pre-change behavior).
- **macOS caveat:** the macOS seed path is verified only by construction on this Linux checkout
  (the VM host is Apple-Silicon-only). Both plausible trust keys are seeded to be robust to the
  symlink resolution; worst case is a harmless extra key.

## Alternatives considered

- **Persist the guest's `~/.claude.json` per project** (like `projects/`/`agents/`) so the
  operator's *own* trust decision survives `destroy`. Rejected: the only per-file mechanism is a
  single-file bind mount, which the atomic-rename write pattern breaks (context §2). A whole-config
  directory relocation via `CLAUDE_CONFIG_DIR` is unsupported (§3).
- **Leave as-is** and document the re-trust step. Rejected: it reads as data loss (the agents look
  gone), and the friction recurs on every `destroy`.
