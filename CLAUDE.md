# CLAUDE.md

Guidance for agents working in this repository.

## Code comments

A comment explains what the code does *now*, and why when that isn't obvious. Keep it readable
by someone who has never opened `docs/`.

### No references to ADRs or other docs

Code is read by humans for *what* it does; the deeper *why* is looked up with AI, which finds
the ADR (`docs/decisions/`) from the code because every ADR names the functions and files it
governs. So comments do not cite ADRs, security reviews, or their section/clause labels
(`ADR-0007`, `§3 Option A`, `C7`, `docs/decisions/…`) — such pointers are unreadable without
opening the doc and go stale when a decision is superseded.

- Name the concept in plain words instead of a number ("macOS 27's automated provisioning",
  not "ADR-0018's automated provisioning").
- Where the code looks wrong or surprising and someone might "fix" it, say that it is
  deliberate, in plain words, with a one-line reason: `Deliberately NOT gated: …`,
  `Accepted trade-off: …`. That marker is what sends a reader (or an AI) to look for the why.

```bash
# Bad
# NOT gated, on purpose (see the ADR): down/destroy/list/status must keep working ...
# Escape hatch out of ADR-0018's automated provisioning: take the manual Setup
# Assistant flow (ADR-0007) even on a macOS 27+ host/guest pair.

# Good
# Deliberately NOT gated: down/destroy/list/status must keep working ...
# Escape hatch out of macOS 27's automated provisioning: take the manual Setup
# Assistant flow even on a macOS 27+ host/guest pair.
```

### No history in comments

Describe the current state, not how it got here. Phrases like "used to", "reverses", "shipped
broken", "the original …", "after the amendment", "pre-fix" belong in an ADR or the commit
message, not in code. Keep a past-tense note only when it explains a compatibility path the code
still has to handle (e.g. a base VM built by an older augur).

### Explain a fact once

When the same behavior matters at several call sites, explain it at the definition and point to
it elsewhere (`see macos_admin_password()`) instead of re-explaining it at each site.
