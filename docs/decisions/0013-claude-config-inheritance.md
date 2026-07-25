# ADR-0013 — Claude Code configuration is classified, not mirrored

- **Status:** Accepted.
- **Date:** 2026-07-25.
- **Applies to:** Both modes (Apple Container + macOS VM).
- **Builds on:** [`0012`](./0012-drop-workspace-trust-seed.md) (folder trust stays with Claude Code),
  [`0003`](./0003-swappable-agent-abstraction.md) (the agent seam),
  [`0010`](./0010-container-persistence.md) / [`0006`](./0006-macos-vm-clone-persistence.md)
  (both guests persist across `down`).

## Decision

**augur never mirrors the host's Claude Code configuration into the guest.** Every configuration
surface is instead assigned to exactly one of **four categories**, each with a fixed rule:

| # | Category | Source of truth | Mechanism | Direction |
|---|---|---|---|---|
| 1 | **Persisted guest state** | the guest | per-project host dir under `$AUGUR_DIR` | guest → host |
| 2 | **Repo-provided** | the repository | already inside the workspace mount; augur does nothing | — |
| 3 | **Opt-in operator profile** | `~/.augur/claude-profile/` | copied/mounted read-only into the guest's `~/.claude/` | host → guest |
| 4 | **Managed policy** | augur | baked into the image / base VM at the *managed-settings* layer | augur → guest |

And one standing prohibition across all four:

> **augur never reads, copies, or mounts the host's real `~/.claude/` tree or the host's real
> `~/.claude.json`.** Not wholesale, not stripped, not read-only. The only host-side inputs are the
> explicitly named credential env vars (`agent_auth_specs`) and the category-3 profile directory,
> which the operator creates on purpose.

### Category 1 — persisted guest state

State the agent *generates* while running. Kept in a **per-project host directory keyed on
slug + path-hash**, deliberately **outside** the host's own `~/.claude` so the host's Claude Code
never enumerates guest-written files.

- `~/.claude/projects/` — transcripts → `$AUGUR_DIR/claude-projects/<slug>-<hash>` (mount)
- `~/.claude/agents/` — user-level subagent definitions → `$AUGUR_DIR/claude-agents/<slug>-<hash>` (mount)
- `~/.claude/projects/<project>/memory/` — auto-memory Claude maintains per project. Already covered
  by the `projects/` mount above, which carries every leaf under it, not just the transcripts.
- `~/.claude/history.jsonl` — up-arrow prompt recall. **Not** on a mount, so Container mode keeps a
  bounded **carry-over snapshot** under `$AUGUR_DIR/claude-carryover/<slug>-<hash>` (mode `0600`).
- `~/.claude/agent-memory/` — **known limitation, deliberately not carried.** This is subagent
  persistent memory, created only for a subagent whose frontmatter sets `memory: user` (the
  cross-project variant). It has no mount and no snapshot, so it does not survive a container
  recreate. Judged not worth a third per-project mount in both modes for how narrow it is: the
  *project*-scoped variants (`memory:` → `.claude/agent-memory/`, `memory: local` →
  `.claude/agent-memory-local/`) already live in the workspace mount and survive everything, and a
  subagent without a `memory:` field never creates any of this. Note it is a different feature from
  the main session's auto-memory above, which *is* covered.

The snapshot exists because augur recreates the container for its *own* reasons — a rotated
credential, an egress toggle, a memory change, `build`/`update`/`install-cert`, any fingerprint
drift — and each discards the writable layer. It is taken while the container is running (on exit
from `claude`/`shell`, in `down` before the stop, and in `invalidate_persisted_container` before
`build`/`update`/`install-cert` throw the layer away) and pushed back on the create path of `up`.

Three boundaries make it safe rather than clever:

- **`destroy` deletes the snapshot** instead of feeding it forward. `destroy` is the clean-guest
  button (the A2 setup-token integrity remedy); carrying guest-written data across it would defeat
  the guarantee the operator asked for. A *drift* recreate inside `up` is augur's own decision, not
  theirs, so continuity is right there.
