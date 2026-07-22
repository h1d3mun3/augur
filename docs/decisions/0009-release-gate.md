# ADR-0009 — The pre-release macOS-VM E2E is a structural gate, and `VERSION` (not a tag) is the release's source of truth

- **Status:** Accepted.
- **Date:** 2026-07-22.
- **Applies to:** How augur cuts a release — the protected `release` branch, `VERSION`,
  `scripts/release-gate.sh`, `.github/workflows/release.yml`, and `augur version` / `install`
  version reporting (README "Cutting a release"). Supersedes the prior trust-based "remember to
  run `make e2e` before tagging" convention. Landed on PR #108.

## Decision

augur's heavy pre-release gate — the macOS-VM E2E (`make e2e`: boot a VM, `xcodebuild test`,
virtiofs + testmanagerd + VM-mode egress fail-closed) — is **enforced by the server and executed
on a Mac**, instead of trusting a human to remember it before tagging. Concretely:

- **`VERSION` (repo root) is the single source of truth for the version number.** `augur version`
  and `install` read it; git is used only to *append* a dev suffix (`<v>-dev+<sha>`) when HEAD is
  not exactly the release tag. **A tag is the OUTPUT of a release, never its input.**
- **A protected `release` branch is the gate.** Branch protection requires the `e2e/macos-vm`
  commit status before any commit can land there, and applies to admins too (`enforce_admins:
  true`). `main` stays the everyday branch.
- **`scripts/release-gate.sh` runs `make e2e` locally and posts the status** (`success` only on
  exit 0). **`.github/workflows/release.yml`** then fires on push to `release`, reads `VERSION`,
  and creates the annotated tag `v<VERSION>` + a GitHub Release — idempotently (a collision guard
  makes an un-bumped or follow-up push a no-op). It boots no VM.

augur deliberately does **not** build, for this:

- a self-hosted runner or any always-on release infrastructure;
- the macOS-VM E2E as a GitHub-hosted CI job (it *cannot* exist — see Rationale);
- a tag-push trigger for releases (that would let a tag drive the release);
- a second place the version number lives (it is never read back from `git describe` as the
  source of truth);
- a tag-protection ruleset to block manual tags (see Rationale + Consequences);
- a packaging layer — a self-updater, a Homebrew tap, signed binaries — deferred below.

## Context

The pre-release macOS-VM E2E is load-bearing but **cannot run in CI**: GitHub's arm64 macOS
runners are themselves Virtualization.framework guests with no nested virtualization, so anything
that boots a VM/microVM fails on every hosted runner (documented in the README "Continuous
integration" and the `Makefile` header). So the E2E was a *local* step (`make e2e`) that a human
was trusted to run before cutting a `vX.Y.Z` tag by hand.

That trust is the weak link: "remember to run the heavy test before tagging" is exactly the kind
of step that gets skipped under time pressure, and nothing structural caught a skip. Separately,
`augur version` derived the version from `git describe --tags`, which made the tag both the
trigger for and the name of a release — a circular dependency (you tag to make a version, and the
version is read back from the tag).

The design brief was explicit: keep execution local, move enforcement to the server, and build no
standing infrastructure. The open decision was the branch model, resolved to **B** (below).

## Rationale

**Execution must be local, so enforcement moves to the server.** Because no hosted runner can
nest a VM, "run the E2E in the cloud" is off the table — the only lever left is to gate on a
*result* the local run produces. `scripts/release-gate.sh` turns the E2E's exit code into an
`e2e/macos-vm` commit status; branch protection on `release` makes that status mandatory. This is
why there is deliberately no self-hosted runner: the goal is not to run the E2E somewhere central,
it is to make a locally-produced proof *unskippable* on the path to a tag.

**The version number belongs in a committed file; the tag is what the gate emits.** Moving the
number into `VERSION` breaks the circular "tag drives version" dependency, lets `augur version`
answer instantly with no tags present, and — most importantly — makes the tag a *certificate the
pipeline issues after the gate*, not a string a human types. `release.yml` computes `v$(cat
VERSION)` and creates the tag itself, so a tag can only come into existence as the output of a
push that already cleared the gate.

**Branch model B (add a `release` branch) over model A (repurpose `main`).** B keeps `main` the
everyday branch, so every existing CI job and PR flow is untouched and the default branch stays
the one people actually branch from. Model A — make `main` the gated branch and add a `develop`
for daily work — would invert the default branch to a rarely-moving one and force re-pointing
every existing CI trigger onto `develop`, buying nothing at augur's scale. The cost of B is one
extra branch; the cost of A is churn across the whole existing setup.

**`required_linear_history` is deliberately OFF.** `main` is integrated with merge commits, so a
linear-history rule on `release` would reject the fast-forward release push *every cycle* — the
pushed range carries merge commits. The property that matters, "the tested SHA is the tagged SHA,"
is delivered instead by fast-forwarding `release` to the *exact* status-carrying commit plus the
required status check: only a commit that carries the green `e2e/macos-vm` status can become the
tip, and `release.yml` tags that tip. Linear history would break releases while adding nothing
that the FF-of-the-exact-SHA discipline doesn't already give. (An adversarial review of PR #108
caught this before it shipped — the first draft copied a linear-history rule that would have
dead-locked every release.)

