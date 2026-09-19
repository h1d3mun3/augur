# ADR-0019 — macOS 27 resolves the virtiofs staleness defect

- **Status:** Accepted.
- **Date:** 2026-09-19.
- **Applies to:** macOS VM mode, specifically macOS 27.0+ host **and** guest.
- **Narrows:** [`0017`](./0017-accept-virtiofs-staleness.md) — 0017's "accept, do not mitigate"
  decision, and its "no timeout, no knob, Apple's to fix" framing, stand unchanged for macOS 26.x.
  This ADR establishes that on macOS 27.0 (build 26A428) the underlying defect is no longer
  observed.
- **Closes:** [#124](https://github.com/h1d3mun3/augur/issues/124),
  [#135](https://github.com/h1d3mun3/augur/issues/135).

## What changed

Re-ran the conditions from 0016 §1's table — plus the two this issue and #135 specifically call
out — on **macOS 27.0, build 26A428, host and guest**, on 2026-09-19. This is a targeted
spot-check on a single machine, not a repeat of the original 105-arm campaign. Every condition
came back clean: no staleness, no metadata/data divergence.

## Environment

- Host: `Darwin hidemunes-MacBook-Pro-M1-Max.local 27.0.0 Darwin Kernel Version 27.0.0: Tue Aug 11
  21:22:49 PDT 2026; root:xnu-13432.1.9~1/RELEASE_ARM64_T6000 arm64` (Apple M1 Max)
- Guest: `Darwin augurs-Virtual-Machine.local 27.0.0 Darwin Kernel Version 27.0.0: Tue Aug 11
  21:00:07 PDT 2026; root:xnu-13432.1.9~1/RELEASE_ARM64_VMAPPLE arm64` (same build, via
  Virtualization.framework)
- Both: `ProductVersion: 27.0`, `BuildVersion: 26A428`
- augur commit under test: `5f8f5bf3017cbf31045b1203e8bff6597de2ada2`
- Guest vnode table was already saturated at test time: `kern.num_vnodes == kern.maxvnodes ==
  129634` (0016 measured ~129,950 under the same condition) — not an artificially forced
  condition, the guest's steady state.

## Method

Host-side edits were driven from a real terminal on the host Mac (`~/GitHub/augur`, the same
checkout `augur up --macos` was started from). Guest-side observation used a Python poller running
inside the VM that polled and held descriptors on the shared paths, logging every observed change
against a wall-clock timestamp. Host and guest clocks agreed to well under a second across every
trial below.

## Results

| Condition | Trials | Result |
|---|---|---|
| Rapid successive edits, rw workspace share | 15 | All detected in 0.4–0.6s |
| Cold idle (10 min, zero guest reads) → single host edit | 1 | Detected within ~0.6s of the actual write (an initial "stale" read in the raw log was an artifact of the host-side script starting ~16s late, not caching — the guest's read genuinely preceded the host's write) |
| Directory entry create/delete, rw share | 1 each | Both reflected in `readdir` within 0.2s; continuous direct `open`/`stat` for 40s post-delete never reproduced the phantom-dentry read #124 reports |
| `:ro` share (`claude-profile`) | 3 | All detected in <0.5s |
| Bulk create, 500 files at once | 1 | Full content convergence 0.18s after the directory listing itself became visible |
| Bulk create, **12,600 files** (matches this repo's own file count, the scale 0016 measured host-side detection cost on) | 1 | 100% match on the *first* full guest-side scan pass — 0 mismatches, 0 missing. Scan itself took 4.16s (0016 predicted guest reads run ~15× host cost: 0.31s × 15 ≈ 4.65s, close to the observed 4.16s — consistent with virtiofs read overhead, not staleness) |
| Atomic replace (temp + `mv`) with a long-held fd/mmap opened *before* the edit | 2 | Fresh `open()` saw the new content in <1s every time. The held fd/mmap kept showing the pre-rename content forever after — expected POSIX unlink-while-open semantics (rename orphans the old inode), not the cache defect. |
| **Same-inode in-place edits (no rename), same held fd/mmap opened before any edit** | 3 | **The held fd and held mmap — never reopened — reflected every edit in real time, with no explicit invalidation call.** This directly contradicts 0016 §1's core finding that a held-open/mmapped file does not see host writes without a forced `msync(MS_INVALIDATE)`. |

## What this does not establish

- Single machine (Apple M1 Max / T6000), single ~2-hour session — not the original 105-arm,
  multi-condition statistical campaign.
- Not tested: concurrent multi-process guest readers racing a host writer, multi-hour soak, other
  Apple Silicon variants or Intel, macOS 27.x point releases other than 26A428.

## Decision

On macOS 27.0+ (host and guest), augur no longer treats the virtiofs staleness defect as present.
#124 and #135 are closed by this ADR. The `topic/virtiofs-cache` mitigation is **not** reinstated:
0017's reasons for withdrawing it — a half-finished mechanism whose own bugs kept compounding, the
same silent-failure mode as the defect it mitigated, bounded staleness rather than coherence, and
an ongoing cost carried against a defect that was Apple's to fix — hold independently of whether
the defect is present, and a defect that no longer reproduces needs no mitigation.

Operators on macOS 26.x continue to see the defect exactly as 0017 describes it; `down --macos &&
up --macos` remains the remedy there. Operators on macOS 27.0+ should not need that remedy for
staleness specifically, though it remains available for the other reasons 0006 documents.

## Consequences

- No invariant changes — same as 0017; nothing here touches
  `docs/security-reviews/INVARIANTS.md`.
- This is a documentation-only change: no mitigation code is reinstated, and augur gains no
  macOS-version-conditional behavior from it.
- If a future report reproduces staleness on macOS 27.x, treat this ADR as contradicted, reopen
  #124/#135 (or file new issues referencing them), and treat `topic/virtiofs-cache` plus 0016 §5
  as the starting inventory for a real fix — per 0017's own "What would bring it back."
- This ADR does not claim macOS 26.x is unaffected, does not claim every macOS 27.x point release
  is unaffected, and does not claim every hardware configuration is unaffected — see "What this
  does not establish" above.
