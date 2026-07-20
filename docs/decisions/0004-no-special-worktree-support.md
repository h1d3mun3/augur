# augur × Claude Code `--worktree`: why augur does not add special support

- **Date:** 2026-07-06
- **Status:** Design record, partially superseded — see the 2026-07-07 (implementation)
  revision below. **Still true:** no argv forwarding is added to `cmd_claude` for
  `--worktree`; `augur claude --worktree ...` still does not work, and the sanctioned path
  remains `augur shell` + manual launch (§8). **No longer true:** "no history-mount
  changes" — §9's symmetric swap (mount the whole `~/.claude/projects` parent in
  Docker/`container` mode; key `--macos`'s per-project VM name on `workspace_path_hash`,
  not `basename` alone) was reconsidered and **implemented**. Kept as a design record so
  the *reasoning* (why each option was rejected, then why the calculus changed) isn't lost
  and doesn't need re-deriving from scratch.
- **Method:** Source inspection of `augur` (`cmd_claude`, `agent_launch_argv`,
  `agent_state_guest_leaf`, `cmd_up`, `cmd_down`), an empirical `git worktree add` probe in
  this repo to confirm the on-disk `.git` file format, and verified facts about Claude
  Code's `--worktree` feature (path layout, project-leaf keying, `Ctrl+W` resume picker).
- **Revised:** 2026-07-07 (analysis). Follow-up review added the sanctioned `augur shell`
  + manual-launch workaround (§8), the finding that `--macos` mode's persistence model
  sidesteps gap 2 entirely (§7), the "symmetric swap" between the two backends' mount
  models — at this point still only analyzed, not built (§9 as first written) — and an
  incidentally-found, out-of-scope `macos_project_vm` naming-collision gap (appended to
  §6). Additional method: reading `cmd_shell`/`cmd_shell_macos`, `agent_fixed_env`,
  `cmd_up_macos`/`cmd_down_macos`/`cmd_destroy_macos`, `ensure_macos_claude_projects`,
  `macos_project_vm`, `workspace_slug`/`workspace_path_hash`; an empirical
  `git clone --local` inode check confirming object hardlinking is a generic
  same-filesystem git behavior, not APFS-specific.
- **Revised:** 2026-07-07 (implementation), later the same day. The symmetric swap was
  reconsidered and shipped: `cmd_up`'s history mount now binds the whole
  `~/.claude/projects` parent (not one leaf), with a one-time migration for pre-existing
  installs' flat layout; `macos_project_vm()` now keys on `workspace_path_hash` too, not
  `basename` alone. §9 is rewritten to describe what was actually built instead of what
  was declined. `agent_launch_argv`/`cmd_claude` argv forwarding is untouched — that half
  of the original decision still stands. Verified via `tests/00_seam_unit.sh`,
  `tests/10_construct_docker.sh`, `tests/11_construct_container.sh` (new migration and
  parent-mount assertions), `tests/30_macos_vm.sh` (new same-basename-different-VM
  assertion) — full suite green (`tests/run.sh`); `shellcheck` unavailable offline in this
  environment (no sudo, no decompressor for the release tarball), so CI's `make unit` is
  the first real lint pass this change gets.