**`release` doubles as the stable install channel; packaging is deferred, not rejected.** augur
is built from source (Swift/Go), so a git ref *is* the version selector: `git clone -b release`
installs the latest gated build (bare `X.Y.Z` from `augur version`), `main` installs dev
(`X.Y.Z-dev+<sha>`), and the suffix makes the two distinguishable at a glance. A real packaging
layer — an `augur upgrade` self-updater (the `augur update` name is already taken by the image
rebuild), a Homebrew tap, or signed/notarized binaries — only earns its ongoing maintenance if
non-developers install augur, which today they do not (the audience already has Xcode/Swift/Go and
clones the repo). This is deferred with a clear trigger, not declined on principle.

**The gate stops an *accidental* skip, not a determined admin.** An admin can still hand-push a
tag (`release.yml` does not fire on tags, and branch protection does not cover tag refs) or simply
disable the protection rule. This is accepted, the same shape as ADR-0008 and ADR-0001: the
structural guarantee is that the *paved path cannot skip the E2E*, converting a silent omission
into a deliberate, visible, auditable override. Forcing even the admin through the gate would need
a tag-protection ruleset that allows `release.yml`'s bot while blocking humans — fiddly (the
GITHUB_TOKEN actor must be bypass-listed or the auto-release itself breaks), still admin-bypassable
via ruleset edits, and disproportionate for a solo/small-team repo — so it is documented-and-
declined rather than built. A hand-cut tag is additionally a footgun: it *shadows* the automated
path (the collision guard sees the tag and no-ops), so that version can never be cut properly.
That is why the README carries a "never hand-cut tags" warning instead of a machine block.

## Consequences

- The README "Cutting a release" section documents the operator flow (`VERSION` bump on `main` →
  `scripts/release-gate.sh` on a Mac → fast-forward `release` → automatic tag/Release) and points
  here for the reasoning — the same README-points-to-ADR pattern ADR-0008 established.
- One-time human setup that cannot be automated: a fine-grained PAT scoped to **only** "Commit
  statuses: write", stored in the login Keychain as `augur-release-gate`. The `release` branch and
  its protection (required check `e2e/macos-vm`, `enforce_admins`, `required_linear_history:
  false`, no force-push/deletion) are applied out-of-band by an admin.
- `augur version` / `install` no longer stamp an install date or read `git describe` as the
  source; they report `VERSION` (plus a `-dev+<sha>` suffix off-tag). No repository code parses the
  version string, so the format change is display-only.
- A future proposal to put the E2E in CI, add a tag-push trigger, re-derive the version from tags,
  turn on linear history, block manual tags with a ruleset, or ship a brew/binary distribution
  should treat these as settled and bring a *new* ADR arguing the calculus changed, rather than
  implementing directly.

## Related

- README — "Cutting a release (structural gate)", "Continuous integration", "Pre-release gate".
- [ADR-0001](./0001-sudo-free.md) and [ADR-0008](./0008-exfiltration-ceiling-accepted.md) — the
  same shape of decision: a residual (here, admin bypass) is documented and accepted rather than
  closed, because closing it would cost more than it is worth at augur's scale.
- `scripts/release-gate.sh` (header) and `.github/workflows/release.yml` — the mechanism.
- PR #108 — where this landed.
