<p align="left">
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-0c90b4.svg" alt="License: MIT"></a>
</p>

<p align="center">
  <img src="resources/auger.png" alt="augur" width="320">
</p>

Run Claude Code in an isolated environment.
Works in any directory — only the current directory is exposed to the container or VM.

Two modes are available:

| | Container mode | macOS VM mode |
|---|---|---|
| **Isolation** | Linux container | macOS VM (Apple Virtualization Framework) |
| **Xcode / xcodebuild** | ✗ | ✓ |
| **iOS Simulator** | ✗ | ✓ |
| **Setup time** | ~5 min (image build) | ~75 min (VM build) |
| **Disk usage** | ~2 GB | ~70 GB+ |
| **Requires** | Apple Container (macOS 26+) | augur-vm (bundled), IPSW, Xcode XIP |

---

## Container mode (default)

Lightweight Linux container. Suitable for most projects that don't need Xcode.

The container is hosted by **Apple Container** (`container`, github.com/apple/container) on **macOS 26+** — native to macOS, no Docker Desktop, no licensing; each container runs in its own lightweight Linux VM. `augur status` shows the active engine.

### Setup

```bash
# 1. Run the install script
bash install

# 2. Reload shell config
source ~/.zshrc  # or source ~/.bashrc

# 3. Build the image
augur build
```

The install script copies `Dockerfile` and `augur` to `~/.augur/` and configures `PATH`. Safe to re-run.

> **Apple Container only:** `augur build`/`augur update` implicitly starts a BuildKit "builder" VM (~2 CPU/2GiB) that keeps running after the build finishes, to speed up the next one. It's a single instance shared by every `container build` on the machine — not scoped to a project — so augur deliberately never stops it for you (doing so from one project's `down`/`build` could kill another project's in-flight build). If you want to free the RAM/CPU, run `container builder stop` yourself once you're sure nothing else is building.

### Usage

```bash
cd ~/projects/my-app

augur up [--swift VERSION]      # start the container
augur claude                    # launch Claude Code
augur shell                     # open a bash shell (for debugging)
augur setup-token               # get a Claude subscription token (runs in the guest, saves on the host)
augur down                      # stop and remove the container
augur status                    # show status, toolchain, and auth info
augur build [--swift VERSION]   # build the container image
augur update [--swift VERSION]  # rebuild image with latest tool versions
augur init-conf                 # scaffold ./.augur/{allowlist,resources}.conf
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

> **The read/write workspace mount includes `.git` — treat it as attacker-controlled.** A prompt-injected agent running inside the container can write `.git/hooks/pre-commit` (or `post-checkout`, `post-merge`, …) into the mounted repo. Git runs repo-local hooks with no trust prompt, so the next `git` command *you* run on the **host** in that repo executes guest-authored code at your full host-user privilege — a complete escape of both the container boundary and the egress allowlist. This isn't a bug augur can close in software: it's inherent to mounting a repo read-write so an agent can edit it. Review diffs before trusting them, and treat `.git/hooks` (and anything else the host later runs unreviewed, e.g. a `Makefile` or `.envrc`) in an augur-touched repo as attacker-controlled until inspected. See `docs/security-reviews/2026-07-10-egress.md` §6 item 12.

> Claude Code's `--worktree` isn't specially supported (`augur claude --worktree ...` won't forward the flag). If you want it anyway: run `augur shell`, then type `claude --worktree <name>` yourself at the prompt — the worktree's files/git state persist fine, but its conversation history does not survive `augur down && up` (only the main checkout's project leaf is persisted). See `docs/decisions/0004-no-special-worktree-support.md` for the full trade-offs.

### Disk cleanup

`augur update`/`augur install-cert` rebuild the image and self-prune the previous generation
right after (`container image prune`), so normal use doesn't accumulate. For anything beyond
that — a stray stopped container from a crash mid-`up`, or reclaiming the shared builder's
own resources — use Apple Container's own commands directly:

```bash
container prune              # remove stopped containers
container image prune --all  # remove dangling AND unused tagged base images
container builder stop       # stop the shared BuildKit builder (see note above), or:
container builder delete     # delete it outright — also clears its own build cache
                              # (~/Library/Application Support/com.apple.container/build)
