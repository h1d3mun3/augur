# augur-proxy

Host-side egress filter for augur. Enforces a domain allowlist (`.augur.conf`) so
the container/VM can only reach explicitly-permitted domains; everything else is
blocked. Runs as the **host user — never needs `sudo`**.

It is a separate, dependency-free, cross-platform Swift package (Linux + macOS) —
kept apart from `augur-vm`, which is macOS-only because it links
Virtualization.framework.

## Why the boundary is outside the guest

The AI agent has **root inside the guest** in both modes (Docker `dev` has
passwordless sudo; the macOS VM has `sudoers.d/augur`). So any in-guest firewall it
can edit is not a real boundary. Enforcement therefore lives in the host network
topology, where the guest's root cannot reach it:

- **Docker**: the container runs on a `docker network --internal` (no route to the
  internet) with `--cap-drop=NET_ADMIN` (root can't re-route). Its only reachable
  egress is this proxy via `host.docker.internal`. A boot self-test in `augur`
  proves a direct (proxy-less) connection fails — else it refuses to start.
- **macOS**: the VM's only NIC is a host-owned `socketpair` via
  `VZFileHandleNetworkDeviceAttachment` (see `augur-vm`'s `--net-vfkit`). A
  user-space network stack (`gvproxy`, see below) runs the guest's network on the
  host and forwards all guest TCP to this proxy's SOCKS5 port. No Apple-gated
  `com.apple.vm.networking` entitlement is used.

Both datapaths hand the proxy a **hostname**, so the allow/deny decision is
identical across modes (`Filter`).

## What it does

One process, fail-closed:

- **HTTP CONNECT / forward proxy** (Docker) — reads the `CONNECT host:port` (or
  absolute-form `Host`) and allows/denies by domain.
- **SOCKS5** (macOS, gvproxy upstream) — `atyp=domain` gives the hostname.
- **Allowlist** (`Allowlist`) — reversed-label, boundary-anchored matching:
  `*.github.com` matches `api.github.com` but **not** `evilgithub.com`.
- **DNS pin table** (`PinTable`) — IP-literal connects are denied unless the
  filtering DNS recently handed that client the IP for an allowed name (defends
  against IP-literal exfil and ECH-hidden SNI).
- **Hot reload** — re-reads the allowlist file on change; keeps the old policy if a
  reload can't be read (never falls open).
- **Deny logging** — one greppable line per blocked attempt.

## Usage

```
augur-proxy --allowlist <path> [--listen 127.0.0.1]
            [--http-port N] [--socks-port N]
            [--log <path>] [--pidfile <path>] [--allow-private]
```

`augur` starts/stops it automatically on `up`/`down`; you rarely run it by hand.

## `.augur.conf` format

One pattern per line, `#` comments:

```
example.com     # exact host only (apex). Does NOT match subdomains.
*.example.com   # subdomains only (api.example.com yes; example.com no).
.example.com    # the apex AND every subdomain.
```

The effective allowlist is the global baseline `~/.augur/augur.conf` merged with the
project's `./.augur.conf`. The merge happens on the host at `augur up`, and the proxy
reads the host-side copy under `~/.augur/proxy/` — so the guest editing the mounted
`./.augur.conf` mid-session cannot widen its own policy.

## Build / test

```
swift build          # cross-platform
swift test           # unit tests (Allowlist matching, SNI, CONNECT/SOCKS parsing)
```

## macOS datapath

On macOS the guest reaches this proxy through a small **fork of `gvproxy`
(gvisor-tap-vsock)** in `../gvproxy/` (a patch + `build.sh`, built by `install`),
which runs the guest's network on the host and forwards every guest TCP connection
to this proxy's SOCKS5 by destination IP. This proxy then peeks the TLS SNI / HTTP
Host on the SOCKS-by-IP stream, applies the allowlist by name, and dials out by
name. `augur` starts it as:

```
augur-gvproxy --listen-vfkit unixgram://<sock> \
              --socks-upstream 127.0.0.1:<socks-port> \
              --ssh-port <fwd-port> --deny-direct
```

The Docker datapath and this proxy core are verified on Linux; the macOS datapath
is verified end-to-end on Apple Silicon. See `../gvproxy/README.md` for the fork.
