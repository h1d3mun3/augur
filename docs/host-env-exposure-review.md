# Security review: host environment-variable exposure to the guest

- **Date:** 2026-06-25 (citations re-verified 2026-06-28; re-baselined 2026-07-08 for the Apple Container engine migration, the unified auth seam, and the hermetic SSH helpers; re-baselined again 2026-07-08 after Docker support was dropped — Apple Container is now the sole container engine; re-baselined 2026-07-20 after macOS mode stopped scp'ing `~/.claude.json` entirely, commit `3d59f7d`).
- **Scope:** Whether host (developer-machine) *environment variables* are exposed to the guest OS, in **container mode** (Apple Container, macOS 26+) and **macOS VM mode**.
- **Status:** Living document — re-verify when the container `run`/`exec` invocations (`cmd_up` / `cmd_claude` / `cmd_shell`), the macOS `cmd_up_macos` injection block, the SSH helpers (`ssh_macos` / `ssh_macos_provision`), the base-image provisioning path, or the `augur-vm` VM configuration change. Source citations reference `augur` functions by name (not line numbers) so they survive unrelated edits.
- **Method:** Multi-angle source inspection (container runtime, macOS runtime, build-time baking, mounted/copied files, full env-var census) followed by an adversarial pass that actively hunted for any channel leaking an *unnamed* host variable, plus a completeness pass that opened every otherwise-unread file/command path. Re-verified 2026-07-08 against the post-migration source (the `eng` engine abstraction, the `agent_auth_specs` auth seam, and the hermetic `-F /dev/null` SSH helpers), with an adversarial completeness sweep per mode.

> This is an **assessment of the current security posture**, not a decision record. The genuine *decisions* it rests on (inject credentials via the environment rather than mounting the Keychain; never forward the host environment wholesale) belong in an ADR that links back here, if/when one is written.

---

## Bottom line

**Neither mode exposes the host environment wholesale.** `augur` uses no environment-inheritance mechanism anywhere — no container `run`/`exec` env inheritance, no `--env-file`, no bare `-e VAR` pass-through, no ssh `SendEnv`/`SetEnv`/`AcceptEnv`, and no serialization of `ProcessInfo.environment` into the VM. Container mode injects env only via an explicit `run_args` array (`container run -e …`) and `container exec -e …`. Only **explicitly named** variables cross, by value.

| | Container mode (Apple Container) | macOS VM mode |
|---|---|---|
| Wholesale host-env forwarding | **No** | **No** |
| Host-derived secrets that become guest env vars | `ANTHROPIC_API_KEY`, `CLAUDE_CODE_OAUTH_TOKEN`, `GH_TOKEN` | `ANTHROPIC_API_KEY`, `CLAUDE_CODE_OAUTH_TOKEN`, `GH_TOKEN` |
| augur-built (non-secret) guest env vars | `HTTP(S)_PROXY`/`NO_PROXY` (egress only), `GIT_CONFIG_*` (only when a gh token is present), `DISABLE_AUTOUPDATER=1` | `DISABLE_AUTOUPDATER=1` |
| Unnamed host vars that can cross | none¹ | `TERM` only (always, via SSH PTY) |

¹ In both modes, `gh auth token` may emit a value that `gh` itself sourced from the host `GH_TOKEN`/`GITHUB_TOKEN` — so a host variable whose *name* augur never reads can still transit into the guest's `GH_TOKEN` by value. See the `GH_TOKEN` note below.

---

## What counts as "exposure" here

Four distinct things, kept separate throughout:

- **(a) Wholesale** — the whole host environment (or arbitrary host vars) leaks into the guest.
- **(b) Specific named** — a variable `augur` deliberately reads and forwards by name.
- **(c) Value-only** — a variable's *value* is embedded in a file/argument the guest can read, without being exported as a guest env var.
- **(d) Protocol-default** — a variable carried by an OS/protocol mechanism `augur` did not configure (e.g. the SSH PTY terminal-type field that carries `TERM`).

The user's question is specifically about **environment variables**. Host *files* that carry credentials into the guest (mounted `~/.config/gh`, scp'd `~/.gitconfig`, etc.) are a separate, adjacent surface and are noted at the end — they are not environment-variable exposure.

---

## Environment variables that reach the guest

### `ANTHROPIC_API_KEY` — both modes (named secret)
Read from the host env, else from `~/.anthropic_api_key`, via the `resolve_api_key` helper driven by the `agent_auth_specs` seam table.
- Container: `container run -e "ANTHROPIC_API_KEY=…"` (in `cmd_up`, via the `run_args` array).
- macOS: written as `export ANTHROPIC_API_KEY='…'` into `~/.augur-env` (`chmod 600`), which `~/.zshenv` sources for every shell — i.e. a real guest env var (in `cmd_up_macos`).

