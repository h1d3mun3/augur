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
- **IP-literal / ECH direct-connect blocked.** IP literals are denied
  unconditionally — the pin table that could re-allow a recently-resolved IP is a
  tested-but-unwired scaffold (no production datapath populates it; see addendum
  A4), so the decision is fail-secure. Docker DNS points at TEST-NET
  (`192.0.2.1`) so DNS exfil fails closed.
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

---

# Addendum — Guest→Host (Axis B) audit, 2026-06-28

A second pass focused exclusively on **Axis B** (the disposable, possibly
prompt-injected guest attacking the trusted single-user host). Method: a
component-by-component read of the whole codebase (the `augur` driver,
`augur-proxy`, the gvproxy fork patch, `augur-vm`, the Dockerfile/topology, and
`install`), with every candidate finding run through an adversarial
three-lens verification (exploitability, premise-fit, claim-correctness) that
defaulted to *refuted*. Six items survived; the notable refutations are recorded
below so they need not be re-investigated.

**Headline:** no host RCE, no VM/container escape, and no direct egress-allowlist
bypass were found. The containment core (`Allowlist`/`SNI`/`Filter`, the
fail-closed `augur-vm` networking, the gvproxy DNS gate + `--deny-direct`, and
the `publicOnly` SSRF guard) holds, and the M2/M3 fixes are complete in the
driver. What survived are **two operator-trust breaks (High)** and **one
lateral-persistence channel (Medium)** — all squarely Axis B.

New finding IDs are `A1`–`A6` (severity is stated per finding, not implied by the
letter, unlike the M/L scheme above).

## Priority

| Finding | Severity | Axis | Class | One-line |
|---|---|---|---|---|
| **A1** — `.augur.conf` terminal-escape injection spoofs the L1 approval UI | **High** | B | operator-trick → egress break | The operator approves an egress domain they were prevented from seeing. |
| **A2** — `setup-token` runs a guest-writable `claude` binary on the operator's TTY | **High** | B | operator-trick → lateral-persist | A trojaned guest `claude` can phish the token the host then persists and re-injects everywhere. |
| **A3** — Docker history dir lives inside the host's `~/.claude/projects` tree | **Medium** | B | lateral-persist | Guest-forged transcripts become trusted context for a host-side Claude resume. |
| **A4** — IP-literal pin path is dead code | Low | — | doc/fail-secure | IP literals are *unconditionally* denied; the documented pin mechanism does not exist. |
| **A5** — short Ethernet frame panics gvproxy | Low | B | self-DoS | A root guest can crash its own egress datapath; no escalation. |
| **A6** — `publicOnly` SSRF guard confirmed on; minor `isPrivate` gaps | Info | B | egress | Strength confirmed; `224/4` and `192.88.99/24` uncovered but not exfil-routable. |

Net priority: **A1**, then **A2**, then **A3**. A4–A6 are defense-in-depth.

## Findings

### A1 — Project `.augur.conf` terminal-escape injection spoofs the L1 approval UI (High, Axis B)

`augur:399-404` (`check_project_conf_approved`), and the same data in
`augur:907` / `augur:1522` (`status` / `status --macos`).

The guest writes `./.augur.conf` through the read-write workspace mount.
`project_conf_domains()` (`augur:354-356`) only runs `sed 's/#.*//'` plus an awk
whitespace trim — it strips ASCII spaces/tabs/comments but **not raw control
bytes (ESC `0x1b`)**. The approval loop then renders each line with
`echo -e "    + ${d}"`, which emits those bytes verbatim to the operator's real
terminal.

Attack: ship a `.augur.conf` with two lines — `evil-exfil.com`, then
`\e[1A\e[2K\e[G` followed by `api.github.com`. On `augur up`, the cursor-up +
erase-line sequence overwrites the printed `evil-exfil.com`, so the operator
visually sees only `+ api.github.com`, approves, and the TOFU hash plus the
merged allowlist (`write_merged_allowlist` `cat`s the raw file) both now contain
`evil-exfil.com`. The proxy parses `evil-exfil.com` as a clean LDH host and
**allows** egress to it (the escape-laden line is non-LDH and is silently
dropped by the proxy). `augur status` pipes the same raw bytes through `echo -e`,
so post-hoc inspection is spoofable too.

