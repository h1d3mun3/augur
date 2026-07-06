# augur × Claude Code `--worktree`: why augur does not add special support

- **Date:** 2026-07-06
- **Status:** Design record. **Decision: do NOT add special handling for Claude Code's
  `--worktree` flag.** No argv forwarding, no history-mount changes. Documented so this
  isn't reconsidered and rebuilt from scratch (or "fixed" into a weaker security posture)
  without re-deriving the trade-offs below.
- **Method:** Source inspection of `augur` (`cmd_claude`, `agent_launch_argv`,
  `agent_state_guest_leaf`, `cmd_up`, `cmd_down`), an empirical `git worktree add` probe in
  this repo to confirm the on-disk `.git` file format, and verified facts about Claude
  Code's `--worktree` feature (path layout, project-leaf keying, `Ctrl+W` resume picker).

---

## Conclusion (key points)

- Claude Code's `--worktree <name>` creates a linked git worktree at `.claude/worktrees/<name>/`
  (relative to the repo root) and gives that session its **own project leaf** under
  `~/.claude/projects/`, separate from the main checkout's history — this is Claude Code's
  own design, not something augur imposes.
- Two concrete gaps stand between "it works" and "augur supports it": (1) `augur claude`
  forwards no CLI arguments at all today, and (2) augur's history-persistence mount is
  pinned to exactly one leaf name, decided when the container is created — a `--worktree`
  session's (different) leaf falls outside it and is lost whenever the container is torn
  down and recreated.
- Every way found to fix (2) either (a) widens the container's blast radius so a
  compromised worktree session can read/tamper with sibling worktrees'/the main session's
  history, or (b) requires a dedicated container per worktree, which resurrects a *worse*
  problem: a linked worktree's `.git` is a file pointing at an **absolute host path**
  outside that container's own mount, breaking `git` inside it unless the shared `.git` is
  bind-mounted read-write at its real path (a **host-escape vector via shared git hooks**)
  or copied in (safe, but no longer a "shared, lightweight worktree" — just a slower,
  more complicated clone).
- Once you're willing to pay for a dedicated container per worktree with a copied-in
  `.git`, you've already given up worktree's whole reason to exist (a shared object store).
  At that point the existing, zero-new-code answer — **clone the repo into a second
  directory and run `augur up`/`augur claude` there** — gets the same isolation and
  persistence guarantees `augur` already provides for any project, with none of the new
  surface area.
- **Decision: ship nothing for `--worktree`.** If a user invokes it ad hoc inside an
  existing `augur claude` session, the worktree's files persist normally (ordinary files
  under the existing workspace bind mount), but that session's conversation history does
  not survive `augur down && augur up` — call this out if it ever becomes user-visible
  confusion (e.g. a help-text note), but no code changes.

---

## 1. What `claude --worktree` actually does

- `claude --worktree <name>` (or `-w`, name optional/auto-generated) runs `git worktree add`
  under the hood, checking out a new branch (`worktree-<name>`) into
  `.claude/worktrees/<name>/`, **relative to the repository root**. It then starts a new
  Claude Code session rooted there.
- Because Claude Code keys its per-directory conversation history off the session's cwd
  (`~/.claude/projects/<slugified-cwd>/<session-uuid>.jsonl`), a worktree session's cwd is
  a different absolute path than the main checkout's, so it gets a **different project
  leaf** — its own separate history stream, not merged into the main checkout's.
  `Ctrl+W` in the resume picker widens the view across sibling worktrees of one repo, but
  this only works because all of those leaves already sit on normal, persistent disk.
- There is no supported way to override which leaf a session's history is keyed to
  (`CLAUDE_PROJECT_DIR` only affects hook context; `CLAUDE_CONFIG_DIR` moves the whole
  `~/.claude` tree, not just history). The leaf name is derived purely from the absolute
  cwd.
- Because `.claude/worktrees/<name>/` nests **inside** the repo root, a worktree created
  this way lands inside `augur`'s single existing workspace bind mount
  (`WORKSPACE_DIR` → `WORKSPACE_MOUNT`, see `cmd_up`). This is a materially different,
  easier case than a worktree created as a *sibling* directory
  (`git worktree add ../foo`): everything — worktree creation and all git operations —
  happens inside the one already-mounted tree, so there is no cross-mount-boundary path
  reference to resolve. (Verified empirically: a real `git worktree add` in this repo
  produces a `.git` file reading `gitdir: /workspace-augur/.git/worktrees/<name>`, whose
  `commondir` resolves to the main repo's real `.git` — an absolute host path. Nesting the
  worktree inside the same mount keeps that path inside the container too.)

