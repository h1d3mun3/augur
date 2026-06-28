# Security review: host environment-variable exposure to the guest

- **Date:** 2026-06-25 (citations re-verified 2026-06-28)
- **Scope:** Whether host (developer-machine) *environment variables* are exposed to the guest OS, in **Docker mode** and **macOS VM mode**.
- **Status:** Living document — re-verify when the `docker run`/`docker exec` invocations, the macOS `cmd_up_macos` injection block, the SSH helpers, or the `augur-vm` VM configuration change. Source citations reference `augur` functions by name (not line numbers) so they survive unrelated edits.
- **Method:** Multi-angle source inspection (Docker runtime, macOS runtime, build-time baking, mounted/copied files, full env-var census) followed by an adversarial pass that actively hunted for any channel leaking an *unnamed* host variable, plus a completeness pass that opened every otherwise-unread file/command path.

> This is an **assessment of the current security posture**, not a decision record. The genuine *decisions* it rests on (inject credentials via the environment rather than mounting the Keychain; never forward the host environment wholesale) belong in an ADR that links back here, if/when one is written.

---

## Bottom line

**Neither mode exposes the host environment wholesale.** `augur` uses no environment-inheritance mechanism anywhere — no `docker run`/`exec` env inheritance, no `--env-file`, no bare `-e VAR` pass-through, no ssh `SendEnv`/`SetEnv`/`AcceptEnv`, and no serialization of `ProcessInfo.environment` into the VM. Only **explicitly named** variables cross, by value.

| | Docker mode | macOS VM mode |
|---|---|---|
| Wholesale host-env forwarding | **No** | **No** |
| Host-derived secrets that become guest env vars | `ANTHROPIC_API_KEY`, `GH_TOKEN` | `ANTHROPIC_API_KEY`, `CLAUDE_CODE_OAUTH_TOKEN`, `GH_TOKEN` |
| augur-built (non-secret) guest env vars | `HTTP(S)_PROXY`/`NO_PROXY` (egress only), `DISABLE_AUTOUPDATER=1` | `DISABLE_AUTOUPDATER=1` |
| Unnamed host vars that can cross | none | `TERM` (always, via SSH PTY); `LANG`/`LC_*` (OS-default `SendEnv`/`AcceptEnv`) — terminal/locale only, no secrets |

---

## What counts as "exposure" here

Three distinct things, kept separate throughout:

- **(a) Wholesale** — the whole host environment (or arbitrary host vars) leaks into the guest.
- **(b) Specific named** — a variable `augur` deliberately reads and forwards by name.
- **(c) Value-only** — a variable's *value* is embedded in a file/argument the guest can read, without being exported as a guest env var.

The user's question is specifically about **environment variables**. Host *files* that carry credentials into the guest (mounted `~/.claude`, `~/.config/gh`, etc.) are a separate, adjacent surface and are noted at the end — they are not environment-variable exposure.

---

## Environment variables that reach the guest

### `ANTHROPIC_API_KEY` — both modes (named secret)
Read from the host env, else from `~/.anthropic_api_key`, via the `resolve_api_key` helper.
- Docker: `docker run -e "ANTHROPIC_API_KEY=…"` (in `cmd_up`).
- macOS: written as `export ANTHROPIC_API_KEY='…'` into `~/.augur-env` (`chmod 600`), which `~/.zshenv` sources for every shell — i.e. a real guest env var (in `cmd_up_macos`).

### `GH_TOKEN` — both modes (named secret)
Obtained by running the subprocess `gh auth token` (in `cmd_up` / `cmd_up_macos`).
- Docker: `docker run -e "GH_TOKEN=…"`.
- macOS: `export GH_TOKEN='…'` in `~/.augur-env`, plus a git credential helper that echoes `password=$GH_TOKEN` for `github.com` (in `cmd_up_macos`) — the helper stores only the *reference* `$GH_TOKEN`, not the value.
- **Note:** `augur` does not read the shell `$GH_TOKEN` directly, but `gh auth token` honors a host `GH_TOKEN`/`GITHUB_TOKEN`, so a host token can transit into the guest's `GH_TOKEN` via that subprocess.

### `CLAUDE_CODE_OAUTH_TOKEN` — macOS only (named secret)
Read from the host env, else `~/.claude_code_oauth_token`, via `resolve_api_key`; exported via `~/.augur-env` (in `cmd_up_macos`).
- **Docker does not forward it.** Docker-mode Claude auth comes from the bind-mounted `~/.claude` / `~/.claude.json` instead. `cmd_status` only *reads* it for a display checkmark; it never enters the container.

### `HTTP_PROXY` / `HTTPS_PROXY` / `NO_PROXY` (+ lowercase) — Docker egress only (augur-built, not host-derived)
Set in the guest to force traffic through the sidecar (in `cmd_up`). **The host's own proxy variables are never read.** The values are built from `AUGUR_SIDECAR_IP:AUGUR_PROXY_HTTP_PORT`. macOS mode does not set these (its datapath is transparent via gvproxy/SOCKS).

