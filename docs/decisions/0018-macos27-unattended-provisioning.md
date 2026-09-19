# ADR-0018 — macOS 27's `VZMacGuestProvisioningOptions` replaces the manual Setup Assistant step, and the base VM's admin password is randomized on that path

- **Status:** Accepted.
- **Date:** 2026-09-15.
- **Applies to:** macOS VM mode only (`cmd_build_macos` / the base-VM build path), host running macOS 27+.

## Decision

When `cmd_build_macos` runs on a **macOS 27+ host** installing a **macOS 27+ guest** IPSW, it
provisions the base VM's admin account **automatically**, using Virtualization.framework's
`VZMacGuestProvisioningOptions` (new in macOS 27, `VZMacOSVirtualMachineStartOptions
.setGuestProvisioning(_:)`). The operator no longer opens a GUI window, creates an account by
hand, or flips on Remote Login in System Settings — `cmd_build_macos` goes straight to a
headless first boot and waits for SSH.

On this path the account password is **generated randomly** per base-VM build (`openssl rand
-base64 24`) and persisted host-side at `~/.augur/macos-admin-password` (mode 600). It is
**not** the fixed `admin`/`admin` credential ADR-0007 kept.

Everything else is unchanged, and unconditionally so: **any other combination — host below
macOS 27, or an IPSW installing a guest OS below macOS 27 — takes the exact manual Setup
Assistant flow ADR-0007 already shipped**, with the fixed `admin`/`admin` credential.
`cmd_build_macos` decides from `sw_vers -productVersion` (host) and `augur-vm
guest-os-version` (the guest OS version captured from
`VZMacOSRestoreImage.operatingSystemVersion` at `create` time and persisted in the VM's
`config.json`), and `--manual-setup` forces the manual flow even when both sides qualify.

The password reaches `augur-vm` on **stdin** (`--provision-password-stdin`), never as a command
argument: argv is observable for the whole life of the boot, and this is the same shape augur
already uses to hand credentials to a child process.

## Amendment (2026-09-15, first live run)

The original version of this decision shipped four defects. Three were found by the first real
build on a macOS 27 host, and all three sat in the seam this ADR removed — the manual flow's
operator prompts turned out to be load-bearing as *waits*, not just as instructions. The fourth
(below) was found by CI, and was the opposite mistake: assuming a runtime gate could stand in
for a compile-time one.

1. **`create` → `run` raced on the auxiliary-storage lock.** Virtualization runs a guest inside
   a `com.apple.Virtualization.VirtualMachine` XPC service that outlives the `create` process
   which spawned it, so `nvram.bin` can still be flock'd after `create` has exited and printed
   "created". The automated path's immediate `run` therefore failed with
   `VZErrorDomain/2 "Failed to lock auxiliary storage."` (underlying `NSPOSIXErrorDomain/35`,
   EAGAIN). The manual flow never hit it because its "press Enter to open the VM window" prompt
   made a human sit out the window. Fixed in `RunSession.handleStartFailure`: that one failure
   (matched on the underlying errno, not the localized string) is retried for ~30s.
2. **A DHCP lease was treated as "SSH is ready."** `macos_vm_ip` only waits for an address;
   `enablesRemoteLogin` brings sshd up well after the guest's NIC. The build went straight from
   the IP to `ssh_macos_bootstrap` and got "Connection refused". The manual flow was gated on the
   operator answering "Remote Login enabled?", which had already guaranteed sshd was listening.
   Fixed by `macos_wait_for_ssh`, which polls TCP/22 itself.
3. **The generated password was persisted before the VM proved it.** Written before the boot, a
   failed boot left `~/.augur/macos-admin-password` describing a credential no VM ever had —
   which a later `--manual-setup` build (whose account really is `admin`/`admin`) would then feed
   to `sudo`. It is now written only after SSH answers, and the manual path removes any stale
   file. The write also pairs `umask 077` with an explicit `chmod 600`, because `>` preserves an
   existing file's mode (the pairing `cmd_setup_token` already used).

Separately, the build VM's boot output no longer goes to `/dev/null`: it lands in
`~/.augur/build-vm.vm.log` and the failure paths print its tail. Without that, defect 1 was
indistinguishable from defect 2 — both surfaced only as "VM did not become reachable".

