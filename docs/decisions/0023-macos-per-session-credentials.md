# ADR-0023 — macOS VM mode delivers credentials per session as the SSH environment, never on the guest's disk

- **Status:** Accepted.
- **Date:** 2026-11-07.
- **Applies to:** macOS VM mode only. Apple Container mode already delivers credentials per session
  ([`0021`](./0021-container-per-session-credentials.md)); this brings macOS VM mode to the same
  property.

## Context

`resolve_session_credentials` resolves the agent's `agent_auth_specs` values (`ANTHROPIC_API_KEY`,
`CLAUDE_CODE_OAUTH_TOKEN`) and `gh auth token` as `GH_TOKEN` once per command, and validates them.
Container mode hands them to the `augur claude` / `augur shell` `container exec` through
`--env-file <(printf …)`: on no argv, not on disk, gone when the session ends.

macOS VM mode wrote the same values as `export VAR='…'` lines into the guest's `~/.augur-env`
(mode 600, atomic rename), sourced from `~/.zshenv`, on every `up`, `claude` and `shell --macos`.
That kept them off argv, but:

1. **Secrets at rest in the guest.** The file sits on the clone's disk, which `down --macos` keeps
   ([`0006`](./0006-macos-vm-clone-persistence.md)); a stopped VM holds the last-pushed tokens
   indefinitely.
2. **Every guest process got them,** not only the augur-started session: any `ssh` into the guest,
   any zsh started by anything, read them from the file.
3. **`up --macos` pushed credentials** although it starts no session.

## Decision

**Credentials reach a macOS guest only as the environment of the interactive ssh that starts
`augur claude --macos` / `augur shell --macos` (`ssh_macos_session`), via OpenSSH env forwarding.**

- **Host side.** The ssh options are resolved first (so the commands that look up the VM's host
  and port never see a value), then a subshell `export`s each resolved `NAME=value` — `export` is a
  builtin, so no value is on any argv — and execs `ssh` with `-o SendEnv=<NAME>` for exactly the
  resolved names. augur's own shell and every other child never hold the values. Not
  `-o SetEnv=NAME=value`: that is argv. `ssh_macos` stays hermetic (`-F /dev/null`, which already
  drops the stock `SendEnv LANG LC_*`) and adds nothing; augur's other ssh calls (clock sync,
  `ensure_*`, the self-test, the `~/.augur-env` push, `setup-token --macos`) carry no `SendEnv` and
  no credential.
- **Guest side.** The base VM build and `update --macos` write
  `/etc/ssh/sshd_config.d/200-augur-session-env.conf` as root (`install_macos_session_env_acceptance`):
  one `AcceptEnv` line naming exactly `session_credential_names` (the `agent_auth_specs` guest
  variables plus `GH_TOKEN`; exact names, no patterns, charset-checked before they reach a root
  script). macOS's `sshd_config` includes `sshd_config.d/*`, and `AcceptEnv` patterns add up across
  files, so macOS's own `AcceptEnv LANG LC_*` stays. The install then asks `sshd -T` for the
  configuration a new sshd would run with and checks every name is accepted; on any failure the
  drop-in is removed again (a file sshd cannot parse must never stay and lock SSH out) and the
  build/update refuses to save the base VM. Nothing is reloaded: sshd reads its configuration when
  it starts, and every clone boots from the saved disk.