- **Only the prompt history is carried — never `~/.claude.json`.** [`0012`](./0012-drop-workspace-trust-seed.md)
  removed the last per-container write to that file on purpose. Its per-project entry holds folder
  trust and accepted tool permissions, and replaying those into a fresh container would silently
  re-grant approvals given to a container that no longer exists — re-litigating 0012 through the
  back door. It also holds an OAuth session, which has no business on the host outside the
  credential files augur already manages.
- **Bounded by lines *and* bytes.** The only in-guest write mechanism this codebase has proven is
  `eng exec` with the payload in `-e` env vars (augur never uses `container cp`), and Linux caps a
  single env string at 128 KiB. A line cap alone would not hold — one pathological prompt can be
  arbitrarily long — so restore re-checks the byte bound and skips rather than failing mid-`up`.

macOS VM mode needs none of this: the clone persists across `down`, and `destroy --macos` is the
same deliberate clean slate.

### Category 2 — repo-provided

`.claude/settings.json`, `.claude/settings.local.json`, `CLAUDE.md`, `.claude/agents/`,
`.claude/skills/`, `.claude/commands/`, `.mcp.json`. These arrive **for free** inside the RW
workspace mount; augur adds no mechanism. Since [`0012`](./0012-drop-workspace-trust-seed.md) they
take effect only after the operator accepts Claude Code's own folder-trust prompt in the guest,
exactly as they would on any other machine.

### Category 3 — opt-in operator profile

The operator's *personal* Claude Code assets — every user-scope surface the official `.claude`
directory reference lists as operator-authored: slash commands, skills, topic rules, output styles,
dynamic workflows, themes, a user-level `CLAUDE.md`, `settings.json` and `keybindings.json`.
A repository cannot supply these (they are personal, not
project-scoped), and they must not come from the host's `~/.claude` (see *Context*). So augur reads
a **separate, explicitly-populated directory**:

```
~/.augur/claude-profile/
settings.json · CLAUDE.md · keybindings.json   → copied    (Claude may rewrite these)
commands/ · skills/ · rules/ · output-styles/
workflows/ · themes/                           → symlinked (read-only, host edits are live)
```

**Host-global and read-only.** Host-global because personal tooling is not project-scoped;
read-only *because* it is host-global — every project on the machine reads it, so a guest able to
write there would plant a hook or command for all of them. That is the same attack the per-project
keying of the `agents/` mount already refuses.

**Two mechanisms on purpose.** The directories are symlinked, so editing a file *inside* an
already-wired one needs no augur action — it's a live mount. The three files are copied, and both
the copies and any *structural* directory change (an entry added, removed, or replaced, as opposed
to a file changed inside one already wired) need the wiring itself to re-run. That happens on
**every** `up`/`claude`/`shell` in both modes, not only when the container transitions
stopped→running: `cmd_up` short-circuits to a no-op when the container is already running (the
common case — repeated `claude`/`shell` calls with no intervening `down`), which would otherwise
skip the wiring entirely, so `cmd_claude`/`cmd_shell` (and their macOS equivalents) call it directly
too. Found live rather than by inspection: a profile entry added while the container stayed running
was invisible until an explicit `down`, contradicting the "next `claude` picks it up" promise the
directories make for in-place edits. The copy exists in the first place because Claude Code
**writes** user-scope `settings.json` (model selection and several `/config` toggles land there) and
a symlink into a read-only mount would turn that into an error. The profile is their source of
truth — but augur only ever writes a name that actually **exists** in the profile, so an operator
who ships no `settings.json` never has one written.

**Freshness is NOT symmetric across the two modes.** Container mode reaches the profile through an
Apple Container **bind mount**, and a host-side edit is visible immediately (verified on real
hardware). macOS VM mode reaches it through a **virtiofs share**
(`VZVirtioFileSystemDeviceConfiguration` + `VZSharedDirectory(readOnly: true)`, see
`augur-vm/Sources/augur-vm/RunSession.swift`), and there a host-side edit is **not** visible to the
guest for minutes. Measured on real hardware: still stale 2 minutes after the write, visible some
time before the 10-minute mark. augur holds no cache of its own — `ensure_macos_claude_profile` only
`ln -sfn`s and `cp`s — and Virtualization.framework exposes **no** cache-control knob for these
shares (Apple's documentation is silent on caching entirely; `isReadOnly` is documented purely as
access control). The workaround is `down --macos && up --macos`, which is correct *by construction*:
`cmd_up_macos` builds a brand-new VM and share device every time.

