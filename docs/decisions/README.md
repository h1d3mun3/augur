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
| [0005](./0005-no-prune-command.md) | **No `prune`/cleanup command** — reclaiming disk beyond automatic self-prune is documented as raw `container`/`augur-vm` commands instead. |
| [0006](./0006-macos-vm-clone-persistence.md) | **`down --macos` keeps the clone** — macOS VM mode is Xcode-exclusive, so preserving DerivedData/Simulator/SPM-CocoaPods state across restarts outweighs the disposability Container mode's `down` favors. |
| [0007](./0007-macos-build-fixed-credential.md) | **macOS build keeps fixed `admin`/`admin`** — declines L2's randomize suggestion (keychain-desync footgun on the load-bearing auto-login path vs. an effective-Info gain); instead removes the operator-typed SSH prompt via OpenSSH `SSH_ASKPASS`. |
| [0008](./0008-exfiltration-ceiling-accepted.md) | **The egress allowlist's exfiltration ceiling is accepted, not mitigated** — declines TLS MITM/DLP, per-service authorization, and even opt-in least-privilege helpers (`--no-token`, read-only mount); that need belongs outside augur (dedicated security tooling), not inside it. |
| [0009](./0009-release-gate.md) | **The pre-release macOS-VM E2E is a structural gate, and `VERSION` is the source of truth** — enforcement is server-side (branch protection on `release` requires the `e2e/macos-vm` status), execution is local (`make e2e` can't run in CI); tags are the *output* of a gated release, never the input. Linear history is off (merge-commit `main`); admin bypass is accepted. |
| [0010](./0010-container-persistence.md) | **Apple Container mode keeps the container across `down`** — `down` stops (keeps) it, `up` reconciles and reuses it, `destroy` removes it; makes Container mode symmetric with macOS VM mode. Supersedes 0006's Container-mode "full-delete is correct" consequence; safe because reuse recreates on any config drift and the boot self-test gates every `up`. |
| [0011](./0011-workspace-trust-seed.md) | **augur pre-trusts the mounted workspace** — seeds `hasTrustDialogAccepted` for the workspace cwd in the guest's *own* `~/.claude.json` (container: `seed_workspace_trust` on create; macOS: the static `up` stub) so `/agents` surfaces user-level subagents immediately and survives `destroy && up`. The sandbox is the trust boundary, so the in-guest dialog is redundant; the host's real `~/.claude.json` is still never read. Forced choice — the image is shared (can't bake the path) and `.claude.json`'s atomic-rename writes break single-file bind mounts. |

> Numbering: 0001 is the foundational principle (recorded latest but conceptually first);
> 0002–0011 follow their original decision dates.
