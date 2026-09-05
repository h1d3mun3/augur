export const meta = {
  name: 'augur-egress-survey',
  description: 'Full re-audit of augur egress control; writes a new dated docs/security-reviews snapshot',
  phases: [
    { title: 'Audit', detail: 'one agent per architecture section, grounded in current code + tests' },
    { title: 'Synthesize', detail: 'assemble into one document matching the existing snapshot format, write it' },
  ],
}

// args: { prevSnapshotPath, prevCommit, prevDate, newDate, outPath }
// e.g. { prevSnapshotPath: 'docs/security-reviews/2026-07-28-egress.md',
//        prevCommit: '3b7cd1e62c7abe654413840d3af6de193a6280b1',
//        prevDate: '2026-07-28', newDate: '2026-09-05',
//        outPath: 'docs/security-reviews/2026-09-05-egress.md' }
const prevPath = args.prevSnapshotPath
const prevCommit = args.prevCommit
const prevDate = args.prevDate
const newDate = args.newDate
const outPath = args.outPath
const prevFileName = prevPath.split('/').pop()
const outFileName = outPath.split('/').pop()

const COMMON = `
You are contributing ONE section to a new dated security-review snapshot for the augur project (a
sudo-free sandboxing tool for coding agents). The snapshot format is an immutable, dated,
current-state review of egress control living under docs/security-reviews/. Read the PREVIOUS
snapshot at ${prevPath} in full before writing anything - it is the baseline you are updating,
correcting, or reaffirming. Read docs/security-reviews/INVARIANTS.md for the contract (I1-I10).

The previous snapshot's commit is ${prevCommit}; today's snapshot is dated ${newDate}. To see what
changed in the egress core since the baseline, run:
  git log ${prevCommit}..HEAD -- augur augur-proxy gvproxy augur.conf augur-vm

Ground every claim in the CURRENT code (read the actual files - do not trust the previous
snapshot's prose blindly) and in real test runs where feasible (swift test in augur-proxy/, bash
tests/run.sh, or a specific test tier). Cite file:line. Where the previous snapshot's claim still
holds, say so briefly; where it changed, say what changed and why; do not silently repeat stale
prose as if it were freshly verified.

Write ONLY the section(s) described below, as clean GitHub-flavored markdown, matching the heading
depth and the terse, technical, citation-heavy prose style of the previous snapshot. Do not write a
document title or front-matter, and do not write sections outside your scope. Your entire response
must be the markdown for your section(s) - no preamble, no commentary before or after it.
`

