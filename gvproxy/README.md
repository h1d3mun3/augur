# augur-gvproxy

The macOS egress datapath needs a user-space network stack on the host so the VM's
only NIC (a `VZFileHandleNetworkDeviceAttachment` socket) has somewhere to send its
L2 frames. augur uses [`gvisor-tap-vsock`](https://github.com/containers/gvisor-tap-vsock)
(the `gvproxy` from podman/vfkit) for that, with a small fork so that **all guest
egress is forced through `augur-proxy`'s allowlist**.

## What the fork changes

`augur-egress.patch` (pinned commit `197eea05`) adds three flags to `gvproxy`:

- `--socks-upstream host:port` — the TCP forwarder dials every guest connection
  through this SOCKS5 proxy (the host-side `augur-proxy`) by destination IP,
  instead of `net.Dial`-ing it directly. `augur-proxy` then peeks the TLS SNI /
  HTTP Host and applies the domain allowlist.
- `--deny-direct` — does not register the UDP and ICMP forwarders at all. They
  `net.Dial` directly and would otherwise be egress holes (QUIC/HTTP3 exfil, ICMP
  tunneling). With this flag, **SOCKS-filtered TCP is the only way out** — a root
  agent in the guest cannot bypass it.
- `--dns-allowlist <file>` — the gateway DNS server only resolves names matching
  this allowlist (same `.augur/allowlist.conf` grammar) and returns NXDOMAIN otherwise;
  non-address record types are refused. Makes DNS-resolvable == connection-allowed,
  closing DNS-exfil. The matcher (`pkg/services/dns/dns_allowlist.go`) is a 1:1 port
  of `augur-proxy`'s Swift `Allowlist`.

The hook is `pkg/services/forwarder/tcp.go` (the single point all guest TCP egress
funnels through); the SOCKS5 client is dependency-free (`socks_client.go`).

## How augur runs it

```
augur-gvproxy --listen-vfkit unixgram://<sock> \
              --socks-upstream 127.0.0.1:<augur-proxy-socks-port> \
              --dns-allowlist ~/.augur/proxy/<slug>-<path-hash>.allowlist \
              --ssh-port <fwd-port> --deny-direct
```

Every per-project name above is keyed on `<slug>-<path-hash>` — the project directory's
basename plus the first 12 hex of a sha256 of its FULL path — so two checkouts that share a
basename (`~/work/app`, `~/archive/app`) never share an allowlist, a socket or a pidfile
(invariant I7). `<sock>` is the one exception to the *full* slug: it is truncated to 24
characters, because a unix-socket path has only 103 usable bytes (`sun_path`) where the
neighbouring regular files have `PATH_MAX`.

`augur` starts this automatically in `cmd_up_macos` when egress filtering is on;
`augur-vm run --net-vfkit <sock>` attaches the VM's NIC to the same socket. The
guest's gateway/DNS/DHCP are served by gvproxy (fixed addressing — gateway
`192.168.127.1`, guest `192.168.127.2`).

## Build

```
bash build.sh           # → ./augur-gvproxy   (needs Go; clones the pinned commit + applies the patch)
```

`install` runs this on macOS and installs the result to `~/.augur/augur-gvproxy`.

## Threat model & known residual

A root agent in the guest is assumed to actively try to reach a non-allowlisted
host. With `--deny-direct`, the **only** egress is SOCKS-filtered TCP (verified:
UDP/ICMP forwarders are not registered; IPv6/IP-literal connects are dialed through
the SOCKS proxy and fail closed without a recoverable SNI/Host). An adversarial
review of the datapath found and fixed two would-be bypasses in `augur-proxy`
(NUL-byte SNI truncation; IPv4-mapped-IPv6 SSRF) — see `augur-proxy` `SecurityTests`.

**DNS is gated (`--dns-allowlist`):** the gateway DNS server (`192.168.127.1:53`)
only resolves names that match the allowlist — the SAME merged `.augur/allowlist.conf` used
for connections — and returns NXDOMAIN otherwise; non-address record types
(TXT/MX/NS/SRV) are refused. A disallowed query is answered locally and never
leaves the host, so the QNAME-based DNS-exfil/C2 channel is closed. The matcher is
a 1:1 port of `augur-proxy`'s Swift `Allowlist`/`Hostname` (see
`pkg/services/dns/dns_allowlist_test.go` for the parity tests). Residual: a guest
can still resolve `<data>.<allowlisted-wildcard-domain>` if the allowlist contains
a broad third-party wildcard the guest doesn't control — identical to the
connection-side exposure; mitigation is allowlist policy, not the matcher.

**Compatibility limit:** connections with no recoverable SNI/Host (ECH/ESNI,
non-TLS/non-HTTP protocols) fail closed (denied). augur's egress needs are all
HTTPS, so this is acceptable.

## Verification status

