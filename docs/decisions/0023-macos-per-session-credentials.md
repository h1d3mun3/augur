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
  the SSH wait (before the clock, the self-test and the rest of the bring-up) with `_creds` emptied,
  so a guest not yet self-tested gets no `GIT_CONFIG_*` git helper lines either; a second push after
  the self-test writes them. On a running VM it is the session's or `up`'s one push, whose
  `~/.augur-env` carries the `GIT_CONFIG_*` lines whenever the host has a gh token, refused or not
  (they hold no secret, and no session follows a refusal). A project VM cloned
  from a base built before this — or for a different set of names — still gets the new
  `~/.augur-env` (removing credentials an older augur wrote there) and is then refused, before any
  credential is sent. The remedy names `augur destroy --macos && augur up --macos` as enough when
  the base VM is already up to date, and `augur update --macos` first otherwise (augur does not
  detect the base's version).
  The refusal and its remedy are reported even when a later step of that push (the `~/.augur-env`
  write, the `~/.zshenv` line) fails, together with that step.
  There is deliberately no fallback to writing credentials to disk, and no in-place patching of
  project VMs. Without the check the guest's sshd would silently drop the values and the agent
  would start unauthenticated. A guest that lies to the check gains nothing: its sshd decides what
  it accepts, and the worst case is a session without credentials.
- **A boot that fails before its self-test stops the VM.** Any failure of the boot's first push
  (a refusal, a transport error, a full disk) stops the VM, its gvproxy and its proxy, and keeps the
  clone (`require_macos_session_env_accepted` → `stop_unverified_macos_boot`, shared with the SSH-wait
  timeout). A VM left running there would never have been self-tested, and the next `claude` /
  `shell --macos` would take `prepare_macos_session`'s running path and send it credentials. A
  refused VM is of no use anyway; `destroy` stays the operator's call.
- **The push that carries the check removes every stale temp file.** A killed push can leave a
  `~/.augur-env.tmp.*`, and one written by an older augur may hold credentials. A plain push
  removes only those older than a minute, so a concurrent push keeps its own. The checked push
  (every session, `up` on a running VM, the boot's first push) removes every one except its own,
  whatever its age: a refused guest gets no later push, and a guest clock that lags right after a
  boot makes an old file look new. A concurrent push that loses its temp file to it fails; an
  accepted trade-off.
- **Delivery is checked in the guest, not only the drop-in.** The drop-in check reads a file, so it
  still passes when the guest's `sshd_config` has lost its `Include` (a guest macOS update, a hand
  edit) and sshd silently drops every `SendEnv`. So the session's remote command starts with
  `macos_session_env_delivery_cmd`: `[ -n "${NAME:-}" ] || exit 197` for each name the session
  sent, which names variables and prints no value. A missing one exits before the agent or shell
  starts, and `ssh_macos_session` maps that status to the refusal ("sshd did not accept augur's
  session credentials") and the same remedy. An agent or shell that itself exits 197 is reported as
  that refusal too; an accepted trade-off. The drop-in check stays: it gates the scrub and fails
  before the bring-up.
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

"Nothing on the guest disk" also relies on the helper-chain reset in `git_credential_env`, so that
augur's `$GH_TOKEN` helper is the only helper git hands the token to. Without the reset, git's
`store` step after a successful push would hand `GH_TOKEN` to every configured helper, including
the system or host `osxkeychain` helper, which can write it into the guest's login keychain on
disk if that keychain is unlocked. The reset is the first of the two `GIT_CONFIG_*` entries
`push_macos_guest_env` writes into `~/.augur-env` (an empty `credential.https://github.com.helper`
value); those lines hold only the `$GH_TOKEN` reference, and the token itself reaches the helper
from the session's environment. `tests/35_macos_gitconfig_helper.sh` pins the reset against real
git, with `GH_TOKEN` set the way the session ssh sets it.

The `GIT_CONFIG_*` lines sit inside `if [ -n "${GH_TOKEN:-}" ]; then … fi` in `~/.augur-env`, and
each line still goes through `macos_env_add_export`'s validation before it is wrapped. `~/.zshenv`
sources the file in every guest zsh, but only an augur session has `GH_TOKEN` (sshd sets it before
`~/.zshenv` runs). Without the guard, the VM's GUI Terminal or a hand-run `ssh` would get the reset
plus a helper with no token: git's own helpers cleared, `password=` answered, and HTTPS git failing
with a 401 and no prompt (reproduced with git 2.53). The same held for a session started while the
host had no gh token once a later session rewrote the file with the lines. With the guard, those
shells keep git's normal helpers; tests 35 and 56 pin both sides.

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
  the helper-chain reset in `git_credential_env` (above).
- Credentials exist only in the environment of augur-started session processes in the guest, for
  the life of those processes, as in Container mode. A manual `ssh` into the guest gets none.
- `up --macos` hands the guest no credential.
- Existing base VMs need one `augur update --macos`, and each project VM cloned from an old base
  `augur destroy --macos && augur up --macos` (its Claude history lives on the host and survives).
  Until then `up`, `claude` and `shell --macos` refuse with that remedy, and a VM booted for the
  refusal is stopped again (clone kept).
- A guest whose sshd stops delivering the values (a lost `Include`) is refused per session, before
  the agent or shell starts, rather than running unauthenticated.
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
