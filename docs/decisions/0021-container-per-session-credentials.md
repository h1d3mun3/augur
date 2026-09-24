# ADR-0021 — Container mode injects credentials per session, not at `container run`

- **Status:** Accepted. Amends [`0010`](./0010-container-persistence.md) — its rationale that
  credentials are baked at `run` and fingerprinted so a rotated token recreates the container.
- **Date:** 2026-09-24.
- **Applies to:** Apple Container mode only. macOS VM mode (`~/.augur-env` over SSH stdin) is
  unchanged.

## Decision

**augur stops baking credentials and `TZ` into the container at `container run`.** They are
injected per session instead, only on the `container exec` that starts `augur claude` and
`augur shell`.

- **Secrets** — the resolved `agent_auth_specs` values (`ANTHROPIC_API_KEY`,
  `CLAUDE_CODE_OAUTH_TOKEN`) and `gh auth token` as `GH_TOKEN`; named-only, non-empty only — are
  passed with `--env-file <(printf '%s=%s\n' …)`. `printf` is a bash builtin, so no value reaches
  any process's argv; the `container` CLI reads the FIFO once at startup (apple/container's
  `Parser.envFile` reads through `FileHandle` explicitly "to support named pipes (FIFOs) and
  process substitutions"); nothing is written to disk; and exec-time config is not persisted in the
  container bundle.
- **Non-secret per-session values** go as plain `-e`: `TZ`, and the `GIT_CONFIG_COUNT` /
  `GIT_CONFIG_KEY_0` / `GIT_CONFIG_VALUE_0` git credential helper (only when a gh token exists).
  Moving the helper off `run` also means a later host `gh auth login` needs no recreate.
- **Validation** (`validate_resolved_credentials` / `validate_secret_value`) runs at session
  start, before the `exec`.
- **`augur setup-token` gets no credentials injected.** It exists to mint one; the current token is
  not handed to a guest binary for that flow. A manual `container exec` outside augur also gets
  none — accepted and documented.
- **`container_fingerprint` drops** the resolved auth values and the gh token (the helper and
  `TZ` follow them off `run`; `TZ` was never fingerprinted). Because the digest changes, every
  persisted container is recreated once on the first `augur up` after upgrading; prompt history
  survives through the existing carry-over snapshot (`save_guest_history` /
  `restore_guest_history`).
- **`augur claude` / `augur shell` against an already-running container check the fingerprint
  too**, and on mismatch refuse with `augur down && augur up`. Today they skip `cmd_up` when the
  container is running (`container_running || cmd_up`), so only `augur up` reaches
  `reconcile_running_container`'s refusal. See Context for why exec-time env cannot be relied on
  to override a baked value; without this check a container created by an older augur would keep
  its baked, possibly stale, credentials and they would win over the per-session ones.
- **Minimum Apple Container CLI: 1.0.0**, for FIFO-safe `--env-file` and explicit-empty `K=`
  semantics. augur checks the version and refuses older CLIs with a clear message (no such check
  exists today). Latest release at time of writing: 1.4.1.
- **Mid-session token rotation** is picked up by the next session, not live.

The corresponding updates to `README.md`, `docs/security-reviews/INVARIANTS.md` (I10) and
`docs/security-reviews/host-env-exposure-review.md` ship with the implementation PR, so the docs
never describe behavior that is not merged.

## Context

Today `recreate_container` bakes three things into `container run`:

- the agent auth vars, via `_add_auth_run_args` (`-e ANTHROPIC_API_KEY=…` /
  `-e CLAUDE_CODE_OAUTH_TOKEN=…`);
- `GH_TOKEN` plus the `GIT_CONFIG_*` credential helper, via `_add_host_config_run_args`;
- `TZ`, via `run_args+=(-e "TZ=$(host_timezone)")`.

Consequences of baking the secrets:

1. **Secrets at rest.** Apple Container writes the run configuration, including the init process's
   environment, as plaintext JSON to the container bundle's `config.json`, and `container inspect`
   prints it. Since ADR-0010 the container persists across `down`, so the token sits on disk for
   the container's whole lifetime.