This defeats the one thing L1's display exists to provide — letting the operator
*see* what they authorize — so the guest obtains egress to an arbitrary
attacker-chosen host: a containment break, not merely a cosmetic glitch.

**Fix:** in `project_conf_domains`, drop non-printing bytes and reject any line
that is not a strict LDH hostname (mirror `isValidHostname`), so a non-hostname
line is removed rather than rendered. Print with a non-interpreting
`printf '    + %s\n' "$sanitized"` (never `echo -e` on raw guest bytes) in both
the approval prompt and `status`. Optionally have `write_merged_allowlist` also
drop non-LDH lines so "what was shown" == "what is allowed".

### A2 — `setup-token` runs a guest-controlled `claude` binary attached to the operator's TTY (High, Axis B)

`augur:843-855` (`cmd_setup_token`, `docker exec -it … claude setup-token`) and
`augur:1436-1448` (`cmd_setup_token_macos`, `ssh_macos -t … 'claude setup-token'`).

In Docker the `claude` binary is installed to `/home/dev/.local/bin/claude`
**owned by uid 1001 (the `dev` user the agent runs as)** and first on `PATH`
(`Dockerfile:27-34`); in macOS the guest is `admin`/`admin` and `claude` lives in
the guest-writable `~/.local/bin`. A prompt-injected agent can therefore replace
that binary. `setup-token` attaches it to the operator's real terminal as a
full-screen TUI.

A trojaned `claude setup-token` can render a convincing sign-in screen that
substitutes an attacker's OAuth/device-code URL (or uses escapes to hide the real
prompt), so the operator authorizes a flow the attacker initiated. Back on the
host, `read -rp … token` accepts whatever is pasted after only a `sk-ant-*`
prefix check (`save_oauth_token`, `augur:182-190`) and writes it to
`~/.claude_code_oauth_token`; augur then injects it as `CLAUDE_CODE_OAUTH_TOKEN`
into **every** future `up`, in **every** project (`augur:759-761`, `1382`). The
attacker-backed credential thus persists across the disposable-guest boundary and
re-enters all future guests.

**Fix:** don't run the guest's `claude` against the operator's TTY for a
security-sensitive token flow. Verify the binary's provenance before exec (the
macOS *build* does `codesign … | grep Anthropic`; the Docker image does not check
at run time and the binary is guest-writable), make the image's `claude`
root-owned and read-only, and run `setup-token` only against a freshly recreated
guest so a tampered binary from a prior session cannot persist. Tighten
`save_oauth_token` validation and warn against pasting attacker-supplied values.

### A3 — Docker history dir lives in the host's `~/.claude/projects` tree (Medium, Axis B)

`augur:770-772` (mount), `Dockerfile:45-46`.

The Docker history mount is `~/.claude/projects/-workspace-<slug>` —
**inside the host's own global Claude Code projects tree**. (macOS mode was
relocated by M2 to `~/.augur/claude-projects/<vm>`, *outside* `~/.claude`; Docker
was not.) The guest (uid 1001) can write forged `*.jsonl` transcripts there
(fabricated user/assistant/tool-result turns with embedded instructions). Because
the directory is a real entry under the host's `~/.claude/projects`, host-side
Claude Code enumerates and parses it (session list / resume picker); if the
operator ever resumes that session on the host, the guest-authored content loads
as trusted prior context into a host agent that holds the operator's real
credentials and unconfined filesystem access.

This is a lateral move from the disposable guest into a higher-privilege host
agent, exceeding the intended "persist *this project's* history" grant (faithful
round-tripping of the guest's own conversation, not guest-forged context a host
agent trusts).

**Fix:** mirror the macOS fix — persist Docker history under
`~/.augur/claude-projects/<slug>` (outside `~/.claude/projects`) and bind-mount
that, or persist via host-mediated copy-back (`rsync`) on `augur down` so the
guest never holds a live FD into the host's Claude tree. At minimum, document
that the operator must never run host-side Claude Code in `/workspace-<slug>` or
resume an augur project's session on the host.

### A4 — IP-literal pin path is dead code (Low; fail-secure, doc divergence)

`PinTable.swift` (`PinTable.pin(...)` has no production caller); `Filter.swift:41-49`.

