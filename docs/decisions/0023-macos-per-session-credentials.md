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
  script; `macos_session_env_names` reads them from that list, not back out of the `AcceptEnv`
  line). macOS's `sshd_config` includes `sshd_config.d/*`, and `AcceptEnv` patterns add up across
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
- **The root script is never staged.** It runs over one ssh connection whose stdin carries the
  admin password line, a marker line, then the script (`macos_run_root_script`), under
  `sudo -S -k -p ''` on a root `sh` that discards every line up to the marker and runs the rest
  (`sh -s`). A script written to a file in the guest user's home first and run by a second
  connection could be swapped in between by any process of that user, which would mean root in
  the VM every project is cloned from. `sudo -S` reads the password one byte at a time up to its
  newline, so it takes that line only; `-k` stops a cached credential from skipping the read. A
  NOPASSWD grant (a build holds one until it revokes it) still skips it, which is what the marker
  is for: whether or not sudo read the line, the password never reaches the shell running the
  script, where an unknown command would print it. The marker is a shell comment. A wrong password
  fails sudo, and no line of the script runs. The password stays on no argv.
- **The drop-in is checked again last.** Homebrew, the agent installer and custom provisioning
  (which runs a root hook) all run after `update --macos` installs the drop-in, and the build's
  Xcode selection, sudo revoke and signature check run after its install. So both re-run the same
  `sshd -T` test against the live configuration (`verify_macos_session_env_acceptance`, the shared
  `macos_session_env_accepts_sh`, over `macos_run_root_script`) as their last guest step, after the
  signature check and right before the VM is stopped and saved, and in the same root script the
  very check every clone runs (`macos_session_env_check_cmd`, the exact `AcceptEnv` line in the
  drop-in). The two can disagree: sshd may accept the names from another file while the drop-in has
  changed or gone, and every clone of that base would be refused. A failure of either saves
  nothing.
- **`~/.augur-env` stays, without credentials and without git's helper set.** It still carries the
  non-secret per-VM env (brew shellenv, the agent's PATH, `DEVELOPER_DIR`, `agent_fixed_env`) and
  is pushed on every `up` / `claude` / `shell --macos`. It never reads the resolved credentials, so
  every push is safe before any self-test. It is rewritten whole, so the first push to a guest
  whose file an older augur wrote removes the credentials (and any `GIT_CONFIG_*` lines) from it.
  That push is now **fatal for a session** as well as for `up`: `~/.zshenv` sources the file in
  every session shell *after* sshd has set the session's environment, so a stale
  `export GH_TOKEN=…` would silently replace the fresh value.
- **Old bases are refused, not migrated.** `up`, `claude` and `shell --macos` check over ssh that
  the drop-in holds exactly the line augur would write (`macos_session_env_check_cmd`), always as
  the first step of every `~/.augur-env` push (`push_macos_guest_env`), so every refusal takes one
  code path and costs no extra connection. The line is built from `macos_session_env_names`, the
  validated names, the same way the drop-in's is. On a boot that push runs right after
  the SSH wait (before the clock, the self-test and the rest of the bring-up) and is the boot's
  only push: its content is built from host-side constants and nothing later in the bring-up
  writes `~/.augur-env` or `~/.zshenv`. On a running VM it is the session's or `up`'s one push. A
  project VM cloned
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
  it accepts, and a session whose credentials it drops is refused by the delivery check (below).
- **A VM whose containment is unproven is stopped.** Any failure of the boot's push
  (a refusal, a transport error, a full disk), the SSH-wait timeout, a failing self-test and a
  passed one that cannot be recorded (below) all stop the VM, its gvproxy and its proxy through one teardown, `stop_unverified_macos_vm`, which
  also drops the record below and keeps the clone (`destroy` stays the operator's call;
  `setup-token --macos` deletes its throwaway clone itself). A VM left running there would be
  attached to by the next `claude` / `shell --macos`. A refused VM is of no use anyway. Under
  `--no-egress` the same boot failures stop the VM too; only the self-test is skipped.
- **A running VM gets a session only if its current boot passed the self-test.** A session that
  attaches to a running VM runs no self-test of its own, so an `up --macos` interrupted between
  `augur-vm run` and the self-test (Ctrl-C, a kill, a host crash) would otherwise leave a VM that
  the next `claude` / `shell --macos` trusts. A host-side record, `macos_egress_verified_file`
  (`<slug>-<hash>.egress-verified` in the proxy directory, beside the egress-mode record), says
  that the self-test passed during the VM's current boot. It is removed just before every
  `augur-vm run`, by `stop_unverified_macos_vm` and by `down` / `destroy`, and written by
  `cmd_up_macos` only once `verify_macos_egress_locked` has passed: on a boot, and on the
  already-running branch, which re-runs the self-test (so `up --macos` also clears a VM whose boot
  was interrupted). It holds the VM's run id (`macos_vm_run_id`): the pid augur-vm's `run` writes
  to the VM's `run.pid`, and that process's start time as `ps -o lstart=` prints it under
  `TZ=UTC0 LC_ALL=C` (padding collapsed). `lstart` is local time, and the augur run that writes the
  record and the one that reads it may have different `TZ`s (another terminal, a shell that sets
  it), so the zone is pinned. `require_macos_egress_verified` accepts the record only when both
  still match, so a VM booted again by any means does not inherit an old record, and neither does
  an `augur-vm run` started by hand after a host crash that happens to get the pid the old record
  holds. A pid alone could match there. `prepare_macos_session` checks it right after the egress-mode check, before
  any other guest step. A refusal first pushes `~/.augur-env`, as every refusal of a running VM
  does (below); deliberately on a VM whose containment is unproven, since the push sends no
  credential. It then refuses, leaving the VM running, with `augur up --macos` as the remedy: on
  the running VM that re-runs the self-test and records it. (On a VM from an old base that `up`
  then refuses with the old-base remedy; the first message promises only the self-test.) When the
  run id cannot be read after a passed self-test (no `run.pid`, no process with that pid, no start
  time), the pass cannot be recorded and every session would refuse the VM, so `up` fails and stops
  it through `stop_unverified_macos_vm`, the clone kept. A marker rather than a trap on the interrupted `up`: a trap cannot run on a kill or a
  host crash. Deliberately egress-on only: a `--no-egress` boot has no self-test to record, and a
  `--no-egress` session attaches only to a VM booted that way (`require_macos_egress_mode_current`),
  where there is no containment for the record to vouch for.
- **Every push removes stale temp files, by age.** A killed push can leave a `~/.augur-env.tmp.*`,
  and one written by an older augur may hold credentials. Every push removes, except its own, each
  one older than a minute (`find -mmin +1`) or dated ahead of the guest's clock (`-newer` than a
  reference file it has just created with `mktemp` in `/tmp` and removes again; both are
  BSD-find primaries): right after a boot the guest clock may lag, so a file written before the
  reboot looks newer than now rather than old. A concurrent push finishes well within the minute,
  so it keeps its own file. Accepted trade-off: a concurrent push that creates its temp file in the
  instant between another push's reference file and its `find` loses it and fails.