const SECTIONS = [
  {
    key: 'essence-changes',
    label: 'Essence + changes-since',
    prompt: `${COMMON}
Your scope is two things.

1. A section titled "## What changed since the ${prevDate} snapshot" - summarize, by reading the
   actual commits (git log ${prevCommit}..HEAD -- augur augur-proxy gvproxy augur.conf augur-vm),
   what landed in the egress core since the baseline. Group a related commit series (e.g. one PR's
   worth of commits, or a revert stack) into one paragraph each rather than listing every commit.
   Call out explicitly whether this is a contract change - check with
   'git log ${prevCommit}..HEAD -- docs/security-reviews/INVARIANTS.md' - and correct anything the
   ${prevDate} snapshot said that you can verify is now wrong.
2. A section titled "## 1. Essence" - a short (3-6 sentence) plain-language restatement of what
   augur's egress control is and how it fails closed, updated for anything material that changed.`,
  },
  {
    key: 'container-engine',
    label: 'Apple Container engine',
    prompt: `${COMMON}
Your scope is "## 2. Enforcement boundary per engine" - write the H2 heading plus a short (2-4
sentence) intro contrasting the two engines (Apple Container and macOS VM) at a high level, then
the Apple Container half only, as subsections:
  ### 2.1 Base-image custom provisioning
  ### 2.2 Custom CA trust (augur install-cert)
  ### 2.3 Container lifecycle: persist-and-reconcile
Do NOT write anything about the macOS VM engine or workspace containment - a different agent owns
those and will be merged in after you.

Ground this in the augur script's container_*, cmd_up, cmd_down, and verify_egress_locked
functions, and in tests/11_construct_container.sh, tests/22_egress_failclosed.sh,
tests/32_proxy_per_mode.sh. State plainly what mechanically enforces the boundary (host-only
network, --no-dns, --cap-drop NET_ADMIN, the boot self-test tearing the container down on a leak)
and what is documented-but-not-enforced (cross-reference INVARIANTS.md I1 and I8's notes on argv
not being asserted by any test).`,
  },
  {
    key: 'macos-engine',
    label: 'macOS VM engine (gvproxy)',
    prompt: `${COMMON}
Your scope is two subsections, continuing under the "## 2. Enforcement boundary per engine" H2
that a different agent is writing (do not write the H2 yourself, do not write 2.1-2.3):
  ### 2.4 macOS lifecycle
  ### 2.5 Workspace containment

2.4 is the macOS VM engine's egress datapath (gvproxy). This is the part most likely to have
changed recently: gvproxy was just re-pinned from 629a4a42 to d3d4f055 (closing issue #167 - see
gvproxy/build.sh's PIN and gvproxy/augur-egress.patch), and a bug found by code review was fixed
where the SOCKS dial path (pkg/services/forwarder/socks_client.go's socksDial) had no connect
timeout unlike the direct-dial branch, now fixed by threading connectTimeout through. Describe the
current gvproxy pin, what augur-egress.patch does (--socks-upstream, --deny-direct,
--dns-allowlist), and verify against pkg/virtualnetwork/services.go, pkg/services/forwarder/tcp.go,
pkg/services/dns/dns.go that the wiring is as described - read those files inside
gvproxy/augur-egress.patch directly, do not assume. Ground the VM lifecycle in augur's
verify_macos_egress_locked, the two 'up --macos' paths (fresh boot and reconcile), 'down --macos',
and tests/30_macos_vm.sh, tests/36_macos_egress_selftest.sh, tests/38_macos_guest_clock.sh,
tests/40_macos_selftest_transport.sh.

2.5 (workspace containment, require_safe_workspace) applies identically to both engines - write it
once here and say so explicitly rather than assuming the reader saw it duplicated for Container.`,
  },
  {
    key: 'proxy-internals',
    label: 'augur-proxy filter internals',
    prompt: `${COMMON}
Your scope is "## 3. augur-proxy filter internals". Read
augur-proxy/Sources/AugurProxyCore/*.swift (Allowlist, Hostname, the SNI/filter core,
AddressPolicy) and actually run "cd augur-proxy && swift test" yourself to confirm it is green -
quote the real pass count you observed, do not guess.

Cover: SNI extraction from a TLS ClientHello, the allowlist matcher's label-boundary semantics
(I2), hostname LDH validation and the NUL-truncation defense (I3), IP-literal deny (I4 - including
whether the PinTable is still an unwired dead scaffold; grep for "pins.pin(" in
augur-proxy/Sources and confirm there is still no production caller), hot-reload fail-safe
semantics (I6), and the private-IP / SSRF dial guard (I8, AddressPolicy.isPrivateV4 / isPrivateV6).`,
  },
  {
    key: 'allowlist-tofu',
    label: 'Allowlist model + TOFU',
    prompt: `${COMMON}
Your scope is "## 4. Three-layer allowlist config model + TOFU". Ground this in the augur script's
write_merged_allowlist, project_conf_domains, conf_line_valid, and check_project_conf_approved
functions, and the baseline/global/project conf precedence. Actually run
tests/01_egress_allowlist_unit.sh and tests/32_proxy_per_mode.sh yourself (via bash tests/run.sh,
or invoke the tier scripts directly) and quote the pass count you observed.

Cover invariant I7 in full: where the merged allowlist is written (outside the project tree),
how project-supplied domains are sanitized before merging, and the full-workspace-path keying that
prevents one project's TOFU approval from ever reaching another project's live proxy.`,
  },
  {
    key: 'current-state',
    label: 'Current state table',
    prompt: `${COMMON}
Your scope is "## 5. Current state - DONE / PARTIAL / PLANNED / RECOMMENDED". Build it from three
sources:
(a) INVARIANTS.md's own "Enforced by" markers (fully-tested items are DONE; anything marked
    partial or review-only is a PARTIAL candidate - quote its own caveat rather than paraphrasing
    loosely);
(b) run "gh issue list --state open" and "gh pr list --state open" if gh is authenticated; pull
    anything egress-related into PLANNED. If gh is not authenticated or the commands fail, say so
    plainly and skip this source rather than guessing or fabricating issue/PR numbers;
(c) your own judgment from this audit pass - a real gap you noticed reading the code that is not
    filed anywhere becomes a RECOMMENDED entry that you are proposing, not one you found already
    tracked.
Never invent an issue or PR number you did not actually see in command output.`,
  },
  {
    key: 'residual-risks',
    label: 'Known limitations & residual risks',
    prompt: `${COMMON}
Your scope is "## 6. Known limitations & residual exfil channels". This is an accumulating ledger,
not a from-scratch list - read the ${prevDate} snapshot's own section 6 in full (its "Closed since
X", "Closed before this review", "Checked and refuted (do not re-investigate)", and "New this
review" subsections) and re-derive this review's version of it:
- Anything closed since ${prevDate} moves into a new "### Closed since ${prevDate}" subsection,
  citing the commit or PR that closed it (use the commit range from the changes-since instructions
  above).
- Everything in "Checked and refuted" that still holds carries forward into your own
  "### Checked and refuted (do not re-investigate)" - do not silently drop entries just because
  re-deriving them is tedious.
- Everything already in "Closed before this review" carries forward as-is (it is closed history).
- Actively look for genuinely NEW residual risks this pass - anything you noticed reading the
  current code, especially anything touched by the recent gvproxy repin work, that the previous
  snapshot did not cover.
- End with a "### Summary" one-paragraph readout of the overall residual-risk posture.
Do not invent risks that are not real - if nothing is new, say that plainly instead of padding.`,
  },
]

