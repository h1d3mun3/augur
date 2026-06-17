# augur

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-0c90b4.svg" alt="License: MIT"></a>
</p>

Run Claude Code, Codex CLI, and Gemini CLI in an isolated environment.
Works in any directory — only the current directory is exposed to the container or VM.

Two modes are available:

| | Docker mode | macOS VM mode |
|---|---|---|
| **Isolation** | Linux container | macOS VM (Apple Virtualization Framework) |
| **Xcode / xcodebuild** | ✗ | ✓ |
| **iOS Simulator** | ✗ | ✓ |
| **Setup time** | ~5 min (image build) | ~60 min (VM build) |
| **Disk usage** | ~2 GB | ~60 GB+ |
| **Requires** | Docker | tart, IPSW, Xcode XIP |

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
augur codex     # launch Codex
augur gemini    # launch Gemini CLI
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
| Current directory | mounted at `/workspace` (read/write) |
| `~/.claude/` | shared (Claude auth and settings) |
| `~/.codex/` | shared (Codex auth, settings, history) |
| `~/.gemini/` | shared (Gemini auth and settings) |
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

#### 1. Install tools

```bash
brew install cirruslabs/cli/tart
```

#### 2. Download Apple-signed assets

- **IPSW** — macOS restore image: https://ipsw.me or System Preferences > Software Update
- **Xcode XIP** — Xcode installer: https://developer.apple.com/download/all/

#### 3. Build the base VM (one-time, ~60 min)

```bash
augur build --macos --ipsw ~/Downloads/macOS.ipsw --xcode-xip ~/Downloads/Xcode.xip
```

This will:
1. Create a macOS VM from your IPSW (`tart create --from-ipsw`)
2. Open the VM window for manual Setup Assistant completion (credentials: `admin` / `admin`, Remote Login enabled)
3. Install Xcode, Homebrew, Node.js, and Claude Code
4. Save the result as a reusable base VM (`augur-macos-base`)

> **Supply chain note:** The base VM is built entirely from Apple-signed assets (IPSW + Xcode XIP).
> No third-party automation scripts are used.

### Usage

```bash
cd ~/projects/my-app

augur up --macos        # clone base VM and start (first run clones automatically)
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
| Current directory | exposed at `~/workspace` in the VM (read/write, virtiofs auto-mount) |
| `~/.gitconfig` | copied on VM start (HTTPS `git push` uses `GH_TOKEN`) |
| `~/.claude/` | **not** shared — local to the VM; auth is injected via env (see above) |
| Everything else | **not visible to the VM** |

> Tart auto-mounts the shared directory under `/Volumes/My Shared Files/workspace`; augur symlinks
> it to `~/workspace`. The sealed system volume can't host a symlink at `/workspace`, so `~/workspace`
> is used in the VM (Docker mode still uses `/workspace`).

### Running `xcodebuild test`

`xcodebuild test` needs an Aqua (GUI) login session to reach `testmanagerd`; a headless SSH login
has none. The base VM is built with **auto-login** enabled so a GUI session exists at boot — once a
user is logged in, `xcodebuild test` works over SSH for all test types. Recommended invocation
(SwiftData's `@Model` macro needs `-skipMacroValidation` in a headless VM):

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
"project is damaged" errors), copy the project to local disk first: `rsync -a ~/workspace/ ~/Developer/<app>/`.

### Requirements

- macOS (Apple Silicon)
- [tart](https://github.com/cirruslabs/tart): `brew install cirruslabs/cli/tart`
- macOS IPSW (Apple-signed)
- Xcode XIP (Apple-signed, from developer.apple.com)

---

## API keys and authentication

Set whichever keys you need. Add to `~/.zshrc`:

```bash
export ANTHROPIC_API_KEY="sk-ant-..."   # for Claude Code
export OPENAI_API_KEY="sk-..."          # for Codex
export GEMINI_API_KEY="..."             # for Gemini CLI
```

Alternatively, place the key in a file (`~/.anthropic_api_key`, `~/.openai_api_key`, `~/.gemini_api_key`).

**Account-based auth** (no API key needed):
- **Claude Code**: run `augur claude` — prompts for login on first use
- **Gemini CLI**: run `augur gemini` — displays a URL for browser-based OAuth
- **Codex**: run `augur codex` — prompts for login on first use

**GitHub CLI:**

```bash
brew install gh
gh auth login
```

`gh` credentials are shared automatically in both modes.