- **Delivery is checked in the guest, not only the drop-in.** The drop-in check reads a file, so it
  still passes when the guest's `sshd_config` has lost its `Include` (a guest macOS update, a hand
  edit) and sshd silently drops every `SendEnv`. So the session's remote command starts with
  `macos_session_env_delivery_cmd`: `[ -n "${NAME:-}" ] || exit 197` for each name the session
  sent, which names variables and prints no value. A missing one exits before the agent or shell
  starts, and `ssh_macos_session` maps that status to the refusal. Only a session that sent a
  credential has the check, so only its exit status is read that way; a session that sent nothing
  passes 197 through as the shell's own. An agent or shell that itself exits 197 after credentials
  were sent is reported as that refusal too; an accepted trade-off, which the message makes cheap:
  it says the session exited with 197, the status the delivery check uses when the guest's sshd
  did not pass on a credential, and to ignore it if the agent or shell itself exited so. Its first
  remedy is `augur up --macos`, which re-checks the drop-in (`macos_session_env_check_cmd`, the
  old-base refusal with its remedy if it is gone); only if that passes and sessions keep exiting
  with 197 does it say to recreate the VM (`augur destroy --macos && augur up --macos`, after
  `augur update --macos` if the base is out of date), since a lost `Include` is not something
  `up` can see or repair. The drop-in check stays: it gates the scrub and fails before the
  bring-up.
- **git's credential helper rides in the session's remote command.** After the delivery check, and
  only when `GH_TOKEN` is sent, the remote command exports `git_credential_env`'s `GIT_CONFIG_*`
  set (`macos_session_git_env_cmd`: each line through `macos_env_add_export`, so the name is a
  shell variable name and the single-quoted value holds no quote or control byte). The values hold
  only the `$GH_TOKEN` reference, so no credential is on the ssh argv. The set exists only in the
  shells of an augur session that has the token: a guest shell augur did not start (the GUI
  Terminal, a hand-run `ssh`) has none, and git keeps its own helpers there.
- **Every refusal of a running VM pushes first.** A `~/.augur-env` an older augur wrote holds
  credentials, so a refusal must not leave it behind. The old-base refusal happens inside the push
  itself; the two refusals made before any push, a credential that cannot be used
  (`resolve_running_macos_vm_credentials`) and a boot with no passed self-test
  (`require_macos_egress_verified`), push with `--refusing` before they refuse. With `--refusing`,
  a push that could not rewrite the file, or whose outcome is unknown, says the file may still hold
  an older augur's credentials, as the old-base refusal does; the refusal stands either way.
  `push_macos_guest_env`'s header is the one place the code explains why.