## 2. Two concrete gaps

### 2.1 `augur claude` forwards no argv today

`agent_launch_argv()` is a fixed literal (`"claude"`); `cmd_claude()` reads it and execs it
verbatim — nothing in `"$@"` reaches the guest. `augur claude --worktree feature-auth`
today does not even reach the `claude` binary. Before making this variable, note the
existing contract comment on `agent_launch_argv`: on macOS VM mode this string is
interpolated into an SSH remote-command string (today safe only because it's a constant);
making it variable requires a metachar/control-byte reject guard and `printf %q`-style
quoting first. Docker/`container` mode is unaffected (argv is passed as an array to
`exec`, safe by construction).

### 2.2 History persistence is pinned to one leaf, decided at container-creation time

`cmd_up` mounts exactly one host directory at exactly one guest leaf path:

```
host_hist_dir="$AUGUR_DIR/$(agent_state_host_subdir)/$(workspace_slug)-$(workspace_path_hash)"
docker_args+=(-v "${host_hist_dir}:$(agent_state_guest_projects_dir)/${agent_proj_leaf}")
```

`agent_proj_leaf` is `agent_state_guest_leaf "$(workspace_slug)"` — a leaf name matching
the *main* checkout's cwd, decided once, before the container starts. A `--worktree`
session's cwd (and therefore its leaf name) is different and cannot be known in advance
(names can be user-chosen or auto-generated). Since bind mounts can only be set up when a
container is *created* (`run`), not when a shell is attached later (`exec` — which is all
`cmd_claude` does to an already-running container), there is no way to retroactively mount
the right host directory for a leaf whose name you didn't know about yet.

Consequence: a `--worktree` session's transcripts are written to the container's writable
layer, not to any bind-mounted, host-persisted location. `cmd_down` only removes the
container (`engine_rm_force`) and stops egress — it does not touch `host_hist_dir` — and
`cmd_up` always creates a **fresh** container instance from the (separately persisted)
image, never resuming the old one. So anything living only in the old container's writable
layer — including any `--worktree` session's history — is gone the moment the container is
recreated. The worktree's actual files (checked-out branch, `.git` file) are unaffected:
they're ordinary files under `WORKSPACE_MOUNT`, which *is* a host bind mount.

## 3. Options considered for the history gap (all rejected)

### Option A — mount the `~/.claude/projects` parent instead of one leaf

Mounting the per-project host directory at the *parent* guest path instead of one named
leaf would automatically capture any leaf Claude ever creates for this project (main or
any worktree, present or future), with no need to predict Claude's leaf-naming algorithm.
It is also what would make Claude's own `Ctrl+W` cross-worktree resume picker work
correctly inside the container.

**Rejected.** Within one shared container, bind-mounting N host directories at N different
guest paths does not create any access boundary *between* them — a process in that
container (compromised or not) has ordinary filesystem read/write access across all of
them simultaneously, exactly as if they were one merged directory. A compromised
`--worktree` session could therefore read or plant poisoned content in a sibling
worktree's (or the main session's) transcript, to be replayed as "past context" whenever
that other session is later resumed. This does not cross augur's real security
boundaries — it never reaches another augur project (those live in entirely separate,
never-mounted host directories keyed by `workspace_slug`+`workspace_path_hash`) or the
host's real `~/.claude/projects` (augur deliberately persists history under
`~/.augur/claude-projects/...` instead, specifically so the host's own Claude Code never
enumerates or resumes a guest-forged transcript). It is, however, a **new tier of
isolation** — intra-project, cross-session — that augur has never promised, introduced
solely to support one convenience feature. Judged not worth it.

(Note in passing, not a justification either way: an equivalent same-leaf version of this
risk already exists today with zero worktree involvement — a compromised session can
forge its own transcript, that host file is untouched by `augur down`, and a future
`augur up`+resume of the *same* leaf would replay it. Widening to the parent directory
extends this already-shipped, accepted risk sideways to sibling leaves; it isn't a new
*category* of risk, just a wider blast radius within one already-accepted one. Still
rejected — see above.)

### Rejected variant — harvest leaves from the outgoing container, mount them individually next time

Idea: before `cmd_up` removes a stale container, enumerate any non-main leaves under its
`~/.claude/projects/`, copy each to its own new host directory, and mount each individually
(not the whole parent) on subsequent `up`s.

**Rejected.** All harvested leaves still end up mounted into the same one container, so the
blast radius is identical to Option A — separating the *host-side* storage locations buys
no isolation once they all land in one shared guest filesystem namespace. It is also less
robust (only runs on a clean `augur down`/`up`, not on a crash or an out-of-band container
removal; unverified whether the Apple `container` CLI even supports extracting files from
a container) and accumulates stale leaf directories for worktrees long since deleted, with
no natural pruning. Strictly worse than Option A: same rejected risk, more complexity, less
reliability.

