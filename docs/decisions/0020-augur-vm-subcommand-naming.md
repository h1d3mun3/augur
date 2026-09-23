# ADR-0020 — augur-vm's `ParsableCommand` structs are suffixed `Command`

- **Status:** Accepted.
- **Date:** 2026-09-23.
- **Applies to:** `augur-vm` only (every `ParsableCommand`-conforming struct under
  `augur-vm/Sources/augur-vm/`).

## Decision

Every `ParsableCommand` struct in `augur-vm` is named `<Noun>Command` (e.g. `CloneCommand`,
`RunCommand`, `SetCommand`), and its defining file is named to match (`CloneCommand.swift`,
`RunCommand.swift`, `SetCommand.swift`). No prefix, no abbreviated suffix — full word, always
on.

## Context

Before this decision, augur-vm's 11 subcommand structs used three different, inconsistent
conventions at once:

- bare noun/verb, no suffix: `Version`, `Smoke`, `Create`, `Run`, `IP`, `Stop`, `Clone`
- abbreviated `Cmd` suffix: `ListCmd`, `SetCmd`, `DeleteCmd`
- full `Command` suffix: `GuestOSVersionCommand` — the only one already in the shape this ADR
  adopts

The mix made it impossible to predict where a given subcommand's implementation lived from its
name alone. `IPCommand.swift`, the sharpest example, declared `struct IP` — file name and type
name didn't even agree with each other. A readability pass over the whole package flagged this
(see PR #191, which applies the rename this ADR documents), and settling on one convention was
chosen deliberately over two other real candidates.

## Rationale

Three shapes were on the table:

- **Prefix (`CmdClone`)** — rejected outright. This is an Objective-C/C holdover (`NS`, `UI`)
  that existed only to fake a namespace in a language that had none. Swift has real
  module-level namespacing, so a prefix buys nothing here and reads as legacy style.

- **No suffix (bare `Clone`)** — this is what Apple's own `swift-argument-parser` documentation
  actually uses (its canonical `math` example ships `Add`/`Multiply` subcommands with no
  suffix at all), and it's what 7 of augur-vm's 11 commands already did before this change.
  `ParsableCommand` conformance plus the enclosing `subcommands:` list already say "this is a
  command," so repeating that in the name is arguably redundant.
  Rejected for one concrete, non-stylistic reason: `SetCmd` → bare `Set` collides with the
  standard library's `Set<Element>`. Going bare-noun everywhere would have meant carving out an
  exception for exactly that one command — trading three inconsistent conventions for "bare,
  except when it isn't" — and a real landmine for autocomplete/jump-to-definition inside this
  file (`Set` resolving to the wrong type is a silent, not a compile-time, problem in some
  contexts).

- **Full `Command` suffix (chosen)** — matches Swift's general convention of a
  role-communicating suffix where one earns its keep (`...Error`, `...Delegate`,
  `...ViewController`); is collision-proof by construction, so no bare-noun exception is
  needed anywhere; and is trivially greppable (`grep "Command:"` or `*Command.swift` finds
  every subcommand definition in one pass, which a mix of three shapes never could).
  `GuestOSVersionCommand` already used this shape, so adopting it project-wide also removed the
  one existing outlier instead of adding a new one.

## Consequences

- All 11 `ParsableCommand` structs, and their defining files, use the `<Noun>Command` shape
  uniformly — see `augur-vm/Sources/augur-vm/*Command.swift`.
- `AugurVM.swift`'s `subcommands:` list carries a short comment pointing here, so a future
  "why not just `Clone`?" question finds the standing answer instead of re-litigating it.
- This is a source-level-only naming convention: `CommandConfiguration.commandName` strings,
  flag/option names, help text, and `augur-vm --help`'s actual output are unaffected — verified
  unchanged when this rename was applied (PR #191).
- A new augur-vm subcommand should be named `<Noun>Command` from the start rather than
  reopening this choice.

## Related

- `augur-vm/Sources/augur-vm/AugurVM.swift` — the `subcommands:` list, where this ADR is
  referenced inline.
- PR #191 — the mechanical rename that applied this convention across the package.
