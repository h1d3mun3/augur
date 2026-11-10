# augur tests

Automated checks for the **agent ACL seam** (`docs/decisions/0003-swappable-agent-abstraction.md`).
They replace the by-hand `chk` runs: the goal is to prove the refactor stays
**byte-identical** — the seam emits the right data, and augur builds the right
`container run` / `container exec` / macOS-launch commands from it.

## Run

```bash
tests/run.sh          # everything; tiers self-skip when their prereqs are absent
tests/run.sh 11       # just the script(s) whose name matches "11"
```

Exit code is non-zero **iff** an assertion FAILED. Skips never fail the run, so the
same command is safe in CI, the Linux dev container, and on a macOS host.

## Tiers

| File | Needs | What it proves |
|---|---|---|
| `00_seam_unit.sh` | nothing | Every pure `agent_*` function in `agents/claude.sh` emits its expected DATA (byte-equivalence floor). |
| `54_agent_seam_leak_unit.sh` | nothing | No Claude / Anthropic / `sk-ant` literal sits in a non-comment line of `augur` outside the agent seam file (`agents/claude.sh`), `AUGUR_AGENT_SEAM`-tagged lines and a short allowlist (help text, the `augur claude` subcommand name, the in-place tagged token validator and notice). |
| `55_agent_file_unit.sh` | nothing | The agent definition file: `augur` fails closed (non-zero, "re-run `bash install`", no engine call) when it is missing, unreadable or incomplete (an undefined accessor, an empty signing Team ID) in every entry path; the loader's required-accessor list equals the accessors `augur` calls; `bash install` ships it (agent file first, by rename) and refuses a tree without it; `augur` run through a symlink finds it; the constructed `-v` / `--dir` host paths never expose the install dir or `agents/`. |
| `56_macos_session_credentials.sh` | nothing | macOS `claude` / `shell` deliver the host's current credentials only as the session ssh's environment: `-o SendEnv=` for exactly the resolved names, values in that `ssh` process's environment only (an `ssh` shim records both), never on any argv, in any guest file, or in augur's other ssh calls; `~/.augur-env` (pushed on every `up` / `claude` / `shell`, atomically, mode 600, end-marker checked) holds no credential and no `GIT_CONFIG_*` helper lines (the session's remote command exports those, holding no token value, only when it sends `GH_TOKEN`), replaces one an older augur wrote, and removes stale temp files older than a minute or dated more than a minute ahead of the guest clock (a concurrent push's fresh file stays; old ones still go when the guest's `mktemp` fails); the base VM build/update write the sshd `AcceptEnv` drop-in (rolled back if `sshd -T` does not confirm it; its root script sent with the sudo password on one ssh stdin, nothing staged, the password never run or printed) and re-check it last before the save (with the clones' own exact-line check too), and a guest without it, or with other names, is refused with the remedy (also when a later step of that push fails), gets no session, and has an older augur's credential lines removed in the same push; a bad or unreadable credential, or a push that fails twice (a dropped connection or failed write is tried once more, a refusal never), aborts before any session (on a running VM after only the push of `~/.augur-env`); a VM with no SSH transport gets no push, the message says so and nothing is retried; a session whose guest drops a sent credential never starts (exit 197 read as that only when a check was sent, the message naming the status and `up --macos` before a recreate); a running VM whose current boot (pid plus start time, read in UTC) has no record of a passed self-test gets no session, only the refusal's credential-free push of `~/.augur-env`, and the refusal names `up --macos`; the value sent is the value validated; every path launches once and pushes once when nothing fails (on a boot, the push that carries the acceptance check); `setup-token` gets nothing. |
| `57_macos_managed_settings_unit.sh` | nothing (the tiers that run the root script need unprivileged user + mount namespaces and overlayfs; skipped elsewhere) | The base VM build/update install the managed agent policy as one root script over one ssh connection (`macos_run_root_script`), with nothing staged in the guest user's home, run as the guest by `bash --posix` with the script's bytes unchanged. The whole policy directory is replaced: a fresh root:wheel 755 directory (ACL stripped with `chmod -N`) holding only the policy file (root:wheel 644, no ACL, byte-exact for hostile payloads), swapped in after the old path is moved into a 700 quarantine under /var/root, which is then removed (a failed removal is only a warning naming it); the parent must be a real root-owned directory unwritable by group and others, with no ACL or only deny entries (an `ls` stand-in plays macOS's `ls -le` lines; an allow entry or an unparsable line is refused); a failure after the old directory is moved aside (also a failed check of the swapped-in one) puts it back, or names where it is when that fails. Whatever was at the path is gone and its outside targets untouched: a 777 directory with entries, a hard link, a root-owned `.managed-settings.backup/`, a directory at the target path, a regular file or a symlink (dangling or to a directory) at the directory's path. The admin password is on no argv, in no output and in no file, NOPASSWD sudo or not. ANY failure (generator, no stored password or SSH transport, wrong password, `chown`, `chmod -N`, quarantine, files not ending up root-owned) returns 1 with the guest's reason and leaves the old directory and no fresh one; build/update then stop without saving (`52_macos_setup_token_unit.sh`, with the remedy; there and in `30_macos_vm.sh`, the install runs once, before custom provisioning, whose own files in the directory survive). Success needs status 0 and the script's `AUGUR_POLICY_LIVE` report as its last line (discarded names travel base64, so none can forge a report); a deny ACL entry that denies reading is refused; an `ls -le` that fails or prints nothing is refused; entries discarded with an old directory are named. `verify_macos_managed_settings` (run by build/update after the signer check, before the sshd re-check, pinned in `30`/`52`) passes on the policy as installed with other files beside it and refuses, naming what differs, a file overwritten, loosened, removed, hard-linked or given an ACL, or a directory loosened, symlinked or given an allow ACL entry, and reports a mismatch apart from a check that could not run; in `52`, provisioning that overwrites or chmods the file stops build and update. |
| `59_macos_update_with_timeout_unit.sh` | nothing | The time bound `update --macos` puts on the agent installer and on Homebrew (`_with_timeout`, extracted from `augur`): a finished command's own status comes back and nothing is left holding its stdout; on timeout the command and everything it started are stopped (TERM, then KILL 10 s later for whatever ignores TERM) and the status is 124, even for a command that exits 0 on TERM; a child left running by a step that finished in time is ended too; a signal to the helper ends both process groups and removes its temp dir; stderr carries only what the command printed (or the helper's own message when it has no temp dir). |
| `61_bash32_portability_unit.sh` | nothing | No non-comment line of `augur`, `completions/augur.bash` or a test script uses `$BASHPID` or a `$(sh -c ... PPID)` without `exec`: under macOS's /bin/bash (3.2) the first is empty and the second names a throwaway subshell, so a test that signals "itself" signals nothing. |
| `11_construct_container.sh` | nothing | The **real** `cmd_up` / `cmd_claude` / `cmd_shell` / `cmd_setup_token` build the expected `container run` / `container exec` argv from the seam — cwd-keyed history mount, fixed env, launch argv — and credentials (named-only) reach **only** the `claude` / `shell` exec, through `--env-file <(…)`: never on any argv, never on `container run`, never on `setup-token` or augur's own execs. Also covers the absent `~/.config/gh` mount (and its one-time fingerprint recreate), rotation without recreate, the stale-running-container refusal, session-start credential validation, the Apple Container ≥ 1.0.0 floor, and the pre-Option-A flat-history migration. Uses a `container` **shim**, so no runtime. |
| `21_container_live.sh` | Apple Container (macOS 26+) | The built image actually runs the agent; auto-skips unless the `container` CLI + service are present, so it's a no-op on Linux/CI and macOS < 26. `AUGUR_TEST_LIVE=1` adds a real `up → exec → down` lifecycle, including a secrets-zero check (`container inspect` shows no credential name or value, and no `TZ`) and a live `exec --env-file <(…)` round-trip. |
| `22_egress_failclosed.sh` | Apple Container (macOS 26+) + `bash install` + built image | **The security layer** (a LOCAL gate — Apple Container has no free CI runner). Brings up egress mode (firing augur's boot self-test `verify_egress_locked`) and asserts the agent's only way out is the allowlist proxy: allowlisted domain reachable **via the proxy**, non-allowlisted **blocked (403)**, external **DNS does not resolve**, **direct** egress **severed**. `AUGUR_TEST_LIVE=1` runs it (skips if a prereq is absent); **`AUGUR_TEST_REQUIRE_EGRESS=1` makes a missing prereq a FAILURE, not a skip** — a security check must fail closed. |
| `30_macos_vm.sh` | (guards: nothing) / macOS host | Source guards: the macOS launch/state paths consume the seam (no re-hardcoded `claude`). Live smoke is gated on macOS + `augur-vm` + `AUGUR_TEST_LIVE=1`. |

`tests/e2e_macos_vm.sh` is **not** an `NN_*` tier (so `tests/run.sh` never picks it up): it's
the LOCAL pre-release gate behind `make e2e` — it boots a macOS VM and runs `xcodebuild test`
inside it, which no GitHub-hosted runner can do. See the repo README "Pre-release gate".

`tests/e2e_macos_session_credentials.sh` is not an `NN_*` tier either: it is the LOCAL, on-a-Mac
check of macOS per-session credentials (`make e2e-session-creds`), and covers what test 56 can only
stub: the base VM's real sshd drop-in and `sudo sshd -T`, the self-test record against
`augur-vm`'s real run pid, a session's delivery of a dummy `GH_TOKEN` (and git's helper set) with
nothing on the guest's disk or the host's argv, a plain ssh that gets none, the push's temp-file
cleanup, the root-script `sudo -S -k` protocol (a wrong password runs nothing), and the refusal of
a running VM with no self-test record for its boot. Run it from the augur checkout after
`bash install --here`, with a base VM built or updated by this augur and the project VM cloned
from it:

```bash
AUGUR_TEST_LIVE=1 bash tests/e2e_macos_session_credentials.sh                          # ~3–5 min
AUGUR_TEST_LIVE=1 AUGUR_E2E_DESTRUCTIVE=1 bash tests/e2e_macos_session_credentials.sh  # +4–6 min
```

Its own sessions send only a random dummy credential. The real `augur up --macos` it runs resolves
and validates the operator's credentials as every `up` does (which may raise a keychain prompt) and
sends none to the guest; like `make e2e`, it runs with `AUGUR_ACCEPT_PROJECT_CONF=1`, which approves
the project's `./.augur/allowlist.conf` and records the approval. `AUGUR_E2E_BOOT=1` lets it boot a
stopped project VM. `AUGUR_E2E_PROJECT=<dir>` picks the project (default this checkout); any other
directory also needs `AUGUR_E2E_ANY_PROJECT=1`. `AUGUR_E2E_DESTRUCTIVE=1` adds the steps that change
the VM: the drop-in moved away and back (the old-base refusal and the delivery check's exit 197),
and gvproxy stopped under the live VM (no SSH transport; recovery stops and reboots the VM, ending
this project's sessions; `AUGUR_E2E_SKIP_GVPROXY=1` leaves it out). An EXIT trap restores what it
changed and leaves the VM running, ignoring a second Ctrl-C meanwhile; an interrupted run exits
non-zero. If a restore fails, the summary prints the command to finish it
(`AUGUR_TEST_LIVE=1 AUGUR_E2E_RESTORE=1 bash tests/e2e_macos_session_credentials.sh` puts the
drop-in back).

`tests/e2e_macos_managed_settings.sh` is not an `NN_*` tier either: it is the LOCAL, on-a-Mac check
of the managed Claude Code policy in the macOS base VM (`make e2e-managed-settings`), and covers
what test 57 can only emulate: macOS's own `/bin/sh`, `ls -le` ACL lines, `chmod -N`, `mv` of a
symlink, `cmp -s -`, `base64 --decode` and `mktemp -d` as root through the real
`macos_run_root_script`; the stock `/Library/Application Support` against the install script's own
parent check; the real install script swapping a sandbox directory under `/var/root`; and the
policy the base VM holds (root:wheel 755 / 644, no ACL, one link, the bytes the host renders, no
staging or quarantine file left, the real `verify_macos_managed_settings`). It works on a throwaway
clone of the base VM (`augur-e2e-policy`, booted on NAT and deleted at the end); the base VM must be
stopped, and no project VM is touched.

```bash
AUGUR_TEST_LIVE=1 bash tests/e2e_macos_managed_settings.sh            # ~3–6 min
AUGUR_TEST_LIVE=1 bash tests/e2e_macos_managed_settings.sh --update   # +10–30 min
AUGUR_TEST_LIVE=1 bash tests/e2e_macos_managed_settings.sh --hook     # +35–90 min
```

`--update` runs `augur update --macos` first. `--hook` moves `~/.augur/provision/` and its approval
record aside, runs an update whose hook adds a file beside the policy (it must succeed and keep the
file) and one whose hook overwrites the policy (it must fail and save nothing), puts your own
provisioning back, and ends with a clean update that discards the test file; your own provisioning
must already be approved. An EXIT trap deletes the clone and puts `~/.augur/provision/` back; after
an interrupted run, `--restore` does that.

## How the offline construction test works

`11_construct_container.sh` puts `tests/shims/` first on `PATH`, so augur calls our fake
`container` (and `gh`). The shim fakes just enough preflight (`system status`, `image
inspect`, `inspect`) for augur to reach the real `container run` / `container exec` it
constructs, then records that argv to `$AUGUR_TEST_SHIMLOG.{run,exec}` for assertions. For every
`--env-file P` it also appends P's content to `$AUGUR_TEST_SHIMLOG.envfile` (it reads the
`/dev/fd/N` pipe while it runs), so a test can see what a session received without the values
being on the argv. `AUGUR_TEST_CONTAINER_VERSION` overrides its `--version` (default 1.4.1), and
the `gh` shim prints `AUGUR_TEST_GH_TOKEN` for `gh auth token` when set.
Egress is turned off (`--no-egress`) so no proxy/network is needed. This is the design
doc's "verify the constructed argv is byte-identical" check (§5 DoD) without a live
container.

## Opt-in live runs

```bash
AUGUR_TEST_LIVE=1 tests/run.sh 21     # real container up/exec/down in a temp project
AUGUR_TEST_LIVE=1 tests/run.sh 30     # macOS only
AUGUR_TEST_LIVE=1 tests/run.sh 22     # egress fail-closed E2E (skips if a prereq is absent)

# CI runs the egress tier fail-closed (a missing prereq FAILS instead of skipping):
AUGUR_TEST_LIVE=1 AUGUR_TEST_REQUIRE_EGRESS=1 AUGUR_ACCEPT_PROJECT_CONF=1 tests/run.sh 22
```
