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

Two further entry points were added after the first cut and this enumeration no longer describes the
whole of it: the host-side **loop** (§4) sweeps on its own every few seconds, and **`augur refresh
--macos`** (`cmd_refresh_macos`) sweeps once on demand. Counting them, the sweep has six call sites —
four automatic and attach-driven, one automatic and unattended, one manual — and only the manual one
is exempt from the `--share-refresh` mode gate. See §4 for why.

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
| Host-side list accumulation | ~130 µs per **changed** file (2026-07-28 snapshot, item 37) |
| Guest-side invalidation | 0.23 ms per file |
| Full blind sweep, all five shares | 2.87 s for 12,600 files, zero failures |
| Realistic incremental sweep | ~10 ms for a few dozen files |

There is deliberately **no cap** on the changed set. A legitimate one can be large (a host-side build,
a branch switch), and silently truncating the list would be the same class of failure the surrounding
work exists to remove.

The second row was **added after the fact** and it corrects this section. The original four rows did
not measure the shell loop that builds the path list, which appends once per changed file and reopens
the list file each time — ~99 % of the host-side cost. Adding it to the guest's 0.23 ms, both paid
serially, one sweep costs **~0.36 ms per changed file end to end**, so past roughly **14,000** changed
files a sweep outlasts the default 5 s interval and the loop below degrades into a rising duty cycle
on one host core for the lifetime of the VM. That is reachable with no adversary — `npm install`, a
large `git checkout`, a full build — and augur's own repo is 12,626 files. So "the worst case is
bounded at a few seconds" was true of the sweep and false of the loop, and the answer is the operator
dial in §4, not a cap.

