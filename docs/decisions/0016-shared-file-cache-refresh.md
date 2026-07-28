# ADR-0016 — Refresh the guest's view of shared files with `msync(MS_INVALIDATE)`

**Status:** accepted (2026-07-28)
**Relates to:** [#124](https://github.com/h1d3mun3/augur/issues/124), [#135](https://github.com/h1d3mun3/augur/issues/135), ADR-0013 (which this corrects), ADR-0015 (the sibling mitigation)

## 1. The defect

A macOS guest under Virtualization.framework keeps serving **stale file data** from a virtiofs share
after the host edits the file. Every share is affected — read-only and read-write alike.

A 105-arm experiment (2026-07-26, results in #124) established:

| Question | Answer |
|---|---|
| Is it specific to `:ro` shares? | **No.** `claude-profile` (`:ro`), `claude-agents` (rw) and the workspace (rw) went stale and fresh **together**, with no measurable difference |
| Is it a timeout? | **No.** One arm stayed stale **904.9 s** with zero natural refreshes |
| What ends it? | A **guest vnode reclaim**. Every arm went fresh 10.3 s after one was forced (recycled 4,019,385 → 4,383,507) |
| Are metadata and data consistent? | **No.** A file 14 minutes stale reported the *new* size and mtime while `read` returned the *old* bytes, inode unchanged |
| Does atomic replace help? | **No.** temp + `rename` behaved identically to an in-place overwrite |
| What about deletions? | A phantom remains: `readdir` stops listing the entry while `lstat`/`open` still succeed |

The guest's vnode table is permanently saturated (`kern.num_vnodes == kern.maxvnodes`, measured
129,950 with an idle recycle rate near zero), so nothing evicts the stale vnode on its own.

**It is the guest-side client, not the mechanism.** A Linux container guest on the same host reading
the same directory over a mount that is *also* virtiofs sees current content live. There is no knob
to turn: `VZSharedDirectory` exposes `readOnly` and `URL` and nothing else, `mount_virtiofs` takes no
cache options, `sysctl -a | grep -ic virtio` is 0 in the guest, and Apple's documentation does not
mention caching at all.

## 2. Decision

At every point where augur attaches to a macOS guest, the **host** computes which shared files have
changed since the last sweep and the **guest** invalidates exactly those, using
`msync(addr, len, MS_INVALIDATE)` on a `PROT_READ` mapping of each file.

Implemented as `refresh_macos_shares()`, called immediately after `sync_macos_guest_clock()` at the
same four sites: `cmd_up_macos`'s fresh path and its already-running reconcile branch,
`cmd_claude_macos`, and `cmd_shell_macos`.

### Why `msync(MS_INVALIDATE)`

Measured in a live guest: it drops the guest's cached pages for the file and the next ordinary
`read()` refetches from the host. Its properties are what make it usable here — **no privilege**, **no
write permission** (`O_RDONLY` + `PROT_READ` is enough, so `:ro` shares are reachable), the file is
**not modified** (ino/size/mtime unchanged), and it does **not** force a mass vnode reclaim (+7
recycled). It also works while another process holds the file open and mmapped, and — measured — the
holder's own existing mapping sees the fresh bytes afterwards.

POSIX specifies close to exactly this behaviour: `MS_INVALIDATE` shall invalidate cached copies "that
are inconsistent with the permanent storage locations" such that subsequent references obtain
consistent data. Apple's man page reduces it to four words ("Invalidate all cached data") and the
client is a closed kext, so the behaviour is *intended* rather than *contracted* — see §5.

### Why the host computes the change set

Detection belongs where the truth is.

- A host-side `find -newer` over this repo measures **0.31 s** (12,626 files). The same walk from
  inside the guest costs roughly 15× that over virtiofs.
- More decisively: **the guest's own metadata is not reliably fresh either.** A grown file was
  measured reporting its OLD size while its data was stale. A guest-side mtime scan would be deciding
  what is stale using values that are themselves stale.

### Why it retries

That stale-size case is a trap with a silent failure mode. If the guest's cached size is the old,
smaller one when the call is made, `mmap` covers only that many bytes, only those pages are
invalidated, and the subsequent read is EOF-clamped — returning the first N bytes **of the new
content**. The file then looks valid and is quietly truncated, which is worse than being stale.

Measured: a 40,972-byte file grown to 262,156 read back as `HEAD-B` with an empty tail after one
`msync`, and matched the host's sha256 only after a second. The `msync` itself refreshes the size, so
the loop re-stats afterwards and repeats while the size keeps moving (`_MACOS_SWEEP_TRIES`, 3).

### Why the whole path list, and why NUL

The cache is keyed by **name**, not by inode: msyncing a file through one name leaves a hardlink
alias to the same inode stale (measured). A symlink is fine, because it resolves to the same name.
So the sweep covers names, which is what `find` yields anyway — and an "optimisation" that deduped by
inode would silently reintroduce the defect.

The list crosses to the guest **NUL-separated**, and is accumulated in a file rather than a shell
variable because bash strings cannot hold NUL. Every path augur shares lives under
`/Volumes/My Shared Files/`, so any whitespace-separated protocol is broken by construction. This is
not hypothetical: the 105-arm experiment lost ten arms to exactly this, and the first draft of the
implementation shipped the bug until a test caught it.

### Cost

| | Measured |
|---|---|
| Host-side detection | 0.31 s (`find -newer`, 12,626 files) |
| Guest-side invalidation | 0.23 ms per file |
| Full blind sweep, all five shares | 2.87 s for 12,600 files, zero failures |
| Realistic incremental sweep | ~10 ms for a few dozen files |

There is deliberately **no cap** on the changed set. A legitimate one can be large (a host-side build,
a branch switch), the worst case is bounded at a few seconds, and silently truncating the list would
be the same class of failure the surrounding work exists to remove.

## 3. Placement, and why the order is load-bearing

The refresh runs **before** the `ensure_macos_*` wiring, not after. `ensure_macos_claude_profile`
`cp`s `settings.json`, `CLAUDE.md` and `keybindings.json` **out of the profile share**: a wiring pass
that runs first copies stale bytes into the guest, and that copy stays wrong until the next attach.
The tests assert this ordering on line numbers within each function, not by searching for a mention.

It runs after `sync_macos_guest_clock` for consistency across all four sites, and the two do not
interact: the sweep reads **host** mtimes only, so the guest clock is not an input to it.

On the fresh and reconcile paths it also precedes `verify_macos_egress_locked`. That costs a wasted
sweep on the rare path where the tripwire tears the VM down — tens of milliseconds — in exchange for
one identical rule at four call sites.

## 4. What this does NOT fix

- **It is not coherence.** The guarantee is "fresh within one refresh interval", not "fresh at the
  instant of read". A host edit is invisible to the guest until the next sweep picks it up. That
  turns "stale until a vnode reclaim, which may never come" into a bounded window — a large
  practical difference, and still not a coherent filesystem.

  The attach-time sweep alone would not even buy that: it gives "fresh as of the last attach", which
  does **not** fix the symptom #124 actually reports — an edit made on the host *while the agent is
  running*. So a host-side loop re-runs the sweep every `AUGUR_MACOS_REFRESH_INTERVAL` seconds
  (default 5) for as long as the VM is up, started on both `up` paths and stopped by `down` and
  `destroy`. Its pidfile is keyed by `workspace_path_hash`, like every other per-project host-side
  process, because a same-basename sibling sharing one pidfile is the collision class PR #127
  removed. An idle tick costs one host-side `find` and **zero** SSH round trips, because a sweep that
  finds nothing never reaches the guest.

  The loop's exit condition is the guest's own liveness, checked before every tick, rather than
  trusting anyone to stop it: a crashed augur, a killed VM or a host reboot must not leave a process
  SSHing at a guest that no longer exists.

  It **polls** rather than watching. An FSEvents watcher would be event-driven and strictly cheaper,
  but there is no FSEvents binding in the shell or in the stdlib python this uses, and `fswatch` is
  not a dependency augur has — so it would mean a compiled component. That is the obvious next
  optimisation and is deliberately not in the first cut.

  The second sweeper is also what forces a **lock**. Two concurrent sweeps each stamp a pending
  marker, scan against the shared one, and promote — and the loser's promotion can carry a timestamp
  taken before the winner's scan, silently dropping every file changed in between. `mkdir` is the
  atomic primitive; a skipped tick is correct because the holder is scanning the same trees against
  the same marker. A lock older than two minutes is stolen, so a crash cannot wedge the refresh
  permanently.
- **Directory entries are out of reach.** A directory cannot be `mmap`ed at all (EINVAL — also true
  on local APFS, so it is a POSIX property, not a virtiofs quirk). The measured residue is that
  `stat` succeeds on a host-deleted path and reports `nlink=0`, which is the direct cause of augur's
  own `[ -d "$src/$d" ]` checks and dangling-link removal never firing. Creations and deletions did
  propagate promptly to `ls` and `open` in the 2026-07-28 run.
- **The platform bug is untouched.** This is a mitigation. The only route to a real fix is Apple.

## 5. Removal condition

This mitigation exists because of a defect in a closed guest-side component. It must be **cheap to
remove**, and its removal must be **detectable** rather than guessed at.

### 5.1 What tells you it can go

- **No invariant asserts freshness.** `INVARIANTS.md` is deliberately untouched by this change. If a
  later change wants to depend on "the guest sees the host's current content", that is a contract
  change and needs the dated-snapshot ceremony — precisely so that this mitigation cannot quietly
  become load-bearing for something else. Nothing outside the list in §5.3 reads its state.
- The self-test carries **two** controls, because one cannot tell the two futures apart:
  - content does not match **after** msync → the mitigation is **broken** on this guest OS (warn);
  - content already matches **before** any msync → the mitigation is **no longer needed**, i.e. the
    platform has been fixed. `up --macos` prints *"Shared files were already current before the
    refresh — this guest OS may no longer need it (ADR-0016 §5)"*.
- One such observation is a signal, not a proof. Confirm it across a few `up`s and, if possible, more
  than one guest image before acting: a single run can be fresh by luck if nothing was cached.
- Re-verify whenever the guest base image is rebuilt from a new IPSW. `augur update --macos` does not
  change the guest OS; a base rebuild does. That is the moment the behaviour this rests on can change
  in either direction.

### 5.2 Staged removal, not a single delete

The mitigation is inert when it is not needed — an unnecessary `msync` costs 0.23 ms and changes
nothing — so there is no pressure to rip it out the day the signal appears. Prefer:

1. **Stop the loop first.** `AUGUR_MACOS_REFRESH_INTERVAL` only sets the period, so add a disable
   path or set it absurdly high locally, and run normally for a while. If nothing goes stale, the
   platform really is fixed. This is the cheapest and most reversible step.
2. **Keep the tripwire longest.** It is three SSH round trips on `up` and it is the only thing that
   would notice a *regression* in a later macOS. Delete it last, or keep it permanently as a cheap
   canary.
3. **Then delete the mechanism** per §5.3.

### 5.3 What removal actually touches

Not "one function". As shipped, in `augur`:

| | |
|---|---|
| Sweep | `refresh_macos_shares`, `_refresh_macos_shares_locked`, `_macos_msync_program`, `macos_share_roots`, `macos_share_sweep_marker`, `_MACOS_SWEEP_TRIES` |
| Tripwire | `verify_macos_share_freshness`, `_MACOS_FRESHNESS_PROBE` |
| Loop | `start_share_refresher`, `stop_share_refresher`, `share_refresher_running`, `share_refresher_pidfile`, `share_refresher_logfile`, `_MACOS_REFRESH_INTERVAL` (and its `AUGUR_MACOS_REFRESH_INTERVAL` override) |

Call sites: `refresh_macos_shares` ×4 (`cmd_up_macos` fresh + reconcile, `cmd_claude_macos`,
`cmd_shell_macos`) plus once inside the loop; `verify_macos_share_freshness` ×2 and
`start_share_refresher` ×2 (both `up` paths); `stop_share_refresher` ×2 (`cmd_down_macos`,
`cmd_destroy_macos`). The reaping block in `cmd_destroy_macos` goes too.

Host state to stop creating — and to clean up once from existing installs, since nothing will remove
it afterwards: `$AUGUR_DIR/vm-state/<vm>.shares-swept` (plus `.pending` and the `.lock` **directory**),
`$AUGUR_PROXY_DIR/<slug>-<hash>-refresher.{pid,log}`. Guest state: the
`.augur-freshness-probe` dotfile in each per-VM `claude-agents` share.

Tests: delete `tests/41_macos_share_refresh.sh`, `tests/42_macos_share_freshness_selftest.sh`,
`tests/43_macos_share_refresher.sh`; drop the `start_share_refresher`/`stop_share_refresher` stubs
from `tests/34`, `tests/36` and `tests/38` (left in place they are harmless, but they would stub
functions that no longer exist); and remove the "Shared-file refresh" section from
`tests/e2e_macos_vm.sh`.

Docs: this ADR is retired (status → superseded, with the observation that retired it), its index row
in `docs/decisions/README.md` goes, and the macOS caveat in `README.md`'s operator-profile section is
rewritten — **not deleted**. A reader on an older guest image still hits the defect.

### 5.4 What must NOT be reverted with it

Two changes rode along in the same series and are **independent of whether Apple ever fixes this**:

- **The documentation corrections.** `README.md` and ADR-0013 used to attribute the staleness to
  read-only sharing and to claim it resolved "before the 10-minute mark". Both were measured false.
  That is historical fact about the platform, not a consequence of the mitigation.
- **The removal of the `gh-config` share from macOS mode.** That share was mounted and never wired to
  `~/.config/gh`, so it carried the host's real `config.yml` and `hosts.yml` into a guest that never
  read them. It is exposure without a feature and stays removed regardless. If it is ever wired
  properly it must reappear in **both** the `--dir=` argv and `macos_share_roots`.

Measured on macOS **26.5.2** (build 25F84, `xnu-12377.121.10 RELEASE_ARM64_VMAPPLE`), guest page size
16384. Everything above rests on that one guest.

Measured on macOS **26.5.2** (build 25F84, `xnu-12377.121.10 RELEASE_ARM64_VMAPPLE`), guest page size
16384. Everything above rests on that one guest.

## 6. Alternatives rejected

**Forced vnode reclaim.** Measured to work, and it fixes directory entries too, which msync cannot.
Rejected as the primary mechanism: it cannot be aimed. There is no syscall to request it — you flood
the cache until the kernel evicts, and the guaranteed sweep needed +364,122 recycles against a
capacity of 129,950 (~2.8 full turnovers), which discards every other process's cached lookups. It
also offers no confirmation that the file you cared about was actually evicted. Retained as a
possible operator-facing escape hatch, not as the mechanism.

**Sync the files instead of sharing them** (Mutagen or similar, over SSH or vsock). Investigated in
depth. The failure asymmetry decides it: if this mitigation stops running, the guest is back to
today's behaviour; if a syncer stops running, the guest reads local files that are silently and
permanently stale, with no error. Beyond that, Mutagen forbids a symlink as a sync root and three of
augur's guest paths are symlinks today; conflicts leave no on-disk marker; `.gitignore` is not
honoured; and `:ro` would stop being kernel-enforced and become a per-session flag. Recorded here so
the option is not re-litigated from scratch.

**Push content over SSH instead of sharing it.** Not rejected — it is *better* than this mitigation
where it applies, because it removes the dependency instead of managing it: no share means no cache
to invalidate. It does not apply to the read-write workspace. Tracked separately for the small
read-only shares.

**Waiting.** The previous record advised `down --macos && up --macos` and described the delay as
resolving "before the 10-minute mark". There is no timeout; waiting is the one thing that does not
work. Corrected in ADR-0013 and `README.md`.