Accepted rather than fixed in this change, because the profile is not edited often, the workaround
is exact, and the alternative is a real redesign — pushing the tree from the host over SSH instead
of mounting it, which would also require re-implementing deletion tracking and the `.pre-profile`
rescue. Tracked as a follow-up. Two things about it are worth recording now: that redesign would let
the share be **dropped entirely** (stronger isolation than read-only, since the guest could no
longer reach the host directory at all), and the same staleness plausibly affects the **existing
`gh-config` read-only share**, which has had this property since `:ro` support landed (2026-06-28,
`213aa24`) without anyone noticing — that share's content simply changes too rarely to surface it.

**UNVERIFIED and load-bearing for any future fix:** whether `readOnly: true` is the causal variable
at all. No test has compared a read-write virtiofs share in the *same VM* against a read-only one.
The read-write shares (workspace, `claude-projects`, `claude-agents`) are *presumed* live — strongly
so, since a stale workspace would mean the agent reads stale source code, which macOS-mode users
would have noticed — but presumption is not verification. An idle/time-based staleness affecting
every share, read-only or not, has not been ruled out.

**Wiring is non-destructive.** A real `~/.claude/commands` or `~/.claude/skills` the *guest* created
before the profile existed is moved aside to `<name>.pre-profile`, never deleted (an empty one is
dropped, and if the rescue name is already taken the entry is left unwired rather than either copy
destroyed). Silently deleting the guest's own work to make room for the operator's is not a trade
the operator asked for.

**Inert by default**: no directory, or an empty one, and augur wires nothing.

### Category 4 — managed policy

augur's own non-negotiables, at Claude Code's **managed-settings** layer:

- Container: `/etc/claude-code/managed-settings.json`, root-owned, baked in the `Dockerfile`
- macOS VM: `/Library/Application Support/ClaudeCode/managed-settings.json`, installed into the
  **base VM** by both `cmd_build_macos` and `cmd_update_macos`

This layer exists because of the documented precedence (highest → lowest):

> **managed** → command-line args → `.claude/settings.local.json` → `.claude/settings.json` →
> `~/.claude/settings.json`

A category-3 profile is user scope — the **lowest** layer — so it loses to any repository's own
settings. augur is the isolation boundary, so its policy belongs at the **top** of the stack, the
same reasoning that puts egress enforcement in the proxy/netstack rather than in a guest-editable
config.

**The payload is deliberately one key:**

```json
{"env":{"DISABLE_AUTOUPDATER":"1"}}
```

The `Dockerfile` already sets `DISABLE_AUTOUPDATER` as an `ENV` *because the integrity gate depends
on it* — it keeps the on-disk binary byte-identical to the image and removes the binary's ability to
rewrite itself. But a settings-file `env` block outranks the process environment, so a repository
could re-enable the updater and swap out the very binary augur verifies. Managed scope is the only
layer that closes that.

Two rules govern additions:

1. **augur must be able to back the assertion.** A `permissions.deny` rule is a tool-level speed
   bump, not a boundary — the same action is usually still reachable from a shell — so pinning one
   would overstate what augur enforces. `INVARIANTS.md` is a *testable* contract and must not
   accumulate soft controls.
2. **It must not already be enforced by a stronger layer.** Egress is enforced by the proxy/netstack
   and `--no-dns`; the filesystem by read-only, root-owned mounts. Restating either in a config file
   is theatre.

Pinning a repository's `permissions` or `hooks` was considered and **rejected**:
[`0012`](./0012-drop-workspace-trust-seed.md) has just decided that Claude Code's own folder-trust
dialog is the right gate for those. Overriding it here would reverse that decision through the back
door, days after it was made.

## Context

The temptation is to mirror: bind-mount the host's `~/.claude` so "everything just works." Four
reasons that is wrong, in descending order of severity.

**1. Most config surfaces are executable, and a RW mount is a host-compromise path.** augur already
refuses to mount the host's *global* `~/.claude/agents` for exactly this reason — a compromised
guest could plant a subagent definition read by every future session in every project. That applies
with **more** force to `~/.claude/commands/`, `~/.claude/skills/`, and `settings.json`'s `hooks` /
`statusLine`: a subagent runs only when invoked, whereas a hook fires unconditionally — the same
asymmetry [`0012`](./0012-drop-workspace-trust-seed.md) leaned on.

