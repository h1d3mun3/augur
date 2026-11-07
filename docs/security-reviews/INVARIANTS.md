# augur security invariants (the contract)

This is a **contract** (properties that must always hold), not a description of the
current state. Where a [snapshot](./README.md) **describes** "how it works at a point
in time," this **prescribes** "what must never break." It changes rarely.

> **Foundational principle — augur is sudo-free.** It never requires root on a production
> path. That is *why* the invariants below are enforced with unprivileged mechanisms, and
> why some risks are documented-and-accepted rather than closed by taking privilege. Before
> proposing "just use sudo/`pf` here," read
> [`decisions/0001-sudo-free.md`](../decisions/0001-sudo-free.md).

## Operating rules

- A normal security fix only needs to **keep this contract green** — you do not edit
  the prose. Running the `Enforced by` tests with `swift test` (plus the boot
  `verify_egress_locked`) checks most of it **mechanically**.
- **Changing an invariant is a contract change**: update this file AND open a **new
  dated snapshot**. That is a "security-quality decision" the implementer owns, not
  "documentation cleanup."
- `Enforced by` legend: **✅ test** (enforced by a unit/self test) / **🟡 partial**
  (only partly tested) / **⚠ review-only** (prose only — can rot silently; a test candidate).

---

## Invariants

### I1. Egress fails closed on every engine  ✅ test
- **Rule:** Unreadable allowlist → refuse to start. Empty → deny all. Undecidable
  (no SNI / upstream unreachable) → deny. If the boot self-test fails, tear the **guest**
  down: on Apple Container the container (`verify_egress_locked`), on macOS the VM together
  with gvproxy and the proxy (`verify_macos_egress_locked`).
- **Why:** Prevent a misconfiguration or partial failure from "opening up." When it
  fails, it must fail to the closed side.
- **Enforced by:** `AllowlistTests.testEmptyConfDeniesEverything` / shell `verify_egress_locked()`
  (container) **and `verify_macos_egress_locked()`** (macOS VM, `augur`). Until the latter existed,
  "on every engine" held for the *policy* half on both engines but the boot tripwire was
  container-only: `verify_egress_locked` had exactly one call site (`finish_up`), which macOS mode
  never reaches, so no macOS production path ever probed the guest's network. The macOS peer now
  runs on **both** `up --macos` paths (fresh boot and the already-running reconcile) and tears the
  VM, gvproxy and the proxy down on a failure. On the already-running path it runs only when the VM
  was booted with egress on and this invocation asks for egress too: the egress mode a VM was booted
  with is recorded host-side (`macos_egress_mode_file`), and `up`/`claude`/`shell --macos` refuse a
  running VM whose record differs or is missing (`require_macos_egress_mode_current`) instead of
  attaching to it — so a VM started with `--no-egress` is never silently used by a plain
  `claude --macos` (`tests/51_macos_egress_mode_unit.sh`). `setup-token --macos` boots its throwaway
  VM through the same datapath and self-test (`tests/52_macos_setup_token_unit.sh`). Both self-tests are inherently live (they need a
  booted guest); the *wiring* — invoked on both paths, and a NOT-locked verdict exits non-zero with
  the teardown having run — is covered offline by `tests/36_macos_egress_selftest.sh`; its transport pre-check fails closed too — with the SSH forward port unreadable, teardown runs and no probe is sent (`tests/40_macos_selftest_transport.sh`). `tests/34_up_reconcile.sh` pins the **already-running** path on both engines (container reaches
  `finish_up`; macOS reaches `verify_macos_egress_locked`). `verify_egress_locked` has no offline
  test of its verdict: `tests/11_construct_container.sh` pins only its probe transport (the execs it
  issues, `/bin/sh` by absolute path, a pinned `PATH`), not the leak verdict, the teardown or the
  through-proxy requirement. Its live gate is `tests/22_egress_failclosed.sh`, and mutation testing
  confirms that deleting its fail-closed branch, or its call from `finish_up`, leaves the offline
  suite green. The two engines' halves of this invariant therefore rest on very unequal evidence.

### I2. Domain matching is label-boundary anchored  ✅ test
- **Rule:** `*.x` matches `a.x` but not `evilx`. `x` = apex only; `.x` = apex + subdomains.
- **Why:** Prevent an allowlist bypass via a suffix match (e.g. `evilgithub.com`).
- **Enforced by:** `AllowlistTests.{testWildcardSubdomainsOnly, testSubdomainBoundaryHelper, testExactHostOnly, testDotPrefixMatchesApexAndSubdomains}`