- **Revised:** 2026-07-08 (correction, doc-only). Live testing on a real Mac
  (`make unit`, `tests/run.sh`, then a manual `--worktree` session on both backends)
  confirmed §9's implementation works, and surfaced that §7's "history is lost only on
  `augur destroy --macos`" claim was wrong — `cmd_destroy_macos` never touches the
  host-side history directory, so it survives `destroy` + a fresh clone too, as long as
  the project directory doesn't move. §7 and §8 are corrected below; no code changed. A
  separately-considered fix (auto-migrating an existing macOS project's *pre-hash-fix*
  history directory forward to its new hashed name) was built, tested, then explicitly
  declined and reverted — losing that continuity across the naming-scheme change was
  judged acceptable, not worth the extra code.

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
- **Decision: no argv forwarding for `--worktree`, but the history-mount trade-off is now
  shared by both backends (§9).** `augur claude --worktree ...` still doesn't work — the
  sanctioned path remains `augur shell` (or `augur shell --macos`) + typing
  `claude --worktree <name>` manually, which bypasses gap §2.1 entirely at zero cost in
  augur code (§8). What survives `augur down && up` is now the same on both backends: any
  leaf under the current project — main checkout or a worktree — persists, because
  Docker/`container` mode's `cmd_up` mounts the whole `~/.claude/projects` parent instead
  of one leaf (§2.2's gap is closed), matching what `--macos` mode already did (§7).
  `--macos`'s own project-keying gap (§6) was fixed the same day, in the same direction:
  `macos_project_vm()` now includes `workspace_path_hash`.

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

> **Fixed 2026-07-07 — see §9.** This section is kept as-is for the historical record of
> what the gap was and why it existed; `cmd_up` no longer mounts a single leaf.

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

This entire gap is specific to Docker/`container` mode's `cmd_up`. `--macos` mode's
persistence model is structurally different and does not have this gap — see §7.

## 3. Options considered for the history gap (all rejected)

### Option A — mount the `~/.claude/projects` parent instead of one leaf

> **Adopted 2026-07-07 — see §9.** Rejected here on first analysis; the calculus changed
> once `--macos` mode turned out to already ship this exact trade-off unconditionally
> (§7), making it something to *match*, not something new to *introduce*. The rejection
> reasoning below is kept because it's still the correct description of the trade-off
> being accepted, not a mistake that was corrected.

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

**Do not add special `--worktree` support** — still true. No argv forwarding is added to
`cmd_claude`/`agent_launch_argv` for this purpose. For parallel work on multiple branches,
the supported path remains: clone the repository into a second directory and run
`augur up`/`augur claude` there independently.

**Superseded in part, 2026-07-07 (see §9):** "no change is made to
`agent_state_guest_leaf`/the history mount" is no longer accurate. `agent_state_guest_leaf`
itself is unchanged, but `cmd_up` now mounts `agent_state_guest_projects_dir()` (the
parent) instead of `agent_state_guest_projects_dir()/agent_proj_leaf` (one leaf) —
Docker/`container` mode now behaves like `--macos` mode always did (§7).

If a user runs `claude --worktree <name>` ad hoc from inside an existing `augur claude`
session anyway (once/if argv forwarding is ever added for unrelated reasons), the worktree
itself should work at the file/git level (§1), but its conversation history will not
survive `augur down && augur up` — only its code changes will, since those live under the
already-persisted `WORKSPACE_MOUNT`.

The cleaner way to get there: don't nest inside an already-running `augur claude` session
— use `augur shell` (or `augur shell --macos`) first, then invoke
`claude --worktree <name>` as the first and only Claude Code process in that shell. See §8
for why this needs no code changes and what it actually persists per backend.

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

A second, unrelated residual surfaced while investigating the `--macos`/Docker
persistence asymmetry (§7): `macos_project_vm()` keys the per-project VM name (and
therefore its host-side history directory) purely off `basename "$WORKSPACE_DIR"`, with
no equivalent of Docker/`container` mode's `workspace_path_hash` component. Two distinct
directories that happen to share a basename (e.g. `~/work/myapp` and `~/archive/myapp`)
collide onto the same VM name (`augur-macos-myapp`) and therefore the same history
directory, egress config, and everything else keyed by that name — a cross-*project*
collision with no Docker/`container`-mode equivalent. Not caused by anything in this
document and not fixed by any option above; flagged here for the same reason as the rest
of this section — a candidate for a future, separate review, not a new consequence of the
`--worktree` investigation.

## 7. `--macos` mode's persistence model is structurally different — gap 2 doesn't apply

§2.2's gap is specific to how Docker/`container` mode's `cmd_up` works: it always
discards the old container and creates a fresh one, so only the one host directory it
explicitly bind-mounts at container-creation time survives. `--macos` mode does not work
this way, for two independent reasons — either alone would already close gap 2:

1. **The VM disk itself persists across `down`/`up`.** `cmd_down_macos` only calls
   `"$VM_CLI" stop`, printing "clone kept; CoW so it costs ~0 on disk"; `cmd_up_macos`
   only re-clones from the base VM if the project VM doesn't already exist
   (`macos_vm_exists "$project_vm" || ... clone`). So anything written to the VM's own
   filesystem survives an ordinary `down`/`up` cycle. **This reason turns out to be moot
   for `~/.claude/projects` specifically** — see the correction below; item 2 is what
   actually governs it. (The *reason* the clone is kept at all — independent of the
   `--worktree`/history question this section is about — is recorded separately in
   [`0006-macos-vm-clone-persistence.md`](./0006-macos-vm-clone-persistence.md).)
2. **`~/.claude/projects` is shared as a whole directory, not one pinned leaf.**
   `ensure_macos_claude_projects` symlinks the VM's entire `~/.claude/projects` to
   `/Volumes/My Shared Files/claude-projects`, a virtiofs share backed by a host-side
   per-project directory (`~/.augur/claude-projects/<vm-name>`, keyed by
   `macos_project_vm`). This is exactly the "Option A" pattern §3's first option proposes
   and rejects for Docker/`container` mode — except here it isn't a worktree-motivated
   addition, it's `--macos` mode's own pre-existing design for its single-VM history
   persistence, adopted before `--worktree` was ever a consideration.

> **Corrected 2026-07-08, after live testing on a real Mac.** The original claim below —
> "lost only on `augur destroy --macos`" — is wrong. `cmd_destroy_macos` only calls
> `"$VM_CLI" delete "$project_vm"`; it never touches the host-side
> `~/.augur/claude-projects/<vm-name>` directory item 2 backs `~/.claude/projects` with.
> Since `macos_project_vm()` is a deterministic function of the project directory's path
> (not a random ID), a fresh `up --macos` after `destroy` resolves to the *same* VM name
> and therefore the *same* host-side directory, and `ensure_macos_claude_projects`
> (called again by the very next `claude --macos`/`shell --macos`, not just by `up`)
> re-establishes the same symlink. Confirmed live: `destroy --macos` → fresh
> `up --macos` → `shell --macos` → both the main and `--worktree` leaves were still
> there. Item 1 (the VM disk surviving `down`) is real but doesn't actually decide this
> either way for `~/.claude/projects` — that path is redirected to the host from the
> moment `ensure_macos_claude_projects` first runs, never mind what happens to the VM
> disk afterward. The only ways to actually lose this project's `--macos`-mode Claude
> history: manually delete `~/.augur/claude-projects/<vm-name>` on the host, or move/
> rename the project directory (changes `workspace_path_hash`, hence the VM name — the
> same one-time-orphaning cost §9 documents for its own basename+hash fix).

Consequence: a `--worktree` session's conversation history is not lost on
`augur down && up --macos`, nor on `augur destroy --macos` followed by a fresh
`up --macos` for the same project directory — only by deleting the host-side directory
directly, or by moving the project (see the correction above). This comes with the same
cross-leaf, no-isolation-within-one-project trade-off §3's Option A was rejected for in
the Docker/`container` case (any leaf in the shared VM can read or tamper with any sibling
leaf's transcript) — except `--macos` mode already accepted this trade-off
unconditionally, for its own reasons, independent of `--worktree`, before Docker/`container`
mode did too (§9 later closed that gap the same way, deliberately). Using
`claude --worktree` there (§8) doesn't introduce a new risk category; it just exercises a
risk surface `--macos` mode already ships — and, as of §9, so does Docker/`container` mode.

(Comparison note: at the time this section was first written, `augur down && up --macos`
preserving worktree history *unlike* Docker/`container` mode was the whole point of §7.
§9 later closed that asymmetry, so the "unlike" no longer holds — kept here as history,
not current behavior.)

## 8. The sanctioned ad hoc workaround: `augur shell` + manual `claude --worktree`

For a user who wants `--worktree` today, despite no formal support: run `augur shell`
(`cmd_shell`: `eng exec -it "$CONTAINER_NAME" bash`) or `augur shell --macos`
(`cmd_shell_macos`: `ssh_macos ... "cd ~/${MACOS_SHARE} && exec zsh -l"`), then type
`claude --worktree <name>` at the resulting prompt. Verified:

- **Gap §2.1 (argv forwarding) does not apply.** Both `cmd_shell` variants just open a
  plain interactive shell — no argv is constructed or forwarded on the user's behalf, so
  the metachar/quoting hardening §2.1 says `agent_launch_argv` would need before being
  made variable is irrelevant here. The user is typing a command at a live prompt, same as
  any other command.
- **Auth already works.** `ANTHROPIC_API_KEY`/`CLAUDE_CODE_OAUTH_TOKEN` are injected at
  container/VM-creation time (`cmd_up`'s `docker_args`/`cmd_up_macos`'s `~/.augur-env`),
  not at `cmd_claude`'s exec call, so they're already present in a shell session.
- **One trivial gap:** `agent_fixed_env` (`DISABLE_AUTOUPDATER=1`) is only injected at
  `cmd_claude`'s exec time, so a manually-launched `claude` inside `augur shell` won't have
  it set unless the user exports it themselves. Cosmetic; not a functional blocker.
- **What persists is now the same on both backends** (as of §9): on both, the history
  lives in a host-side directory keyed by `workspace_slug`+`workspace_path_hash`, outside
  the container/VM's own lifecycle — surviving `down`/`up`, and (per §7's correction)
  surviving `destroy --macos` + a fresh `up --macos` too, since that host-side directory
  is untouched by `destroy` and the next VM resolves to the same name. On either backend
  it's lost only by deleting that host-side directory directly, or by moving/renaming the
  project (which changes the key). Before §9, Docker/`container` mode lost a `--worktree`
  session's history on every `down && up`; that asymmetry no longer exists.

This is the same scenario §5's closing paragraph already accepted ("if a user runs
`claude --worktree <name>` ad hoc from inside an existing `augur claude` session
anyway..."), just entered more cleanly — via a shell that was never itself running
`claude`, rather than nesting a second `claude` process inside a running session.

## 9. Implemented: symmetrizing the two backends' mount models

Since `--macos` mode already accepted Option A's cross-leaf trade-off (§7) and
Docker/`container` mode avoided it only because it mounted a single leaf (§2.2), and since
`--macos` mode had its own, separate project-keying gap Docker/`container` mode didn't
(§6's added paragraph: `macos_project_vm`'s `basename`-only keying vs
`workspace_slug`+`workspace_path_hash`), symmetrizing both ways — Option A's
whole-directory mount in Docker/`container` mode, `workspace_path_hash`-style keying in
`--macos` mode — leaves both backends with an identical isolation model: strict
cross-project separation, no cross-leaf separation within one project. It introduces no
new category of risk beyond what §3's Option A and §6's added paragraph already separately
describe — it just means both backends now carry the same, already-analyzed trade-offs
instead of one carrying a version the other didn't.

First analyzed and declined as not worth the surface area purely to formalize a
`--worktree` path that already worked via §8's workaround. Reconsidered and **implemented
2026-07-07**, same day, once weighed against a concrete, unrelated cost of *not* fixing
§6's basename-collision gap (a correctness bug independent of `--worktree`, not a
nice-to-have): leaving it unfixed after documenting it here would mean shipping a design
doc that names a known collision bug without shipping the one-line fix for it. Bundling
that fix with the mount-topology change (both touch the same "state/history" contract
seam, §4 C7 of `docs/decisions/0003-swappable-agent-abstraction.md`) was judged cheaper than
tracking it as a separate follow-up indefinitely.

