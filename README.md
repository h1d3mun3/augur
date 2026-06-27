<p align="left">
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-0c90b4.svg" alt="License: MIT"></a>
</p>

<p align="center">
  <img src="resources/auger.png" alt="augur" width="320">
</p>

Run Claude Code in an isolated environment.
Works in any directory — only the current directory is exposed to the container or VM.

Two modes are available:

| | Docker mode | macOS VM mode |
|---|---|---|
| **Isolation** | Linux container | macOS VM (Apple Virtualization Framework) |
| **Xcode / xcodebuild** | ✗ | ✓ |
| **iOS Simulator** | ✗ | ✓ |
| **Setup time** | ~5 min (image build) | ~75 min (VM build) |
| **Disk usage** | ~2 GB | ~70 GB+ |
| **Requires** | Docker | augur-vm (bundled), IPSW, Xcode XIP |

---

## Docker mode (default)

Lightweight Linux container. Suitable for most projects that don't need Xcode.

### Setup

```bash
# 1. Run the install script
bash install

# 2. Reload shell config
source ~/.zshrc  # or source ~/.bashrc

# 3. Build the Docker image
augur build
```

The install script copies `Dockerfile` and `augur` to `~/.augur/` and configures `PATH`. Safe to re-run.

### Usage

```bash
cd ~/projects/my-app

augur up        # start the container
augur claude    # launch Claude Code
augur shell     # open a bash shell (for debugging)
augur down      # stop and remove the container
augur status    # show status and auth info
augur build     # build the Docker image
augur update    # rebuild image with latest tool versions
augur version   # show tool versions
```

### File access

| Path | Description |
|------|-------------|
| Current directory | mounted at `/workspace-<project>` (read/write), named after the directory |
| `~/.claude/` | shared (Claude auth and settings) |
| `~/.config/gh/` | shared (GitHub CLI auth) |
| `~/.gitconfig` | mounted read-only |
| Everything else | **not visible to the container** |

### Requirements

- Docker (Docker Desktop or Docker Engine)
- bash

---

## macOS VM mode (`--macos`)

Full macOS VM built from an Apple-signed IPSW. Supports Xcode, xcodebuild, and iOS Simulator.
The VM is isolated per project — each directory gets its own thin clone of the base VM.

### Setup

#### 1. Build the VM backend

augur ships its own VM backend (`augur-vm`), a small Swift CLI built directly on
Apple's Virtualization.framework — no third-party tools required.

```bash
# on the macOS host (needs the Xcode / Swift toolchain)
bash install        # builds & installs augur-vm into ~/.augur
```

#### 2. Download Apple-signed assets

- **IPSW** — macOS restore image: System Preferences > Software Update
- **Xcode XIP** — Xcode installer: https://developer.apple.com/download/all/

#### 3. Build the base VM (one-time, ~75 min)

```bash
augur build --macos --ipsw ~/Downloads/macOS.ipsw --xcode-xip ~/Downloads/Xcode.xip
```

This will:
1. Create a macOS VM from your IPSW (`augur-vm create --from-ipsw`)
2. Open the VM window for manual Setup Assistant completion (credentials: `admin` / `admin`, Remote Login enabled)
3. Install Xcode, Homebrew, Node.js, and Claude Code
4. Download the iOS Simulator runtime (Xcode installed from a XIP does not bundle it)
5. Save the result as a reusable base VM (`augur-macos-base`)

By default only the **iOS** Simulator runtime is baked in. Use `--platforms` to bake in others —
baking them into the base VM means every project clone gets them without re-downloading:

```bash
# iOS + watchOS
augur build --macos --ipsw ... --xcode-xip ... --platforms iOS,watchOS

# every platform Xcode offers (watchOS, tvOS, visionOS, …) — many extra GB
augur build --macos --ipsw ... --xcode-xip ... --platforms all
```

> **Supply chain note:** The base VM is built entirely from Apple-signed assets (IPSW + Xcode XIP).
> No third-party automation scripts are used.

### Usage

```bash
cd ~/projects/my-app

augur up --macos        # clone base VM and start (first run clones automatically)
augur up --macos --gui  # same, but also open a VM window (display + keyboard + pointer)
augur claude --macos    # launch Claude Code  (starts VM if not running)
augur shell --macos     # open a bash shell   (starts VM if not running)
augur down --macos      # stop the VM (keeps the clone — next up is fast)
augur destroy --macos   # stop and remove the project VM clone
augur status --macos    # show VM status and auth info
augur update --macos    # update Claude Code in the base VM
augur version --macos   # show tool versions in the base VM
```

### Authentication

On macOS, Claude Code stores its OAuth login in the Keychain, which is unreadable over SSH and
absent from a freshly cloned VM. So macOS mode injects a credential through the environment on
every `up` (the same way it does for the GitHub token):

- `CLAUDE_CODE_OAUTH_TOKEN` — subscription token; run `claude setup-token` once on the host, then
  set the env var or save it to `~/.claude_code_oauth_token`.
- `ANTHROPIC_API_KEY` — Console API key (env or `~/.anthropic_api_key`). Takes priority if both are set.

### File access

| Path | Description |
|------|-------------|
| Current directory | exposed at `~/workspace-<project>` in the VM (read/write, virtiofs auto-mount) |
| `~/.gitconfig` | copied on VM start (HTTPS `git push` uses `GH_TOKEN`) |
| `~/.claude/` | **not** shared — local to the VM; auth is injected via env (see above) |
| Everything else | **not visible to the VM** |