The patch builds (`go build ./cmd/gvproxy`) and `go vet` is clean. The SOCKS-by-IP
→ SNI-peek protocol it relies on is verified end-to-end against `augur-proxy` (see
the augur-proxy tests / `--socks5` live checks, including a NUL-injection exploit
attempt that is correctly blocked). The full VM integration (VZFileHandle + gvproxy
+ a booted macOS guest) has been **validated end-to-end on Apple Silicon**: an
allowlisted host is reachable, a non-allowlisted host is blocked, and SSH reaches
the VM through gvproxy's forward. (It cannot run in a Linux CI sandbox.)

## Staying current with upstream

The base is a pinned upstream commit plus a small patch, so it can silently fall
behind — and because gvproxy parses attacker-influenced guest frames on the host,
an upstream hardening fix can be security-relevant to us. Two layers watch for that:

**Automated (primary).** `check-freshness.sh` runs daily via
`.github/workflows/gvproxy-freshness.yml`. It does NOT build the binary (the real E2E
needs an Apple Silicon host) — it compares `PIN` against upstream `main`, ignores
tooling/docs/test noise, and grades what remains:

| severity | meaning | issue? |
|---|---|---|
| `ACTION`  | `augur-egress.patch` no longer applies to `main`, or applies but the patched tree fails `go vet`/`go test` | yes |
| `REVIEW`  | upstream code compiled into the binary, a module linked into it, or a `go.mod` build setting moved | yes |
| `NOISE`   | behind, but nothing that reaches the binary (`tools/`/docs/CI/tests, test-only deps) | closes the issue |
| `CURRENT` | pin is at `main` | closes the issue |

"Reaches the binary" is decided by `go list -deps ./cmd/gvproxy` for darwin/arm64 with
the augur patch applied, at both the pin and `main`:

- **Upstream's own code** counts when the changed file sits in a package directory the
  build reaches (or is embedded by one), not by folder name. If upstream moves code to
  a new directory such as `internal/`, it is covered as soon as gvproxy imports it.
- **Dependencies** count when their module is in the build graph, comparing versions.
  So a Dependabot bump of a test-only library (gomega, ginkgo) is `NOISE`, but a bump
  that drags a shipped module along (say `golang.org/x/net`) is still `REVIEW`.
- **Build settings**: changes to `go.mod`'s `go`/`toolchain`/`godebug`/`replace` lines
  are always `REVIEW`.

A patch that applies cleanly can still break: upstream may add a test or call site
that uses a signature the patch changes. So once it applies, the check runs `go vet`
for darwin/arm64 (which type-checks `_test.go` files too) and then a native `go test`
on every package the patch touches (the directories of the `.go` files it names). A
failed step is re-run on unpatched `main`: if that passes, the failure is the patch's and
the run is `ACTION`; if it fails too (a new vet check in a newer Go, a flaky upstream
test), the issue notes it without grading it, and `go test` still runs after a `go vet`
that fails on both. Either way the issue quotes the first lines of the output.

The tests are upstream's unreviewed code, so the workflow runs them in a separate job
(`patched-tests`, via `check-freshness.sh --run-patched-tests`) that has no token, no
permissions and no persisted credentials. It reports back only data: a state, the
upstream commit it tested, and the go output as an artifact. The job holding
`issues: write` (`check`, via `--use-patched-tests-result`) never runs upstream code (its
`go list` runs none). It accepts only a known state for the same upstream `main` it
resolved itself, treating anything else as "could not run", and it sanitizes and bounds
the quoted output itself. When the patched-tree check could not run (or a failed step
could not be compared with unpatched `main`), the run goes red so the missing signal is
noticed, whatever the severity.

Without a working `go` the build graph is skipped and the check falls back to paths:
any change under `cmd/gvproxy/`/`pkg/` or to `go.mod`/`vendor` counts as `REVIEW`.
The patched-tree `go vet`/`go test` is skipped as well, and the issue says it did not run.

On `REVIEW`/`ACTION` it opens or refreshes a **single** issue labelled
`gvproxy-freshness` (idempotent — no notification spam); on `NOISE`/`CURRENT` it
closes it. Do not gauge staleness by raw commit count — it is mostly `tools/vendor`
churn; the signals that matter are "does the patch still apply" and "did anything that
reaches the binary move".

Run it locally any time: `bash gvproxy/check-freshness.sh` (needs an authenticated
`gh` and Go). With no option it does both halves in one process, so `go test` runs
upstream's tests on your machine with your privileges.

**Manual (backup).** Watch <https://github.com/containers/gvisor-tap-vsock> →
**Custom → Releases + Security advisories** so an advisory reaches you even if the
keyword heuristic misses it. Note that release tags lag `main`: a security fix can sit
on `main` for weeks before it is tagged, so we pin to a `main` commit, not a release.

**Responding.** Bump `PIN` in `build.sh` to the chosen commit, re-run `build.sh`
(re-applies the patch), run `go vet` and `go test` on the patched packages in a clone
of upstream at the new pin with the patch applied (`build.sh` removes its own), then run the macOS egress E2E on Apple Silicon. If the patch conflicted, or applies but
the patched tree fails `go vet`/`go test` (`ACTION`), rebase it against `main` first.