**How firm is 14,000, and why it does not contradict the blind-sweep row.** It does not, but only
because the table has three independent measurements in it, not four: 2.87 s ÷ 12,600 = 0.228 ms, so
the "guest-side invalidation 0.23 ms per file" row *is* the blind-sweep row, divided. Whatever
host-side accumulation that one run paid is already inside both, and neither can be added to the
other. That leaves a band rather than a number — 5 s ÷ 0.23 ms ≈ 22,000 changed files if the
accumulation cost is already included, 5 s ÷ 0.36 ms ≈ 14,000 if it is additive — and **14,000 is the
conservative end**, which is the one quoted in the code, `--help` and the README. The snapshot's own
figure of 30–40k is a third thing again: it is the host-side term *alone*, with the guest's share
excluded. Nothing here rests on the exact crossing; what it rests on is that a crossing exists at a
count no adversary is needed to reach, which all three readings agree on.

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

  Because that cost scales with a count nobody bounds (§Cost), the three mechanisms are dialled at
  launch with **`--share-refresh <continuous|attach|off>`**: `continuous` (default) is all three,
  `attach` keeps the attach-time sweep and the tripwire and stops the loop, `off` stops all three
  — including the tripwire, because verifying a refresh that did not happen is a misreport, not a
  check. `attach` is the answer to "this repo is too big for a 5 s loop": the loop is the unattended,
  repeated cost, while the attach sweep runs once in front of an operator who can read what it says.
  Anything other than `continuous` warns on every attaching command, names #124/#135, and says how to
  restore the default — a silently disabled freshness mechanism is the defect this series removed
  from the refresher's own warnings. Because it warns on all four of those commands, all four also
  **stop** a loop an earlier `up` left running: `cmd_claude_macos`, `cmd_shell_macos` and
  `cmd_setup_token_macos` skip `cmd_up_macos` entirely against an already-running VM, so without a
  reconcile of their own they would print "the loop is off for this run" over a loop that kept
  sweeping — the misreport shape, not the cost, is what makes that unacceptable.
  `--share-refresh-interval` sets the period (flag > `AUGUR_MACOS_REFRESH_INTERVAL` > 5), and both
  layers are validated as positive integers: `0` used to reach `sleep 0` and spin, and it is now
  **refused** rather than read as "off", because it would be a second spelling of a disable that
  leaves the sweep and the tripwire running. The env layer is checked only on the commands that can
  reach `sleep` (`up`/`claude`/`shell`/`setup-token`) — the same rule §5.3's teardown inventory
  depends on: a stale export in a shell profile must not be able to refuse `augur down --macos`, which
  is the one command that stops the loop it is spinning.

  The dial left the two non-default modes **half-built**, and `augur refresh --macos`
  (`cmd_refresh_macos`) is what finishes them. With the loop stopped, the only remaining ways to get
  a host-side edit into a running guest were to attach — `up`/`claude`/`shell`, every one of which
  puts the operator *inside* the guest as a side effect — or to wait, which §1 measured as not
  working. An operator who turns the loop off because one sweep outlasts the interval had no
  replacement and was pushed back to `continuous` or to reading stale data, so the dial's most useful
  setting was also its least usable one. The manual command sweeps once, against the VM that is
  already running, and reports normally (no `quiet`) because a human typed it and wants the count and
  the named failures.

  It deliberately does **not** boot a VM, unlike `claude`/`shell`, whose job is to put the operator in
  the guest: a stopped guest holds no virtiofs cache to invalidate, and the `up` that would start one
  sweeps on the way in anyway — so it refuses and names that command. It also pre-checks the SSH
  transport before sweeping, the #137 remedy in the shape `verify_macos_egress_locked` established:
  `ssh_macos` *exits* rather than returning when it cannot name a host, and although the sweep
  contains that exit (it happens inside a command substitution) it converts it into a warning under a
  **success** exit status — right for a bring-up, wrong for a command whose only job is the round
  trip, and invisible altogether when nothing changed and the guest is never contacted.

  And it runs **under `off`**, which is the one part of this worth arguing about. The gate lives
  inside `refresh_macos_shares` — one chokepoint for all five automatic callers rather than an `if`
  at each — so the manual path reaches the sweep through a second, ungated entry point,
  `refresh_macos_shares_now`, which `cmd_refresh_macos` alone calls. That is not a hole in the gate;
  it is what allows the gate to be absolute for everything else. `off` means "do not refresh on your
  own", not "never refresh".

  Be exact about how much that bypass is carrying, because a first draft of this section was not.
  `_MACOS_REFRESH_MODE` has **no env layer** — only the interval does — and is re-derived from each
  command line, so an operator who launched the VM with `--share-refresh off` and later types a plain
  `augur refresh --macos` is in `continuous` for that command and sweeps through the **gated** entry
  anyway. The ungated entry is therefore load-bearing for exactly one command line, `augur refresh
  --macos --share-refresh off`, and the argument for it is consistency rather than rescue: a flag
  that describes what the mechanism does *on its own* must not silently cancel the operator's
  explicit act, and a command that accepted the flag and then did nothing would be the worse of the
  two failures. It is explicitly **not** true that refusing would leave an operator who chose `off`
  with no remedy short of `down`/`up`; that argument was drafted and is wrong, for the reason above.

  A `force` argument on
  the gated function was rejected for a testability reason — a bypass must be visible in the *call*,
  so that `grep refresh_macos_shares_now` is the complete list of code that skips the mode check, and
  a bypass never reads like the five ordinary call sites around it. tests/41 counts that name against
  a **bare** needle, not `name "`: an unquoted sixth caller (`refresh_macos_shares_now $project_vm`)
  is idiomatic-looking, is what shellcheck would catch if shellcheck could run here, and left the
  suite fully green when it was measured. Under `off` the command prints one
  run-scoped line saying the automatic refresh stays off, so a successful manual sweep cannot be read
  as `off` having lapsed; it claims nothing about a *live* loop (`status --macos` measures that half)
  and, unlike the attaching commands, does not stop one — it makes no claim that a surviving loop
  would falsify, and killing a background refresher as a side effect of `refresh` is the same class of
  surprise as booting a VM would be.

  **The manual command reports the outcome in its exit status; the automatic callers do not.** This
  is the one behavioural difference between the two entry points beyond the mode gate, and it exists
  because the best-effort contract that is right for a bring-up is wrong for a command whose only job
  is the round trip. The sweep returns 0 on every path — a stale share is degraded, not uncontained,
  and a non-zero return would abort `up --macos` between "SSH is up" and the egress tripwire, which
  is the failure shape the I1 series removed. So `refresh_macos_shares_now` hands back what happened
  (`_MACOS_SWEEP_BUSY`, `_MACOS_SWEEP_FAILED`, `_MACOS_SWEEP_NOWORK`), `refresh_macos_shares` maps
  every one of them to 0 for its five automatic callers, and `cmd_refresh_macos` turns them into
  lines and a status:

  | outcome | `augur refresh --macos` | automatic callers |
  |---|---|---|
  | swept, guest confirmed every file | reports the count, exit 0 | reports, continues |
  | nothing had changed | "No shared file has changed…", exit 0 | silent, continues |
  | another sweep held the lock | "Another sweep is already in progress", exit **1** | silent skip, continues |
  | round trip failed, or state dir unwritable | the sweep's warning, exit **1** | warns, continues |
  | guest reported `msyncfail`/`nomap` | the named files, exit **1** | warns, continues |
  | guest reported only `unstable` | the named files, exit 0 | warns, continues |

  The lock row is the one worth spelling out. Skipping a tick you cannot lock is correct for the
  **loop** — the holder is scanning the same trees against the same marker, so the work is covered —
  and that reasoning does not survive the move to a one-shot command: the holder stamped its pending
  marker and ran its `find` *before* the operator's edit, so that edit belongs to the *next* sweep,
  and under `attach`/`off` this command **is** the next sweep. Reporting success there would be the
  #147/#151 misreport class in the very command written to remove it. `unstable` is excluded from the
  failing set on the same evidence-first grounds: a file whose size keeps moving across every retry
  is a live host-side writer, which is expected during a build and is not this mechanism failing.

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

