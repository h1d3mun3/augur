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

augur up [--swift VERSION]      # start the container
augur claude                    # launch Claude Code
augur shell                     # open a bash shell (for debugging)
augur setup-token               # get a Claude subscription token (runs in the guest, saves on the host)
augur down                      # stop and remove the container
augur status                    # show status, toolchain, and auth info
augur build [--swift VERSION]   # build the Docker image
augur update [--swift VERSION]  # rebuild image with latest tool versions
augur init-conf                 # scaffold a ./.augur.conf egress allowlist
augur version                   # show augur version
```

### File access

| Path | Description |
|------|-------------|
| Current directory | mounted at `/workspace-<project>` (read/write), named after the directory |
| `~/.claude/projects/-workspace-<project>` | **only this project's** Claude history is shared (read/write) — not the rest of `~/.claude`, so other projects' transcripts and host auth/settings stay invisible |
| `~/.config/gh/` | mounted **read-only** (the container can read but not rewrite it; the token is injected via `GH_TOKEN`) |
| `~/.gitconfig` | mounted read-only |
| Claude auth | injected via env (`CLAUDE_CODE_OAUTH_TOKEN` / `ANTHROPIC_API_KEY`) — the host's credential store is never mounted |
| Everything else | **not visible to the container** |

> Auth is env-based in both modes now. If you only ever logged in via the browser, run `augur setup-token` (or set `ANTHROPIC_API_KEY`); see [API keys and authentication](#api-keys-and-authentication). Upgrading from an older augur requires a one-time `augur build` (the image now pre-creates the scoped history dir).

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
3. Install Xcode, Homebrew, GitHub CLI, and Claude Code
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
augur setup-token --macos  # get a Claude subscription token (runs in the VM, saves on the host)
augur down --macos      # stop the VM (keeps the clone — next up is fast)
augur destroy --macos   # stop and remove the project VM clone
augur status --macos    # show VM status, toolchain, and auth info
augur list --macos      # list all VMs and their state
augur update --macos    # update Claude Code in the base VM
augur version --macos   # show augur version (macOS mode)
```

### Authentication

On macOS, Claude Code stores its OAuth login in the Keychain, which is unreadable over SSH and
absent from a freshly cloned VM. So macOS mode injects a credential through the environment on
every `up` (the same way it does for the GitHub token):

- `CLAUDE_CODE_OAUTH_TOKEN` — subscription token; either set the env var / save it to
  `~/.claude_code_oauth_token`, or run **`augur setup-token`**: it runs `claude setup-token`
  inside the guest (so you don't install Claude Code on the host), then you paste the token
  back once and augur saves it to `~/.claude_code_oauth_token`.
- `ANTHROPIC_API_KEY` — Console API key (env or `~/.anthropic_api_key`). Takes priority if both are set.

### File access

| Path | Description |
|------|-------------|
| Current directory | exposed at `~/workspace-<project>` in the VM (read/write, virtiofs auto-mount) |
| `~/.gitconfig` | copied on VM start (HTTPS `git push` uses `GH_TOKEN`) |
| `~/.config/gh/` | shared **read-only** (token also injected via `GH_TOKEN`) |
| Claude history | **only this project's** history is shared, in a per-VM isolated dir (`~/.augur/claude-projects/<vm>`), so other projects' transcripts stay invisible. Cross-mode (Docker↔macOS) resume is no longer shared. |
| Claude auth | **not** shared — injected via env (the macOS Keychain is unreadable over SSH; see above) |
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

**On by default.** Filtering is always active using a **managed baseline** (`~/.augur/augur.conf.default`, shipped with sensible defaults and refreshed on every install). Add your own always-on domains to `~/.augur/augur.conf`, or per-project ones to a `./.augur.conf` in the project root. To disable for one run, pass `--no-egress`.

```bash
cd ~/projects/my-app

# Optional: extend the baseline with project-specific domains
cat > .augur.conf <<'EOF'
# project-specific domains (merged on top of the managed baseline)
registry.example.com
api.myservice.com
EOF

augur up            # Docker, egress on (baseline + augur.conf + .augur.conf if present)
augur up --macos    # macOS VM, same
augur up --no-egress  # disable egress filtering for this run
augur up --egress     # force egress filtering on (re-enables if AUGUR_EGRESS=0)
augur status        # shows: Egress on/off + the active allowlist
```

Filtering is on by default; set `AUGUR_EGRESS=0` to disable it persistently, or `AUGUR_EGRESS=1` to force it on. The `--no-egress` / `--egress` flags override that environment variable for a single run.

### `.augur.conf` format

One pattern per line, `#` for comments:

| Pattern | Matches |
|---|---|
| `example.com` | that exact host (the apex) only |
| `*.example.com` | subdomains only (`api.example.com`, not `example.com`) |
| `.example.com` | the apex **and** all subdomains |

The effective list is three layers merged (union — a layer can only widen, never narrow):

1. **Managed baseline** (`~/.augur/augur.conf.default`) — shipped defaults for Claude Code / GitHub / npm / Homebrew. augur owns this file and **refreshes it on every install**, so shipped domain updates reach you automatically. Don't edit it; your changes are overwritten.
2. **Your global additions** (`~/.augur/augur.conf`) — always-on domains you add. **Never overwritten** by install.
3. **Project** (`./.augur.conf`) — per-project domains.

The merge happens on the host, so the guest can't widen its own policy by editing the mounted file. Edits take effect on the next `augur up`.

**Project domains require approval (trust-on-first-use).** Because `./.augur.conf` ships inside a repository you may not fully trust, augur shows the domains it adds and asks you to approve them on first sight and again whenever the file changes — the same model as SSH host keys. The approval fingerprint is stored host-side under `~/.augur/project-hashes/` (never in the project tree or a mounted share), so a compromised guest that rewrites `./.augur.conf` cannot get the change honored without a fresh host-side approval. `augur status` shows the project's domains and whether they're approved. For non-interactive / disposable runs (CI), set `AUGUR_ACCEPT_PROJECT_CONF=1` to accept automatically; without a TTY and without that variable, an unapproved/changed conf fails closed.

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

**Account-based auth** (subscription, no API key needed): augur never mounts the host's
Claude credential store into the guest — auth is injected via the environment in both
modes. The easiest way to get a long-lived subscription token is **`augur setup-token`**,
which runs `claude setup-token` inside the guest (no Claude install on the host) and saves
the token for you. Or generate one yourself if you already have Claude Code on the host:

```bash
claude setup-token            # prints a token for CLAUDE_CODE_OAUTH_TOKEN
export CLAUDE_CODE_OAUTH_TOKEN="..."   # or save it to ~/.claude_code_oauth_token
```

augur reads `CLAUDE_CODE_OAUTH_TOKEN` (env or `~/.claude_code_oauth_token`) and injects it
into the container/VM. `ANTHROPIC_API_KEY` takes priority if both are set.

**GitHub CLI:**

```bash
brew install gh
gh auth login
```

`gh` credentials are shared automatically in both modes (token injected via `GH_TOKEN`;
the host's `~/.config/gh` is mounted read-only so the guest can't rewrite it).