```

`augur` deliberately doesn't wrap these in a command of its own — they're already one-liners
in Apple's CLI, and disk cleanup beyond the automatic self-prune is rare enough not to carry
as a maintained wrapper. `container builder delete` is machine-wide, not scoped to this
project: it aborts any build in flight anywhere else on the Mac. See
`docs/decisions/0005-no-prune-command.md`.

### Requirements

- **Apple Container** (`container`) on macOS 26+
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
| Claude history | **only this project's** history is shared, in a per-VM isolated dir (`~/.augur/claude-projects/<vm>`), so other projects' transcripts stay invisible. Cross-mode (container↔macOS) resume is no longer shared. |
| Claude auth | **not** shared — injected via env (the macOS Keychain is unreadable over SSH; see above) |
| Everything else | **not visible to the VM** |

> The macOS guest auto-mounts the shared directory under `/Volumes/My Shared Files/workspace-<project>`; augur
> symlinks it to `~/workspace-<project>`. The sealed system volume can't host a symlink at `/workspace`, so the
> per-project `~/workspace-<project>` path is used in the VM (container mode uses `/workspace-<project>`).

> Same `.git/hooks` host-code-execution risk as container mode: the workspace mount here is read/write too, so a
> prompt-injected agent can plant a hook that runs on the host at your privilege the next time you `git` in this
> repo. See the note in [Container mode's File access](#file-access) section.

> Same caveat as container mode for Claude Code's `--worktree`: not specially supported, but `augur shell --macos` +
> manually running `claude --worktree <name>` works today. Unlike container mode, its conversation history *does*
> survive `augur down --macos`/`up --macos` (the VM's disk is stopped, not destroyed, until `augur destroy --macos`).
> See `docs/decisions/0004-no-special-worktree-support.md`.

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

### Disk cleanup

`augur destroy --macos` removes the *current* project's VM clone — but augur names a clone
from its project directory, so if that directory is later renamed or moved, the old clone
becomes unreachable by `destroy` (it's still on disk, just under a name `destroy` no longer
computes). `augur list --macos` still shows it; remove it directly:

```bash
augur list --macos       # every VM the store knows about, by name — not just this project's
augur-vm stop <name>     # if it's running
augur-vm delete <name>   # remove that VM/clone
```

Same story for `~/.augur/claude-projects/<vm>/` — a per-clone Claude-history directory that
`destroy --macos` doesn't touch either; it's plain files, safe to `rm -rf` once you know the
clone is gone for good. Both are accepted, documented trade-offs, not oversights — see
`docs/decisions/0004-no-special-worktree-support.md` (§9, "What actually shipped") and
`docs/decisions/0005-no-prune-command.md`.

### Requirements

- macOS (Apple Silicon)
- Xcode / Swift toolchain (to build the bundled `augur-vm` backend via `bash install`)
- macOS IPSW (Apple-signed)
- Xcode XIP (Apple-signed, from developer.apple.com)

---

## Egress allowlist (`.augur/allowlist.conf`)

Restrict the container/VM to a set of domains — everything else is blocked. Enforcement runs in a small proxy on the **host, as your user — it never needs `sudo`**. Useful for sandboxing an agent so it can only reach the services it should.

**On by default.** Filtering is always active using a **managed baseline** (`~/.augur/augur.conf.default`, shipped with sensible defaults and refreshed on every install). Add your own always-on domains to `~/.augur/augur.conf`, or per-project ones to a `./.augur/allowlist.conf` in the project root. To disable for one run, pass `--no-egress`.

```bash
cd ~/projects/my-app

# Optional: extend the baseline with project-specific domains
augur init-conf   # scaffolds ./.augur/allowlist.conf
cat >> .augur/allowlist.conf <<'EOF'
registry.example.com
api.myservice.com
EOF

augur up            # container, egress on (baseline + augur.conf + allowlist.conf if present)
augur up --macos    # macOS VM, same
augur up --no-egress  # disable egress filtering for this run
augur up --egress     # force egress filtering on (re-enables if AUGUR_EGRESS=0)
augur status        # shows: Egress on/off + the active allowlist
```

Filtering is on by default; set `AUGUR_EGRESS=0` to disable it persistently, or `AUGUR_EGRESS=1` to force it on. The `--no-egress` / `--egress` flags override that environment variable for a single run.

### `.augur/allowlist.conf` format

One pattern per line, `#` for comments:

| Pattern | Matches |
|---|---|
| `example.com` | that exact host (the apex) only |
| `*.example.com` | subdomains only (`api.example.com`, not `example.com`) |
| `.example.com` | the apex **and** all subdomains |

The effective list is three layers merged (union — a layer can only widen, never narrow):

1. **Managed baseline** (`~/.augur/augur.conf.default`) — shipped defaults for Claude Code / GitHub / Homebrew. augur owns this file and **refreshes it on every install**, so shipped domain updates reach you automatically. Don't edit it; your changes are overwritten.
2. **Your global additions** (`~/.augur/augur.conf`) — always-on domains you add. **Never overwritten** by install.
3. **Project** (`./.augur/allowlist.conf`) — per-project domains.

The merge happens on the host, so the guest can't widen its own policy by editing the mounted file. Edits take effect on the next `augur up`.

