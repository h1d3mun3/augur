# Security review: host environment-variable exposure to the guest

- **Date:** 2026-06-25 (citations re-verified 2026-06-28; re-baselined 2026-07-08 for the Apple Container engine migration, the unified auth seam, and the hermetic SSH helpers; re-baselined again 2026-07-08 after Docker support was dropped — Apple Container is now the sole container engine; re-baselined 2026-07-20 after macOS mode stopped scp'ing `~/.claude.json` entirely, commit `3d59f7d`; re-baselined 2026-09-24 after Container mode moved credentials, `TZ` and the git credential helper from `container run` to the per-session `container exec`; re-baselined 2026-11-07 after macOS VM mode moved the credentials out of `~/.augur-env` onto the `claude`/`shell --macos` session ssh's environment, via `SendEnv`/`AcceptEnv` for exactly the named variables).
- **Scope:** Whether host (developer-machine) *environment variables* are exposed to the guest OS, in **container mode** (Apple Container, macOS 26+) and **macOS VM mode**.
- **Status:** Living document — re-verify when the container `run`/`exec` invocations (`cmd_up` / `cmd_claude` / `cmd_shell`), the macOS session ssh (`ssh_macos_session`, called by `cmd_claude_macos` / `cmd_shell_macos`), the `~/.augur-env` writer `push_macos_guest_env` (called by `cmd_up_macos` and `prepare_macos_session`), the base VM's sshd drop-in (`install_macos_session_env_acceptance`), the SSH helpers (`ssh_macos` / `ssh_macos_provision`), the base-image provisioning path, or the `augur-vm` VM configuration change. Source citations reference `augur` functions by name (not line numbers) so they survive unrelated edits.
- **Method:** Multi-angle source inspection (container runtime, macOS runtime, build-time baking, mounted/copied files, full env-var census) followed by an adversarial pass that actively hunted for any channel leaking an *unnamed* host variable, plus a completeness pass that opened every otherwise-unread file/command path. Re-verified 2026-07-08 against the post-migration source (the `eng` engine abstraction, the `agent_auth_specs` auth seam, and the hermetic `-F /dev/null` SSH helpers), with an adversarial completeness sweep per mode.

> This is an **assessment of the current security posture**, not a decision record. The genuine *decisions* it rests on (inject credentials via the environment rather than mounting the Keychain; never forward the host environment wholesale) belong in an ADR that links back here, if/when one is written.

---

## Bottom line

**Neither mode exposes the host environment wholesale.** `augur` uses no environment-inheritance mechanism anywhere — no container `run`/`exec` env inheritance, no `--env-file` that reads a host file or the host env, no bare `-e VAR` pass-through, no ssh `SetEnv` and no `SendEnv`/`AcceptEnv` pattern, and no serialization of `ProcessInfo.environment` into the VM. Container mode injects env only via an explicit `run_args` array (`container run -e …`, egress proxy vars only), `container exec -e …`, and — for the credentials, on the `augur claude` / `augur shell` exec only — `container exec --env-file <(session_credential_env)`, a pipe augur writes with the bash builtin `printf` from the named `agent_auth_specs` values plus `gh auth token`. macOS VM mode sends the same resolved values only on the `augur claude --macos` / `augur shell --macos` session ssh (`ssh_macos_session`): a subshell exports them into that one `ssh` process and passes `-o SendEnv=<NAME>` for exactly those names, and the base VM's sshd `AcceptEnv`s exactly those names (`session_credential_names`). Only **explicitly named** variables cross, by value.