> The macOS guest auto-mounts the shared directory under `/Volumes/My Shared Files/workspace-<project>`; augur
> symlinks it to `~/workspace-<project>`. The sealed system volume can't host a symlink at `/workspace`, so the
> per-project `~/workspace-<project>` path is used in the VM (Docker mode uses `/workspace-<project>`).

### Running `xcodebuild test`

`xcodebuild test` needs an Aqua (GUI) login session to reach `testmanagerd`; a headless SSH login
has none. Two things make that session exist at boot: the base VM is built with **auto-login**
enabled, and the VM is always run with a **virtual display device** (macOS only starts an Aqua
session when a framebuffer exists — `--no-graphics` suppresses only the host-side window, not the
display device). With both in place, `xcodebuild test` works over SSH for all test types. Recommended
invocation (SwiftData's `@Model` macro needs `-skipMacroValidation` in a headless VM):

```bash
NSUnbufferedIO=YES xcodebuild test \
  -scheme <Scheme> \
  -destination 'platform=macOS,arch=arm64' \
  -parallel-testing-enabled NO \
  -skipMacroValidation \
  -derivedDataPath ~/DerivedData \
  CODE_SIGNING_ALLOWED=NO
```

If builds are flaky from the shared mount (virtiofs is not tuned for heavy I/O — occasional
"project is damaged" errors), copy the project to local disk first: `rsync -a ~/workspace-<project>/ ~/Developer/<app>/`.

### Requirements

- macOS (Apple Silicon)
- Xcode / Swift toolchain (to build the bundled `augur-vm` backend via `bash install`)
- macOS IPSW (Apple-signed)
- Xcode XIP (Apple-signed, from developer.apple.com)

---

## Egress allowlist (`.augur.conf`)

Restrict the container/VM to a set of domains — everything else is blocked. Enforcement runs in a small proxy on the **host, as your user — it never needs `sudo`**. Useful for sandboxing an agent so it can only reach the services it should.

**On by default.** Filtering is always active using the global baseline (`~/.augur/augur.conf`, installed with sensible defaults). Add a `./.augur.conf` in the project root to extend it with project-specific domains. To disable for one run, pass `--no-egress`.

```bash
cd ~/projects/my-app

# Optional: extend the global baseline with project-specific domains
cat > .augur.conf <<'EOF'
# project-specific domains (merged on top of ~/.augur/augur.conf)
registry.example.com
api.myservice.com
EOF

augur up            # Docker, egress on (global baseline + .augur.conf if present)
augur up --macos    # macOS VM, same
augur up --no-egress  # disable egress filtering for this run
augur status        # shows: Egress on/off + the active allowlist
```

### `.augur.conf` format

One pattern per line, `#` for comments:

| Pattern | Matches |
|---|---|
| `example.com` | that exact host (the apex) only |
| `*.example.com` | subdomains only (`api.example.com`, not `example.com`) |
| `.example.com` | the apex **and** all subdomains |

The effective list is the **global baseline** (`~/.augur/augur.conf`, installed with sensible defaults for Claude Code / GitHub / npm / Homebrew) merged with the project's `./.augur.conf` if present. The merge happens on the host, so the guest can't widen its own policy by editing the mounted file. Edits take effect on the next `augur up`.

### How it works

| Mode | Enforcement |
|------|-------------|
| **Docker** | The agent runs on an internal network (no route to the host or the internet) with `NET_ADMIN` dropped, so a root agent can't re-route. A proxy **sidecar** container joins that internal network (to receive the agent's traffic) and a normal bridge (to egress) — making it the agent's only way out. A boot self-test fails closed if direct egress is ever reachable. |
| **macOS VM** | The guest's only NIC is a host-owned socket (`VZFileHandleNetworkDeviceAttachment`); a bundled `gvproxy` runs the guest's network on the host and funnels every connection to the proxy. Needs no special entitlement. |

In both modes the proxy decides by domain (the CONNECT host, or the TLS SNI / HTTP Host) and connects out by name.

### Requirements

`install` builds the proxy (`augur-proxy`, Swift) automatically. **macOS egress also needs Go** (for `augur-gvproxy`) — `brew install go`, then re-run `bash install`. Without it, macOS egress is unavailable but everything else works.

The host ports the proxy uses are derived per-project so two egress-enabled projects can run at once; override with `AUGUR_PROXY_HTTP_PORT` / `AUGUR_PROXY_SOCKS_PORT` / `AUGUR_SSH_FWD_PORT` if needed.

> **Scope.** This guarantees *"the guest can only reach allowlisted domains."* DNS is gated on the same allowlist (a name resolves only if it's connectable), so the guest can't tunnel data out via DNS queries either. It is still **not** exfiltration-proof: an allowlisted, writable host (e.g. `github.com` with your `GH_TOKEN`) and the shared workspace are intentional channels. See `augur-proxy/README.md` and `gvproxy/README.md`.

---

## API keys and authentication

Set the key you need. Add to `~/.zshrc`:

```bash
export ANTHROPIC_API_KEY="sk-ant-..."   # for Claude Code
```

Alternatively, place the key in a file (`~/.anthropic_api_key`).

**Account-based auth** (no API key needed):
- **Claude Code**: run `augur claude` — prompts for login on first use

**GitHub CLI:**

```bash
brew install gh
gh auth login
```

`gh` credentials are shared automatically in both modes.
