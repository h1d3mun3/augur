# ADR-0014 — the shared workspace must not contain augur's own control plane

- **Status:** Accepted.
- **Date:** 2026-07-26.
- **Applies to:** Both modes (Apple Container + macOS VM).
- **Builds on:** [`0008`](./0008-exfiltration-ceiling-accepted.md) (the workspace mount's
  write-back ceiling is accepted, not mitigated),
  [`0001`](./0001-sudo-free.md) (why the fix is a refusal rather than a privilege).

## Decision

**augur refuses to start a guest whose workspace is, contains, or lives inside augur's own
control plane.** `require_safe_workspace` runs from **one** site in the shared dispatch tail and
refuses four cases:

| Rule | Refused when the resolved workspace… | Example |
|---|---|---|
| **R1** | is the filesystem root | `cd / && augur up` |
| **R2** | is `$HOME` | `cd ~ && augur claude` |
| **R3** | is a strict **ancestor** of `$HOME` | `cd /Users && augur up` |
| **R4** | is, **contains**, or lives **inside** `$AUGUR_DIR` | `cd ~/.augur/proxy && augur shell` |

Gated commands: `up`, `claude`, `shell`, `setup-token` — the four that hand this directory to a
guest. Everything else is deliberately ungated (see *Why down/destroy/list/status stay open*).

There is **no environment override.** Not `AUGUR_ALLOW_HOME_WORKSPACE`, not a flag.

## Context

`WORKSPACE_DIR="$(pwd)"` (`augur:12`) is mounted **read-write** into the guest — `-v
"${WORKSPACE_DIR}:${WORKSPACE_MOUNT}"` in container mode (`augur:1683`),
`--dir="${MACOS_SHARE}:${WORKSPACE_DIR}"` in macOS mode (`augur:2790`) — and until this ADR it was
mounted with **no validation of any kind**. All 14 `WORKSPACE_DIR` sites in `augur` carried no
`$HOME`, `/`, or ancestor check.

A read-write workspace is not itself a defect: [`0008`](./0008-exfiltration-ceiling-accepted.md)
and `security-reviews/2026-07-23-egress.md` §6 item 12 accept it explicitly. Item 12's bargain is
that **the guest can attack the repo you gave it** — plant a `.git/hooks/pre-commit`, rewrite
`.claude/settings.local.json` — and that the mitigation is out-of-band review.

**`cd ~ && augur claude` is not that bargain.** It is one tier above it, because `$HOME` contains
`~/.augur`, which is augur's control plane:

- `install:8` sets `INSTALL_DIR="$HOME/.augur"`. `install:34/89/106/123` put `augur`,
  `augur-proxy`, `augur-gvproxy` and `augur-vm` in it.
- `install:150` appends `export PATH="$HOME/.augur:$PATH"` to the shell rc. **Prepended** — so
  `~/.augur` is *first* on the host's PATH.
- `resolve_proxy_cli` (`augur:620`) resolves the proxy via `command -v augur-proxy`, then
  `$AUGUR_DIR/augur-proxy`. `resolve_gvproxy` (`augur:1254`) does the same for `augur-gvproxy`.
  The **host** executes whatever those resolve to, **as the host user, on every `up`**.

So a guest that can write `~/.augur` gets host code execution at the operator's full privilege —
unconditionally, with no host-side `git` operation or any other operator action required to trigger
it. Item 12's residual needs the operator to run `git commit` in the attacked repo; this one only
needs the operator to run `augur up` again, which is the one thing they are guaranteed to do.

### It was also a literal I7 violation

`INVARIANTS.md` **I7** ("the guest cannot widen its own allowlist") states that the merged allowlist
is written host-side at `~/.augur/proxy/<slug>.allowlist`, **"outside the project tree"**. With
`WORKSPACE_DIR=$HOME` that file is *inside* the read-write share, and `augur-proxy` polls its mtime
and hot-reloads it every ~2 s (`augur-proxy/Sources/augur-proxy/main.swift:156-183`). The guest
therefore edits the **enforcement** file directly and its own egress policy widens within seconds —
no `./.augur/allowlist.conf`, no `conf_line_valid` sanitisation, no TOFU approval anywhere in the
path. Every mechanism I7 names is bypassed by simply not going through it.

