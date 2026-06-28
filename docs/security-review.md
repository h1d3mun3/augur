# augur Security Review

Scope: egress allowlist enforcement, credential handling, and host/guest
isolation across Docker mode and macOS VM mode. Reviewed the proxy core
(`augur-proxy`), the `augur` driver script, the `install` script, the macOS VM
backend (`augur-vm`), and the gvproxy egress patch.

## Threat model

augur is operated on a **trusted, single-user host** (the developer's own
machine). Guests are **disposable** — created and thrown away per project — and
some host state is **deliberately persisted across guests**: Claude Code history
(`~/.claude`, `~/.claude.json`) and GitHub auth (`~/.config/gh` + an injected
`GH_TOKEN`). Those shared paths are intended features, not leaks.

Given that, two distinct adversary axes must be kept separate, because the
premise only relaxes one of them:

- **Axis A — another user on the host reads secrets.** Largely neutralized by
  the single-user trusted host. Findings whose only victim is "some other local
  user" downgrade to informational here.
- **Axis B — the disposable guest (running a possibly prompt-injected agent)
  writes back into, or moves laterally across, the trusted host.** This is
  augur's whole reason to exist and is **not** relaxed by the premise: the
  adversary is the repo content / the agent, not another host user. Egress
  containment and the host/guest write boundary live on this axis.

Key consequence for the intended persistence channels: *every persistence
channel is also an injection channel.* The fix is never "close the channel" but
"narrow it" — persist (and read) only the **current project's** state, never all
projects or the whole auth config.

## Summary

The security core (`Allowlist` / `Hostname` / `SNI` / `Filter`) is robust and no
critical egress bypass was found. The findings below are mostly defense-in-depth
hardening. Each finding carries two severities: its **raw** severity (generic
multi-user host, fully hostile guest) and its **effective** severity under the
[threat model](#threat-model) above (trusted single-user host, disposable guest,
intentional persistence channels). The effective column is what to prioritize.

### Priority under the threat model

| Finding | Raw | Effective | Axis | Why the effective severity |
|---|---|---|---|---|
| **L1** — project `.augur.conf` widens allowlist | Low–Med | **Medium** | B | Containment is augur's reason to exist; an untrusted repo pre-authorizing egress is exactly the threat. Premise does not relax it. |
| **M3** — macOS fail-open NAT default | Medium | **Medium** | B | Egress containment is the core guarantee; unaffected by host trust. |
| **M2** — RW mounts of host dirs into guest | Medium | **Medium** | A+B | Reading *own* project state is intended (downgrades). Cross-project **read** and any **write/tamper** into the host remain — narrow to the current project, don't close. |
| **M1** — Docker secrets on `docker run` argv | Medium | **Low** | A | Only victim is another local user; single-user host neutralizes it. Cheap to fix anyway. |
| **L2** — `admin/admin` + sudo in VM | Low | **Info** | (B) | Root in a disposable VM that can't cross the VM boundary or egress is not an escalation. |
| **L3** — sidecar binds `0.0.0.0` on bridge | Low | **Info** | A | Needs another container on the host bridge; single-user host. |
| **L4** — `~/.augur-env` chmod race | Low | **Info** | A | Brief world-readable window only matters with other local users. |

Net: prioritize **L1** and **M3** (Axis B, premise-independent), then re-scope
**M2** to the current project. M1/L2/L3/L4 become cheap hygiene.

### Strengths confirmed

- **NUL-truncation defense.** The allowlist decision and the `getaddrinfo` dial
  use the same string, and `isValidHostname` enforces strict LDH so
  `evil.com\0.github.com` is rejected. Regression tests exist
  (`augur-proxy/Tests/AugurProxyCoreTests/SecurityTests.swift`).
- **Label-anchored subdomain match.** `evilgithub.com` does not match
  `*.github.com` (`Allowlist.isSubdomain` boundary `.` check).
- **IP-literal / ECH direct-connect blocked.** IP literals are only allowed via
  the pin table (IPs the filtering DNS handed out for an allowed name); Docker
  DNS points at TEST-NET (`192.0.2.1`) so DNS exfil fails closed.
- **Fail-closed throughout.** SNI parse failure, unreachable upstream, and a
  failed `verify_egress_locked` self-test all deny / tear down. The self-test
  checks direct-hostname, direct-IP, DNS, and proxy reachability.
- **macOS network isolation.** The guest has exactly one NIC, a host-owned
  socket (`VZFileHandleNetworkDeviceAttachment`) — no NAT/bridged device, no
  second NIC. Entitlements are minimal (`com.apple.security.virtualization`
  only). The gvproxy patch drops UDP/ICMP and forces all TCP through the SOCKS
  allowlist.