**Project domains require approval (trust-on-first-use).** Because `./.augur/allowlist.conf` ships inside a repository you may not fully trust, augur shows the domains it adds and asks you to approve them on first sight and again whenever the file changes — the same model as SSH host keys. The approval fingerprint is stored host-side under `~/.augur/project-hashes/` (never in the project tree or a mounted share), so a compromised guest that rewrites `./.augur/allowlist.conf` cannot get the change honored without a fresh host-side approval. `augur status` shows the project's domains and whether they're approved. For non-interactive / disposable runs (CI), set `AUGUR_ACCEPT_PROJECT_CONF=1` to accept automatically; without a TTY and without that variable, an unapproved/changed conf fails closed.

### How it works

| Mode | Enforcement |
|------|-------------|
| **Container** | The agent runs on a **host-only** `--internal` network (internet severed; the host reachable) with `NET_ADMIN` dropped and `--no-dns` (external DNS fails closed). The **host-side** `augur-proxy` is its only egress, reached via the host-only gateway. A boot self-test fails closed if direct egress is ever reachable. **Trade-off:** host-only also lets the agent reach other host services bound to `0.0.0.0`; closing it would need host `pf` rules (sudo), which augur avoids. |
| **macOS VM** | The guest's only NIC is a host-owned socket (`VZFileHandleNetworkDeviceAttachment`); a bundled `gvproxy` runs the guest's network on the host and funnels every connection to the proxy. Needs no special entitlement. |

In every mode the proxy decides by domain (the CONNECT host, or the TLS SNI / HTTP Host) and connects out by name.

### Requirements

`install` builds the proxy (`augur-proxy`, Swift) automatically — both container and macOS VM modes run the native host `augur-proxy`. **macOS VM egress also needs Go** (for `augur-gvproxy`) — `brew install go`, then re-run `bash install`. Without it, macOS VM egress is unavailable but everything else works.

The host ports the proxy uses are derived per-project so two egress-enabled projects can run at once; override with `AUGUR_PROXY_HTTP_PORT` / `AUGUR_PROXY_SOCKS_PORT` / `AUGUR_SSH_FWD_PORT` if needed.

