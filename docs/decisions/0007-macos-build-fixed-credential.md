# ADR-0007 — macOS base-VM build keeps the fixed `admin`/`admin` credential, but stops making the operator type it

- **Status:** Accepted.
- **Date:** 2026-07-20.
- **Applies to:** macOS VM mode only (`cmd_build_macos` / the base-VM build path).

## Decision

The macOS base-VM build **keeps the fixed `admin`/`admin` guest credential** and does **not**
randomize it. Separately, it **removes the operator-typed SSH password prompt** that used to appear
after Setup Assistant: the known password is now fed to the one-time bootstrap `ssh` non-interactively
via OpenSSH's own `SSH_ASKPASS` (`SSH_ASKPASS_REQUIRE=force`) in a new `ssh_macos_bootstrap` helper,
and the SSH key is installed **first** so only a single password-authenticated connection ever occurs
(everything after runs over key auth). No third-party tool, no randomization, no dynamic `kcpassword`.

## Context

After Setup Assistant, `cmd_build_macos` made **two raw, password-authenticated** `ssh` calls before
key auth was bootstrapped (configure passwordless sudo, then install the SSH key). OpenSSH therefore
prompted for the `admin` login password on the controlling terminal and the operator had to type
`admin` — **twice** (the in-code comment even claimed "password only needed this once", which was
inaccurate). No `sshpass`/`expect`/askpass automation existed anywhere.

Two questions were on the table:

1. **The credential itself.** The `admin`/`admin` account is called out by security review L2
   (`../security-reviews/2026-06-28-full-review.md`, raw-Low → **effective Info**), whose suggested
   fix is *"set a strong random account password after key auth is established (with a matching
   `kcpassword` for auto-login), or run the agent as a non-admin user; optionally
   `PasswordAuthentication no`."* That standing recommendation invites a future "why don't we just
   randomize it" — this ADR is the answer.
2. **The prompt.** Regardless of the credential's value, requiring a human to type it at the terminal
   is a wart (and blocks any unattended build) that can be removed independently.

## Rationale

### Eliminate the prompt with `SSH_ASKPASS` (not `sshpass`)

`SSH_ASKPASS` + `SSH_ASKPASS_REQUIRE=force` is **inside `ssh` itself** — it adds no dependency, so it
respects the base-VM build's stated principle of *"no third-party tools required" / "No third-party
automation scripts are used"* (`README.md`). `SSH_ASKPASS_REQUIRE=force` (OpenSSH ≥ 8.4; macOS ships
10.x) is the load-bearing part: it makes askpass answer the **login-password** prompt (not just key
passphrases) **even with a controlling TTY and without `DISPLAY`**, so no `setsid`/fake-`DISPLAY`
dance is needed. `sshpass` was rejected: it is not Apple-shipped and lives only in a non-core Homebrew
tap, i.e. a real external dependency the build principle forbids. The helper's askpass script replies
only to password prompts and `StrictHostKeyChecking=accept-new` keeps the host-key question off it.

### Keep `admin`/`admin` — do **not** randomize (for now)

Randomizing is L2's own fix and is technically feasible and dependency-free (reset via
`sysadminctl`/`dscl` over key-auth SSH, plus a dynamically-computed `kcpassword`). It was declined
because the **cost/risk outweighs the Info-level benefit**:

- **Benefit is effective-Info.** The VM is disposable and single-user; the agent inside already has
  passwordless (`NOPASSWD`) sudo, so knowing the password grants it nothing extra; the guest cannot
  cross the VM boundary or escape egress; and in normal operation Remote Login is not network-exposed.
- **Randomization perturbs a load-bearing path.** Auto-login (kcpassword) is *required* so a GUI Aqua
  session exists for headless `xcodebuild test`. Any **external** password reset
  (`sysadminctl`/`dscl`) leaves the login keychain (`login.keychain-db`) encrypted under the *old*
  password, so the auto-login session stalls on a "unable to unlock login keychain" prompt — which is
  exactly why CI macOS-VM images set the password once at build time and never rotate it. Rotating
  *after* the account exists (our only option, since the account is born in a human-run Setup
  Assistant) is precisely the case that triggers the desync, adding a real failure surface to a core
  feature for a cleanup-level gain.

If the network-credential angle ever matters, the cheaper hardening is L2's other suggestion —
`PasswordAuthentication no` on the guest sshd — which neutralizes password login without touching the
account password or the keychain. Fully unattended builds (removing the manual Setup Assistant, so
the host *chooses* the credential and no human types anything) would use macOS 27's
`VZMacGuestProvisioningOptions`; that is version-gated and out of scope here.

## Consequences

- Zero password typing at the terminal after Setup Assistant; the operator still creates `admin`/
  `admin` in Setup Assistant itself (unavoidable before macOS 27). The base VM builds and auto-logs-in
  exactly as before.
- The fixed credential — and its accepted effective-Info posture — is unchanged; every project VM
  cloned from the base still shares it.
- The change is confined to `cmd_build_macos` and the new `ssh_macos_bootstrap` helper in `augur`,
  with source-guard and execution-guard regression tests in `tests/30_macos_vm.sh`. No egress-core
  change.
