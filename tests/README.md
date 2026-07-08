# augur tests

Automated checks for the **agent ACL seam** (`docs/swappable-agent-abstraction-design.md`).
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
| `00_seam_unit.sh` | nothing | Every pure `agent_*` function emits its expected DATA (byte-equivalence floor). |
| `11_construct_container.sh` | nothing | The **real** `cmd_up` / `cmd_claude` build the expected `container run` / `container exec` argv from the seam — auth env (named-only), cwd-keyed history mount, fixed env, launch argv. Also covers the pre-Option-A flat-history migration. Uses a `container` **shim**, so no runtime. |
| `21_container_live.sh` | Apple Container (macOS 26+) | The built image actually runs the agent; auto-skips unless the `container` CLI + service are present, so it's a no-op on Linux/CI and macOS < 26. `AUGUR_TEST_LIVE=1` adds a real `up → exec → down` lifecycle. |
| `22_egress_failclosed.sh` | Apple Container (macOS 26+) + `bash install` + built image | **The security layer** (a LOCAL gate — Apple Container has no free CI runner). Brings up egress mode (firing augur's boot self-test `verify_egress_locked`) and asserts the agent's only way out is the allowlist proxy: allowlisted domain reachable **via the proxy**, non-allowlisted **blocked (403)**, external **DNS does not resolve**, **direct** egress **severed**. `AUGUR_TEST_LIVE=1` runs it (skips if a prereq is absent); **`AUGUR_TEST_REQUIRE_EGRESS=1` makes a missing prereq a FAILURE, not a skip** — a security check must fail closed. |
| `30_macos_vm.sh` | (guards: nothing) / macOS host | Source guards: the macOS launch/state paths consume the seam (no re-hardcoded `claude`). Live smoke is gated on macOS + `augur-vm` + `AUGUR_TEST_LIVE=1`. |

`tests/e2e_macos_vm.sh` is **not** an `NN_*` tier (so `tests/run.sh` never picks it up): it's
the LOCAL pre-release gate behind `make e2e` — it boots a macOS VM and runs `xcodebuild test`
inside it, which no GitHub-hosted runner can do. See the repo README "Pre-release gate".

## How the offline construction test works

`11_construct_container.sh` puts `tests/shims/` first on `PATH`, so augur calls our fake
`container` (and `gh`). The shim fakes just enough preflight (`system status`, `image
inspect`, `inspect`) for augur to reach the real `container run` / `container exec` it
constructs, then records that argv to `$AUGUR_TEST_SHIMLOG.{run,exec}` for assertions.
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