> **Scope.** This guarantees *"the guest can only reach allowlisted domains."* DNS is gated on the same allowlist (a name resolves only if it's connectable), so the guest can't tunnel data out via DNS queries either. It is still **not** exfiltration-proof: an allowlisted, writable host (e.g. `github.com` with your `GH_TOKEN`) and the shared workspace are intentional channels. This is a deliberate, accepted boundary, not a gap augur intends to close — see [`docs/decisions/0008-exfiltration-ceiling-accepted.md`](docs/decisions/0008-exfiltration-ceiling-accepted.md) for why. See also `augur-proxy/README.md` and `gvproxy/README.md`.

---

## Container memory (`.augur/resources.conf`)

Apple Container's per-container default memory (~1 GB) is too tight for running an agent, so augur passes `--memory 4g` by default.

To change the default for a project — and have it apply consistently everywhere you clone or open that project, unlike an environment variable that only exists on the machine where you set it — commit a `.augur/resources.conf` (`augur init-conf` scaffolds one alongside the allowlist):

```bash
augur init-conf                   # or by hand: mkdir -p .augur
echo "MEMORY=8g" > .augur/resources.conf
```

Precedence: an `AUGUR_CONTAINER_MEMORY` environment variable (if set) overrides `.augur/resources.conf`, which overrides the built-in `4g` default. `augur status` shows the effective value. Like `.augur/allowlist.conf`, this file is guest-writable (it lives inside the mounted workspace) — but unlike the allowlist, it carries **no approval gate**: a guest requesting more or less memory for itself isn't a containment breach the way widening egress is, so it just takes effect on the next `augur up`.

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

---

## Testing & CI

augur's tests are split by what each layer can prove on a free runner, and by which bugs
each layer actually catches.

```bash
make unit           # Swift build/test + shellcheck + version smoke              (CI: macos-26)
make offline-tests  # seam + command-construction shell tiers (shimmed engine)   (CI: ubuntu)
make container-e2e  # LOCAL egress FAIL-CLOSED proof on Apple Container (macOS 26+)
make e2e            # LOCAL pre-release gate: macOS VM boot + xcodebuild test (never in CI)
```

The shell test tiers live in `tests/` and run via `tests/run.sh` (see `tests/README.md`);
each live tier self-skips when its prerequisites are absent, so the same command is safe in
CI, the Linux dev container, and on a Mac.

### Continuous integration (`.github/workflows/ci.yml`)

CI runs on **free GitHub-hosted runners only**, and **no CI job boots a VZ guest**:

| Job | Runner | What it proves |
|-----|--------|----------------|
| `build-unit` | `macos-26` | `swift build`/`swift test` the CLIs (`augur-vm` builds, `augur-proxy` builds + tests), `shellcheck`, and a side-effect-free `augur version` smoke. No engine, no VM. |
| `offline-tests` | `ubuntu-latest` | The seam + command-construction tiers: drive the real `cmd_up`/`cmd_claude` against a `container` shim and assert the built argv is byte-identical to the seam's declaration. No engine/VM needed. |

Both jobs are **secrets-zero** — the coding agent is never authenticated in CI. So
`pull_request` runs from forks are safe: there is nothing to exfiltrate.

**Why the live E2Es are *not* in CI.** GitHub's arm64 macOS runners are themselves
Virtualization.framework guests with **no nested virtualization** (confirmed by GitHub; the
request to enable it was closed as not planned). So anything that boots a VM/microVM — the
macOS VM mode or Apple Container mode — **cannot run on any GitHub-hosted runner** (standard
*or* larger). A bigger runner gives more cores/RAM, not nesting. Those heavy paths — the
Apple Container egress fail-closed proof (`make container-e2e`) and the macOS VM E2E (`make
e2e`) — are gated locally instead.

### Pre-release gate (`make e2e`, local only)

Before tagging a release, run the macOS-VM E2E on a real Mac:

```bash
# from your project directory (boots the VM; verifies mount + testmanagerd + egress fail-closed)
make -C /path/to/augur e2e
# add a real in-VM build:
AUGUR_E2E_PROJECT=/path/to/app AUGUR_E2E_SCHEME=App make -C /path/to/augur e2e
```

This boots the macOS VM, checks the **virtiofs** workspace mount and **testmanagerd**
reachability, optionally runs **`xcodebuild test`** inside the VM, and re-proves the
**egress fail-closed** guarantee for the VM datapath (the macOS-VM variant of the
`container-e2e` assertions). It's local-only for the nested-virtualization reason above, and
because it needs Apple-signed IPSW/XIP that can't live in CI.

### Cutting a release (structural gate)

The `make e2e` gate above can't run in CI, so instead of *trusting* a human to remember it,
the release is **structurally** blocked until it passes. The pieces:

- **`VERSION`** (repo root) is the single source of truth for the version number. `augur
  version` reads it; **tags are the *output* of a release, never the input.** A checkout
  whose HEAD is exactly `v<VERSION>` reports the bare number; any other checkout reports
  `<VERSION>-dev+<sha>`.
- **Branches** (model B): `main` is the everyday branch (all existing CI runs here). The
  `release` branch is gate-passage-only and protected — a commit cannot reach it without a
  green `e2e/macos-vm` status.
- **`scripts/release-gate.sh`** runs `make e2e` on your Mac and posts its result as the
  `e2e/macos-vm` commit status. The status is issued **only** on exit 0, so it can't be
  faked or skipped.
- **`.github/workflows/release.yml`** fires on push to `release`, reads `VERSION`, and — if
  no tag `v<VERSION>` exists yet — creates the annotated tag and a GitHub Release. Bumping
  nothing, or a follow-up commit, is a safe **no-op** (collision guard). It boots no VM.

**One-time setup (human, admin):**

```bash
# 1. Create the gate-passage branch at the current released commit, then protect it.
git push origin main:refs/heads/release
gh api -X PUT repos/h1d3mun3/augur/branches/release/protection --input - <<'JSON'
{ "required_status_checks": { "strict": true, "contexts": ["e2e/macos-vm"] },
  "enforce_admins": true, "required_pull_request_reviews": null,
  "restrictions": null, "required_linear_history": false,
  "allow_force_pushes": false, "allow_deletions": false }
JSON

# 2. Create a fine-grained PAT scoped to this repo with ONLY "Commit statuses: write",
#    and store it in the login Keychain (once):
security add-generic-password -s augur-release-gate -a "$USER" -w <TOKEN>
```

**Releasing:**

```bash
# 1. Bump VERSION on main via a normal PR (e.g. 0.9.0 -> 0.10.0), get it merged.
# 2. On your Mac, from a clean checkout of that main commit, prove the E2E:
scripts/release-gate.sh                 # runs `make e2e`; posts e2e/macos-vm=success on green
# 3. Fast-forward release to that (now-green) commit. Branch protection permits the push
#    only because the SHA carries the green status, so the tested SHA == the tagged SHA:
git fetch origin && git push origin origin/main:release
# release.yml then tags v0.10.0 and cuts the GitHub Release. Done.
```

The fast-forward push moves `release` to the *exact* commit that carried the green
`e2e/macos-vm` status, and branch protection only accepts a tip that carries that status, so
**the tested SHA is identical to the SHA the tag points at** — you can never tag something
the E2E didn't actually run against. (`required_linear_history` is deliberately **off**:
`main` is integrated with merge commits, which that rule would reject on the fast-forward,
and it buys nothing here — the exact-SHA push already gives the tested==tagged guarantee.)