**2. Host config is host-path-dependent and breaks in a Linux guest.** `hooks`, `statusLine`, and
`apiKeyHelper` reference host absolute paths and host binaries (`/opt/homebrew/bin/…`). A broken
hook does not fail quietly — it fails on every turn, which is worse than the feature being absent.

**3. Permissions calibrated for the host are the wrong permissions for the guest.** A host
`permissions.allow` list is written for a world with *no* sandbox. Replaying it inside the sandbox
imports the strictest of both worlds and discards half of what augur is for. The guest should have
its **own** posture, not a copy of one.

**4. A separate directory buys "guest-shaped content" structurally, with no code.** If augur
mirrored `~/.claude`, augur would owe the user a *sanitizer*: detect unresolvable hook paths, strip
`apiKeyHelper`, scrub secrets out of `settings.json`'s `env`, and stay correct as Claude Code adds
keys. With an opt-in directory, the operator placing a file there *is* the assertion that it was
written for the guest. augur writes no sanitizer, and there is no silent-drift class of bug.

The corollary, stated plainly because it is easy to get backwards: **"just use the repo's config" is
the convenient answer, not automatically the safe one.** The workspace is a RW mount of the
operator's real checkout, so a guest that writes `.claude/settings.local.json` or
`.claude/commands/*.md` is writing files the *host's* Claude Code will later execute. That exposure
is accepted upstream ([`0008`](./0008-exfiltration-ceiling-accepted.md)) and is now gated by the
restored folder-trust prompt ([`0012`](./0012-drop-workspace-trust-seed.md)) — reduced, not removed.

### Verified facts this rests on

Checked against the official documentation on 2026-07-25 (`code.claude.com/docs/en/…`):

- **Precedence** is managed → CLI → project-local → project → user. User scope is the **lowest**,
  which is what forces category 4 to exist separately from category 3.
- **Managed-settings paths** are `/Library/Application Support/ClaudeCode/managed-settings.json`
  (macOS) and `/etc/claude-code/managed-settings.json` (Linux/WSL).
- **Prompt history is `~/.claude/history.jsonl`** — *"Every prompt you've typed, with timestamp and
  project path. Used for up-arrow recall."* It is **not** in `~/.claude.json`, which is easy to
  assume and wrong; category 1 carries the right file because of this.
- **`~/.claude.json`** holds *"your OAuth session, MCP server configurations for user and local
  scopes, per-project state (allowed tools, trust settings), and various caches."* Hence: never read
  the host's copy, and never carry the guest's.
- **Claude Code writes `~/.claude/settings.json` at user scope**, which is why category 3 copies
  that file rather than symlinking it into a read-only mount.
- **UNVERIFIED — whether `CLAUDE_CONFIG_DIR` also relocates `~/.claude.json`.** The variable *is*
  documented (`/docs/en/env-vars`) and relocates the `~/.claude` **directory**: *"every `~/.claude`
  path on this page lives under that directory instead."* That sentence is scoped to `~/.claude`
  paths and the same page lists `~/.claude.json` under the home directory rather than inside
  `.claude/`, but it never states the case either way and the `env-vars` entry could not be
  retrieved in full. Recorded as open rather than resolved by assumption; augur's decision does not
  depend on it (see *Alternatives*).

## Security

- **Category 3 is read-only, host → guest, and opt-in.** A compromised guest cannot write back into
  the profile, so it cannot plant a hook/skill/command that a *later* session — or another
  project — would execute. A mirrored RW `~/.claude` would destroy exactly that property.
- **Category 3 content is operator-supplied and executed in the guest.** augur does not validate it.
  That is the same trust level as the repo's own `.claude/`, and strictly better than the host's
  `~/.claude` would be, because the operator opted in per file.
- **Category 1's carry-over is the guest's own history file, verbatim** — no credential, no
  permission grant, no trust flag, and nothing from any other file. It is guest-*written* content,
  so it is guest-controlled text: augur bounds and shape-filters it (whole `{…}` records only) but
  does not otherwise validate it, and it is replayed into nothing but the next guest's own history
  file. Created under `umask 077` (not `chmod`-after, which would leave a readable window) beneath
  `$AUGUR_DIR`, outside the host's own `~/.claude`, so the host's Claude Code never enumerates it.
  `destroy` removes it.
