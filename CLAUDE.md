# CLAUDE.md

Guidance for agents working in this repository.

## Code comments

A comment explains what the code does *now* and why. Keep it readable by someone who has never
opened `docs/decisions/`.

### Referring to ADRs

ADRs (`docs/decisions/NNNN-*.md`) hold the rationale; code comments only point at them.

- **The comment must make sense with the ADR number deleted.** Never use an ADR number as a noun
  standing in for the concept ("ADR-0018's automated provisioning", "the fixed ADR-0007
  credential"). Name the concept in plain words.
- **Cite one ADR, at the end, with its subject:** `(see ADR-0018: macOS 27 provisioning)`.
  Do not chain several (`ADR-0006/ADR-0010`, `ADR-0012, reverses ADR-0011`); cite the one that
  currently governs the code.
- **No section pointers** (`§3 Option A`, `C7`). If the detail matters, say it in the comment.
- **Never "see the ADR"** without a number.

```bash
# Bad
# Escape hatch out of ADR-0018's automated provisioning: take the manual Setup
# Assistant flow (ADR-0007) even on a macOS 27+ host/guest pair. ADR-0018 shipped
# with no way to opt out, which left a host where ...

# Good
# Force the manual Setup Assistant flow even on a macOS 27+ host/guest pair, for hosts
# where the unattended first boot never completes. (see ADR-0018: macOS 27 provisioning)
```

### No history in comments

Describe the current state, not how it got here. Phrases like "used to", "reverses", "shipped
broken", "the original …", "after the amendment", "pre-fix" belong in the ADR or the commit
message, not in code. Keep a past-tense note only when it explains a compatibility path the code
still has to handle (e.g. a base VM built by an older augur).

### Explain a fact once

When the same behavior matters at several call sites, explain it at the definition and point to
it elsewhere (`see macos_admin_password()`) instead of re-explaining it at each site.
