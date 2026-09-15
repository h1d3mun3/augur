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

The original version of this decision shipped three defects that a first real build on a
macOS 27 host found, all of them in the seam this ADR removed — the manual flow's operator
prompts turned out to be load-bearing as *waits*, not just as instructions:

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
admin account actually has. Three call sites beyond the build itself authenticate as that
account over `sudo -S` against a *running project clone*, not just during the base build:
`install_macos_managed_settings` (pushes augur's managed Claude Code policy on every `up
--macos`), `sync_macos_guest_clock` (corrects guest drift on every `up`/`claude`/`shell
--macos`), and `run_base_provisioning`'s temporary sudo grant (`augur update --macos`
provisioning). All three, plus `ssh_macos_bootstrap`'s SSH-key install during the build itself,
now resolve the password through one function, `macos_admin_password()`, instead of assuming
the constant `admin` string. `macos_admin_password()` reads `~/.augur/macos-admin-password` if
it exists (a base VM built on the automated path) and falls back to the fixed `admin`/`admin`
credential otherwise (a base VM built on the manual path, or one built before this ADR) — so a
pre-existing base VM's clones keep working unchanged, with no migration step.

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
  unless `cmd_build_macos` decides to pass them.
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