### The fourth defect: the feature did not compile on a macOS 26 SDK

This ADR originally reasoned that `@available`/`#available` were enough to keep a pre-27 host
working, and `Package.swift` said so ("a host below macOS 27 still builds"). That was **wrong**,
and CI caught it: `@available` gates *runtime* availability — it lets a build that *has* a
declaration call it only where the OS supports it. `VZMacGuestProvisioningOptions` is declared
**only in the macOS 27 SDK**, so against the macOS 26 SDK the symbol does not exist and the
build fails outright:

```
error: cannot find 'VZMacGuestProvisioningOptions' in scope
error: value of type 'VZMacOSVirtualMachineStartOptions' has no member 'setGuestProvisioning'
```

That is not merely a CI problem. `install` builds `augur-vm` from source on **every** macOS host
and augur supports **macOS 26+**, so an unguarded reference takes down all of `--macos` mode —
not just automated provisioning — for every macOS 26 user, with `install` reporting it as a
warning and moving on. The CI job on `macos-26` was reproducing exactly what those users get.

The feature is therefore **compiled out** against an older SDK, gated on `#if compiler(>=6.4)`.
Swift has no SDK-version conditional (`canImport(Virtualization)` is true on both SDKs), so the
compiler version stands in for the SDK generation — Xcode ships them together (Xcode 26.6 →
Swift 6.3.3 + macOS 26 SDK; Xcode 27 → Swift 6.4 + macOS 27 SDK). It is a source-level condition
rather than a `-D` from a build script because `augur-vm` is built from three entry points
(`install` → `scripts/build.sh`, the Makefile's `make unit`, and a plain `swift build`), and only
a source-level one covers all three identically — a define that some paths miss would silently
produce a binary whose capabilities depend on how it was built.

`run`'s provisioning **flags** are gated too, not just their implementation, so `run --help` is
an honest report of what the binary can do. `cmd_build_macos` probes exactly that
(`vm_cli_supports_provisioning`) as a third condition beside the host and guest OS versions,
because the host's version is not evidence about the binary: a host upgraded to macOS 27
**without re-running `bash install`** reports 27 while running a binary built against the 26 SDK.
That case now falls back to the manual flow with an explanatory warning, instead of failing the
build with "Unknown option".

Keeping a `macos-26` CI job is what holds this invariant: it is the only thing that compiles the
`#else` side of the gate. The `xcode-27` runner image (public preview, macOS 27 + Xcode 27 beta)
exists and would make the current failure disappear — which is precisely why switching to it
alone was rejected: it would have made CI green while leaving macOS 26 users unable to build.

## Amendment (2026-09-19, stale-clone sudo password)

`macos_admin_password()` is one file for the whole host (`~/.augur/macos-admin-password`),
rewritten every time `cmd_build_macos` provisions a *fresh* base VM on the automated path. A
project VM cloned from an earlier base has its real admin password frozen at whatever that base
had when the clone was taken. If the base is rebuilt afterward — a host OS upgrade to macOS 27
that re-runs `augur build --macos`, say — the file now holds a new random password that the
older, still-running clone was never given. `sync_macos_guest_clock`'s `sudo -S` call against
that clone (every `up`/`claude`/`shell --macos`) then authenticates with the wrong password and
fails the same way a network hiccup would: a generic warning, no obvious cause.

Verified directly against a live macOS 27 guest: `echo '<wrong password>' | sudo -S -p '' true`
prints `Sorry, try again.` followed by `sudo: 1 incorrect password attempt`, `exit=1` — a signature
distinct from every other reason that call can fail (guest unreachable, a malformed `date`
argument, etc.).

Fixed with a diagnostics-only change, not a migration mechanism: `warn_if_stale_admin_password()`
inspects `sync_macos_guest_clock`'s captured sudo output for `Sorry, try again.` and, only then,
appends a hint naming the likely cause and the remedy (`augur destroy && augur up --macos`,
which re-clones from the current base and so gets the current password). Nothing tracks
per-clone passwords, detects the mismatch proactively, or auto-recreates anything — in keeping
with ADR-0007/0017's standing preference for accepting a rare, self-recoverable edge case over
building machinery for it.

`install_macos_managed_settings` and `run_base_provisioning`'s temporary sudo grant were
checked and are **not** exposed to this: both authenticate against the base VM itself, at a
moment `macos_admin_password()` is always correct for it, never against an already-existing
project clone. Only `sync_macos_guest_clock` needed the hint. See the corrected "Why every
clone..." section above, which named all three (plus `ssh_macos_bootstrap`) as clone-facing
before this amendment.

## Context

ADR-0007 removed the operator-typed SSH password prompt but explicitly kept the base VM's
`admin`/`admin` credential, and named the reason: **auto-login depends on a `kcpassword` that
matches the account's actual password**, and the only way augur had to set that password was a
human typing it into Setup Assistant. Any password reset performed *after* the account already
existed (the only kind possible under that constraint) would leave the login keychain encrypted
under the *old* password, stalling auto-login — exactly the failure mode CI macOS-VM images
avoid by setting the password once at build time and never rotating it. ADR-0007 closed with:

> Fully unattended builds (removing the manual Setup Assistant, so the host *chooses* the
> credential and no human types anything) would use macOS 27's `VZMacGuestProvisioningOptions`;
> that is version-gated and out of scope here.

macOS 27 shipped that API. `VZMacGuestProvisioningOptions` lets the **host** set `fullName`,
`username`, `password`, `logsInAutomatically` and `enablesRemoteLogin` on
`VZMacOSVirtualMachineStartOptions`, evaluated by the guest **only on its first boot after
restore** (later boots ignore it; so does a guest whose OS predates macOS 27 — the framework
silently no-ops rather than erroring, which is why `cmd_build_macos` also checks the *guest's*
OS version before relying on it, not just the host's).

## Rationale

### Randomizing is now safe, not just possible

ADR-0007's objection to randomizing wasn't to randomization itself — it was to *resetting a
password after the account already exists*, which is precisely how every previous randomization
route (`sysadminctl`/`dscl` over SSH) had to work, because the account was always born in a
human-run Setup Assistant that augur didn't control. `VZMacGuestProvisioningOptions` removes
that constraint at the root: the host chooses the password **before the account is ever
created**, so there is no keychain-vs-account desync to cause — the login keychain is created
under the correct password from the start, the same way it always was for `admin`/`admin`. The
"cost/risk outweighs the Info-level benefit" calculus in ADR-0007 was specifically about the
cost of an external reset; that cost doesn't exist on this path, so there's no reason to keep
carrying the fixed credential's Info-level residual risk (L2, `../security-reviews/2026-06-28-full-review.md`)
where it's avoidable for free.

### Why every clone, not just the base VM, needs the password persisted

Project VMs are APFS clones of the base VM, so a clone inherits whatever password its base VM's
admin account actually has. Four call sites beyond `ssh_macos_bootstrap`'s SSH-key install
authenticate as that account over `sudo -S`, and — corrected 2026-09-19, see the amendment below
— they do not all target the same thing. `install_macos_managed_settings` and
`run_base_provisioning`'s temporary sudo grant both run against the base VM itself, inside
`cmd_build_macos`/`cmd_update_macos`, where `macos_admin_password()` is always correct for that
VM (it was just written this same build, or the base hasn't changed since). Only
`sync_macos_guest_clock` runs against a **running project clone**, on every `up`/`claude`/`shell
--macos`. All four now resolve the password through one function, `macos_admin_password()`,
instead of assuming the constant `admin` string. `macos_admin_password()` reads
`~/.augur/macos-admin-password` if it exists (a base VM built on the automated path) and falls
back to the fixed `admin`/`admin` credential otherwise (a base VM built on the manual path, or
one built before this ADR) — so a pre-existing base VM's clones keep working unchanged, with no
migration step.

### Why base64 for the generated password

`openssl rand -base64 24` was chosen specifically because its output alphabet
(`[A-Za-z0-9+/=]`) contains no shell metacharacters — in particular no single quote. The
`sudo -S` call sites embed the password inside a single-quoted `echo '<password>' | sudo -S`
remote-command string built on the **host**; a password containing `'` would break that
quoting. `ssh_macos_bootstrap`'s askpass helper is not subject to this (it embeds the password
via `printf %q`, which escapes correctly for any content), but the other three call sites are,
so the generator is constrained to stay in that safe alphabet. Anyone changing the generator
must re-audit those call sites.

### Why the guest's OS version has to be checked too, not just the host's

`VZMacGuestProvisioningOptions` is declared `API_AVAILABLE(macos(27.0))` — that gates the
*host's* Virtualization.framework, and is what `#available(macOS 27, *)` in `augur-vm`'s
`RunSession.boot()` enforces. But Apple's own header notes the options are evaluated by the
**guest OS**, and a pre-27 guest ignores them entirely rather than erroring — so a macOS 27 host
installing an older IPSW would silently fall through to a guest sitting at the login window
forever with no operator present to complete Setup Assistant, and `cmd_build_macos` would hang
waiting for SSH that never comes up. Checking `augur-vm guest-os-version` (persisted from
`VZMacOSRestoreImage.operatingSystemVersion` at `create` time — see `Installer.swift` and
`VMConfig.guestOSMajorVersion`) before ever passing `--provision-username`/`--provision-password-stdin`
closes that gap: an older guest OS always takes the manual path, matching the framework's own
"ignored, not enforced" semantics instead of assuming they apply.

### Why `enablesRemoteLogin` also removes the manual "flip Remote Login on" step

The manual flow's second instruction (`System Settings → General → Sharing → Remote Login →
ON`) exists only because augur had no way to enable it before a human could click through Setup
Assistant. `VZMacGuestProvisioningOptions.enablesRemoteLogin` sets it as part of first-boot
provisioning, so the automated path can go straight from `create` to a headless `run` and poll
for SSH — there is no GUI step to skip past.

## Consequences

- A macOS 27 host building a macOS 27 guest gets a genuinely unattended `cmd_build_macos`: no
  `read -rp` prompts, no GUI window, no operator typing a fixed password into Setup Assistant.
- Every other combination (older host, older guest IPSW, or a pre-existing base VM built before
  this ADR) is **byte-for-byte the ADR-0007 flow** — same fixed credential, same manual Setup
  Assistant instructions, same kcpassword auto-login hack. Nothing regresses for anyone not on a
  macOS 27 host.
- A new host-side secret exists: `~/.augur/macos-admin-password` (mode 600), read by
  `macos_admin_password()`. It is exactly as sensitive as the fixed `admin`/`admin` credential
  it replaces on this path (an agent inside the guest already has passwordless `sudo`, so the
  password itself grants nothing extra inside the guest; the difference is the host no longer
  ships a *guessable* value) — no change to augur's broader secret-storage model.
- `augur-vm` gains one new subcommand (`guest-os-version`) and three new `run` flags
  (`--provision-username`, `--provision-password-stdin`, `--provision-full-name`), all inert
  unless `cmd_build_macos` decides to pass them. The first two exist only in a build made
  against the macOS 27 SDK; `run --help` is therefore the binary's own answer about whether it
  can provision, and `vm_cli_supports_provisioning` asks it before the automated path is chosen.
- Building `augur-vm` with Xcode 26 still works and still yields a fully functional
  `--macos` mode — minus automated provisioning, which is what `--manual-setup` covers anyway.
  Building with Xcode 27 is what enables it; re-running `bash install` after a host OS upgrade
  is what turns it on.
- `augur build --macos` gains `--manual-setup`, the way back to the ADR-0007 flow on a host
  where both sides qualify. It exists because the guest half of automated provisioning is
  unattended and opaque: if a first boot does not complete, without this flag there is no way
  to build a base VM at all.
- `augur-vm run` now retries a start that fails *only* on auxiliary-storage lock contention,
  which makes a back-to-back `create`/`run` safe for every caller, not just this build path.
- Live coverage (an actual first boot completing unattended, on a real macOS 27 host) is
  necessarily local-only, same as the rest of macOS VM mode's live paths (no GitHub-hosted
  runner can boot a VZ guest — see the repo README's CI section). The offline suite
  (`tests/41_macos_admin_password_unit.sh`) covers the pure decision functions
  (`macos_admin_password`, `host_macos_major_version`) it's possible to test without a VM.
  **This ADR's three amended defects were all outside that reach** — each needed a real first
  boot on a macOS 27 host to show up, which is why they shipped.