2. **Secrets on argv.** The values are on the `container run` command line. INVARIANTS I10 lists
   this as the accepted container residual (M1), review-only.
3. **Rotation forces a recreate.** `container_fingerprint` hashes the resolved secret *values*, so
   a rotated token discards the writable layer on the next `up` — part of why the prompt-history
   carry-over exists.

### Exec-time `-e` does not reliably override a baked value

Measured on the maintainer's Mac, 2026-09-24, against a running augur container whose baked
`TZ` was `Asia/Tokyo`:

| Probe (via `container exec -e TZ=UTC <c> …`) | Result |
|---|---|
| `env` | prints **both** `TZ=Asia/Tokyo` and then `TZ=UTC` |
| `bash -c 'echo $TZ'` | `UTC` (bash: last duplicate wins) |
| `date +%Z` | `JST` (libc `getenv`: first duplicate wins) |

apple/container's `ContainerExec` starts from the container's init-process configuration and
appends the exec `-e` entries without de-duplicating against it. So an exec-time value overrides a
baked one only for programs that happen to take the last duplicate; anything using libc `getenv`
sees the baked one. Two consequences:

- the per-session `TZ` "refresh" `cmd_claude` / `cmd_shell` do today is effective only for shells,
  not for `date` or any other non-shell program (the comment in `recreate_container` claiming
  "`exec -e` overrides it per call" is wrong);
- per-session injection is only correct if the value is **absent** from the baked config. That is
  the core constraint on this design, and why the running-container fingerprint check above is
  required rather than optional.

## Alternatives considered

- **Keep baking at `run` (status quo).** Leaves all three problems above.
- **`container exec -e K=V`.** The secret sits on the host's `container exec` argv for the whole
  session, visible to `ps` — a straight I10 violation, arguably worse than today's short-lived
  `run` argv.
- **`container exec -e K` (inherit from the CLI's environment).** Works on CLIs older than 1.0.0,
  but requires exporting the secret into the `container` CLI process's environment, where it stays
  for the session. An acceptable fallback, not chosen because 1.0.0 is required anyway.
- **A temporary `--env-file` on disk.** Puts the secret at rest in a host file and introduces a
  create/read/delete race.
- **A 0600 file written into the guest and sourced via `BASH_ENV` / `profile.d`, like macOS VM
  mode's `~/.augur-env`.** Unnecessary — exec env already reaches `claude` and every shell it
  spawns — and worse: the secret would sit at rest in the guest-writable layer that ADR-0010
  persists. bash also has no `zshenv` equivalent, so non-interactive, non-login shells would need
  `BASH_ENV` plumbing on top.

## Consequences

- I10's container residual (M1) is closed, and I10 can become test-enforced for Container mode:
  the offline engine shim can assert that no credential appears on the `run` argv and that the
  `claude` / `shell` `exec` lines carry `--env-file`.
- A rotated token (or a new `gh auth login`) no longer recreates the container; the writable
  layer survives it.
- One forced recreate per persisted container on the first `augur up` after upgrading (history is
  carried over).
- Apple Container ≥ 1.0.0 is required; older CLIs are refused with a clear message.
- A host timezone change is picked up per session, for every program rather than only shells.
- `augur setup-token` and ad-hoc `container exec` sessions run without credentials.
- Credentials exist only in the environment of augur-started session processes in the guest, for
  the life of those processes.
- macOS VM mode is unchanged.

## Related

- [`0010-container-persistence.md`](./0010-container-persistence.md) — the reconcile/fingerprint
  design this ADR amends: secrets and `gh` token leave the fingerprint, and the
  running-container refusal extends from `augur up` to `augur claude` / `augur shell`.
- [`0013-claude-config-inheritance.md`](./0013-claude-config-inheritance.md) — the prompt-history
  carry-over that makes the one-time upgrade recreate cheap.
- `docs/security-reviews/INVARIANTS.md` — I10 (credentials not on argv), whose container residual
  M1 this closes.
