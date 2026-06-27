# Design notes: per-run agent/LLM profiles (local Ollama, alternate agents)

- **Date:** 2026-06-27
- **Status:** **Explored but NOT shipped.** A design + lessons record kept for the day augur
  needs to make its agent swappable (e.g. add Aider) or point at a local/LAN LLM. It was
  built end-to-end and security-reviewed, then set aside because the expected use was too
  low to justify carrying the surface in mainline. The full, working implementation (proxy
  IP-rule egress, the generic `.augur.llm` profile system, bundled Aider, tests) is
  **preserved on the `feature/ollama-llm-endpoint` branch** (PR #35, closed unmerged) —
  cherry-pick from there rather than re-deriving.
- **Scope:** Letting `augur` run a coding agent against a non-Anthropic LLM endpoint —
  primarily a LAN or Tailscale [Ollama](https://ollama.com) server addressed by IP — for a
  **single run**, selected at launch, in both Docker and macOS VM modes, **without weakening
  the egress guarantee**; and generalizing the mechanism so the agent itself (Claude Code,
  Aider, …) is a swappable payload rather than a hard dependency.

> The sections below describe the design **as implemented on that branch** (present tense).
> They are the record to follow if/when the capability is revived; they do **not** describe
> anything currently in mainline augur.

---

## Motivation

Two needs, one mechanism:

1. **Backend availability / sensitivity.** Within the same project, case-by-case: drop from Anthropic's cloud to a local model — "Anthropic is down, use local", or "this content is sensitive, keep it local". The switch must be **per-invocation** (not a sticky host setting); the default stays Anthropic.
2. **Tool-supply resilience.** augur's durable asset is the **sandbox** (egress allowlist, isolation, no host sudo), not any one agent. If Claude Code is ever pulled/restricted/broken, augur should still deliver value with another agent. So the agent is treated as a **swappable payload**, with one alternate (Aider) bundled and proven so the hedge is real rather than theoretical.

### Non-goals

- **Cloud "ultra" features** (e.g. `/code-review ultra`) run on Anthropic's backend and ignore `ANTHROPIC_BASE_URL`; unavailable against a local endpoint (and inconsistent with the sensitivity use case anyway).
- **Heavy multi-agent orchestration** mechanically follows the endpoint but is slow (one local GPU serializes agents) and unreliable (local models are weaker at sustained tool-calling). A local profile targets **ordinary single-agent editing**.
- Becoming a maintained multi-agent platform: Claude Code is first-class, Aider is a bundled fallback, everything else is bring-your-own (`augur shell` / fork).

---

## Two layers, two homes

| Concern | Where it lives | Switching unit |
|---|---|---|
| **Profile definition** (launch command, env, secrets, egress) | project `.augur.llm` (or global `~/.augur/augur.llm`) | resident per project |
| **Which profile to use** | launch flag `--profile <name>` / `--local` | **per run** |
| **Permitting traffic to the endpoint** | derived from the active profile's `allow`, appended to the merged allowlist | **per run** (closed again on a plain `augur claude`) |

`.augur.conf` (the egress allowlist) and `.augur.llm` (profiles) are kept **separate**: different grammars, different trust handling (below).

---

## Profile format (`.augur.llm`, generic)

INI-style named sections; project file preferred, global fallback. Scaffolded by `augur init-llm`.

```ini
[local]
launch  = claude                                       # the agent (default: claude)
env.ANTHROPIC_BASE_URL = http://192.168.1.50:11434     # literal guest env var
env.ANTHROPIC_MODEL    = qwen2.5-coder:32b
env.ANTHROPIC_SMALL_FAST_MODEL = qwen2.5-coder:7b      # else background tasks hit api.anthropic.com
env.ANTHROPIC_AUTH_TOKEN = ollama                      # dummy; Ollama needs no key
allow   = 192.168.1.50:11434                           # egress this run may open

[aider-local]
launch  = aider --model ollama/qwen2.5-coder:32b --no-auto-commits
env.OLLAMA_API_BASE = http://192.168.1.50:11434
allow   = 192.168.1.50:11434

[remote]
launch  = claude
env.ANTHROPIC_BASE_URL = https://ollama.example.com
secret.ANTHROPIC_AUTH_TOKEN = MY_OLLAMA_TOKEN          # resolved from the HOST env, never inlined
allow   = ollama.example.com
```

- `launch` — the command run in the sandbox (default `claude`). Word-split for args; no quoted spaces.
- `env.<NAME>` — literal env var injected into the guest process (per-invocation).
- `secret.<NAME>` / `secretfile.<NAME>` — env var resolved from a **host** env var / file. For authenticated endpoints; never commit the secret itself.
- `allow` — egress entries to open for this run (space/comma-separated, repeatable). An IP keeps its `:port` (→ proxy IP rule); a hostname drops the port (→ domain rule).

Ollama speaks an **Anthropic-compatible `/v1/messages`** (v0.14+), so Claude Code needs no translation proxy for the common case. Inherent Ollama limits (no `count_tokens`, no prompt caching, lower tool-calling fidelity) are model/server limits, not augur's.

### Injection per mode

- **Docker:** extra `-e KEY=VALUE` on `docker exec`, launch word-split as the exec command (per-invocation; the container env from `up` is untouched).
- **macOS VM:** inline `KEY=VALUE` prefix + launch on the remote command over SSH (per-invocation; `~/.augur-env`, the persistent secret file, is untouched).

---

## Egress security model

augur's invariant: **all guest egress flows through the host-side proxy**; only allowlisted destinations are reachable; the guest never holds a direct route out. A LAN/Tailscale endpoint is reached the same way — the Docker sidecar (dual-homed) and macOS gvproxy can route to it; the agent only ever talks to the proxy.

Reaching a private IP is a **new and powerful capability** (the proxy historically blocked *all* private destinations to prevent SSRF). It is granted narrowly, enforced at three points:

### 1. The proxy honors an explicit IP rule (`augur-proxy`)

- `Allowlist` parses `IPv4:port` rules (`allowsIP`), kept **separate** from domain matching (`allows` still rejects IP literals). A **port is mandatory** (a portless rule would open every port on a host); **IPv6 IP rules are deferred** (their SOCKS `atyp=4` textual form needs canonicalization first).
- `Filter.decideDial` returns the verdict **and** an `explicitIP` flag from a **single allowlist snapshot** (no decide-vs-exception hot-reload race).
- `Sock.dialBlocked` is the one dial gate: under `lanException` (an explicit IP rule), it permits **only a reachable-private address** — RFC1918 **plus CGNAT 100.64/10 (Tailscale)** — and blocks everything else, including **public IPs** (an IP rule is for a vetted private/tailnet endpoint, not arbitrary public exfil; use a hostname for public) and **loopback / link-local / cloud-metadata**. Containment rests on re-vetting every *resolved* `sockaddr`, not on `getaddrinfo` returning the literal.

### 2. Untrusted layers can't open an IP (`augur` host-side merge)

`./.augur.conf` and `./.augur.llm` live in the workspace — they ship in cloned repos and are writable by the (prompt-injectable) agent. So:

- `write_merged_allowlist` runs the project `./.augur.conf` through **`strip_project_ip_rules`**, which drops every IP-literal line (keeping domains). IP rules are honored only from the host-side **baseline/global** layers and from a profile's `allow`.
- A profile's `allow` is trusted only because the user **explicitly** selected the profile *and* confirmed it (below).

### 3. Activating a workspace profile requires confirmation (`augur`)

Because `.augur.llm` is repo-located, `confirm_llm_profile` prints the launch command + egress the profile will open and asks to confirm before activating (`AUGUR_ASSUME_YES=1` skips; non-interactive without it fails closed). This catches a hostile repo's `[local]` pointing somewhere unexpected.

> **Residual, accepted/documented.** A user who lists their *own* host's LAN/Tailscale IP can reach host services bound to `0.0.0.0` (the loopback block doesn't cover the host's routable private IP). The Docker datapath also receives the exception (both modes are in scope). Pre-existing, out-of-scope items surfaced by review: no global connection cap (DoS) and raw-domain bytes in the SOCKS deny log — tracked separately.

This model was shaped by an adversarial SSRF review (multi-agent): it caught IPv6-ULA-metadata admission, public-IP egress via IP rules, portless all-ports, a decide/exception TOCTOU, and — most importantly — that **provenance must be enforced host-side** because the proxy sees only a single flattened allowlist.

---

## Agents

- **Claude Code** — default, installed in the image; the 90% cloud path is unchanged.
- **Aider** — **bundled in both modes** (Docker image and macOS base VM) as a Claude-Code-independent fallback: an isolated `aider-chat` venv with `aider` on PATH, so the resilience hedge is real. Use via a profile `launch = aider …`. (A macOS base VM built before this lands picks it up with `augur update --macos`.)
- **Anything else** — bring-your-own via `augur shell` (installs persist for the container's life) or a fork. augur provides the generic seam (launch + env + allow); it does not maintain a fleet.

---

## Usage

```bash
augur init-llm                       # scaffold ./.augur.llm; edit IP/model
augur claude                         # default: Anthropic cloud (endpoint path closed)
augur claude --local                 # = --profile local  (confirm prompt)
augur claude --profile aider-local   # bundled Aider against the same endpoint
augur claude --local --macos         # same, macOS VM mode
AUGUR_ASSUME_YES=1 augur claude --local   # skip confirmation (trusted project)
```

---

## Security summary

- All guest egress still flows through `augur-proxy`; the only new hole is the **one private `IP:port`** of the active profile, open only **for that run**.
- IP rules: **IPv4, port-mandatory, private-only** (RFC1918 + Tailscale CGNAT); public/loopback/link-local/metadata refused; matched by a path kept **separate** from domain matching.
- Untrusted workspace layers **cannot** open an IP (project `./.augur.conf` IP rules stripped); a profile's endpoint requires **explicit selection + confirmation**.
- Profile env is injected **per-invocation** and **named** (no wholesale host-env forwarding); see [host-env-exposure-review.md](host-env-exposure-review.md).