I7's prose is **not** changed by this ADR. Its parenthetical was always the intended property; the
guard is what makes it true. (A later change in this series revisits I7's wording.)

### A structural tell

With `WORKSPACE_DIR=$HOME`, `AUGUR_PROJECT_DIR` (`augur:53`, `"$WORKSPACE_DIR/.augur"`) evaluates
to exactly `AUGUR_DIR` (`augur:41`, `"$HOME/.augur"`). `cmd_init_conf` (`augur:4028`) would then
scaffold the *project* allowlist and resources file straight into the *global* augur directory.
Two conceptually distinct paths collapsing onto one string is the same confusion the mount exposes,
visible without any attacker at all.

## Why physical-path comparison is required

`WORKSPACE_DIR` is `$(pwd)` — the **logical** path, which keeps symlinks unresolved. A string
comparison against `$HOME` is therefore not sound:

```
ln -s "$HOME" ~/link      # or any symlink chain reaching $HOME
cd ~/link && augur claude
```

`pwd` reports `/Users/you/link`, which `!=` `/Users/you`, so a logical check passes it — and then
the container engine and `virtiofs` both resolve the symlink and share the **real `$HOME`**. The
check must therefore compare what the *engine* will mount, not what the *shell* printed. The guard
computes `ws="$(cd "$WORKSPACE_DIR" && pwd -P)"` plus physical `$HOME`/`$AUGUR_DIR` equivalents.

This also matters for the message: the refusal names the **resolved** path, because "refusing to
share `~/link`" would leave the operator with no idea why a directory that plainly is not `$HOME`
was refused.

**`WORKSPACE_DIR` itself is deliberately left alone.** The physical forms are local to the guard.
`workspace_path_hash` (`augur:866`) digests `WORKSPACE_DIR` and feeds container names, VM names, the
TOFU approval key (`project_conf_hash_file`) and every per-project state directory. Re-basing it on
`pwd -P` would silently rename all of that for any user whose project path crosses a symlink — a
one-time orphaning of their container, VM, egress approval and prompt history, to fix a problem that
does not require it. The guard resolves paths; the identity keying does not change.

## Why there is no environment override

augur has escape hatches elsewhere — `--no-egress`, `AUGUR_ACCEPT_PROJECT_CONF=1` — so declining one
here needs a reason. It is this: **every existing override weakens the guest's confinement. This one
would surrender augur's own integrity, plus the host account.**

That is a different kind of object. `--no-egress` says "I accept that this guest can reach the
network"; the blast radius stays inside the trade the operator just made. An
`AUGUR_ALLOW_HOME_WORKSPACE=1` would say "I accept that this guest can rewrite the binary that
enforces every other decision, including `--no-egress` itself." An override that can disable the
enforcement mechanism is not a policy knob, and a guest that can edit `~/.augur/augur` can re-enable
whatever the operator turned off. There is no coherent use case that needs `$HOME` shared and cannot
be served by a subdirectory.

### Relocating `AUGUR_DIR` is not a workaround either

The obvious rejoinder is "move `~/.augur` elsewhere, then `$HOME` is safe to share." It is not, and
this is exactly why **R2/R3 are their own rules rather than a special case of R4**:

- `~/.augur` stays on the host's PATH regardless — the `export PATH` line lives in `~/.zshrc`, and
  a guest with write access to `$HOME` can edit `~/.zshrc` directly anyway.
- `~/.gitconfig` is host-executed by design: `core.pager`, `core.editor`, `alias.*` and
  `credential.helper` are all shell commands the operator's own `git` runs.
- `~/.ssh/config` (`ProxyCommand`, `LocalCommand`), `~/.local/bin` and `~/bin` on PATH,
  `~/Library/LaunchAgents` — none of these involve `AUGUR_DIR` at all.

`$HOME` is a host-code-execution surface whether or not augur lives in it. R4 protects augur's
control plane wherever it is put; R2/R3 protect the host account. Neither subsumes the other.

## Why the rule stops at augur's control plane

The rule is **containment of augur's own directory and `$HOME`**, not "the workspace must not
contain anything dangerous." It deliberately does **not** grow into a dotfile denylist, so
`cd ~/.ssh && augur claude` stays **allowed**. Three reasons:

1. **A denylist is unbounded.** `.ssh`, `.gnupg`, `.aws`, `.kube`, `.docker`, `.npmrc`, `.netrc`,
   `.config/gh`, every language toolchain's credential cache, and whatever the operator installs
   next month. A list that is incomplete by construction gives the *appearance* of a
   security boundary while providing none — worse than a rule with a stated, honest edge.
2. **§6 item 12 already accepts an attacker-writable workspace.** The operator pointing augur at a
   directory of secrets is choosing to share those secrets, which is the same choice they make with
   any repo containing a `.env`. That is the accepted ceiling, and it needs no new mechanism.
3. **False positives break real work.** Plenty of legitimate projects live under a dot-directory,
   and refusing them costs the operator something concrete in exchange for nothing.

The line drawn here is narrower and defensible: augur will not hand the guest **the thing that
enforces the guest's confinement**, nor the account that runs it. Everything else remains the
operator's call, as it already was.

## Why `down`/`destroy`/`list`/`status` stay ungated

Only `up`, `claude`, `shell` and `setup-token` are gated. `down`, `destroy`, `list`, `status`,
`init-conf`, `build`, `update`, `install-cert`, `version` and `help` are not, on purpose:

- **`destroy` and `down` are the remedy.** A pre-fix augur could already have created a container or
  VM from `$HOME`. Gating teardown would strand it with no supported way to remove it — the guard
  would be creating the mess it exists to prevent. `list` and `status` are how the operator *finds*
  the stranded guest, so they must work from the same directory.
- **`build` does not use the workspace.** Its build context is `$SCRIPT_DIR`, not `WORKSPACE_DIR`.
- **`init-conf`, `update`, `install-cert`, `version`, `help` hand nothing to a guest.** `init-conf`
  writing into `~/.augur` from `$HOME` is the cosmetic oddity noted above, not an exposure: the file
  is written by the *host*, and no guest is started.

`tests/12_down_teardown.sh` asserts this directly — `destroy` from `$HOME` exits 0 and still reaches
`delete --force` — precisely so a later refactor cannot "tidy up" by applying the guard uniformly
across the dispatch and silently close the escape route.

### One call site, not per-command

The check lives in the shared dispatch tail (after `MACOS_SHARE=`, before `if $MACOS_MODE`) rather
than inside `cmd_up`/`cmd_up_macos`. Two reasons, both load-bearing:

- **Structural.** One site covers both modes, so it is impossible to fix container mode and leave
  macOS mode open (or vice versa). `tests/30_macos_vm.sh` proves the macOS half from the same site,
  and because the guard precedes `require_vz` (`augur:443`) the refusal names the *workspace* rather
  than the host OS — which is also what lets that test run on the Linux CI runner.
- **Correctness.** `cmd_claude`/`cmd_shell` call `up` only when the guest is *not* already running
  (`container_running || cmd_up`, `augur:1865`; `macos_vm_running … || cmd_up_macos`, `augur:2922`).
  A check inside `up` would be skipped in exactly the case that most needs refusing: attaching to a
  guest that a pre-fix augur had already created from `$HOME`.

## Accepted exposure: running augur from its own checkout

`resolve_proxy_cli` (`augur:620-630`) falls back to `$SCRIPT_DIR/augur-proxy/.build/release/augur-proxy`
(then `.build/debug/…`). A developer running `./augur` **from the augur repo itself** therefore
shares a directory containing a binary that the host will later execute — the same shape as the
defect above, at a smaller radius. This is **accepted, not fixed**:

- **It is unreachable for any installed augur.** The fallback is 4th in line. `command -v
  augur-proxy` (`augur:622`) and `$AUGUR_DIR/augur-proxy` (`augur:624`) are both checked first, and
  `bash install` satisfies both. It affects only a developer running `./augur` in a checkout with no
  augur installed.
- **Gating the repo would break the test suite.** `make container-e2e` stages and drives augur from
  its own checkout by design (`Makefile`: `stage` → `image` → `egress`). A rule refusing
  `$SCRIPT_DIR` would make augur's own security gate unrunnable.
- **The dogfooding audience is the one that can evaluate it.** Someone running augur from a git
  checkout to develop augur is reviewing the diff anyway; they are not the operator this guard
  protects.

Recorded here rather than left implicit, because the *reason* it is acceptable (resolution order)
is not obvious from the mount, and a future reorder of `resolve_proxy_cli` that promotes the local
build above `$AUGUR_DIR` would turn this into a real exposure for every installed user.

## Security

- **Net change: strictly narrower.** A previously-unconditional guest→host code-execution path is
  closed. No command that previously worked on a legitimate project directory changes behaviour.
- **I7 becomes true as written.** The merged allowlist can no longer land inside the read-write
  share, so `augur-proxy`'s hot reload can no longer be driven by the guest.
- **No new privilege.** The fix is a refusal, consistent with
  [`0001`](./0001-sudo-free.md) — augur declines the operation rather than taking privilege to make
  it safe.
- **§6 item 12 is unchanged.** The workspace remains read-write and the guest can still attack the
  repo it was given. This ADR does not narrow that ceiling; it only stops the workspace from *being*
  augur.

## Consequences

- `cd ~ && augur claude` (and `up`/`shell`/`setup-token`) now fails with a refusal naming the
  directory, the rule it hit, and two remedies: move into a subdirectory, or run `augur destroy`
  here first to remove a guest a pre-fix augur created from this directory.
- Anyone who was *using* `$HOME` as their workspace must move the work into a subdirectory. There is
  no override, and this is the one workflow this ADR knowingly breaks.
- Symlinked workspace paths are resolved for the *check* only. Container names, VM names, egress
  approvals and per-project state stay keyed on the logical `WORKSPACE_DIR`, so no existing
  per-project state is renamed by this change.
- Teardown and inspection (`down`, `destroy`, `list`, `status`) keep working from `$HOME`, which is
  what makes a pre-fix container recoverable. That behaviour is now test-enforced, not incidental.

## Alternatives considered

- **Refuse only `$HOME`, on the grounds that R4 is the "real" risk.** Rejected: `$HOME` and
  `$AUGUR_DIR` are independent surfaces (see *Relocating `AUGUR_DIR`*), and a rule covering only one
  is trivially sidestepped by `cd ~/.augur/proxy` or by relocating `AUGUR_DIR` and sharing `$HOME`.
- **Add `AUGUR_ALLOW_HOME_WORKSPACE=1` for "advanced users".** Rejected as above: an override that
  hands the guest write access to the enforcement binary can silently re-enable everything else the
  operator turned off.
- **Mount the workspace read-only when it is `$HOME`.** Rejected: an agent that cannot write is
  broken for augur's actual purpose, so this trades an exposure for a confusingly non-functional
  session. [`0008`](./0008-exfiltration-ceiling-accepted.md) already declined a read-only-mount
  option for the same reason.
- **Move `~/.augur` out of `$HOME` (e.g. `~/Library/Application Support/augur`) instead of guarding.**
  Rejected as insufficient rather than wrong: it would shrink R4's overlap with R2 but leaves `$HOME`
  itself a host-execution surface via `~/.zshrc`/`~/.gitconfig`/`~/.ssh`, so the guard is still
  needed. Relocation remains open as independent hygiene; it is not a substitute.
- **Extend the rule into a dotfile denylist (`.ssh`, `.aws`, `.gnupg`, …).** Rejected: unbounded,
  false-positive-prone, and redundant against §6 item 12's accepted ceiling. See *Why the rule stops
  at augur's control plane*.
- **Gate the augur repo itself, closing the dogfooding fallback.** Rejected: it would break
  `make container-e2e`, and the fallback is unreachable for any installed augur. Documented as an
  accepted exposure above instead.
