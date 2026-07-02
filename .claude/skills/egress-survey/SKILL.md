---
name: egress-survey
description: >-
  Bounded drift audit of augur's egress control. Verify the code still satisfies each
  invariant in docs/security-reviews/INVARIANTS.md, confirm the contract's tests are
  green, and report ONLY what diverged or changed since the newest dated snapshot —
  like `git diff`, not a full re-description. Use when the user asks to audit / check /
  survey egress control, look for egress drift, or sanity-check egress before merging a
  change to the egress core (augur / augur-proxy/ / gvproxy/ / augur.conf / augur-vm/).
  To fully REGENERATE the snapshot instead of auditing it, run the `augur-egress-survey`
  workflow (the heavy path) — this skill does not do that.
---

# Egress drift audit (the light path)

Goal: **bounded, high-signal output.** If nothing drifted, say so in a few lines. Do NOT
re-describe the whole egress architecture — that is what a dated snapshot is for. Report
only (a) contract health, (b) divergences between the docs and the code, and (c) egress-core
changes since the newest snapshot.

The two artifacts you audit against:
- **Contract:** `docs/security-reviews/INVARIANTS.md` (invariants I1–I10 with an `Enforced by`).
- **Newest snapshot:** the highest-dated `docs/security-reviews/YYYY-MM-DD-*.md`.

The egress core (what "changed enough to matter" means): `augur`, `augur-proxy/`, `gvproxy/`,
`augur.conf`, `augur-vm/`.

## Steps

1. **Read the contract and the newest snapshot.** List the invariants and their claimed
   `Enforced by`, and note the snapshot's date.

2. **Run the mechanical checks (the contract must be green).**
   - `cd augur-proxy && swift test` — the unit/self tests behind I1–I8.
   - `bash tests/run.sh` — the shell tiers (`01_egress_allowlist_unit.sh` = I7,
     `30_macos_vm.sh` entitlement = I9, etc.). Live tiers self-skip; that is expected.
   - Record pass/fail per suite. Any failure is a **hard finding** (the contract is broken).

3. **Structural checks (cheap greps mapped to invariants).** For each, confirm reality still
   matches the invariant; flag any mismatch as a divergence:
   - **I4 / dead PinTable:** `grep -rn "pins.pin(" augur-proxy/Sources` should show no
     production caller, and there should be no in-process DNS responder (no `:53` / UDP
     listener). If the pin path got wired, I4's "always deny" note and the snapshot are stale.
   - **I8 / `--allow-private`:** `grep -n "allow-private" augur` — augur must never pass it on
     a production path.
   - **I7 / host-side merge:** `write_merged_allowlist` must still write under `~/.augur/proxy`
     (outside the project tree), and `./.augur.conf` must go through `conf_line_valid`.
   - **I9 / entitlements:** `augur-vm/augur-vm.entitlements` must NOT contain
     `<key>com.apple.vm.networking</key>` (bridged networking).
   - **New surface:** grep the engine cases / `AUGUR_EGRESS` / the 3-layer merge for any new
     engine, allowlist tier, or egress flag the snapshot doesn't mention.
   - **Default domains:** diff the domains shipped in `augur.conf` against the list the newest
     snapshot records; report additions/removals.

4. **Changes since the newest snapshot.** Find the snapshot's commit (or use its date) and run
   `git log --oneline <since>..HEAD -- augur augur-proxy gvproxy augur.conf augur-vm` to list
   egress-core commits landed since. Summarize what each touched (one line each).

5. **Cross-check the snapshot's claims.** For a handful of load-bearing statements in the newest
   snapshot (e.g. "PinTable is a dead scaffold", "Docker reaches the proxy via the sidecar's
   fixed IP", the default-domain list), confirm they still hold in the code. List any that no
   longer do.

## Output (keep it bounded)

Write the report block below in **English**, regardless of the conversation language —
it feeds English repo artifacts (`INVARIANTS.md`, dated snapshots, PR/issue comments), so
the language must stay consistent. Any conversational commentary *around* the block may
follow the user's language.

```
Egress drift audit — <date>, vs snapshot <YYYY-MM-DD>

Contract:   <N>/10 invariants green   (swift test: <pass/fail>, tests/run.sh: <pass/fail>)
Divergences (doc ↔ code):
  - <none>  |  <one line each: what the doc says vs what the code now does, + which invariant>
Egress-core changes since snapshot:
  - <none>  |  <one line per commit>
Recommendation:
  - <No action — no drift>  |
  - <Update INVARIANTS.md: invariant I# changed>  |
  - <Re-baseline: run the `augur-egress-survey` workflow to write a new dated snapshot>
```

Rules:
- **Empty is a valid, good result.** "0 divergences, 0 egress-core commits since <date>" is the
  healthy case — report it in a few lines and stop.
- A broken contract test (step 2) is always a finding, even if nothing else changed.
- Recommend the heavy `augur-egress-survey` workflow only when the *narrative* is materially
  stale (new engine, reshaped datapath, several load-bearing claims wrong) — not for a one-line
  domain tweak.
- This skill never edits the snapshots (they are immutable). It may propose an `INVARIANTS.md`
  update when an invariant's `Enforced by` or status genuinely changed.