### Option B — treat a worktree as its own independent augur project

Instead of letting Claude Code's own `--worktree` machinery run inside the existing
container, have `augur` itself give the worktree directory a dedicated container, with its
own `workspace_slug`/`workspace_path_hash` and its own single pinned leaf — exactly the
pattern that already works for any two unrelated projects today. This actually mirrors
Claude Code's own model: Claude already treats a worktree's history as belonging to a
separate leaf from the main checkout, so mapping it to a separate *augur project* isn't a
stretch — it's the same boundary Claude already draws, one level up.

This genuinely restores full isolation (separate containers ⇒ separate mount namespaces,
not just separate host directories), and history persistence needs **no new mount
tricks** — it reuses the exact single-leaf-per-container mechanism that already works
reliably for the main project.

It costs two things:

1. **The git-mount-boundary problem returns.** A linked worktree's `.git` is a file
   containing an absolute host path into the main repo's `.git/worktrees/<name>` (see §1).
   A dedicated container that only mounts the worktree's own directory doesn't include
   that path, so `git` breaks inside it. Fixing this needs one of:
   - Bind-mount the shared `.git` read-write at its real absolute host path. This reopens a
     **host-escape vector**: `.git/hooks/` is shared across every worktree of a repo, so a
     compromised worktree container could plant a hook (`post-checkout`, `pre-commit`,
     etc.) that later executes **on the host**, at the human's privilege, the next time
     they run an ordinary git command in the main checkout or another worktree — a
     filesystem escape entirely independent of augur's egress controls.
   - Copy the resolved common gitdir into the container at start instead of live-mounting
     it. Safe (the container only ever touches a copy), but the container's git state no
     longer live-syncs with the host's; commits/branches only get back out via an explicit
     push.
2. **Resource overhead**: one container (and, if egress filtering is on, one proxy/network)
   per worktree in concurrent use, instead of one shared container.
3. **A different UX shape.** This is no longer "one Claude Code session, hopping between
   worktrees via `--worktree`/`Ctrl+W`" — it becomes one terminal (one `augur up` +
   `augur claude`) per worktree. `--worktree` itself would not actually be forwarded to
   `claude` under this model; augur would be doing its own, separate thing.

## 4. Why Option B collapses into "just clone the repo again"

Git worktree's entire value proposition is a **shared, live git object store** — multiple
working trees without the disk/time cost of a full clone. Option B's only safe path (copy
the gitdir in, no live shared mount) throws that away: the container's git state is a
disconnected copy from the start. At that point there is no remaining advantage over the
thing that already works today, with no new code, no new mount logic, and no new risk: put
a second `git clone` of the same repo in a new directory and run `augur up`/`augur claude`
there. A plain clone's `.git` is self-contained (no absolute-path indirection into another
directory), so it never hits the git-mount-boundary problem at all — and because it's a
different absolute path, `workspace_slug`/`workspace_path_hash` already key it as a fully
separate, fully isolated, fully-persisted project, exactly like any other two unrelated
repos on this machine.

## 5. Decision

**Do not add special `--worktree` support.** Concretely: no argv forwarding is added to
`cmd_claude`/`agent_launch_argv` for this purpose, and no change is made to
`agent_state_guest_leaf`/the history mount. For parallel work on multiple branches, the
supported path is: clone the repository into a second directory and run `augur up`/
`augur claude` there independently — this already works today.

If a user runs `claude --worktree <name>` ad hoc from inside an existing `augur claude`
session anyway (once/if argv forwarding is ever added for unrelated reasons), the worktree
itself should work at the file/git level (§1), but its conversation history will not
survive `augur down && augur up` — only its code changes will, since those live under the
already-persisted `WORKSPACE_MOUNT`.

## 6. Residual observation (pre-existing, out of scope here)

Not caused by anything above, but surfaced while investigating it: augur's
history-persistence design already has a same-leaf, cross-*time* version of the §3
Option A risk, with zero worktree involvement. A compromised session can forge its own
`.jsonl` transcript; that host file is untouched by `cmd_down`; a later `augur up` in the
same directory mounts the same file back in, so a "fresh" container can still be handed a
poisoned transcript if it (or the user) resumes. This is inherent to persisting history at
all, not something this decision introduces or changes — flagged here only so it isn't
mistaken for a new consequence of the `--worktree` investigation, and as a candidate for a
future, separate review if tamper-evident history ever becomes a priority.