| | Container mode (Apple Container) | macOS VM mode |
|---|---|---|
| Wholesale host-env forwarding | **No** | **No** |
| Host-derived secrets that become guest env vars | `ANTHROPIC_API_KEY`, `CLAUDE_CODE_OAUTH_TOKEN`, `GH_TOKEN` | `ANTHROPIC_API_KEY`, `CLAUDE_CODE_OAUTH_TOKEN`, `GH_TOKEN` |
| When secrets are injected | per session, on the `augur claude` / `augur shell` exec only (not `container run`, not `setup-token`) | per session, as the environment of the `augur claude --macos` / `augur shell --macos` ssh only (not `up --macos`, not `setup-token`, never on the guest's disk) |
| augur-built (non-secret) guest env vars | `HTTP(S)_PROXY`/`NO_PROXY` (egress only, at `run`); per session: `TZ` (from `/etc/localtime`, not env), `GIT_CONFIG_*` (only when a gh token is present), `DISABLE_AUTOUPDATER=1` (claude only) | `DISABLE_AUTOUPDATER=1`; `GIT_CONFIG_*` (only when a gh token is present) |
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
- Container: a `ANTHROPIC_API_KEY=…` line in `container exec --env-file <(session_credential_env)`, on the `augur claude` / `augur shell` exec only (in `cmd_claude` / `cmd_shell`). Never on `container run`, so it is not in the container's persisted config or `container inspect`, and never on any argv.
  - **Correction (2026-09-24):** an earlier revision said `container run -e "ANTHROPIC_API_KEY=…"` (in `cmd_up`). Container mode no longer passes any credential to `container run`; the same applies to `CLAUDE_CODE_OAUTH_TOKEN` and `GH_TOKEN` below.
- macOS: in the environment of the `augur claude --macos` / `augur shell --macos` session ssh, sent with `-o SendEnv=ANTHROPIC_API_KEY` and accepted by the guest sshd's `AcceptEnv` drop-in, so it is an env var of that session's processes only (in `ssh_macos_session`). Never written to `~/.augur-env` or any other guest file.
  - **Correction (2026-11-07):** an earlier revision said macOS writes it as `export ANTHROPIC_API_KEY='…'` into `~/.augur-env`. It no longer does; the same applies to `CLAUDE_CODE_OAUTH_TOKEN` and `GH_TOKEN` below.

### `CLAUDE_CODE_OAUTH_TOKEN` — **both modes** (named secret)
Read from the host env, else `~/.claude_code_oauth_token`, via `resolve_api_key` — from the **same** `agent_auth_specs` table as `ANTHROPIC_API_KEY`.
- Container: a `CLAUDE_CODE_OAUTH_TOKEN=…` line in the same per-session `--env-file` (in `cmd_claude` / `cmd_shell`).
- macOS: the same session ssh environment (`-o SendEnv=CLAUDE_CODE_OAUTH_TOKEN`, in `ssh_macos_session`).
- Both auth vars are injected whenever set; `augur` applies **no** precedence itself — Claude Code applies the official `ANTHROPIC_API_KEY` > `CLAUDE_CODE_OAUTH_TOKEN` order when both are present. Both modes (container and macOS VM) forward it, resolved from the same `agent_auth_specs` table. (`cmd_status` still only *reads* it host-side for a display checkmark.)

### `GH_TOKEN` — both modes (named secret)
Obtained by running the subprocess `gh auth token` (in `resolve_session_credentials`, shared by both modes).
- Container: a `GH_TOKEN=…` line in the same per-session `--env-file` (in `cmd_claude` / `cmd_shell`).
- macOS: the same session ssh environment (`-o SendEnv=GH_TOKEN`, in `ssh_macos_session`), plus the `GIT_CONFIG_*` credential helper that echoes `password=$GH_TOKEN` for `github.com`, exported by that session's remote command (in `macos_session_git_env_cmd`, called by `ssh_macos_session`), never in `~/.augur-env` — the helper holds only the *reference* `$GH_TOKEN`, not the value, and the token itself is never written to the guest's disk.
- **Note (unnamed-host-var transit):** `augur` does not read the shell `$GH_TOKEN`/`$GITHUB_TOKEN` directly, but `gh auth token` honors them, so a host token can transit into the guest's `GH_TOKEN` via that subprocess. This is the one path by which a host variable `augur` never *names* crosses in container mode too (macOS is the same).

### `HTTP_PROXY` / `HTTPS_PROXY` / `NO_PROXY` (+ lowercase) — container mode, egress only (augur-built, not host-derived)
Set in the guest to force traffic through augur-proxy (in `cmd_up`, only when `egress_enabled`). **The host's own proxy variables are never read.** The value comes from `egress_proxy_url`: it points at the host-only gateway (`container_egress_gateway`, overridable by `AUGUR_CONTAINER_GATEWAY`). `NO_PROXY` is the literal `localhost,127.0.0.1`. macOS VM mode does not set these (its datapath is transparent via gvproxy/SOCKS).

### `GIT_CONFIG_COUNT` / `GIT_CONFIG_KEY_0..1` / `GIT_CONFIG_VALUE_0..1` — both modes (augur literals)
Defined once in `git_credential_env` and emitted only when `gh auth token` returns a value. Container: per session as `container exec -e` (in `_add_session_exec_env`, called by `cmd_claude` / `cmd_shell`). macOS: as `export NAME='…'; ` commands at the front of the `claude` / `shell --macos` session's remote command (in `macos_session_git_env_cmd`), only when the session sends `GH_TOKEN`, so a guest shell augur did not start has none; augur no longer edits the guest's copied `~/.gitconfig`. They give the guest a self-contained git credential helper that reads `GH_TOKEN` without writing any git config file. All are hardcoded literals: entry 0 is an empty helper value that resets the helper chain (git reads env config after every config file, so helpers named in system, XDG, global, included or repository config, such as macOS git's system `osxkeychain` or the host `~/.gitconfig`'s helpers, are never called for `github.com`), entry 1 is the helper itself. `GIT_CONFIG_VALUE_1` is single-quoted so its embedded `$GH_TOKEN` expands **inside the guest**, in the helper's shell at push time, not on the host and not when the export runs. No host value rides in these — the secret only crosses via `GH_TOKEN`.

### `DISABLE_AUTOUPDATER=1` — both modes (augur literal)
Hardcoded in `agent_fixed_env`. Container: `container exec -e DISABLE_AUTOUPDATER=1` at agent launch (in `cmd_claude` and the setup-token exec; `cmd_shell` passes only the per-session `TZ` / `GIT_CONFIG_*` and the credential `--env-file`). It is also baked as `ENV DISABLE_AUTOUPDATER=1` in the `Dockerfile`. macOS: an inline `DISABLE_AUTOUPDATER=1 claude` assignment prefix in the `zsh -l -c` command (in `cmd_claude_macos`). Not a host-env read.

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

`augur claude --macos` / `shell --macos` (through `ssh_macos_session`) and the setup-token capture (through `ssh_macos`) run `ssh -t` (PTY). **Every** ssh/scp invocation in macOS mode — including these — is **hermetic** (`ssh -F /dev/null` / `scp -F /dev/null`), so no ssh_config is read (in `ssh_macos` / `scp_to_macos` / `ssh_macos_provision`). One host variable still crosses into the **macOS guest**:

1. **`$TERM`** — the SSH `pty-req` always carries the client's terminal-type to the server. This is a protocol-layer field (RFC 4254), independent of ssh_config, so `-F /dev/null` does not suppress it. The host `TERM` becomes the guest session's `TERM` on the interactive `-t` paths (`cmd_claude_macos` / `cmd_shell_macos` / `cmd_setup_token_macos`). Non-interactive paths — provisioning via `ssh_macos_provision` (`-n`, no `-t`), first-boot probes, and all `scp` — pass no `-t`, so they carry no `TERM`.

2. **`LANG` / `LC_*` — do NOT cross.** OpenSSH's stock `SendEnv LANG LC_*` lives in the system ssh_config, which `-F /dev/null` refuses to load; `augur` adds `-o SendEnv=<NAME>` only on the `claude`/`shell --macos` session ssh, and only for the resolved credential names (never a pattern). So the env-request channel carries those credentials and nothing else, and the guest sshd accepts only them plus its own stock `LANG LC_*`, which the client never sends.
   - **Correction (2026-07-08):** an earlier revision listed `LANG`/`LC_*` as able to cross "via OS-default `SendEnv`/`AcceptEnv`." That predates the hermetic `-F /dev/null` helpers; those variables no longer cross.

`TERM` is the only path by which a host variable `augur` never names reaches a guest. It is **bounded to the terminal type, carries no secret, and is protocol-default behavior — not configured by augur.** Container mode is unaffected: `container exec -it` / `run -t` allocate a PTY whose `TERM` is the engine's default, not a forward of the host `TERM`.

---

## Base-image custom provisioning — no host-env channel

Optional host-global provisioning (`~/.augur/provision/`) baked into / applied to the base image forwards no host env var:

- **macOS:** `manifest.conf` (Homebrew package names) and `hook.sh` run over the hermetic, no-PTY provisioning ssh (`ssh_macos_provision`, and for the hook `ssh_macos_provision_stdin`, whose remote command starts at `/usr/bin/sudo` with no Homebrew prefix). Package names are read from a **file** (charset-validated, passed as `printf '%q'` brew args); `hook.sh` travels base64-encoded inside a root script on one connection's stdin (`macos_run_root_script`, never on an argv or in a guest-user-writable file), and root runs it, with the first `bash` on its Homebrew-first PATH, from a fresh 0700 directory under `/var/root`, so its process env is the guest's (what `sudo` leaves, plus Homebrew's PATH and `HOMEBREW_*` variables set by root), never the host's (`run_provision_hook`, in `run_base_provisioning`).
- **Apple Container:** `container-packages.conf` (apt package names) is passed as a single `--build-arg EXTRA_APT_PACKAGES=…` from that **file** (in `container_provision_build_args`); the `Dockerfile` `ARG EXTRA_APT_PACKAGES` is consumed by a `RUN`, never re-exported as `ENV`. `SWIFT_VERSION` is the only other `--build-arg`. No host env feeds either.

---

## Adjacent surface: host *files* (not environment variables)

For completeness — these expose host *files* (and any secrets those files contain), which is a different channel from environment variables:

- **Container mode** bind-mounts `~/.gitconfig` (`:ro`), plus a per-project history dir (from `~/.augur/claude-projects/…`, read-write) at the guest's `~/.claude/projects` (in `cmd_up`). **The host's `~/.claude` is deliberately *not* mounted** — Claude auth is injected via the env vars above (not the credential store), and the history dir is kept OUTSIDE the host's own `~/.claude/projects` tree so a hostile guest cannot forge transcripts the host's own Claude Code would enumerate.
  - **Correction (2026-07-08):** an earlier revision said Docker "bind-mounts `~/.claude` (incl. `.credentials.json` — Claude OAuth tokens at rest)." That predates the A3 history-isolation redesign; the host's `~/.claude` / `.credentials.json` is no longer mounted.
  - **Correction (2026-09-25, PR #216):** an earlier revision listed `~/.config/gh` (`:ro`) among Container mode's bind mounts. It no longer is: `_add_host_config_run_args` neither mounts it nor creates it on the host, matching macOS mode. On a macOS host gh keeps the token in the Keychain, so the mounted `hosts.yml` only added a dead account to `gh auth status` in the guest; after `gh auth login --insecure-storage` it exposed a plaintext token to the guest. `gh` in the container authenticates only through the per-session `GH_TOKEN`. A container created with the mount keeps it until it is recreated (`augur destroy && augur up`, or any fingerprint change). The 2026-08-31 correction below still says Container mode bind-mounts it; that was true when written.
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

1. No bare `-e VAR` (without `=value`), no `--env` glob, and no `--env-file` other than the per-session `<(session_credential_env)` pipe in `augur` (the `run_args` / `eng exec` path).
2. Every ssh/scp invocation in macOS mode is hermetic (`-F /dev/null`) and sets no `SetEnv`; the only `SendEnv` is `ssh_macos_session`'s, for exactly the resolved credential names, and the guest sshd's only augur `AcceptEnv` is the base VM drop-in naming exactly `session_credential_names`. (This is what keeps `LANG`/`LC_*` and every other host variable from crossing — see the `TERM` nuance.)
3. The only **secrets** injected — into the container's per-session `--env-file` (never `run_args`) and into the macOS session ssh's environment — are the three named ones (`ANTHROPIC_API_KEY`, `CLAUDE_CODE_OAUTH_TOKEN`, `GH_TOKEN`), all resolved through the `agent_auth_specs` seam. The macOS `~/.augur-env` writer carries no credential at all, and its lines (a header comment, the `brew shellenv` eval, the `~/.local/bin` PATH export, `DEVELOPER_DIR`, `agent_fixed_env`) carry no host-derived values. No additional host secret is ever added.
4. The `augur-vm` backend never reads `ProcessInfo.environment`/`getenv` (only `processorCount` is permitted).
5. Base-image provisioning takes package lists from files (`manifest.conf` / `container-packages.conf`), never from host env; `hook.sh` runs guest-side.
