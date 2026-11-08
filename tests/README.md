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
| `57_macos_managed_settings_unit.sh` | nothing (the tiers that run the root script need unprivileged user + mount namespaces, `unshare -rm`; skipped elsewhere) | The base VM build/update install the managed agent policy as one root script over one ssh connection (`macos_run_root_script`), with nothing staged in the guest user's home, run as the guest by `bash --posix` with the script's bytes unchanged: the payload arrives byte-exact, base64-encoded in a quoted heredoc (quotes, `$`, backslashes, NUL and control bytes, the marker line, the heredoc delimiter and the root script's own text, with or without trailing newlines), lands root:wheel and mode 644 by rename from a temp file in a target directory made root:wheel 755, from which every entry not owned by root, every symlink and every group- or other-writable entry is removed and named (root's own entries are kept; a second namespace mode plays files owned by another user); a symlinked target directory, or a target that is a root-owned directory, is tampering: the install returns 1 and build/update stop without saving (also in `52_macos_setup_token_unit.sh`), and the admin password is on no argv, in no output and in no written file, NOPASSWD sudo or not; a wrong password or a failed `chown` warns and continues, leaving an existing target and no temp file; a failing generator, a VM with no stored password or no SSH transport connects to nothing, and augur's own errors are never shown as guest text. |
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