### I3. Hostnames must pass LDH validation (NUL-truncation defense)  ✅ test
- **Rule:** The allow decision and the `getaddrinfo` dial use the **same string**.
  `isValidHostname` enforces strict LDH and rejects NUL / whitespace / empty labels.
- **Why:** Prevent `evil.com\0.github.com` from being allowed by a suffix match yet dialed to a different host.
- **Enforced by:** `SecurityTests.{testHostnameValidation, testAllowlistRejectsNULInjection, testSNIRejectsNUL}`

### I4. IP-literal connects are denied unconditionally (fail-secure)  ✅ test
- **Rule:** An IP-literal destination is **never** matched by the allowlist. The pin
  table that could re-allow a recently-resolved IP is an unwired scaffold (no
  production datapath populates it — addendum A4), so the decision always falls to deny.
- **Why:** Prevent exfiltration via a direct IP-literal / ECH connection.
- **Enforced by:** `AllowlistTests.testIPLiteralsNeverMatch` / `SNIAndFilterTests.testFilterDeniesUnpinnedIPLiteral`

### I5. DNS fails closed (no DNS tunnel)  ✅ test
- **Rule:** Keep "resolvable == connectable." Apple Container uses `--no-dns` (no
  resolver in the guest), and the macOS VM uses gvproxy's `--dns-allowlist` (NXDOMAIN
  for non-allowlisted; answers only A/AAAA/CNAME queries for an allowlisted name and refuses every other record type).
