# augur-vm

A minimal macOS VM tool built directly on Apple's Virtualization.framework,
covering exactly what `augur`'s macOS VM mode needs (create / run / clone / stop /
directory sharing / list). It is the VM backend `augur` invokes in macOS VM mode.

> **macOS (Apple Silicon) only.** Virtualization.framework does not exist on Linux,
> so this cannot be built or run inside augur's Docker mode — build it on the host.

## Status: feature-complete CLI, integrated into augur

Implemented:

- `augur-vm version` — print version
- `augur-vm list` — list VMs (`Source Name Disk Size State` columns, parsed by augur)
- `augur-vm smoke` — prove VZ links and the virtualization entitlement is embedded
- `augur-vm create <name> --from-ipsw <path> [--disk-size <GB>]` — install macOS from an IPSW
- `augur-vm set <name> [--cpu N] [--memory MB]` — adjust CPU / memory (memory in MB)
- `augur-vm run <name> --no-graphics [--dir name:path ...] [--net-vfkit <socket>]` — boot headless with shared dirs
- `augur-vm run <name>` — boot with a GUI window (display + keyboard + pointer) for Setup Assistant
- `printf %s "$pw" | augur-vm run <name> --no-graphics --provision-username <user> --provision-password-stdin [--provision-full-name <name>]` —
  on a macOS 27+ host, provisions the account automatically on the guest's first boot after
  `create` (`VZMacGuestProvisioningOptions`: auto-login + Remote Login enabled, no manual Setup
  Assistant) instead of waiting for a human at a GUI window. Has no effect on a guest whose
  installed OS predates macOS 27 (see `guest-os-version` below) — the framework silently ignores
  it there rather than erroring. The password is read from stdin and has no option form, because
  argv is observable (`ps`) for the whole life of the boot.
  See `docs/decisions/0018-macos27-unattended-provisioning.md`.
  **These two flags exist only when augur-vm is built against the macOS 27 SDK (Xcode 27+)** —
  the symbol they need is absent from older SDKs, so the feature is compiled out rather than
  failing the build (`#if compiler(>=6.4)`). `run --help` is the authoritative answer for a given
  binary; everything else in `--macos` mode works either way.
  A `run` issued right after `create` may find the bundle's auxiliary storage still locked by the
  installer's VM (whose XPC service outlives the `create` process); that start is retried for
  ~30s rather than reported, so back-to-back `create`/`run` is safe.
- `augur-vm guest-os-version <name>` — print the installed guest's major macOS version, captured
  from the IPSW's restore image at `create` time (empty/exit 1 for a bundle predating this field)
- `augur-vm ip <name>` — print the guest IP (from `/var/db/dhcpd_leases`)
- `augur-vm stop <name>` — graceful shutdown (SIGTERM to the run process; force-kill fallback)
- `augur-vm delete <name>` — remove a VM bundle
- `augur-vm clone <src> <dst>` — APFS copy-on-write clone (near-free on disk)

`--dir name:path` shares are auto-mounted by the macOS guest under
`/Volumes/My Shared Files/<name>` (via the virtiofs automount tag), the path
augur's `~/workspace` symlink targets — so directory sharing works unchanged.

`--net-vfkit <socket>` attaches the guest NIC to a vfkit unixgram socket (gvproxy)
instead of NAT, so all egress passes through the host egress filter. Without it, the
guest uses NAT and traffic is unfiltered.

### Try the vertical slice (macOS Apple Silicon host)

```bash
scripts/build.sh   # build + sign
BIN="$(swift build -c release --show-bin-path)/augur-vm"
"$BIN" create my-vm --from-ipsw ~/Downloads/macOS.ipsw --disk-size 120   # ~15-30 min
"$BIN" set my-vm --cpu 4 --memory 8192
"$BIN" run my-vm --no-graphics &                                         # resident
"$BIN" ip my-vm                                                          # -> 192.168.64.x
ssh admin@$("$BIN" ip my-vm)
```

## Build & verify

```bash
cd augur-vm
scripts/build.sh          # swift build -c release + ad-hoc codesign + smoke test
```

Expected `smoke` output on a correctly signed binary:

```
Virtualization.framework: linked (min cpu=1, min mem=... bytes)
Entitlement com.apple.security.virtualization: PRESENT ✓
M0 smoke: OK
```

If the entitlement is reported MISSING, the binary was run unsigned (e.g. via
`swift run`, which produces an unsigned binary) — use `scripts/build.sh`, which signs
before testing.

## Why ad-hoc signing is enough

`com.apple.security.virtualization` is honored for ad-hoc-signed (`codesign --sign -`)
binaries run locally on Apple Silicon. Developer ID signing is only required to
distribute the binary to other machines.