1. **Stop the loop first.** `augur up --macos --share-refresh attach` does exactly this: the loop
   stops (and a loop left running by an earlier `up` is stopped too, on `claude`/`shell` as well as
   on `up`), while the attach-time sweep and the tripwire stay. Note that the mode is **run-scoped**:
   it has to be passed on each attaching command, so the observation window is the runs you pass it
   on, not "until further notice". Run normally for a while; if nothing goes stale between attaches,
   the platform
   really is fixed. This is the cheapest and most reversible step. Do **not** use `--share-refresh
   off` for it — that also stops the tripwire, which is the instrument this observation depends on.
2. **Keep the tripwire longest.** It is three SSH round trips on `up` and it is the only thing that
   would notice a *regression* in a later macOS. Delete it last, or keep it permanently as a cheap
   canary.
3. **Then delete the mechanism** per §5.3.

### 5.3 What removal actually touches

Not "one function". As shipped, in `augur`:

| | |
|---|---|
| Sweep | `refresh_macos_shares` (the mode gate, which also maps the outcome statuses back to 0) and `refresh_macos_shares_now` (the ungated entry), `_refresh_macos_shares_locked`, `_macos_msync_program`, `macos_share_roots`, `macos_share_sweep_marker`, `_MACOS_SWEEP_TRIES`, `_MACOS_SWEEP_BUSY`/`_MACOS_SWEEP_FAILED`/`_MACOS_SWEEP_NOWORK` |
| Tripwire | `verify_macos_share_freshness`, `_MACOS_FRESHNESS_PROBE` |
| Loop | `start_share_refresher`, `stop_share_refresher`, `share_refresher_running`, `share_refresher_pidfile`, `share_refresher_logfile`, `_MACOS_REFRESH_INTERVAL` (and its `AUGUR_MACOS_REFRESH_INTERVAL` override) |
| Dial | `_MACOS_REFRESH_MODE`, `share_refresh_enabled`, `share_refresh_loop_enabled`, `macos_refresh_interval_valid`, `validate_macos_refresh_interval`, `warn_macos_refresh_mode`, the `--share-refresh` / `--share-refresh-interval` arms of the global flag loop and the `$MACOS_MODE` block below it, the `share_refresh_loop_enabled \|\| stop_share_refresher` line in each of `cmd_claude_macos` / `cmd_shell_macos` / `cmd_setup_token_macos`, and the two `Share refresh:` lines in `cmd_status_macos` |
| Manual command | `cmd_refresh_macos` (including the `require_safe_workspace` call it makes itself — it is the one command guarded from inside rather than from the shared dispatch tail, and the gate's comment records the exception), its `refresh)` arm in the macOS dispatch **and** the macOS-only refusal arm of the same name in the container dispatch (which cites §1: a Linux guest over the same kind of mount sees host edits live), its `augur refresh --macos` line in `cmd_help`'s macOS command list and the bullet in that function's NOTES |

Call sites: `refresh_macos_shares` ×4 (`cmd_up_macos` fresh + reconcile, `cmd_claude_macos`,
`cmd_shell_macos`) plus once inside the loop, and `refresh_macos_shares_now` ×2 — once from the gate
itself, once from `cmd_refresh_macos`, which is the only caller that may skip the mode check;
`verify_macos_share_freshness` ×2 and
`start_share_refresher` ×2 (both `up` paths); `stop_share_refresher` ×2 (`cmd_down_macos`,
`cmd_destroy_macos`) plus once inside `start_share_refresher` itself and once in each of
`cmd_claude_macos` / `cmd_shell_macos` / `cmd_setup_token_macos` — those three attach to an
**already-running** VM without going through `cmd_up_macos`, so the mode reconcile has to be repeated
there or it never happens on the commands an operator uses most. The reaping block in
`cmd_destroy_macos` goes too.

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

**A config file for the refresh mode, instead of the `--share-refresh` flag.** Both candidate layers
were considered and rejected, and this is recorded because it will be proposed again. **The second of
the two has since been adopted — see §6.1 — and the first has not.**

- `./.augur/allowlist.conf` — the project layer — lives **inside the mounted read-write workspace**,
  so the guest can write it. A mode read from there would let a compromised guest, or a
  prompt-injected agent, switch off the mechanism that keeps the operator's view of the guest's own
  filesystem honest. It composes badly with the 2026-07-28 snapshot's item 39(a), where the sweep's
  round trip invokes an unpinned `python3`: the guest could fabricate the refresh report *and*
  disable the tripwire that would notice. The resources file is guest-writable on purpose, but that
  asymmetry is deliberate — inflating your own VM is a self-serve request the operator sees applied,
  whereas silencing a freshness mitigation is invisible by construction.
- A **host-side per-project file** keyed by `workspace_path_hash` (the pattern every other piece of
  per-project host state already uses) has no such hole. It was rejected on cost and on fit: it needs
  a whole `augur config` surface before an operator can use it, and the right value depends on the
  **host's** CPU as much as on the repo's file count, so a value committed with the project is wrong
  on the next machine. *(Both objections are answered in §6.1; this bullet is kept as written so the
  reversal can be read against what it reversed.)*

A launch-time flag has neither problem — the value comes from the operator, in the clear, per run —
and it is where this repo already puts run-scoped options (`--egress`, `--no-egress`, `--gui`).
`AUGUR_MACOS_REFRESH_INTERVAL` keeps its env peer because it predates the flag and only tunes a
period; no `AUGUR_MACOS_REFRESH` peer was added for the mode, because the one place an env var is set
persistently is a shell profile, i.e. per **host** and across every project, which is the one scope
at which "this repo is too big for a 5 s loop" is never the right answer.

**Waiting.** The previous record advised `down --macos && up --macos` and described the delay as
resolving "before the 10-minute mark". There is no timeout; waiting is the one thing that does not
work. Corrected in ADR-0013 and `README.md`.

### 6.1 The host-side per-project file, adopted — and why the repo layer is still refused

The second bullet above was rejected on **cost** ("needs a whole `augur config` surface") and on
**fit** ("a value committed with the project is wrong on the next machine"). The cost has been paid:
`augur config` exists. The fit objection was answered by the same fact that removes the security
hole — the file is **host-side**, so it never travels with the project, and a value set on one machine
is a value set on that machine only. Neither objection ever applied to the *location*.

    ~/.augur/project-settings/<slug>-<workspace_path_hash>.conf

    # augur project settings — written by `augur config`. Host-side; never read from the workspace.
    # workspace: /Users/hidemune/GitHub/big-monorepo
    share_refresh=attach
    share_refresh_interval=30

Line 2 is not decoration. The filename carries a 12-character hash, which identifies nothing to a
human; `~/.augur/project-hashes/` already has that problem, and this comment is the only place the
hash → path mapping exists.

**The first bullet stands, unchanged, and this is the paragraph to read before proposing `./.augur/`
again.** It is the obvious guess — every other per-project knob in augur lives there — and it is
wrong for one reason that has nothing to do with convenience: `./.augur/` is inside `$WORKSPACE_DIR`,
which is mounted **read-write** into the guest, so the guest can write it. A `share_refresh` read from
there lets a compromised guest, or a prompt-injected agent, **switch off the mechanism that keeps the
operator's view of the guest's own filesystem honest** — and it composes with the 2026-07-28
snapshot's item 39(a), where the sweep's round trip invokes an unpinned `python3` in the guest: the
guest could fabricate the refresh report *and* disable the tripwire that would notice the report was
fiction. `.augur/resources.conf` being guest-writable is not a precedent for it: inflating your own VM
is a self-serve request the operator **sees applied** on the next `up`, whereas silencing a freshness
mitigation is invisible by construction, which is the whole reason the mode warns on every run (#148).

That `~/.augur` is out of the guest's reach is a property of the code and was verified against it
rather than assumed: it appears in none of `cmd_up_macos`'s four `--dir=` shares and none of
`cmd_up`'s six `-v` mounts, and `require_safe_workspace` refuses any `$WORKSPACE_DIR` that is,
contains, or lives inside it. `tests/44_macos_project_settings.sh` re-derives the mount argv and
tests containment, so a fifth share cannot land silently.

**Precedence: `--flag` > settings file > `AUGUR_MACOS_REFRESH_INTERVAL` > built-in default.** The
env-vs-file half is a real decision, and it **inverts** the only existing precedent in the codebase:
`resolve_macos_vm_cpu` puts `AUGUR_MACOS_VM_CPU` *above* `.augur/resources.conf`'s `MACOS_CPU`. That
ordering is a **trust** ordering, stated at `clamp_resource_int` — the resources file is
guest-writable and the export is the operator's, so the trusted layer must win. This file is
host-side and written only by an augur command, so it is exactly as trusted as the export, and what
is left to order on is **scope**:

- the export's one persistent home is a shell profile, i.e. per **host** and across every project.
  §6 above already gives that as the reason no env peer was added for the *mode*: it is "the one scope
  at which 'this repo is too big for a 5 s loop' is never the right answer". A layer that reasoning
  rejects as wrongly scoped for the mode cannot outrank a per-project file for the period either.
- the file is per project and deliberate: it exists only because someone ran `augur config` in that
  directory, and it records that directory's path.
- the concrete case is the one §2's dispatch-tail gate already complains about — a **stale**
  `AUGUR_MACOS_REFRESH_INTERVAL` in a profile. Under env > file it would silently override the value
  set for the one repo that needed it, in every shell the operator owns.

Neither direction is silent: `augur config --show` names the winning layer for both keys, and
`status --macos` names it for the mode.

**Two traps had to be closed before any of this could work**, and both were invisible with only two
layers. `_MACOS_REFRESH_MODE=continuous` was a plain assignment, so `--share-refresh continuous` and
an empty command line were indistinguishable — a file layer would have overruled the *explicit* flag
for exactly the value used to escape a persisted `off`. And
`_MACOS_REFRESH_INTERVAL="${AUGUR_MACOS_REFRESH_INTERVAL:-5}"` collapsed the env layer into the
default, which additionally made the validator's `AUGUR_MACOS_REFRESH_INTERVAL` attribution right only
by accident: with a file layer above it, a bad *file* value would have sent the operator to `unset` an
export that was not the problem. Both are closed by a per-setting provenance variable, which the
`--show` output, the `status` line, the launch warning's remedy and the validator's blame all read
from — so no two of them can name different layers.

**A broken file warns; it does not refuse, and it does not fall back silently.** Silence is #148 with
a different cause: someone who wrote a setting and sees no effect concludes the feature is broken. A
refusal is worse than it is for a bad export, in the one direction that matters — `unset` fixes an
export, while this file is deliberately **not** reaped by `destroy --macos`, so a refusal would be
permanent and would take `down --macos` with it. Rejected values are therefore dropped in favour of
the next layer down, named, and paired with the `augur config` line that clears them. The hard
refusal keeps its existing `up|claude|shell|setup-token` gate untouched.

**`destroy --macos` does not delete it.** Everything that command reaps is VM state — the clone, its
pinned host key, the profile and sweep markers, a lock, the refresher logfile — and several are
actively harmful if they outlive the clone. This file is operator intent about the *project*, recorded
because the project's changed-file count made the default loop too expensive, which a re-clone does
not change. Reaping it would also undo the operator's configuration on the exact command line these
warnings recommend (`destroy --macos && up --macos`). `augur config --unset` is the only thing that
removes it.

**`augur refresh --macos` changes size, and the paragraph in §5 that sized it is now wrong.** That
reasoning was: the mode has no env layer and is re-derived per run, so an operator who *launched*
with `off` and later types a bare `augur refresh --macos` is back in `continuous` for that command
and would sweep through the gated entry point anyway — leaving the ungated entry load-bearing for
exactly one command line, the one that repeats the flag. A persisted mode removes the "per run"
premise the whole argument rested on. `share_refresh=off` written once is resolved by the dispatch
tail for **every** macOS command in that project, so a bare `augur refresh --macos` is in `off` too,
`share_refresh_enabled` is false, and the gated entry sweeps nothing. The ungated entry is therefore
load-bearing for **every manual refresh in a configured project** — the ordinary use of the command,
not an edge case — and it is what keeps `augur config --share-refresh off` a setting rather than a
one-way door. Its warning names the layer for the same reason the launch warning does: "off for this
run" describes a flag, and a mode out of the file was never on the command line. This is the one
command an operator reaches while already asking *what is off, and where did that come from*, so it
answers both, and points at `augur config --unset share_refresh`.
