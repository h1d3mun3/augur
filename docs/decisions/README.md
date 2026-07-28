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
| [0011](./0011-workspace-trust-seed.md) | ~~augur pre-trusts the mounted workspace~~ — **superseded by 0012.** Seeded `hasTrustDialogAccepted` for the workspace cwd in the guest's *own* `~/.claude.json` so `/agents` surfaced user-level subagents immediately and survived `destroy && up`, on the theory that the sandbox is itself the trust boundary. Kept for the historical rationale. |
| [0012](./0012-drop-workspace-trust-seed.md) | **augur no longer pre-trusts the mounted workspace** — reverses 0011 in full: Claude Code's own folder-trust dialog now runs in the guest like anywhere else, closing the silent, unreviewed auto-approval of a repo's `permissions.allow`/`hooks` that pre-trust granted. The lost `/agents`-after-`destroy` convenience was a recoverable one-time prompt, not a real cost. Also fixes a macOS-mode bug the same change exposed: `cmd_up_macos` was overwriting `~/.claude.json` unconditionally on every `up`, clobbering accumulated guest state once VM clones started persisting across `down` (0006/0010); the fix writes the now-generic onboarding stub only when the file is absent. |
| [0013](./0013-claude-config-inheritance.md) | **Claude Code config is classified, not mirrored** — every config surface lands in exactly one of four categories (persisted guest state / repo-provided / opt-in operator profile / augur's managed policy), and the host's real `~/.claude` tree and `~/.claude.json` are never read, copied, or mounted. Adds an opt-in `~/.augur/claude-profile/` (read-only, host-global) so a power user's own commands/skills work inside the sandbox, a bounded prompt-history carry-over across augur-initiated recreates (`destroy` still wipes it), and a one-key managed-settings layer that a repo cannot override. |
| [0014](./0014-workspace-must-not-contain-augur.md) | **The shared workspace must not contain augur's own control plane** — `up`/`claude`/`shell`/`setup-token` refuse a workspace that is `/`, is `$HOME`, is an ancestor of `$HOME`, or is/contains/lives inside `$AUGUR_DIR`, comparing *physical* paths so a symlinked cwd cannot slip through. `cd ~ && augur claude` was unconditional guest→host code execution (the RW share covers `~/.augur`, which holds the binaries `install` puts first on the host's PATH and the allowlist `augur-proxy` hot-reloads) — one tier above the residual §6 item 12 accepts. No env override: unlike `--no-egress`, it would surrender augur's own integrity, and relocating `AUGUR_DIR` is not a workaround. Stops at augur's control plane rather than becoming a dotfile denylist; `down`/`destroy`/`list`/`status` stay ungated so a pre-fix container in `$HOME` is still removable. |
| [0015](./0015-guest-clock-from-host.md) | **The macOS guest's clock is set from the host, not by opening NTP** — a cloned guest inherits a *constant* wall-clock offset from the base VM's saved state (measured -5733 s; `kern.monotoniclock_offset_usecs` byte-identical across boots and across 7h36m of uptime, `kern.sleeptime`=0, so not drift), which makes a token minted seconds ago look `nbf`-in-the-future to the agent. NTP cannot be the fix: it is UDP/123, `augur.conf` is a SOCKS5/TCP name list, `--deny-direct` registers no UDP forwarder at all, and opening one regresses I9 — which `verify_macos_egress_locked` now asserts. So `sync_macos_guest_clock` pushes the host's time over `ssh_macos` (`sudo -S`, the mechanism the managed-policy install established) from four sites, before the credential push, idempotently, best-effort, with a read-back. Declines the guest's own `kern.monotonicclock` (unspecified as host wall clock, and no second opinion) and declines touching the guest's network-time setting. |
| [0016](./0016-shared-file-cache-refresh.md) | **The guest's view of shared files is refreshed with `msync(MS_INVALIDATE)`, not waited out** — a macOS guest's virtiofs client serves stale file *data* from **every** share, `:ro` and rw alike, with no timeout: measured 904.9 s stale with zero natural refreshes, then every arm fresh 10.3 s after a forced vnode reclaim, while `stat` reported the new size and mtime the whole time. So the host computes the changed set (`find -newer`, 0.31 s) and the guest invalidates exactly those names (0.23 ms each); it retries per file because a guest whose cached size is stale maps too few bytes and silently returns *truncated new content*. Runs before the `ensure_macos_*` wiring, because that wiring `cp`s out of the profile share. Corrects ADR-0013. Declines forced vnode reclaim (cannot be aimed, ~2.8 cache turnovers, no confirmation) and declines replacing the shares with a syncer (its failure mode is silent-stale-forever, this one's is today's behaviour). Asserts no invariant, so it stays removable — its self-test carries a second control that detects when the platform no longer needs it, and §5 is the removal procedure itself: the signal, a staged rollback, the full inventory of what to delete, and the two changes that must NOT be reverted with it. |

> Numbering: 0001 is the foundational principle (recorded latest but conceptually first);
> 0002–0016 follow their original decision dates.