### What actually shipped

**Docker/`container` mode (`cmd_up`):** the bind mount changed from

```
docker_args+=(-v "${host_hist_dir}:$(agent_state_guest_projects_dir)/${agent_proj_leaf}")
```

to

```
docker_args+=(-v "${host_hist_dir}:$(agent_state_guest_projects_dir)")
```

i.e. `host_hist_dir` (still keyed on `workspace_slug`+`workspace_path_hash` — the C7
project-scoping is untouched) is now mounted at the *parent* projects directory, not one
leaf inside it. Any leaf Claude creates for this project — main checkout or a `--worktree`
session launched via §8 — now lands under the same host-persisted directory and survives
`down`/`up`.

**Migration for existing installs:** pre-this-change, `host_hist_dir` held the main
checkout's `*.jsonl` files directly (it used to be mounted *at* that leaf path). Mounting
the parent instead means those files need to live one level deeper — at
`host_hist_dir/$agent_proj_leaf/` — to keep surfacing at the guest path Claude already
expects. `cmd_up` now does this once, idempotently, guarded on the leaf subdirectory not
already existing: on first `up` after upgrading, any pre-existing flat contents of
`host_hist_dir` move into `host_hist_dir/$agent_proj_leaf/` before the mount is set up.
Covered by `tests/10_construct_docker.sh` (seeds a legacy flat file, re-runs `up`, asserts
it lands in the leaf subdir and nothing is left behind at the old path).