### `CLAUDE_CODE_OAUTH_TOKEN` — **both modes** (named secret)
Read from the host env, else `~/.claude_code_oauth_token`, via `resolve_api_key` — from the **same** `agent_auth_specs` table as `ANTHROPIC_API_KEY`.
- Container: `container run -e "CLAUDE_CODE_OAUTH_TOKEN=…"` (in `cmd_up`).
- macOS: `export CLAUDE_CODE_OAUTH_TOKEN='…'` in `~/.augur-env` (in `cmd_up_macos`).
- Both auth vars are injected whenever set; `augur` applies **no** precedence itself — Claude Code applies the official `ANTHROPIC_API_KEY` > `CLAUDE_CODE_OAUTH_TOKEN` order when both are present. Both modes (container and macOS VM) forward it, resolved from the same `agent_auth_specs` table. (`cmd_status` still only *reads* it host-side for a display checkmark.)

### `GH_TOKEN` — both modes (named secret)
Obtained by running the subprocess `gh auth token` (in `cmd_up` / `cmd_up_macos`).
- Container: `container run -e "GH_TOKEN=…"`.
- macOS: `export GH_TOKEN='…'` in `~/.augur-env`, plus a `git config --global` credential helper that echoes `password=$GH_TOKEN` for `github.com` (in `cmd_up_macos`) — the helper stores only the *reference* `$GH_TOKEN`, not the value.
- **Note (unnamed-host-var transit):** `augur` does not read the shell `$GH_TOKEN`/`$GITHUB_TOKEN` directly, but `gh auth token` honors them, so a host token can transit into the guest's `GH_TOKEN` via that subprocess. This is the one path by which a host variable `augur` never *names* crosses in container mode too (macOS is the same).

### `HTTP_PROXY` / `HTTPS_PROXY` / `NO_PROXY` (+ lowercase) — container mode, egress only (augur-built, not host-derived)
Set in the guest to force traffic through augur-proxy (in `cmd_up`, only when `egress_enabled`). **The host's own proxy variables are never read.** The value comes from `egress_proxy_url`: it points at the host-only gateway (`container_egress_gateway`, overridable by `AUGUR_CONTAINER_GATEWAY`). `NO_PROXY` is the literal `localhost,127.0.0.1`. macOS VM mode does not set these (its datapath is transparent via gvproxy/SOCKS).

### `GIT_CONFIG_COUNT` / `GIT_CONFIG_KEY_0` / `GIT_CONFIG_VALUE_0` — container mode only (augur literals)
Added in `cmd_up` only inside the `[[ -n "$gh_token" ]]` guard, to give the container a self-contained git credential helper that reads `GH_TOKEN` without writing to the read-only `~/.gitconfig`. All three are hardcoded literals; `GIT_CONFIG_VALUE_0` is single-quoted so its embedded `$GH_TOKEN` expands **inside the container** at push time, not on the host. No host value rides in these — the secret only crosses via `GH_TOKEN`. (macOS achieves the same with a `git config --global` credential helper in `cmd_up_macos`, not env vars.)

### `DISABLE_AUTOUPDATER=1` — both modes (augur literal)
Hardcoded in `agent_fixed_env`. Container: `container exec -e DISABLE_AUTOUPDATER=1` at agent launch (in `cmd_claude` and the setup-token exec; `cmd_shell` passes no env). It is also baked as `ENV DISABLE_AUTOUPDATER=1` in the `Dockerfile`. macOS: an inline `DISABLE_AUTOUPDATER=1 claude` assignment prefix in the `zsh -l -c` command (in `cmd_claude_macos`). Not a host-env read.

---

## Host-only variables (read but never reach the guest)

