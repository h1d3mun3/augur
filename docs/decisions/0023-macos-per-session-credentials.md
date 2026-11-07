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
  resolved names. For a value read from a host file or from `gh`, augur's own shell and every other
  child never hold it. A credential the operator exported into augur's environment
  (`ANTHROPIC_API_KEY` / `CLAUDE_CODE_OAUTH_TOKEN` set in their shell) is already held by augur and
  inherited by every child, like any other variable of that shell; that is an accepted trade-off
  (those processes run as the operator), and none of them forwards it. Not
  `-o SetEnv=NAME=value`: that is argv. `ssh_macos` stays hermetic (`-F /dev/null`, which already
  drops the stock `SendEnv LANG LC_*`) and adds nothing; augur's other ssh calls (clock sync,
  `ensure_*`, the self-test, the `~/.augur-env` push, `setup-token --macos`) carry no `SendEnv` and
  no credential.
- **Guest side.** The base VM build and `update --macos` write
  `/etc/ssh/sshd_config.d/200-augur-session-env.conf` as root (`install_macos_session_env_acceptance`):
  one `AcceptEnv` line naming exactly `session_credential_names` (the `agent_auth_specs` guest
  variables plus `GH_TOKEN`; exact names, no patterns, charset-checked before they reach a root
  script). macOS's `sshd_config` includes `sshd_config.d/*`, and `AcceptEnv` patterns add up across
  files, so macOS's own `AcceptEnv LANG LC_*` stays. macOS starts a new sshd per connection
  (launchd), so a file in `sshd_config.d` is live for the next login, and one sshd cannot parse
  would lock SSH out at once. So the candidate is verified before it goes live: written outside
  `sshd_config.d`, then `sshd -T -f <test config>` (a copy of `/etc/ssh/sshd_config` with an
  `Include` of the candidate at the top) must parse and accept every name, from one `sshd -T` run.
  Only then is it renamed into place; the live configuration is checked once more (the drop-in is
  removed if that fails) and one fresh ssh connection must succeed. sshd's own error is shown on
  failure, and the build/update refuses to save the base VM. If that last connection fails, the
  drop-in stays live and is not rolled back; this is an accepted trade-off, because only a scratch
  VM kept with `AUGUR_KEEP_BUILD_VM=1` survives the failure (a guest-side rollback timer or an
  in-guest probe would need a detached root process or guest-side SSH credentials, neither
  verifiable off a Mac). `update --macos` installs the drop-in first, right after its staging clone
  boots and before the agent installer, Homebrew and custom provisioning, so it does not wait on
  the network. The update still saves the base only once every step has passed, so while a
  Homebrew upgrade keeps failing, an old base stays without the drop-in.
