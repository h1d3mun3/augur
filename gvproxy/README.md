# augur-gvproxy

The macOS egress datapath needs a user-space network stack on the host so the VM's
only NIC (a `VZFileHandleNetworkDeviceAttachment` socket) has somewhere to send its
L2 frames. augur uses [`gvisor-tap-vsock`](https://github.com/containers/gvisor-tap-vsock)
(the `gvproxy` from podman/vfkit) for that, with a small fork so that **all guest
egress is forced through `augur-proxy`'s allowlist**.

## What the fork changes

`augur-egress.patch` (5 files, ~140 lines against pinned commit `af3ea886`) adds two
flags to `gvproxy`:

- `--socks-upstream host:port` — the TCP forwarder dials every guest connection
  through this SOCKS5 proxy (the host-side `augur-proxy`) by destination IP,
  instead of `net.Dial`-ing it directly. `augur-proxy` then peeks the TLS SNI /
  HTTP Host and applies the domain allowlist.
- `--deny-direct` — does not register the UDP and ICMP forwarders at all. They
  `net.Dial` directly and would otherwise be egress holes (QUIC/HTTP3 exfil, ICMP
  tunneling). The gateway DNS server is a separate listener and keeps working, so
  name resolution is unaffected. With this flag, **SOCKS-filtered TCP is the only
  way out** — a root agent in the guest cannot bypass it.

The hook is `pkg/services/forwarder/tcp.go` (the single point all guest TCP egress
funnels through); the SOCKS5 client is dependency-free (`socks_client.go`).

## How augur runs it

```
augur-gvproxy --listen-vfkit unixgram://<sock> \
              --socks-upstream 127.0.0.1:<augur-proxy-socks-port> \
              --deny-direct
```

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

**Accepted residual — DNS:** the gvproxy gateway DNS server (`192.168.127.1:53`)
survives `--deny-direct` (it is a separate listener, not the UDP forwarder) and
resolves arbitrary names via the host resolver with no allowlist. That is a
**low-bandwidth exfil/C2 channel** (base32-in-QNAME to an attacker NS) — it cannot
move a TCP/TLS tunnel. It is accepted for now; the fast-follow is to gate
`addAnswers` on the allowlist and restrict RR types to A/AAAA/CNAME.

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