### `DISABLE_AUTOUPDATER=1` — both modes (augur literal)
Hardcoded when launching Claude: `docker exec -e DISABLE_AUTOUPDATER=1` (in `cmd_claude`) / inline in the macOS zsh command (in `cmd_claude_macos`). Not a host-env read.

---

## Host-only variables (read but never reach the guest)

| Variable | Use | Reaches guest |
|---|---|---|
| `HOME` | Locate host config files/dirs for mounts & scp sources (in `cmd_up` / `cmd_up_macos`) | No (guest `HOME` is fixed `/home/dev` / `/Users/admin`) |
| `SWIFT_VERSION` | Docker base-image tag via `--build-arg`; `ARG` declared before `FROM`, no `ENV` persists it (`Dockerfile:1-2`, in `cmd_build`) | Value-only (observable as the toolchain version, not a runtime env var) |
| `AUGUR_SIDECAR_IP`, `AUGUR_PROXY_HTTP_PORT` | Sidecar IP/port; values embedded in the guest `HTTP_PROXY` string (in `cmd_up`) | Value-only (non-secret internal IP/port) |
| `AUGUR_VM_BIN`, `AUGUR_PROXY_BIN`, `AUGUR_GVPROXY_BIN` | Host path overrides for the backend binaries | No |
| `AUGUR_GLOBAL_CONF` | Path to the global egress allowlist; contents merged into a host-side allowlist enforced by the proxy | No |
| `AUGUR_EGRESS` | Host-side on/off switch for egress filtering | No |
| `AUGUR_PROXY_SOCKS_PORT`, `AUGUR_SSH_FWD_PORT`, `AUGUR_INTERNAL_SUBNET` | Host-side loopback ports / Docker internal subnet | No |

---

## The one nuance: macOS SSH PTY (terminal/locale only)

`augur claude --macos` / `shell --macos` run `ssh -t` (PTY) without `-F /dev/null` or env hardening (in `cmd_claude_macos` / `cmd_shell_macos`, via the `ssh_macos` helper). Consequently, into the **macOS guest only**:

1. **`$TERM`** — the SSH `pty-req` always carries the client's `TERM` to the server, so the host `TERM` becomes the guest session's `TERM` unconditionally.
2. **`LANG` / `LC_*`** — with no custom ssh config, the host's stock `ssh_config` `SendEnv LANG LC_*` plus the guest sshd's default `AcceptEnv LANG LC_*` can forward locale variables.

This is the only path by which a host variable `augur` never names reaches a guest. It is **bounded to terminal/locale variables, carries no secrets, and is OS/protocol-default behavior — not configured by augur.** It does not constitute wholesale forwarding. Docker is unaffected: `docker exec -it`/`run -t` set `TERM=xterm` in the container and do not propagate the host `TERM`.

---

## Adjacent surface: host *files* (not environment variables)

For completeness — these expose host *files* (and any secrets those files contain), which is a different channel from environment variables:

- **Docker** bind-mounts `~/.claude` (incl. `.credentials.json` — Claude OAuth tokens at rest), `~/.config/gh` (on Linux, `hosts.yml` may hold a plaintext token), `~/.claude.json`, and `~/.gitconfig` (`:ro`) (in `cmd_up`).
- **macOS** shares `~/.config/gh`, `~/.claude/projects`, and the workspace via virtiofs, and scp's `~/.gitconfig` and `~/.claude.json` (in `cmd_up_macos`). `~/.claude` itself is **not** shared.
- The **workspace mount** is the developer's own repo; a checked-in `.env` is readable by the agent, but that is project content, not the host shell environment — `augur` does no `.env` handling.

These are file-origin credentials, not host-environment-variable exposure.

---

## Compiled components — no env channel

- **augur-vm (Swift):** the VM configuration is built solely from `config.json` + the `--dir` virtiofs shares + the network socket. No `ProcessInfo.environment`/`getenv`; the only `ProcessInfo` use is `processorCount` for CPU sizing (`Installer.swift:183`). `VZMacOSBootLoader` exposes no kernel command line, so a boot-args env leak is impossible by API (`RunSession.swift`).
- **augur-proxy (Swift):** reads `CommandLine.arguments` only; zero `getenv`/`ProcessInfo`.
- **gvproxy (Go, augur patch):** zero `os.Getenv`/`os.Environ`; the DNS allowlist is read from a file passed by CLI flag.

---

## Invariants worth protecting (regression guards)

If these ever change, the conclusion above changes. Candidates for executable tests/lint (cf. the existing `augur-proxy/Tests/AugurProxyCoreTests/SecurityTests.swift`):

1. No bare `-e VAR` (without `=value`), no `--env-file`, and no `--env` glob in `augur`.
2. The SSH helpers set no `SendEnv`/`SetEnv`; the guest sshd config is never modified to `AcceptEnv` extra vars.
3. The only **secrets** the `~/.augur-env` writer exports are the three named ones (`ANTHROPIC_API_KEY`, `CLAUDE_CODE_OAUTH_TOKEN`, `GH_TOKEN`); its other lines (a header comment, the `brew shellenv` eval, and the `~/.local/bin` PATH export) carry no host-derived values. No additional host secret is ever added.
4. The `augur-vm` backend never reads `ProcessInfo.environment`/`getenv` (only `processorCount` is permitted).
