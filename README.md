# augur

Run Claude Code, Codex CLI, and Gemini CLI in an isolated Docker container.
Works in any directory — only the current directory is exposed to the container.

## Setup

### Quick start (install script)

```bash
# 1. Run the script (copies Dockerfile and augur to ~/.augur/, configures PATH)
bash install

# 2. Reload shell config
source ~/.zshrc  # or source ~/.bashrc

# 3. Build the Docker image
augur build
```

**Note:** The script handles both initial setup and updates. Safe to re-run — PATH entry is not duplicated.

---

### Manual setup

### 1. Place files

```bash
mv ~/Downloads/augur ~/.augur
chmod +x ~/.augur/augur
```

### 2. Add to PATH

Add to `~/.zshrc` (or `~/.bashrc`):

```bash
export PATH="$HOME/.augur:$PATH"
```

Reload:

```bash
source ~/.zshrc
```

### 3. Set API keys

Only set what you need. Add to `~/.zshrc`:

```bash
export ANTHROPIC_API_KEY="sk-ant-..."   # for Claude Code
export OPENAI_API_KEY="sk-..."          # for Codex (API key auth)
export GEMINI_API_KEY="..."             # for Gemini CLI (API key auth)
```

To use Gemini with a Google account instead of an API key, run `augur gemini` for the first time — it will display a URL for browser-based OAuth. Credentials are saved to `~/.gemini/` and reused on subsequent runs.

### GitHub CLI (gh)

Install `gh` on the host and authenticate once:

```bash
brew install gh   # macOS
gh auth login
```

`gh` is available inside the container automatically — credentials in `~/.config/gh/` are shared.

### 4. Build the Docker image

```bash
augur build
```

Only needed once (takes a few minutes).

---

## Usage

```bash
cd ~/projects/my-app

augur up        # start the container
augur claude    # launch Claude Code
augur codex     # launch Codex
augur gemini    # launch Gemini CLI
augur down      # stop and remove the container
```

Other commands:

```bash
augur shell     # open a bash shell (for debugging)
augur status    # show status and auth info
augur build     # build the Docker image
```

---

## File access

| Path | Description |
|------|-------------|
| Current directory | mounted at `/workspace` (read/write) |
| `~/.claude/` | shared with container (Claude auth and settings) |
| `~/.codex/` | shared with container (Codex auth, settings, history) |
| `~/.gemini/` | shared with container (Gemini auth and settings) |
| `~/.config/gh/` | shared with container (GitHub CLI auth) |
| `~/.gitconfig` | mounted read-only (consistent git identity) |
| Everything else | **not visible to the container** (host protection) |

---

## Requirements

- Docker (Docker Desktop or Docker Engine)
- bash