- **Ordering and validation.** Resolve once and validate; `cmd_up_macos` resolves before the clone
  (and, on its already-running branch, after the self-test). On a running VM a value that fails
  still gets the guest its `~/.augur-env` push (`resolve_running_macos_vm_credentials`) before
  the command stops, so an older augur's credential-bearing `~/.augur-env` cannot outlive a bad
  host credential, and an old base is named with its remedy next to the resolution error. That
  push carries no secret, and on `up`'s running branch it still comes after the self-test. A
  stopped VM is not booted for it. A `claude` / `shell --macos` that boots the VM through
  `cmd_up_macos` launches with those same values (`cmd_up_macos` fills the caller's `_creds`).
  The launch is the last step, so on every
  path the credentials go only to a guest that passed its boot self-test or attaches to one whose
  current boot did (the accepted trade-off Container mode's per-session exec makes too).
- **What `up --macos` delivers:** the non-secret `~/.augur-env`, no credential and no git helper.
  It still resolves and validates, so a value the next session would refuse fails `up` before the
  clone.
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
  the test config's absolute `Include` as described; end-to-end delivery (the session's
  `SendEnv` values and git's `GIT_CONFIG_*` set present in `claude --macos` / `shell --macos`,
  absent from a plain `ssh`); the temp-file cleanup's `mktemp /tmp/…XXXXXX` and
  `find … \( -mmin +1 -o -newer … \)` under the guest's zsh and BSD userland; that the VM's
  `run.pid` keeps one value for the whole boot, and that `ps -o lstart=` under `TZ=UTC0` prints the
  same start time for that process for the whole boot, across host sleep and clock syncs (the
  record of a passed self-test relies on both; a change would refuse sessions until
  `up --macos`, never admit one);
  and that the guest's `sudo -S -k` takes only the password line from the root-script stdin, and
  that the guest's `/bin/sh` `read` loop and `sh -s` leave the rest for the script, with and
  without the build's NOPASSWD grant.
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
disk if that keychain is unlocked. The reset is the first of the two `GIT_CONFIG_*` entries the
session's remote command exports (an empty `credential.https://github.com.helper` value); those
lines hold only the `$GH_TOKEN` reference, and the token itself reaches the helper from the
session's environment. `tests/35_macos_gitconfig_helper.sh` pins the reset against real git, with
`GH_TOKEN` set the way the session ssh sets it and the exports run the way the session runs them.

The set is exported only by the remote command of an augur session that sends `GH_TOKEN`, never
from `~/.augur-env`. A shell that only sources `~/.augur-env` (the VM's GUI Terminal, a hand-run
`ssh`) would otherwise get the reset plus a helper with no token: git's own helpers cleared,
`password=` answered, and HTTPS git failing with a 401 and no prompt (reproduced with git 2.53).
Those shells keep git's normal helpers; tests 35 and 56 pin both sides. Accepted trade-off: the
exports run in sshd's shell, after its startup files and before the login zsh the remote command
starts sources its own, so a `GIT_CONFIG_*` that a guest startup file exports (`/etc/zshenv`,
`~/.zshenv`, `~/.zprofile`, `~/.zshrc`) replaces augur's set, reset included. Moving the exports
after the login zsh's startup files (into the agent's `zsh -l -c '…'`) was considered and
deliberately not done: every zsh the agent starts to run a command reads `/etc/zshenv` and
`~/.zshenv` again (and, as a login or interactive shell, the other files), so git run there, where
pushes happen, would still see the startup file's set; and the interactive `shell --macos` has no
point after its startup files at which augur could run a command, short of replacing those files
(a `ZDOTDIR` redirect), which is not worth it for a set the operator chose to export.

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
- **Stage the drop-in's root script in the guest user's home, then `sudo -S sh <file>` over a
  second connection.** Keeps the password the only thing on sudo's stdin, but any process of the
  guest user can replace the file between the two connections and run as root in the future base.
- **Tie the passed-self-test record to the `run.pid` pid alone.** A recycled pid (a hand-started
  `augur-vm run` after a host crash) would match an old record.
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
- A running VM whose `up --macos` was interrupted before the self-test, or one booted outside
  augur, gets no session until an `augur up --macos`, which re-runs the self-test on the running VM
  and records it (a restart works too). Running VMs booted before this record
  existed are refused once the same way. An `up --macos` that cannot read the VM's run id after a
  passed self-test fails and stops the VM (clone kept).
- `build` / `update --macos` fail without saving a base whose sshd no longer accepts the session
  credentials at the end, or whose drop-in no longer holds the line its clones check for, even if
  the drop-in installed earlier in the run.
- A plain `ssh` into the guest, or its GUI Terminal, gets neither credentials nor git's helper set.
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