- **Why:** Prevent exfiltration by smuggling data in DNS queries.
- **Enforced by:** the DNS probe in shell `verify_egress_locked()` (container, `augur`) **and the two
  DNS probes in `verify_macos_egress_locked()`** (macOS, on both `up --macos` paths): a
  non-allowlisted name must NOT resolve through the guest's own resolver stack (`dscacheutil`, i.e.
  mDNSResponder → gvproxy's DNS), and the allowlisted `_SELFTEST_HOST` MUST resolve — the pair proves
  `--dns-allowlist` is armed **and discriminating**, not merely closed. Both are live (they need a
  booted guest); `tests/36_macos_egress_selftest.sh` pins offline that a resolving non-allowlisted
  name is treated as a leak and tears the VM down. ⚠ Neither engine's `--no-dns` / `--dns-allowlist`
  argv is asserted by any test (see I8's note).

### I6. Hot reload never falls open  ✅ test
- **Rule:** If a reload of the allowlist is readable (even empty/garbage → deny all)
  it is swapped in atomically. **If it is unreadable, the previous policy is kept.** An
  in-flight request never sees a partial or widened policy.
- **Why:** Prevent egress from accidentally opening on file corruption or a transient read failure.
- **Enforced by:** `SNIAndFilterTests.{testHotReloadSwapsPolicy, testFromFileReturnsNilOnUnreadable, testHotReloadKeepsPolicyWhenFileUnreadable}`. To make "unreadable → nil → keep old policy" testable, the file load was extracted into the core lib `Allowlist.fromFile`.

### I7. The guest cannot widen its own allowlist  ✅ test
- **Rule:** The merged allowlist is written host-side at
  `~/.augur/proxy/<slug>-<workspace-path-hash>.allowlist` (**outside the project tree**). A
  `./.augur/allowlist.conf` is merged only after TOFU approval and only its sanitized domains
  (via `conf_line_valid`); and every per-project egress host-state file — merged allowlist,
  proxy/gvproxy pidfiles, logs, vfkit socket — is keyed on the **FULL workspace path**, so an
  approval granted for one project can never reach another project's enforcement point.
- **Why:** Prevent root-in-guest from rewriting the egress policy mid-session. The path-keying
  clause covers the other direction: an approval is scoped to the project it was granted for, so
  a *second* project can neither inherit that approval nor donate its own to the first project's
  live proxy. Keyed on the basename alone, `~/work/app` and `~/archive/app` shared one merged
  allowlist, and whichever ran `up` last silently rewrote the other's live policy.
- **Enforced by:** `tests/01_egress_allowlist_unit.sh` (checks `conf_line_valid`'s grammar,
  `project_conf_domains` sanitization, that `write_merged_allowlist` drops guest-supplied junk and
  writes **outside the project tree**, and that two same-basename projects write **different**
  merged allowlists neither of which contains the other's approved domains) plus
  `tests/32_proxy_per_mode.sh` (every per-project egress host-state path except the approval record
  differs between two same-basename projects while the slug is identical) plus `tests/11_construct_container.sh` and
  `tests/30_macos_vm.sh` (the workspace-containment guard `require_safe_workspace` — a workspace
  that CONTAINS `~/.augur` would put the merged allowlist itself inside the read-write share, which
  is the same widening this invariant forbids; refused on both engines by the dispatch gate for
  `up`, `claude` and `shell`, and for `setup-token` in Container mode; `setup-token --macos` is
  exempt because its throwaway VM gets no workspace share and no project conf, see
  `docs/decisions/0014-workspace-must-not-contain-augur.md`). The TOFU approval itself
  (`check_project_conf_approved`) is 🟡 partly tested: `tests/01_egress_allowlist_unit.sh` drives the
  `AUGUR_ACCEPT_PROJECT_CONF=1` accept, the non-interactive fail-closed refusal of a conf changed
  after approval, and an accept under `set -e`; the interactive `[y/N]` branch and the
  no-sha256-tool fail-closed branch are ⚠ review-only. ⚠ The full-path keying of the approval
  record itself (`project_conf_hash_file`, under `~/.augur/project-hashes/`) is asserted by no
  test: `tests/32`'s per-project path list omits it, and `tests/01`'s cross-project case cannot
  observe a shared approval record.

### I8. Keep the private-IP dial guard always armed  ✅ test
- **Rule:** Never pass `--allow-private` to `augur-proxy` on a production path. Before
  dialing, re-check the resolved `sockaddr` and block private / loopback / link-local
  / metadata destinations.
- **Why:** Prevent SSRF where an allowlisted name resolves to a LAN / host / metadata IP.
- **Enforced by:** `AddressPolicyTests` (the classification logic was extracted into the core
  lib `AddressPolicy.isPrivateV4`/`isPrivateV6` and tested directly: RFC1918, loopback, CGNAT,
  metadata 169.254.169.254, IPv4-mapped, etc. are classified non-public, while public IPs and
  each block boundary are classified public). Not passing `--allow-private` in production is a
  structural guarantee (addendum A6) — ⚠ **grep-only**: no test asserts `start_proxy`'s argv, and
  inserting the flag into `start_proxy`'s `augur-proxy` argv leaves the entire offline suite green.
  The same gap covers `start_gvproxy`'s `--socks-upstream` / `--dns-allowlist` / `--deny-direct` and
  the containment argv of `container run` (`--network`, `--cap-drop NET_ADMIN`, `--no-dns`, and the
  `--internal` network created by `ensure_egress_network`). A one-line source guard per call site — the `grep -Eq … "$AUGUR"`
  shape `tests/30_macos_vm.sh` already uses for the read-only profile share — would close all of them
  cheaply.

### I9. macOS guest network isolation  🟡 partial
- **Rule:** The guest's NIC is a **single** host-owned socket (`VZFileHandleNetworkDeviceAttachment`).
  No NAT/bridged device and no second NIC is added. The only entitlement is
  `com.apple.security.virtualization`. The gvproxy patch drops UDP/ICMP and forces all TCP
  through the SOCKS allowlist.
- **Why:** Physically remove any path for the guest to bypass the proxy.
- **Enforced by:** the entitlement set (does **not** request `com.apple.vm.networking` = no
  bridged networking) is checked by `tests/30_macos_vm.sh` (✅). The **gvproxy UDP/ICMP drop is now
  checked live on every `up --macos`** by `verify_macos_egress_locked`'s `dig @1.1.1.1` and `ping`
  probes — an answer or a reply is a leak and tears the VM down — with
  `tests/36_macos_egress_selftest.sh` pinning that verdict offline and
  `tests/38_macos_guest_clock.sh` pinning that the gvproxy patch still registers the UDP forwarder
  only in the absence of `--deny-direct`. The **live NIC count** still needs a real VM host and
  stays ⚠ review-only; nothing asserts `config.networkDevices = [network]`.

### I10. Do not expose credentials on argv  🟡 partial
- **Rule:** No injected agent or gh credential (`agent_auth_specs` values, `GH_TOKEN`) is ever
  placed on a command line. In macOS VM mode they reach the guest only as the environment of the
  interactive ssh that starts `augur claude --macos` / `augur shell --macos`
  (`ssh_macos_session`): a subshell `export`s the values (a builtin, no argv) and execs that one
  `ssh`, which names exactly the resolved variables with `-o SendEnv=<NAME>` (never
  `-o SetEnv=NAME=value`, which would be argv); the guest's sshd accepts exactly those names through
  a root-owned drop-in the base VM build/update writes (`install_macos_session_env_acceptance`), and
  a guest without it is refused before any credential is sent (`macos_session_env_check_cmd`).
  They are never written to the guest's disk: `~/.augur-env` (`push_macos_guest_env`) holds only
  non-secret per-VM env, and augur's other ssh calls (`ssh_macos`) carry no `SendEnv`. In Container
  mode credentials are never passed to `container run` at all; they reach only the `container exec`
  that starts `augur claude` / `augur shell`, through `--env-file <(…)` written by the bash builtin `printf`
  (`session_credential_env`). `augur setup-token` and augur's own execs get none. In macOS VM mode
  `augur setup-token --macos` never uses the project VM: it runs in a throwaway clone of the base VM
  that receives no `~/.augur-env`, no `GH_TOKEN`, no git config and no share, and is deleted on every
  exit path. On the macOS host the values sit in that one `ssh` process's environment for the life
  of the session; macOS serves a process's environment only to its own user and root, who can
  already read the host files and `gh` token they come from.
- **Why:** Prevent a co-resident process from reading credentials via `ps` / `/proc`. In Container
  mode, keeping them off `container run` also keeps them out of the container's persisted config
  (plaintext in the container bundle, printed by `container inspect`); in macOS VM mode, keeping
  them out of `~/.augur-env` keeps them off the clone's disk, which `down --macos` persists.
- **Enforced by:** Container mode ✅ `tests/11_construct_container.sh` via the `container` shim:
  the `run` argv carries no credential name or value, no `GH_TOKEN` and no `GIT_CONFIG_*`; the
  `claude` / `shell` exec carries `--env-file` whose captured content holds the credentials while
  no engine argv holds a value; `setup-token` and the profile/history execs carry no `--env-file`.
  `tests/21_container_live.sh` (live, `AUGUR_TEST_LIVE=1`) additionally checks `container inspect`
  shows no credential. macOS mode: `tests/56_macos_session_credentials.sh` asserts, through a
  recording `ssh_macos` and an `ssh` shim on PATH, that the `claude` / `shell --macos` session ssh
  carries `-o SendEnv=` for exactly the resolved names with the values only in its own environment,
  that no value is on any ssh/scp argv, in any guest file (`~/.augur-env` included) or (for
  file- and `gh`-sourced values) in any other ssh call's environment, that the build/update write
  the `AcceptEnv` drop-in, and that a guest without it gets no session. That the real guest sshd
  honours the drop-in and the guest's process list stay ⚠ review-only (Mac-only). `tests/52_macos_setup_token_unit.sh` asserts that no credential value (API
  key, OAuth token file, gh token) and no `~/.augur-env` / `~/.gitconfig` reaches the throwaway VM
  of `setup-token --macos`.
- **Note:** The rule does not cover the macOS guest's admin password (`macos_admin_password`),
  but it is kept off argv the same way: every guest `sudo -S` call gets it on ssh's stdin via
  `macos_admin_password_stdin` (the bash builtin `printf` piped into `ssh_macos` /
  `ssh_macos_provision_stdin`), so it is on neither the host's local `ssh` argv nor the guest's
  process list. `tests/44_macos_sudo_password_stdin.sh` asserts this through a recording `ssh`
  stub, plus a source guard that every `sudo -S` in `augur` is fed that way. This closes item 44
  of [`2026-09-24-egress.md`](./2026-09-24-egress.md) ("[LOW–MEDIUM; STILL OPEN]" there). The
  first-boot SSH login in `ssh_macos_bootstrap` hands the password to OpenSSH through a 0700
  `SSH_ASKPASS` helper file, also not argv.

---

> Of the 10, I1–I8 are enforced by tests/self-tests; I9 is partial (entitlement only); I10 is
> partial (Container mode test-enforced, plus the macOS session ssh's argv and environment and
> `setup-token --macos`'s credential-free throwaway VM).
> The remaining review-only surface is the rest of the macOS half of I10 (a real guest sshd
> honouring the `AcceptEnv` drop-in, and a real guest's process list), the hardware-dependent part of I9 (the live NIC count — the gvproxy UDP/ICMP drop is now probed
> live on every `up --macos`), and two gaps inside I7 (the TOFU gate's interactive and no-sha256
> branches, and the approval record's full-path keying). Note that "enforced by tests" does not extend to augur's own
> argv for I5 and I8: see their notes. For background on each item, see the newest
> [review snapshot](./README.md).