- **`~/.augur-env` stays, without credentials.** It still carries the non-secret per-VM env (brew
  shellenv, the agent's PATH, `DEVELOPER_DIR`, `agent_fixed_env`) and is pushed on every
  `up` / `claude` / `shell --macos`. It is rewritten whole, so the first push to a guest whose file
  an older augur wrote removes the credentials from it. That push is now **fatal for a session** as
  well as for `up`: `~/.zshenv` sources the file in every session shell *after* sshd has set the
  session's environment, so a stale `export GH_TOKEN=…` would silently replace the fresh value.
- **Old bases are refused, not migrated.** Before every `claude` / `shell --macos` session
  (`require_macos_session_env_accepted`) augur checks over ssh that the drop-in holds exactly the
  line it would write. A project VM cloned from a base built before this — or for a different set
  of names — is refused, before any credential is sent and, on a running VM, before the guest is
  changed, with the remedy `augur update --macos` then `augur destroy --macos && augur up --macos`.
  There is deliberately no fallback to writing credentials to disk, and no in-place patching of
  project VMs. Without the check the guest's sshd would silently drop the values and the agent
  would start unauthenticated. A guest that lies to the check gains nothing: its sshd decides what
  it accepts, and the worst case is a session without credentials.
- **Ordering and validation are unchanged.** Resolve once, validate, refuse before touching the
  guest; `cmd_up_macos` resolves before the clone (and, on its already-running branch, after the
  self-test), and a `claude` / `shell --macos` that boots the VM through it launches with those
  same values (`cmd_up_macos` fills the caller's `_creds`). The launch is the last step, so on every
  path the credentials go only to a guest that passed its boot self-test or attaches to one that
  did at its last `up` (the accepted trade-off Container mode's per-session exec makes too).
- **What `up --macos` delivers:** the non-secret `~/.augur-env` and git's credential helper (only
  the `$GH_TOKEN` reference), no credential. It still resolves and validates, so a value the next
  session would refuse fails `up` before the clone.
- **`setup-token --macos`:** unchanged — its throwaway clone gets nothing and its login ssh has no
  `SendEnv`.

### Mechanism facts this rests on

- **No connection multiplexing.** `ssh_macos` passes `-F /dev/null` and no `ControlMaster` /
  `ControlPath`, so every call is its own connection and the env a session sends belongs to it
  alone. (OpenSSH would forward a mux client's `SendEnv` in its new-session request too, but augur
  does not rely on that.)
- **Host-side visibility.** macOS serves another process's environment through the same sysctl as
  its arguments, and only to the process's own user and root. That is exactly who can already read
  the host files and `gh` token the values come from. ADR-0021 accepted the same exposure for the
  `container` CLI ("export into the CLI process's environment": an acceptable fallback). Plain
  `ps` does not print environments, so a credential no longer appears in casual process listings
  the way argv would.
- **Guest login shells keep it.** sshd sets the accepted variables in the session's environment
  before it starts the user's shell. `zsh -l -c …` / `exec zsh -l` inherit them, and nothing augur
  writes (`~/.zshenv`, `~/.augur-env`) or macOS's `/etc/zprofile` (`path_helper`, PATH only) unsets
  them. The agent and every shell it spawns inherit them in turn, and git's credential helper reads
  `$GH_TOKEN` when git runs it inside the session. Processes started outside the session (a manual
  `ssh`, a daemon) do not have them.

## Alternatives considered

- **Keep `~/.augur-env` with the credentials (status quo).** Leaves the secrets at rest in a
  persisted disk and in every guest process.
- **Feed the environment over the session's stdin** (e.g. read `NAME=value` lines from stdin, then
  `exec` the shell). The interactive session's stdin is the operator's terminal, so the values would
  have to be consumed by a guest-side reader before the PTY is handed over — fragile under `-t`, and
  the reader runs inside the guest-writable shell rc chain that also runs the session. A second ssh
  to stage them is a file again.
- **A tmpfs file in the guest** (a RAM disk created per boot, read by the session). Off the
  persisted disk, but readable by every guest process for the VM's whole uptime, needs a privileged
  mount on every boot, and still has a create/read/delete lifecycle to get wrong.
- **`-o SetEnv=NAME=value`.** Same sshd side, but the value is on the host `ssh` argv for the whole
  session — an I10 violation.
- **Install the drop-in into existing project VMs on `up`** (augur can `sudo -S` there). Rejected as
  migration code for old bases; a base update plus re-clone is the supported path.

## Consequences

- No credential at rest in any macOS guest written by this augur; a stopped clone holds none.
- Credentials exist only in the environment of augur-started session processes in the guest, for
  the life of those processes, as in Container mode. A manual `ssh` into the guest gets none.
- `up --macos` hands the guest no credential.
- Existing base VMs need one `augur update --macos`, and each project VM cloned from an old base
  `augur destroy --macos && augur up --macos` (its Claude history lives on the host and survives).
  Until then `claude` / `shell --macos` refuse with that remedy.
- A failed `~/.augur-env` push now stops a session instead of warning.
- Old credential bytes from an earlier `~/.augur-env` may remain in the clone's free disk blocks
  after the file is rewritten; augur does not scrub them.

## Related

- [`0021-container-per-session-credentials.md`](./0021-container-per-session-credentials.md) — the
  Container-mode counterpart, and the host-side environment reasoning reused here.
- [`0006-macos-vm-clone-persistence.md`](./0006-macos-vm-clone-persistence.md) — why the clone
  persists, which is what made credentials at rest matter.
- [`0022-macos-setup-token-throwaway-clone.md`](./0022-macos-setup-token-throwaway-clone.md) —
  `setup-token --macos` gets no credentials.
- `docs/security-reviews/INVARIANTS.md` — I10 (credentials not on argv).
- [`../host-env-exposure-review.md`](../host-env-exposure-review.md) — the env-exposure review this
  changes (augur now uses `SendEnv` / `AcceptEnv`, for exactly these names).