- **Category 4 is a real control in Container mode** (root-owned, agent runs unprivileged) and a
  **policy default only** on macOS: that base VM's account is the published `admin`/`admin`
  ([`0007`](./0007-macos-build-fixed-credential.md)), so anyone with the password can rewrite it.
  Stated here rather than glossed.
- **No egress invariant changes.** None of `INVARIANTS.md` I1–I10 is touched: no new host network
  path, no change to the proxy decision point, no change to what leaves the guest. The one
  fingerprint addition (`profile_mount`) can only make container reuse *more* conservative.

## Consequences

- augur gains a documented, closed classification: every new Claude Code config surface must land in
  one of four categories, and the placement rule is mechanical (*guest-generated? repo-scoped?
  personal? augur's own invariant?*).
- Power users get their personal commands/skills inside the sandbox **without** augur ever touching
  `~/.claude` — the friction that would otherwise push people to mount it wholesale.
- The profile is host-global while categories 1–2 are per-project. Intentional: personal tooling is
  not project-scoped, and a *global RW* mount was the thing to avoid, not a global RO one.
- Adding the profile mount to `container_fingerprint` recreates every existing container once, on
  the first `up` after upgrading. That is what makes the feature actually present rather than
  silently missing until the operator happens to `destroy` — but it also means the first recreate
  predates any carry-over snapshot, so that one time the prompt history is lost like any other
  writable-layer state.
- Claude Code only picks up a top-level `skills/`/`commands/` directory that existed when the
  session started, so populating the profile mid-session needs a relaunch, not just a new `up`.
- Category 4 is currently **one key wide**, and that is the honest state rather than a placeholder:
  the enumeration above found nothing else augur can back that is not already enforced more strongly
  elsewhere. What ships now is the *layer* plus the two rules for extending it.
- Claude Code **silently strips** managed entries that fail schema validation, so a typo degrades to
  inert rather than loud. Both copies of the payload are asserted byte-for-byte in the seam tier.

## Alternatives considered

- **Mirror the host's `~/.claude` read-only.** Rejected: reasons 2–4 above. It also fails the
  power-user goal anyway, since `settings.json` is the one file Claude Code rewrites at user scope,
  so a read-only mount of it is a latent write error rather than a feature.
- **Mirror it read-write.** Rejected outright: reason 1. This is the exact attack augur already
  refuses for `~/.claude/agents`.
- **Relocate the whole guest config tree with `CLAUDE_CONFIG_DIR` and mount one directory.** Looked
  like it could collapse categories 1 and 3 into a single mount. Rejected on grounds that hold
  whichever way the open question above resolves: (i) it relocates the **whole** `~/.claude` tree,
  inverting a deliberate choice — augur persists exactly two leaves and leaves the rest ephemeral,
  so one big mount would silently widen what survives a `destroy`; (ii) the `env-vars` entry ties
  credential storage on Linux to that directory, so pointing it at a mounted path would put **guest
  credentials on the host filesystem**, the opposite of the standing prohibition.
- **Bind-mount `~/.claude/history.jsonl` (or `~/.claude.json`) as a single file** instead of
  snapshotting. Rejected, and previously rejected in [`0011`](./0011-workspace-trust-seed.md):
  Claude Code writes these via write-temp + atomic rename, which replaces the inode, after which a
  single-file bind mount points at a stale inode and silently stops tracking writes.
- **Also carry `~/.claude.json`'s per-project entry** so accepted tool permissions survive a
  recreate. Rejected: see category 1. It would re-grant approvals across a container boundary and
  reintroduce the per-container write [`0012`](./0012-drop-workspace-trust-seed.md) just removed.
- **Put augur's guardrails in the profile (user scope) instead of managed scope.** Rejected: user
  scope is the lowest precedence layer, so any repository could override them — backwards for the
  component that *is* the trust boundary.
- **Do nothing beyond categories 1 and 2** (the status quo). Rejected as the default, but note it
  remains the *behavior* for anyone who never creates a profile directory: categories 3 and 4 are
  additive, and 3 is inert until opted into.
