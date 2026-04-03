# llm-docker

Run Claude Code, Codex CLI, and Gemini CLI in an isolated Docker container.
Works in any directory — only the current directory is exposed to the container.

## Setup

### Quick start (install script)

```bash
# 1. Run the script (copies Dockerfile and llm-docker to ~/.llm-docker/, configures PATH)
bash install

# 2. Reload shell config
source ~/.zshrc  # or source ~/.bashrc

# 3. Build the Docker image
llm-docker build
```

**Note:** The script handles both initial setup and updates. Safe to re-run — PATH entry is not duplicated.

---

### Manual setup

### 1. Place files

```bash
mv ~/Downloads/llm-docker ~/.llm-docker
chmod +x ~/.llm-docker/llm-docker
```

### 2. Add to PATH

Add to `~/.zshrc` (or `~/.bashrc`):

```bash
export PATH="$HOME/.llm-docker:$PATH"
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

To use Gemini with a Google account instead of an API key, run `llm-docker gemini` for the first time — it will display a URL for browser-based OAuth. Credentials are saved to `~/.gemini/` and reused on subsequent runs.

### 4. Build the Docker image

```bash
llm-docker build
```

Only needed once (takes a few minutes).

---

## Usage

```bash
cd ~/projects/my-app

llm-docker up        # start the container
llm-docker claude    # launch Claude Code
llm-docker codex     # launch Codex
llm-docker gemini    # launch Gemini CLI
llm-docker down      # stop and remove the container
```

Other commands:

```bash
llm-docker shell     # open a bash shell (for debugging)
llm-docker status    # show status and auth info
llm-docker build     # build the Docker image
```

---

## File access

| Path | Description |
|------|-------------|
| Current directory | mounted at `/workspace` (read/write) |
| `~/.claude/` | shared with container (Claude auth and settings) |
| `~/.codex/` | shared with container (Codex auth, settings, history) |
| `~/.gemini/` | shared with container (Gemini auth and settings) |
| `~/.gitconfig` | mounted read-only (consistent git identity) |
| Everything else | **not visible to the container** (host protection) |

---

## Requirements

- Docker (Docker Desktop or Docker Engine)
- bash