phase('Audit')
const sections = await parallel(SECTIONS.map(s => () =>
  agent(s.prompt, { label: s.key, phase: 'Audit', effort: 'high' }).then(text => ({ ...s, text }))
))

const drafted = sections.filter(Boolean).filter(s => s.text)
log(`${drafted.length}/${SECTIONS.length} sections drafted`)

phase('Synthesize')
const bundle = drafted.map(s => `<!-- SECTION: ${s.label} (${s.key}) -->\n${s.text}`).join('\n\n')

const writerPrompt = `
You are assembling a new dated security-review snapshot for the augur project, to be written at
${outPath}, dated ${newDate}. Below are independently-drafted sections from separate audit agents,
each grounded in the current code. Your job:

1. Read docs/security-reviews/${prevFileName} in full to see the exact tone, heading style, and
   header-block wording this snapshot format uses - your output must read as one continuation of
   that series, not a different voice.
2. Reconcile the drafted sections below into ONE coherent document: consistent heading numbers
   (## 1..6, ### within), no duplicated content between the container-engine and macos-engine
   drafts, and if two sections make a contradictory claim, resolve it in favor of whichever one
   cites a specific file:line or an actual test run, and add a one-line aside noting you resolved
   a conflict and how.
3. Prepend the standard header block: "# augur Egress Control - Current-State Review" followed by
   a blockquote "**Security-review snapshot - as of ${newDate} / focused on egress control.**" and
   "This is a point-in-time record and is **not maintained** (once stale, the date makes that
   obvious)." and a line pointing to README.md, ending with "Regenerate with the
   augur-egress-survey workflow." (match the previous snapshot's exact wording for this block).
4. Write the assembled document to ${outPath}. This file does not exist yet - it is new. NEVER
   edit any existing docs/security-reviews/*.md file; they are immutable once committed.
5. Read docs/security-reviews/README.md and add exactly one new row at the TOP of the table in its
   "## Snapshots" section (newest-on-top), following the existing row format exactly: date
   ${newDate}, a one-line scope description pulled from the "what changed" section you just
   assembled, and a link to ${outFileName}. Do not alter any existing row.
6. Do NOT edit docs/security-reviews/INVARIANTS.md even if a drafted section argues an invariant's
   status changed - that is a security-quality decision the implementer owns, not something this
   workflow decides. Instead, flag it in your final answer below.

Return a summary (under 150 words) of what you wrote, plus any invariant-change flags from step 6.

SECTIONS:
${bundle}
`

const synthesis = await agent(writerPrompt, { label: 'synthesize', phase: 'Synthesize', effort: 'high' })

return {
  outPath,
  sectionsDrafted: drafted.map(s => s.key),
  sectionsMissing: SECTIONS.map(s => s.key).filter(k => !drafted.some(d => d.key === k)),
  synthesisSummary: synthesis,
}