| Variable | Use | Reaches guest |
|---|---|---|
| `HOME` | Locate host config files/dirs for mounts & scp sources (in `cmd_up` / `cmd_up_macos`) | No (guest `HOME` is fixed `/home/dev` / `/Users/admin`) |
| `SWIFT_VERSION` | Container base-image tag via `--build-arg`; `ARG` declared before `FROM`, no `ENV` persists it (`Dockerfile`, in `cmd_build` / `cmd_update`) | Value-only (observable as the toolchain version, not a runtime env var) |
| `AUGUR_PROXY_HTTP_PORT`, `AUGUR_CONTAINER_GATEWAY` | Host-only gateway IP+port; value embedded in the guest `HTTP_PROXY` string (in `cmd_up` / `egress_proxy_url`) | Value-only (non-secret internal address) |
| `AUGUR_CONTAINER_MEMORY` | Sets the host-side `--memory` run flag on Apple Container (in `resolve_container_memory`) | No |
| `AUGUR_PROXY_MAX_CONNECTIONS` | Read by the **host-side** augur-proxy process to size its connection cap (`augur-proxy` `main.swift`) | No (the proxy runs host-side, not in the agent guest) |
| `AUGUR_PROXY_IDLE_TIMEOUT` | Read by the **host-side** augur-proxy process to size its established-tunnel idle timeout (`augur-proxy` `main.swift`) | No (host-side only) |
| `AUGUR_VM_BIN`, `AUGUR_PROXY_BIN`, `AUGUR_GVPROXY_BIN` | Host path overrides for the backend binaries | No |
| `AUGUR_GLOBAL_CONF` | Path to the global egress allowlist; contents merged into a host-side allowlist enforced by the proxy | No |
| `AUGUR_EGRESS` | Host-side on/off switch for egress filtering | No |
| `AUGUR_PROXY_SOCKS_PORT`, `AUGUR_SSH_FWD_PORT`, `AUGUR_INTERNAL_SUBNET` | Host-side loopback ports / internal subnet | No |

---

## The one nuance: macOS SSH PTY — `TERM` only (terminal type)

`augur claude --macos` / `shell --macos` / the setup-token capture run `ssh -t` (PTY) via the `ssh_macos` helper. **Every** ssh/scp invocation in macOS mode — including these — is **hermetic** (`ssh -F /dev/null` / `scp -F /dev/null`), so no ssh_config is read (in `ssh_macos` / `scp_to_macos` / `ssh_macos_provision`). One host variable still crosses into the **macOS guest**:

1. **`$TERM`** — the SSH `pty-req` always carries the client's terminal-type to the server. This is a protocol-layer field (RFC 4254), independent of ssh_config, so `-F /dev/null` does not suppress it. The host `TERM` becomes the guest session's `TERM` on the interactive `-t` paths (`cmd_claude_macos` / `cmd_shell_macos` / `cmd_setup_token_macos`). Non-interactive paths — provisioning via `ssh_macos_provision` (`-n`, no `-t`), first-boot probes, and all `scp` — pass no `-t`, so they carry no `TERM`.

2. **`LANG` / `LC_*` — do NOT cross.** OpenSSH's stock `SendEnv LANG LC_*` lives in the system ssh_config, which `-F /dev/null` refuses to load; `augur` adds no `-o SendEnv`. So the env-request channel sends nothing and the guest sshd's `AcceptEnv` is moot.
   - **Correction (2026-07-08):** an earlier revision listed `LANG`/`LC_*` as able to cross "via OS-default `SendEnv`/`AcceptEnv`." That predates the hermetic `-F /dev/null` helpers; those variables no longer cross.

`TERM` is the only path by which a host variable `augur` never names reaches a guest. It is **bounded to the terminal type, carries no secret, and is protocol-default behavior — not configured by augur.** Container mode is unaffected: `container exec -it` / `run -t` allocate a PTY whose `TERM` is the engine's default, not a forward of the host `TERM`.

---

## Base-image custom provisioning — no host-env channel

Optional host-global provisioning (`~/.augur/provision/`) baked into / applied to the base image forwards no host env var:

- **macOS:** `manifest.conf` (Homebrew package names) and `hook.sh` run over the hermetic, no-PTY `ssh_macos_provision`. Package names are read from a **file** (charset-validated, passed as `printf '%q'` brew args); `hook.sh` is scp'd as a file and executed guest-side (`sudo bash …`), so its process env is the guest's, never the host's (in `run_base_provisioning`).
- **Apple Container:** `container-packages.conf` (apt package names) is passed as a single `--build-arg EXTRA_APT_PACKAGES=…` from that **file** (in `container_provision_build_args`); the `Dockerfile` `ARG EXTRA_APT_PACKAGES` is consumed by a `RUN`, never re-exported as `ENV`. `SWIFT_VERSION` is the only other `--build-arg`. No host env feeds either.

---

## Adjacent surface: host *files* (not environment variables)

For completeness — these expose host *files* (and any secrets those files contain), which is a different channel from environment variables:

- **Container mode** bind-mounts `~/.gitconfig` (`:ro`) and `~/.config/gh` (`:ro`, where on Linux `hosts.yml` may hold a plaintext token), plus a per-project history dir (from `~/.augur/claude-projects/…`, read-write) at the guest's `~/.claude/projects` (in `cmd_up`). **The host's `~/.claude` is deliberately *not* mounted** — Claude auth is injected via the env vars above (not the credential store), and the history dir is kept OUTSIDE the host's own `~/.claude/projects` tree so a hostile guest cannot forge transcripts the host's own Claude Code would enumerate.
  - **Correction (2026-07-08):** an earlier revision said Docker "bind-mounts `~/.claude` (incl. `.credentials.json` — Claude OAuth tokens at rest)." That predates the A3 history-isolation redesign; the host's `~/.claude` / `.credentials.json` is no longer mounted.
