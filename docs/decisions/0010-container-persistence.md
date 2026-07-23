# ADR-0010 — Apple Container mode keeps the container across `down` (reconcile-on-`up`)

- **Status:** Accepted. Supersedes the Container-mode consequence of
  [`0006`](./0006-macos-vm-clone-persistence.md).
- **Date:** 2026-07-23.
- **Applies to:** Apple Container mode only.

## Decision

**`augur down` now STOPS the container and keeps it** (`cmd_down` calls `container stop`, no
longer `container delete --force`); the next **`augur up` reconciles and reuses it** — restarting
the stopped container when the config it was created with is unchanged, and recreating it clean
otherwise. A new **`augur destroy`** verb is the explicit full-removal (container + egress
network), mirroring `augur destroy --macos`. This makes Container mode symmetric with macOS VM
mode, which has always persisted its clone across `down`.

This **reverses** ADR-0006's stated Consequence that "no action [is] needed on Container mode's
`down` — its full-delete behavior is correct." The *macOS* half of ADR-0006 (keep the VM clone)
is unchanged and still stands.

## Context

Container mode used to fully recreate the container on every `up` and delete it on every `down`,
so each session was byte-fresh from the `augur:swift-<tag>` image. That disposability was load-
bearing for parts of the design (the A2 setup-token integrity remedy told the operator to
`down && up` for a clean guest). ADR-0006 ratified it as "correct for that backend."

The counter-case: a persisted container keeps its **writable layer** — the global SPM repo cache,
`~/.cache`, `~/.npm`, user-level (`--user`) installs, shell history, and any tool state that
lives *outside* the bind-mounted workspace. The workspace (including `.build`) and this project's
Claude history are already bind-mounted, so persistence's marginal benefit is narrower than
macOS's Xcode-cache case — but a fast, cache-preserving restart is still a real, recurring
convenience, and users reasonably expect `down`/`up` to behave like the macOS mode they already
use side-by-side.

The blocker ADR-0006 implicitly assumed — that persistence is unsafe for the egress/threat model
— turned out to be about the **naïve** implementation (`delete`→`stop`, `run`→`start`), not about
persistence itself. A full-fleet analysis (2026-07-23) mapped every objection and found that
**macOS VM mode already persists safely by re-provisioning on every `up`** (re-injects
credentials, re-applies cpu/memory, rebuilds egress, routes `claude`/`shell` through the full
`up`, has `destroy`/`list`, and a path-hash-keyed name). Container mode can't re-provision a
stopped container's baked env/network in place, so it uses the analogous lever — **reconcile:
reuse only when nothing that was baked at `run` has drifted, else recreate clean.**

## Rationale

Persistence is not inherently unsafe (macOS proves it); the danger was in copying macOS's
*persistence* without its *reconcile-on-`up`* machinery. This ADR adopts both:

1. **Reconcile on `up`** (`container_fingerprint`). A stopped container is reused only when a
   hash of everything baked at `run` — egress on/off + gateway, resolved auth token values, gh
   token, memory, and the mounted host paths — is unchanged. Any drift (rotated token, flipped
   egress mode, resized memory, moved workspace) forces a clean recreate, so a reused container
   never runs stale credentials or wiring. Image content is handled out-of-band:
   `build`/`update`/`install-cert` remove this project's container so a rebuilt image always
   takes effect.
2. **The boot self-test gates every `up`, including reuse.** `verify_egress_locked` runs on both
   the fresh and the reused path (via `finish_up`); the datapath is rebuilt on every `up`, never
   cached from a prior boot (upholds INVARIANT I1). One honest caveat introduced by persistence:
   on the reuse path the self-test's probes (`curl`/`getent`) execute *inside a container whose
   writable layer a prior session could have modified*, so they are no longer a fully independent
   tripwire the way they are against a pristine image. This is mitigated — the probes are pinned to
   system dirs (`-e PATH=/usr/bin:/bin:/usr/local/bin`), so the non-root (uid 1001) guest cannot
   shadow them via the dev-writable `~/.local/bin` — but not eliminated (a hypothetical root guest
   could still tamper). The real egress enforcement does NOT depend on the guest: it is host-side
   (the `--internal` network severs routing, `--cap-drop NET_ADMIN`, the host-side allowlist), all
   re-applied by `container start`. The self-test remains a detection layer; `destroy` and the
   setup-token integrity gate are the compensating controls for a persisted foothold.
