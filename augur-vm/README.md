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
- `augur-vm run <name> --no-graphics [--dir name:path ...]` — boot headless with NAT + shared dirs
- `augur-vm run <name>` — boot with a GUI window (display + keyboard + pointer) for Setup Assistant
- `augur-vm ip <name>` — print the guest IP (from `/var/db/dhcpd_leases`)
- `augur-vm stop <name>` — graceful shutdown (SIGTERM to the run process; force-kill fallback)
- `augur-vm delete <name>` — remove a VM bundle
- `augur-vm clone <src> <dst>` — APFS copy-on-write clone (near-free on disk)

`--dir name:path` shares are auto-mounted by the macOS guest under
`/Volumes/My Shared Files/<name>` (via the virtiofs automount tag), the path
augur's `~/workspace` symlink targets — so directory sharing works unchanged.

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