**`--macos` mode (`macos_project_vm`):** changed from

```
echo "augur-macos-${dir_name}"
```

to

```
echo "augur-macos-${dir_name}-$(workspace_path_hash)"
```

**Cost accepted, not mitigated:** this changes every existing project's VM name, so every
project VM cloned under the old (`basename`-only) name is orphaned — `macos_vm_exists`
no longer finds it under the new name, so the next `augur up --macos` for that project
clones fresh from the base VM rather than resuming the old one. The old VM/clone is not
deleted; it is left in place (`augur list --macos` still shows it under its old name) and
can be removed manually if no longer wanted. No migration tooling was built for this, on
the same reasoning §9's predecessor (the now-superseded "considered and declined"
analysis) gave for declining an `augur-vm import` command in
[[macos-vm-basevm-portability]]: a coarse, one-time cost taken deliberately rather than
engineered around.

**Verification:** `tests/00_seam_unit.sh` (unchanged functions still byte-identical),
`tests/10_construct_docker.sh` / `tests/11_construct_container.sh` (new: mount targets the
parent exactly, not a leaf; migration moves a seeded legacy file and leaves nothing behind
at the old path), `tests/30_macos_vm.sh` (new: two directories sharing a basename now
resolve to different VM names; the same directory is stable across calls). Full suite:
`tests/run.sh` — all green. Not verified: an actual live Docker/`container` run or a real
macOS VM boot (this environment has neither); the shimmed construction tests exercise the
exact code path but do not replace a live smoke test before release.