3. **No silent reuse path.** `augur claude`/`shell` route a stopped container through the full
   `up` (`container_running || cmd_up`), not a bare `container start` — so egress is always
   re-established and self-tested. (The old `ensure_running` bare-start path is removed.)
4. **Cross-project isolation.** The container name now embeds `workspace_path_hash`, so two
   projects that share a basename can never resolve to — and thus reuse — the same persisted
   container (mirrors the macOS project-VM name).
5. **`destroy` is the reset.** A2's clean-binary remedy is now `augur destroy && augur up` (not
   `down && up`), and `destroy` also reclaims disk and forces a from-scratch container.

**The residual is the same one macOS already accepts.** A persisted guest can carry a foothold
(a tampered writable layer) across `down`/`up` — exactly the cross-leaf / no-isolation-within-one
exposure ADR-0004 §7 and ADR-0006 already documented and accepted for macOS. Container mode now
carries it too, bounded by the same `destroy` escape hatch and the setup-token integrity gate. It
is a deliberate trade for fast restarts, not a regression that widens egress (the network controls
are container-create-time and re-applied by `start`; the allowlist is host-side).

## Consequences

- `cmd_down` = `container stop` (kept; egress network kept); `cmd_destroy` = remove container +
  network + reconcile fingerprint. `augur destroy` added to the container-mode dispatch and help.
- `cmd_up` reconciles: `container start` on a fingerprint match, else `engine_rm_force` + fresh
  `run`; `finish_up` (proxy + self-test) runs on both paths.
- `build`/`update`/`install-cert` remove this project's container so the new image takes effect;
  other projects on the same image tag need their own `augur destroy && augur up`.
- Credentials are re-fingerprinted, so a rotated token recreates the container on the next `up`
  rather than being silently stale.
- Follow-ups not taken here (noted for later):
  - a container-mode `list` verb (enumeration across projects is still Apple-CLI-only, per ADR-0005);
  - a SIGTERM-handling PID 1 so `container stop` doesn't wait its grace period (`sleep infinity`
    ignores SIGTERM today — `down` is correspondingly slower than the old `delete --force`);
  - re-keying the per-project egress **network name / subnet / ports** off `workspace_path_hash`
    (still basename-derived). Two consequences, both bounded and pre-existing-in-spirit: a
    same-basename `augur destroy` deletes the shared `augur-<slug>-net` a *different* project's kept
    stopped container is still attached to (self-heals on that project's next `up`, which recreates
    the network), and toggling `--no-egress` on a recreate leaves the kept `--internal` network
    momentarily orphaned. Neither widens egress (the network is routeless; the allowlist is
    host-side and regenerated per `up`); closing them fully needs the subnet re-keyed too.

## Related

- [`0006-macos-vm-clone-persistence.md`](./0006-macos-vm-clone-persistence.md) — the macOS
  persistence decision this ADR makes Container mode symmetric with; its Container-mode
  Consequence is superseded here.
- [`0005-no-prune-command.md`](./0005-no-prune-command.md) — why there is still no `augur prune`;
  `destroy` is per-project, raw `container prune` handles the rest.
- [`0004-no-special-worktree-support.md`](./0004-no-special-worktree-support.md) §7 — the
  cross-leaf / no-isolation-within-one-guest residual that persistence now also carries for
  Container mode.
- `docs/security-reviews/INVARIANTS.md` — I1 (self-test gates every `up`, now including reuse)
  and I5 (`--no-dns` re-applied by `start`) are upheld by the reconcile design.