- **`~/.augur-env` stays, without credentials.** It still carries the non-secret per-VM env (brew
  shellenv, the agent's PATH, `DEVELOPER_DIR`, `agent_fixed_env`) and is pushed on every
  `up` / `claude` / `shell --macos`. It is rewritten whole, so the first push to a guest whose file
  an older augur wrote removes the credentials from it. That push is now **fatal for a session** as
  well as for `up`: `~/.zshenv` sources the file in every session shell *after* sshd has set the
  session's environment, so a stale `export GH_TOKEN=…` would silently replace the fresh value.
- **Old bases are refused, not migrated.** `up`, `claude` and `shell --macos` check over ssh that
  the drop-in holds exactly the line augur would write (`macos_session_env_check_cmd`), always as
  the first step of a `~/.augur-env` push (`push_macos_guest_env --require-session-env`), so every
  refusal takes one code path and costs no extra connection. On a boot that push runs right after
  the SSH wait (before the clock, the self-test and the rest of the bring-up) with no credential in
  scope, so it wires no git helper into a guest not yet self-tested; a second push after the
  self-test wires it. On a running VM it is the session's or `up`'s one push. A project VM cloned
  from a base built before this — or for a different set of names — still gets the new
  `~/.augur-env` (removing credentials an older augur wrote there) and is then refused, before any
  credential is sent, with the remedy `augur update --macos` then `augur destroy --macos && augur up --macos`.
  The refusal and its remedy are reported even when a later step of that push (the `~/.augur-env`
  write, the `~/.zshenv` line) fails, together with that step.
  There is deliberately no fallback to writing credentials to disk, and no in-place patching of
  project VMs. Without the check the guest's sshd would silently drop the values and the agent
  would start unauthenticated. A guest that lies to the check gains nothing: its sshd decides what
  it accepts, and the worst case is a session without credentials. A VM refused at boot is left
  running, as after any other failure past the SSH wait except a detected leak; `destroy` removes
  it.
- **Ordering and validation.** Resolve once and validate; `cmd_up_macos` resolves before the clone
  (and, on its already-running branch, after the self-test). On a running VM a value that fails
  still gets the guest one push without credentials (`resolve_running_macos_vm_credentials`) before
  the command stops, so an older augur's credential-bearing `~/.augur-env` cannot outlive a bad
  host credential, and an old base is named with its remedy next to the resolution error. That
  push carries no secret, and on `up`'s running branch it still comes after the self-test. A
  stopped VM is not booted for it. A `claude` / `shell --macos` that boots the VM through
  `cmd_up_macos` launches with those same values (`cmd_up_macos` fills the caller's `_creds`).
  The launch is the last step, so on every
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
- **Host-side visibility (expected, not yet observed; see below).** macOS serves another process's
  environment through the same sysctl as its arguments, and is expected to serve it only to the
  process's own user and root. That is exactly who can already read the host files and `gh` token
  the values come from. ADR-0021 accepted the same exposure for the
  `container` CLI ("export into the CLI process's environment": an acceptable fallback). Plain
  `ps` does not print environments, so a credential no longer appears in casual process listings
  the way argv would.
- **Observed on a macOS 27 guest** (a clone of the base VM, 2026-11-07):
  - `/etc/ssh/sshd_config` has `Include /etc/ssh/sshd_config.d/*` (absolute path, near the top), and
    `sshd_config.d` holds only macOS's own `100-macos.conf` (root:wheel, 644).
  - `sudo sshd -T` prints `AcceptEnv LANG` and `AcceptEnv LC_*`: mixed-case keyword, one name per
    line, not upstream's lowercase `acceptenv`. The install's parse lowercases the keyword and reads
    every field, so it accepts both forms.
  - `launchctl print system/com.openssh.sshd` shows a LaunchDaemon (`ssh.plist`) with
    `active count = 0` even while a session is open, consistent with one sshd per connection.
- **Not yet observed on a Mac:** that macOS serves another user's process environment to no one
  but that user and root (`ps -E` from a second account); that `sshd -T -f <test config>` follows
  the staged config's absolute `Include` as described; and end-to-end delivery (the session's
  `SendEnv` values present in `claude --macos` / `shell --macos`, absent from a plain `ssh`).
- **Guest login shells keep it.** sshd sets the accepted variables in the session's environment
  before it starts the user's shell. `zsh -l -c …` / `exec zsh -l` inherit them, and nothing augur
  writes (`~/.zshenv`, `~/.augur-env`) or macOS's `/etc/zprofile` (`path_helper`, PATH only) unsets
  them. The agent and every shell it spawns inherit them in turn, and git's credential helper reads
  `$GH_TOKEN` when git runs it inside the session. Processes started outside the session (a manual
  `ssh`, a daemon) do not have them.

### Depends on: git's credential helper chain in the guest is reset

"Nothing on the guest disk" also relies on git's credential helper chain in the guest being reset,
so that augur's `$GH_TOKEN` helper is the only helper git hands the token to. As of this decision
the chain is never reset: after a successful push, git's `store` step hands `GH_TOKEN` to every
configured helper, including the system or host `osxkeychain` helper, which can write it into
the guest's login keychain on disk if that keychain is unlocked. Branch
`fix/macos-git-helper-reset` resets the chain and is planned to merge **before** this decision;
this decision does not duplicate that fix. Without it, the guest's keychain is a path by which a
session's `GH_TOKEN` can reach the guest's disk.

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

- No credential at rest in any macOS guest written by this augur; a stopped clone holds none, given
  the git helper chain reset above.
- Credentials exist only in the environment of augur-started session processes in the guest, for
  the life of those processes, as in Container mode. A manual `ssh` into the guest gets none.
- `up --macos` hands the guest no credential.
- Existing base VMs need one `augur update --macos`, and each project VM cloned from an old base
  `augur destroy --macos && augur up --macos` (its Claude history lives on the host and survives).
  Until then `up`, `claude` and `shell --macos` refuse with that remedy.
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