- **macOS credential injection is not argv-visible.** Tokens are written to
  `~/.augur-env` (chmod 600) via SSH stdin, not on a command line.

## Status — fixes applied

M2, M3, and L1 are implemented (Docker + macOS), reviewed by an adversarial
multi-agent pass (8 candidate findings, 7 refuted, 1 acted on), and bash/Swift
syntax-checked. `augur-vm` is macOS-only (imports `Virtualization`) so it must be
compiled with `swift build -c release` on a macOS host; everything else was
verified here.

- **M2** — Docker now mounts only `~/.claude/projects/-workspace-<slug>` (this
  project's history) instead of all of `~/.claude`; Claude auth is env-injected
  (`CLAUDE_CODE_OAUTH_TOKEN`/`ANTHROPIC_API_KEY`), a minimal `~/.claude.json` is
  baked into the image (no host project-list leak), and `~/.config/gh` is mounted
  read-only. macOS: `augur-vm` gained a `--dir name:path:ro` suffix; `claude-projects`
  is a per-VM dir (`~/.augur/claude-projects/<vm>`) and `gh-config` is read-only.
- **M3** — `augur-vm` networking is fail-closed: the egress-filtered socket is the
  default, unfiltered NAT requires `--net-nat`, and a run with neither a socket nor
  `--net-nat` refuses to boot. Build/base/update and the `--no-egress` path pass
  `--net-nat` explicitly.
- **L1** — a project `./.augur.conf` is gated by a SHA-256 trust-on-first-use
  record under `~/.augur/project-hashes/` (host-only, unforgeable by the guest);
  domains are shown on `up` and in `status`; `AUGUR_ACCEPT_PROJECT_CONF=1` keeps
  non-interactive/CI flows working; without a TTY it fails closed. The fingerprint
  step itself fails closed if no sha256 tool is present.
- **Follow-ups from review** — added a self-contained `GH_TOKEN` git credential
  helper to Docker mode (via `GIT_CONFIG_*` env) so HTTPS `git push` works without
  the read-only host gitconfig, and hardened the L1 fingerprint to fail closed.

## Findings

### M1 — Docker: API key / GH token exposed on the `docker run` argv (raw Medium → effective Low, Axis A)

`augur:615` and `augur:633`:

```bash
[[ -n "$anthropic_key" ]] && docker_args+=(-e "ANTHROPIC_API_KEY=${anthropic_key}")
[[ -n "$gh_token" ]]      && docker_args+=(-e "GH_TOKEN=${gh_token}")
```

The secret values become part of the `docker run` argv. While that process is
alive, any other local user can read them via `ps aux` / `/proc/<pid>/cmdline`.
The macOS path is correct (stdin → `~/.augur-env`), so only Docker mode is
inconsistent.

**Under this model:** the only victim is another local user, which the
single-user trusted host removes — effective Low. Still worth the one-line fix as
hygiene (and to match the macOS path).

**Fix:** pass by name and inherit from the environment:
`export ANTHROPIC_API_KEY="$anthropic_key"; docker_args+=(-e ANTHROPIC_API_KEY)`
(same for `GH_TOKEN`). The value never appears on any argv.

### M2 — Sensitive host directories mounted read-write into the hostile guest (raw Medium → effective Medium, Axis A+B)

- Docker `augur:618,628`: `~/.claude` (history for **all** projects) and
  `~/.config/gh` mounted read-write.
- macOS `augur-vm/Sources/augur-vm/RunSession.swift:176`: every `--dir` is
  `readOnly: false` (no read-only option exists). `~/.config/gh` (GitHub OAuth
  token) and `~/.claude/projects` (**all** projects' transcripts) are writable.

Under the "hostile root agent" threat model the guest can (a) read host
credentials and cross-project history it has no need for, and (b) tamper with
host config — overwrite `~/.config/gh/hosts.yml`, or plant files in another
project's `~/.claude/projects/<other>` that execute when the host next runs
`gh` / Claude Code. virtiofs is rooted per-share, so these two shares are the
exposure.

**Under this model:** the persistence requirement splits this finding. Reading
and writing the **current** project's history is the intended feature and is not
a finding. What remains on Axis B is (a) cross-project **read** — project A's
agent reading project B's transcripts (which may carry B's secrets), an unwanted
information flow even on a single-user host; and (b) **write/tamper** from a
disposable guest into host state it doesn't own — exactly the lateral-move /
persistence escalation the VM boundary should prevent. So the answer is to
*narrow* the channel, not close it.

**Fix:** scope the history mount to the current project
(`~/.claude/projects/<this-project>`, kept read-write — that write is the
feature) instead of all of `~/.claude`. `~/.config/gh` is already covered by the
injected `GH_TOKEN` (`augur:633`), so make its mount read-only or drop it. For a
stronger guarantee, persist history via host-mediated copy-back on `augur down`
(rsync from the workspace) so the guest never holds a live FD to `~/.claude` at
all.

### M3 — macOS: fail-open NAT default when egress is not requested (raw Medium → effective Medium, Axis B)

`augur-vm/Sources/augur-vm/RunSession.swift:115-129` / `Run.swift:22`: without
`--net-vfkit` the guest gets `VZNATNetworkDeviceAttachment()` (full unfiltered
NAT). `augur` always passes the flag when `egress_enabled`, but `augur-vm`
itself does not enforce it. A clone disk persists injected tokens in
`~/.augur-env` from prior runs, so a NAT boot = tokens + unrestricted egress.

**Under this model:** unchanged. Egress containment is the core guarantee and its
adversary is the agent, not another host user, so the trusted-host premise does
not relax it.

**Fix:** make the host-owned socket attachment the default and require an
explicit `--net-nat` to opt into unfiltered NAT (fail closed), or have
`augur-vm` refuse NAT for VMs that carry injected secrets.

### L1 — Project `./.augur.conf` silently widens the egress allowlist (raw Low–Medium → effective Medium, Axis B)

`write_merged_allowlist` (`augur:318`) concatenates the project's `./.augur.conf`
into the active allowlist with no confirmation, and `augur status` prints only
`+ .augur.conf` without the domains. An untrusted repository can authorize its
own egress (e.g. an exfil host) just by shipping a `.augur.conf`. The merge
happens on the host so the guest cannot re-widen mid-session (this part is
correct); the gap is the initial trust of repo-supplied domains.

**Under this model:** this is the most important finding and it gets *promoted*,
not relaxed. augur exists to contain a possibly prompt-injected agent, yet the
agent's own working material (an untrusted repo) can pre-authorize egress before
the agent even runs. The host being trusted does not help — the adversary is the
repo content. Trade-off to weigh: requiring confirmation on every `up` erodes the
"disposable, frictionless" workflow, so a sensible default is to *show* the added
domains loudly (and in `status`) and gate only on a first-seen / changed conf.

**Fix:** display the project-conf domains being added on `up` and/or require
confirmation; at minimum list them in `status`.

### L2 — macOS: fixed `admin`/`admin` password + agent in the admin group (raw Low → effective Info, Axis B)

After the build revokes the NOPASSWD grant (`augur:967`), the agent still runs
as `admin` (in the `admin` group) and can `echo admin | sudo -S …` with the
publicly-known password. This defeats the "agent is non-root" intent inside the
VM, though it does **not** break host isolation or egress filtering (and Docker
mode, with no sudo, is unaffected).

**Under this model:** informational. Root in a disposable VM that cannot cross
the VM boundary or escape egress is not a meaningful escalation; the guest is
thrown away. Worth doing only as cleanup.

**Fix:** set a strong random account password after key auth is established (with
a matching `kcpassword` for auto-login), or run the agent as a non-admin user;
optionally `PasswordAuthentication no`.

### L3 — Docker proxy sidecar binds `0.0.0.0` on the bridge (raw Low → effective Info, Axis A)

The sidecar runs `augur-proxy --listen 0.0.0.0 …` and is then connected to the
default bridge for egress (`augur:433` area), so any other container on the host
bridge can use it as an (allowlist-limited) forward proxy.

**Under this model:** informational — it needs another container co-located on
the host bridge to abuse, and even then only reaches allowlisted domains.

**Fix:** bind the proxy to the internal-network IP (`$AUGUR_SIDECAR_IP`) so it is
only reachable from the agent's `--internal` network.

### L4 — `~/.augur-env` create-then-chmod race (raw Low → effective Info, Axis A)

`augur:1147` writes the file (remote umask, typically 644) before `chmod 600`,
leaving a brief world-readable window on a file holding the API key / OAuth token
/ GH token. Single-user VM, so negligible.

**Under this model:** informational — the world-readable window only matters with
another local user present.

**Fix:** `umask 077` before the redirect, or write to a temp file and `mv`.

## Conclusion

Egress enforcement, macOS network isolation, and the credential-injection
mechanics hold up; no bypass was found. Re-prioritized for a trusted single-user
host with disposable guests and intentional persistence channels, the order of
real-world impact is:

1. **L1** — repo-supplied `.augur.conf` widening egress (Axis B, containment core).
2. **M3** — macOS fail-open NAT default (Axis B, containment core).
3. **M2** — re-scope the host mounts to the current project (keep persistence,
   remove cross-project read and host-tamper write).

M1, L2, L3, and L4 reduce to cheap hygiene under this model. The throughline:
the premise relaxes "another user reads my secrets" (Axis A) but not "the
disposable guest writes back into / widens its way out of the trusted host"
(Axis B) — so the egress boundary and the host write boundary stay the priority.
