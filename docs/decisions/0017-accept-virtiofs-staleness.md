# ADR-0017 — Accept the macOS virtiofs staleness rather than mitigate it

- **Status:** Accepted. Supersedes [`0016`](./0016-shared-file-cache-refresh.md) in full.
- **Date:** 2026-08-31.
- **Applies to:** macOS VM mode only. Apple Container mode is not affected by the defect.
- **Relates to:** [#124](https://github.com/h1d3mun3/augur/issues/124),
  [#135](https://github.com/h1d3mun3/augur/issues/135) — both still **open**, both still **unfixed**.

## Decision

**The shared-file refresh mechanism is removed from `main`.** augur no longer tries to make a
host-side edit visible inside a running macOS guest. The platform defect is accepted and documented;
it is not worked around.

Removed in full:

- the host-side sweep (`find -newer` → NUL-separated path list → one SSH round trip) and the
  guest-side `msync(MS_INVALIDATE)` program it drove;
- the 5-second host-side refresher loop, its pidfile and its log;
- the boot-time freshness self-test (the "tripwire") and its probe file;
- the `--share-refresh` / `--share-refresh-interval` dials, `augur refresh --macos`, and the
  `augur config` per-project settings layer that existed only to persist those two keys;
- `warn_if_macos_profile_stale` and its per-VM boot marker — the warning that predated the
  mitigation and was left misreporting once the mitigation shipped (it fired *after* the sweep had
  already refreshed the profile, telling operators to restart a VM that did not need restarting);
- tests `41`–`44` and the E2E arms that gated all of the above.

The implementation is **not deleted from the repository's history**. It is preserved in full on the
`topic/virtiofs-cache` branch, and [`0016`](./0016-shared-file-cache-refresh.md) is retained as the
design record and — more importantly — as the record of the **measurements** this ADR accepts the
defect on.

## The defect is unchanged

Nothing here fixes or reduces the underlying problem. Restating what 0016 §1 measured, because it is
the whole basis for accepting rather than mitigating:

- A macOS guest under Virtualization.framework keeps serving **stale file data** from a virtiofs
  share after the host edits the file.
- It is **not** specific to read-only shares. The read-write workspace share behaves identically
  (#135); every share goes stale and comes back together.
- There is **no timeout to wait out**. One arm stayed stale for **904.9 s** with zero natural
  refreshes; every share went fresh together **10.3 s after a guest vnode reclaim was forced**.
- **Metadata and data disagree**: a stale file reports a *current* `size`/`mtime` while `read`
  returns old bytes. Any freshness check built on `mtime` inside the guest is therefore wrong by
  construction.
- Atomic replace (temp + rename) does not help; deletion leaves a phantom dentry.
- There is no knob. `VZSharedDirectory` exposes only `readOnly` and `URL`; `mount_virtiofs` has no
  cache option. **The only route to a real fix is Apple.**

Confirmed still present on macOS 26.6 (25G72).

## Why the mitigation is withdrawn

**1. It was carried half-finished, and the half-finished state was the expensive part.** The
mechanism worked, but it never became something that could be left alone. Between shipping and
withdrawal it needed: a cost dial because a large workspace outran the refresh interval; host-side
persistence for that dial; a PATH pin after the guest was found able to forge the sweep's own
success report; a retry after the release-gate self-test was measured returning three different
verdicts on one machine; and a fix for a seam bug that left a refresher reporting *healthy* for
**31 hours while invalidating nothing**. Each was a real defect found by real use, and each was in
the mitigation, not in the thing being mitigated.

**2. The failure mode of the mitigation is the same failure mode as the defect.** Both are silent.
0016's own series had to remove three instances of it from its own code (a discarded `msync` return
value counted as success, a tripwire that could never trip, warnings written to `/dev/null`), and
#165 added a fourth after shipping. A mitigation whose breakage is indistinguishable from the bug it
mitigates does not reliably convert "stale reads" into "stale reads you find out about".

**3. What it bought was bounded staleness, not coherence.** 0016 §4 is explicit: the guarantee was
*fresh within one refresh interval*, never *fresh at the instant of read*. Directory entries were
out of reach entirely (directories cannot be `mmap`ed), so file creation and deletion never
propagated at all. Operators still needed `down && up` for those, which is the same remedy they need
now.

**4. The cost was ongoing and the benefit was not compounding.** A long-lived host process per
project, an SSH round trip per sweep with changes, a guest-side program invoked by name, and a
release gate that could only be validated by hand on an Apple Silicon Mac — carried indefinitely
against a defect that is Apple's to fix.

## Consequences

**Accepted, and now the documented behaviour again:** in macOS VM mode, a host-side edit to the
workspace, the operator profile, or the per-project Claude state may not be visible to a running
guest. There is no timeout; waiting does not clear it.

**The remedy is `augur down --macos && augur up --macos`.** It works because the guest reboots with
an empty vnode cache — not because a fresh `vm run` rebuilds the share device. Virtualization.framework
cannot rebuild a share device on a live VM in any case (`config.directorySharingDevices` is assigned
once, at boot), so anyone acting on the device explanation will attack something both irrelevant and
impossible.

**No invariant changes.** 0016 deliberately asserted none, so `docs/security-reviews/INVARIANTS.md`
is byte-untouched by both its arrival and its removal. The egress contract is unaffected: the
mechanism moved no policy, opened no port and added no route. One side effect of removal is that
macOS mode no longer starts a long-lived host-side process per project, which shrinks the surface the
2026-07-28 egress snapshot re-baselined for.

**The dated egress snapshots are left alone.** `docs/security-reviews/` is a ledger — superseded by
new files, never edited — so `2026-07-28-egress.md` still describes the mitigation as shipped. That
is correct for a point-in-time record and should not be rewritten; a future snapshot supersedes it.

## What would bring it back

Not a better implementation — a changed platform, or a changed requirement:

- **Apple fixes it.** Then nothing is needed. 0016 §5's self-test controls exist precisely to detect
  this ("shared files were already current before the refresh"), and would have to be re-added
  temporarily to confirm.
- **The defect widens.** It is accepted today because the workspace share is *usually* fresh enough
  in practice for an agent that reads a file once per session. If a workload appears where stale
  source code is routinely read, the trade changes.
- **A cheaper mechanism appears.** 0016 §6 rejected forced vnode reclaim (not addressable from
  userspace), file syncing (worse failure asymmetry — a stopped syncer is permanently and silently
  stale), and waiting (there is no timeout). It did **not** reject pushing small read-only trees over
  SSH instead of sharing them, which removes the dependency rather than patching it and is the only
  option here that is strictly better than what was withdrawn. It does not apply to the read-write
  workspace share.

If it does come back, `topic/virtiofs-cache` is the starting point and 0016 §5 is still the
inventory of what has to move.