The "Strengths" note above states IP literals are allowed only via the pin table
(IPs the filtering DNS handed out for an allowed name). In fact `PinTable.pin(...)`
is called **only from XCTest**; no production code populates it (`augur-proxy` has
no DNS responder, and gvproxy's Go DNS is a separate process with no channel to
the in-memory `PinTable`). So `Filter.decide`'s pin branch always returns nil and
**every IP-literal connect is unconditionally denied** — fail-secure, *more*
restrictive than documented. The risk is purely the divergence: a future change
that wires DNS→pin without re-validating could silently open IP-literal egress.

**Fix:** either remove `PinTable` and the pin branch (and update the Strengths
note to say IP literals are unconditionally denied), or wire the pin design
correctly (have the datapath's resolver populate it) while keeping the by-name
re-validation. Reconcile the doc either way.

### A5 — Short/truncated Ethernet frame panics gvproxy (Low, Axis B; self-DoS)

Upstream `pkg/tap/switch.go` `rxBuf`, reachable via the `--listen-vfkit`
datapath the fork relies on.

`rxBuf` casts the received buffer to `header.Ethernet` and reads
source/destination/type without checking `len(buf) >= 14`. A root guest emitting
a deliberately truncated frame triggers an index-out-of-range panic with no
`recover()`, crashing the gvproxy process. Impact is bounded and self-inflicted:
the guest knocks out **its own** egress datapath; no host code execution, host
write, or egress past the allowlist. It is an upstream robustness gap, but it is
reachable specifically because `--deny-direct` makes gvproxy the sole datapath.

**Fix (optional, in the fork patch):** length-check before the `header.Ethernet`
casts in `rxBuf` and/or wrap the rx loop in `recover()` so a malformed guest
frame cannot crash the whole proxy.

### A6 — `publicOnly` SSRF guard confirmed on; minor `isPrivate` gaps (Info, Axis B)

`SocketIO.swift` `isPrivate`/`isPrivateV4`/`connect`; `augur:454`, `augur:545`.

Confirmed strength: `publicOnly` defaults true and augur never passes
`--allow-private` (host proxy `augur:454`; Docker sidecar `augur:545`), so the
SSRF guard is armed in both modes. `connect` checks `isPrivate` on the actual
resolved address it then dials (no TOCTOU, no fall-open), blocking
`169.254.169.254`, `0/8`, `10/8`, `127/8`, `172.16/12`, `192.168/16`,
`100.64/10`, `::1`, IPv4-mapped/NAT64/`fe80::/10`/`fc00::/7`/multicast, and
refusing unknown families — so an allowlisted name rebound to a host-local IP is
blocked. Gaps (not exfil-routable, no host gain): IPv4 multicast `224.0.0.0/4`
(`224–239`) and `192.88.99.0/24` (6to4 anycast) are not in `isPrivateV4`.

**Fix (optional, completeness):** add `224.0.0.0/4` and `192.88.99.0/24` to
`isPrivateV4`. Not a containment hole.

## Additional observation — basename-only project slug collision (Low footgun)

`workspace_slug` derives solely from `basename(cwd)` (`augur:87-91`), and that
slug keys the container name, the Claude history dir, the egress proxy
ports/allowlist, **and** the `.augur.conf` approval-hash file
(`project_conf_hash_file`, `augur:361-364`). Two different host directories with
the same basename (e.g. a hostile `~/Downloads/app` and a trusted `~/src/app`)
therefore share all of those namespaces. Mixing in a hash of the full path would
remove the collision. Not run through full Axis-B verification; recorded as a
hardening note.

## Checked and refuted (do not re-investigate)

- **`.augur.conf` symlink → arbitrary host file read** (0c/3r): the target's
  contents land only in the host-side merged allowlist, which the guest cannot
  read back — not an exfil channel. (The displayed contents are still subject to
  A1's escape-injection concern, handled there.)
- **virtiofs share symlink escape** (0c/3r): VZ confines the share root; no
  host-side following was exploitable.
- **`DHCPLeases.ip` returns the lease IP unvalidated** (0c/3r): the file is
  written by macOS `bootpd` (root), not guest-injectable, and the consumer uses
  it as `admin@${ip}` where an injected value cannot become an ssh option.
- **macOS SOCKS peek re-dial desync** (refuted): a spoofed SNI/Host cannot
  desync the destination (the proxy re-dials by name) — confirms the documented
  design.
- **Docker history *leaf* symlink redirects host writes** (0c/3r): no host
  process writes/reads inside that dir following symlinks out of the share
  (`mkdir -p` only).
- **L3 sidecar `0.0.0.0` bind** (refuted as Axis B): needs another container on
  the host bridge — Axis A (informational) on a single-user host, as already
  noted for L3.

## Status — fixes applied

A1–A6 and the slug-collision note are addressed on `fix/guest-host-audit-findings`
(`augur`, `Dockerfile`, `augur-proxy`, and the gvproxy patch). M2/M3 are unchanged
and still complete.

- **A1** — a new `conf_line_valid` validates every `./.augur.conf` line against the
  proxy's grammar (optional `*.`/`.` prefix + strict LDH host, **no byte outside
  `[A-Za-z0-9.*-]`**); `project_conf_domains` now drops any line that fails it, so
  escape/control bytes can never reach the terminal. The approval prompt and
  `status` render with `printf '%s'` (not `echo -e`) and report the count of
  dropped lines as a red flag. `write_merged_allowlist` writes the **sanitized**
  project patterns into the host allowlist, so "what the operator saw" == "what the
  proxy honors". Verified: a conf carrying a hidden `\e[1A\e[2K` line drops that
  whole line (0 ESC bytes reach output) while clean LDH patterns pass unchanged.
- **A2** — `setup-token` no longer trusts the guest's `claude` blindly. Docker:
  the image pins `DISABLE_AUTOUPDATER=1` and augur refuses to run if the
  container's `claude` differs from the image's pristine copy
  (`verify_docker_claude_pristine`). macOS: augur refuses unless the guest binary
  is Anthropic-signed (`verify_macos_claude_signed`). Both modes show a security
  notice before the paste, and `save_oauth_token` now enforces length + a
  token-safe charset (no whitespace/control bytes). Residual: a fully host-side
  token flow would remove the guest-TTY trust entirely — noted as further work.
- **A3** — Docker history now persists under
  `~/.augur/claude-projects/<slug>-<path-hash>` (outside `~/.claude/projects`),
  mirroring the macOS M2 layout, so host-side Claude Code never enumerates or
  resumes guest-written transcripts. The container still sees it at the cwd-derived
  path. (Pre-existing history under `~/.claude/projects/-workspace-<slug>` is not
  migrated — not destroyed, just no longer surfaced — matching how the macOS M2 fix
  handled the same move.)
- **A4** — reconciled code and docs: `Filter.decide` and `PinTable` now state that
  no production datapath populates the pin table, so IP-literal connects are denied
  **unconditionally** (fail-secure); the by-name re-validation is retained so a
  future DNS→pin wiring stays safe. The "Strengths" bullet above is corrected.
- **A5** — `gvproxy/augur-egress.patch` gains a hunk guarding `switch.go`'s
  `rxBuf`: a runt (sub-14-byte) guest frame is dropped instead of panicking the
  un-recovered rx goroutine. Verified the full patch still applies cleanly against
  the pinned upstream commit (`git apply --check`). (Go toolchain absent here, so
  not compile-tested; the change is a length guard using the already-imported
  `header.EthernetMinimumSize`.)
- **A6** — `isPrivateV4` now also rejects `224.0.0.0/4` (multicast) and
  `192.88.99.0/24` (6to4 anycast), and treats all of `240/4`+`255/8` as non-public
  (the prior `case 255` shadowed the reserved-range default). `publicOnly` stays on
  in both modes. `swift build` + `swift test` pass; this branch also fixes a
  pre-existing `testPinExpiry` timing bug (it advanced the clock past `ttl+grace`
  but not past `pin()`'s `max(ttl,30)` floor, so the pin had not yet expired —
  unrelated to A6).
- **slug collision** — the `.augur.conf` approval fingerprint
  (`project_conf_hash_file`) and the Docker history dir are now keyed on the full
  workspace path (`<slug>-<path-hash>`), so a hostile repo sharing a basename with a
  trusted project can neither inherit its egress approval nor cross-contaminate its
  history. **Residual (documented):** the container/VM names, egress ports, and the
  macOS project-VM identity remain basename-keyed, so two *simultaneously* running
  same-basename projects still collide there — a functional limit (both are the
  operator's own), not an Axis-B escalation; changing them would orphan existing
  containers/VMs.