- **macOS** shares the workspace via virtiofs (`--dir`), keeps per-VM Claude history under `~/.augur/claude-projects/<vm>`, and scp's `~/.gitconfig` (in `cmd_up_macos`). `~/.claude` itself is **not** shared, and neither is `~/.config/gh`.
  - **Correction (2026-08-31, PR #168):** an earlier revision said macOS also shares `~/.config/gh` (`:ro`). It did, and that share carried the host's real `config.yml` and `hosts.yml` into the guest — but nothing ever wired it to `~/.config/gh` *inside* the VM (`grep -c ensure_macos_gh_config augur` is 0), so the config was never read while the files stayed readable: exposure without a feature. The share is removed from macOS mode. Container mode still bind-mounts it at `/home/dev/.config/gh`, the guest's real path, where it does work. `gh` in the macOS guest is unaffected — `GH_TOKEN` is the auth path on both engines, and on a macOS host gh keeps the token in the Keychain rather than in `hosts.yml`.
  - **Correction (2026-07-20, commit `3d59f7d`, #90):** an earlier revision said macOS scp's `~/.claude.json` ("onboarding state only — not auth"). It no longer does: `cmd_up_macos` now seeds the **same static stub the container image bakes** (`printf '{"hasCompletedOnboarding":true,"installMethod":"native"}\n'`) and never reads or copies the host's real `~/.claude.json` at all — not even a jq-stripped copy. This closes the exposure by construction rather than by filtering: the host's `~/.claude.json` enumerates every repo on the host (`projects`) and can hold third-party MCP API keys (`mcpServers`); neither ever reaches the guest now. The macOS OAuth token continues to live in the Keychain, not this file.
- The **workspace mount** is the developer's own repo; a checked-in `.env` is readable by the agent, but that is project content, not the host shell environment — `augur` does no `.env` handling.

These are file-origin credentials, not host-environment-variable exposure.

---

## Compiled components — no env channel to the guest

- **augur-vm (Swift):** the VM configuration is built solely from `config.json` + the `--dir` virtiofs shares + the network socket. No `ProcessInfo.environment`/`getenv`; the only host-attribute read is `processorCount` for CPU sizing (`Installer.swift`). `VZMacOSBootLoader` exposes no kernel command line, so a boot-args env leak is impossible by API (`RunSession.swift`).
- **augur-proxy (Swift):** reads its own (host-side) env var `AUGUR_PROXY_MAX_CONNECTIONS` to size the connection cap (`main.swift`), and otherwise only `CommandLine.arguments`. It runs on the host — it never reads the agent guest's env and injects nothing into the guest.
  - **Correction (2026-07-08):** an earlier revision said augur-proxy had "zero `getenv`/`ProcessInfo`." It now reads `AUGUR_PROXY_MAX_CONNECTIONS` — host-side only; no value crosses to the guest.
- **gvproxy (Go, augur patch):** zero `os.Getenv`/`os.Environ`; the DNS allowlist is read from a file passed by CLI flag.

---

## Invariants worth protecting (regression guards)

If these ever change, the conclusion above changes. Candidates for executable tests/lint (cf. the existing `augur-proxy/Tests/AugurProxyCoreTests/SecurityTests.swift`):

1. No bare `-e VAR` (without `=value`), no `--env-file`, and no `--env` glob in `augur` (the `run_args` / `eng exec` path).
2. Every ssh/scp invocation in macOS mode is hermetic (`-F /dev/null`) and sets no `SendEnv`/`SetEnv`; the guest sshd config is never modified to `AcceptEnv` extra vars. (This is what keeps `LANG`/`LC_*` from crossing — see the `TERM` nuance.)
3. The only **secrets** injected — into the container `run_args` and into the macOS `~/.augur-env` writer — are the three named ones (`ANTHROPIC_API_KEY`, `CLAUDE_CODE_OAUTH_TOKEN`, `GH_TOKEN`), all resolved through the `agent_auth_specs` seam. The `~/.augur-env` writer's other lines (a header comment, the `brew shellenv` eval, and the `~/.local/bin` PATH export) carry no host-derived values. No additional host secret is ever added.
4. The `augur-vm` backend never reads `ProcessInfo.environment`/`getenv` (only `processorCount` is permitted).
5. Base-image provisioning takes package lists from files (`manifest.conf` / `container-packages.conf`), never from host env; `hook.sh` runs guest-side.
