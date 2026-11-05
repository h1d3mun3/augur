# ADR-0022 — macOS `setup-token` runs in a throwaway clone; the agent binary's signer is pinned by Team ID

- **Status:** Accepted.
- **Date:** 2026-11-05.
- **Applies to:** macOS VM mode only. Apple Container mode is unchanged (its `setup-token` keeps
  `agent_verify_integrity_engine`'s hash-against-the-image gate and gets no credentials, see
  [`0021`](./0021-container-per-session-credentials.md)).
- **Amends:** [`0003`](./0003-swappable-agent-abstraction.md) — its macOS integrity gate
  (§4 C2 / §5: "codesign signer = Anthropic before setup-token").

## Context

`augur setup-token --macos` attached the project VM's `claude` to the operator's real terminal
to mint a long-lived token, after a gate that ran
`ssh_macos vm 'codesign -dvv "$HOME/.local/bin/claude" 2>&1 | grep -qi "Anthropic"'`. That gate
could not hold:

1. **It ran inside the very guest it was judging.** Every `ssh <host> <cmd>` runs through the guest
   user's zsh, which sources the guest-writable `~/.zshenv` (and through it `~/.augur-env`). A
   function or alias there fakes `codesign` or `grep`. The project VM is kept across `down`
   ([`0006`](./0006-macos-vm-clone-persistence.md)), so a prior session can plant this, and on a
   manual-setup base ([`0007`](./0007-macos-build-fixed-credential.md)) the guest user is an admin
   whose password is published — no in-VM check can hold against root.
2. **The pattern was not a signer check.** `grep -qi Anthropic` also matches the `Identifier=` line:
   `codesign -s - -i com.anthropic.x` (ad-hoc, no certificate) passed. There was no `--verify`.
3. **The launch was not the checked file.** `zsh -l -c 'claude setup-token'` resolved `claude`
   through the guest's PATH again.
4. **It ran with live credentials.** The project VM's `~/.augur-env` holds `ANTHROPIC_API_KEY`,
   `CLAUDE_CODE_OAUTH_TOKEN` and `GH_TOKEN`; container mode deliberately gives `setup-token` none.

The same weak pattern guarded the base VM: `build --macos` aborted on it, `update --macos` only
warned and kept the updated base VM, and `ensure_macos_agent_bin` checked nothing and installed
`latest` into a project VM when the binary was missing (exiting 0 even when that failed).

## Decision

### `setup-token --macos` never uses the project VM

It clones the **base VM** into a throwaway VM, runs the login there, and deletes it on every exit
path. A fresh clone has never run a guest session, so its rc files, its tools and its `claude` are
exactly what the host-controlled `build`/`update` wrote. Therefore an in-guest check is meaningful
there and nowhere else.

- **Nothing project-specific reaches it:** no workspace, history, agents or profile share; no
  `~/.augur-env`; no `GH_TOKEN`; no `~/.gitconfig`. It receives only the onboarding-only
  `~/.claude.json` stub (the same one every project clone gets) so the login does not start with
  first-run onboarding. As defense in depth, right after the clone boots and before anything from
  it runs on the operator's TTY, `macos_scrub_augur_credentials` removes exactly the
  credential-bearing files augur itself writes into a guest — `~/.augur-env`, the `~/.zshenv` line
  that sources it, and `~/.gitconfig` (which carries the `GH_TOKEN` credential helper). augur writes
  these into project VMs only, never into the base VM, so this is normally a no-op; a failure aborts.
  It deliberately does not chase the Keychain or arbitrary files a human left in the base VM.
- **Egress is enforced exactly like a normal `up --macos`:** augur-proxy + gvproxy on the
  file-handle datapath, the guest clock set from the host, then `verify_macos_egress_locked`, which
  tears down and exits on any leak. `--no-egress` / `AUGUR_EGRESS=0` are ignored with a warning.
- **Allowlist: baseline + global, not the project's `.augur/allowlist.conf`.** The login needs only
  Anthropic's endpoints, which the managed baseline carries. A project's domains are per-project
  input and have no business widening a host-wide flow. The global layer is kept because it is
  operator-written host-side input that every normal `up` honours too — so this allowlist is never
  wider than a normal `up`'s, and a user who routes Anthropic through a host-level domain keeps a
  working login.
- **Identity:** the same override `destroy <name>` uses (`TARGET_SLUG`/`TARGET_HASH`), set to
  `_setup-token` / `throwaway`, so every per-VM helper (VM name `augur-macos-_setup-token-throwaway`,
  proxy/gvproxy pidfiles, logs, socket, merged allowlist, known-hosts file)
  points at it without duplicating that machinery. `workspace_slug` never emits `_`, so it cannot
  collide with any project, and `target_name_re` does not match it, so `destroy <name>` and its
  completion never offer it. Ports are fixed (`13998`/`14998`/`20998`, overridable via
  `AUGUR_*_PORT_SETUP_TOKEN`), outside the per-project range and next to the provisioning ones.
  A host-wide lock allows one run at a time: `~/.augur/setup-token-macos.lock`. Every augur host
  lock (`host_lock_acquire`) is a symlink whose target names its holder as `<pid>:<command>`, so it
  is created atomically with its holder. Only a lock whose target is a pid that is no longer alive
  is taken over, by renaming it to a private name and re-checking it (put back if it changed
  meanwhile); anything else — a live holder, an empty or non-pid target — refuses, naming the
  command that holds it. A lock is released only by the process and command that took it.
- **Never a clone of a base VM being replaced:** the clone itself is taken under the base-writer
  lock (`~/.augur/macos-base-writer.lock`, below), held only for the `augur-vm clone`. While a
  `build` or `update --macos` holds it, `setup-token --macos` refuses naming that command; a build
  or update started during the clone is refused instead.
- **Preflight:** it refuses (without stopping anything) when the base VM is running — an
  `install-cert` window or an interrupted run, and clonefile does not refuse a running source — and
  when two augur macOS VMs are already running, since macOS allows at most two guests and a third
  would only fail as an SSH timeout. It never falls back to the project VM.
- **Cleanup:** an EXIT trap (INT/TERM/HUP converted to exit) stops the VM directly (its disk is
  deleted, so there is nothing to shut down gracefully), stops gvproxy and the proxy, deletes the VM
  and removes its state files; the next run removes whatever a crash left behind before cloning. It
  works the same whether or not the project VM exists or runs.
- **Launch:** the binary the signature check verified, by absolute path
  (`/Users/admin/` + `agent_macos_cli_relpath`), with `agent_fixed_env`, attached to the TTY as
  before; the operator warning and `save_oauth_token` are unchanged.
- **Workspace gate:** `setup-token --macos` no longer needs
  [`0014`](./0014-workspace-must-not-contain-augur.md)'s workspace check (nothing is shared), so it
  can run from any directory.

### One strict signer check, used by build, update and the throwaway clone

`agent_verify_integrity_macos` runs, in the guest,
`/usr/bin/codesign --verify --strict -R='anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = "<TEAM>"'`
on the absolute binary path, then requires `codesign -dvv` to print exactly `TeamIdentifier=<TEAM>`.
`<TEAM>` is the agent seam's `agent_macos_signing_team` (Anthropic PBC, `Q6L2SF6YDW`). An ad-hoc
signature, a certificate from another team, or a binary that fails verification is refused whatever
its `Identifier` says.

- **Where it runs: last, on the final guest state.** In both `build` and `update` the check runs
  after every guest mutation — the installer, custom provisioning (whose `hook.sh` runs as root and
  could replace the binary), the `~/.claude.json` scrub, the managed policy, the Xcode selection and
  the sudo revoke — immediately before the VM is stopped and saved. Provisioning stops the scratch
  VM's NAT session to boot it on the filtered provisioning datapath; `run_base_provisioning` then
  restarts it on NAT, so every later step reaches a running VM. Accepted trade-off: the provisioned
  guest has open NAT for those few steps, as it already has at the start of every later
  `update --macos`.
- `build --macos`: aborts, and its EXIT trap discards the build VM.
- `update --macos`: now runs entirely on a staging clone of the base VM (`augur-macos-update`) and
  replaces the base VM only after every step has passed — this check, and the Xcode selection, which
  is fatal in update as it is in build. Until then any failure leaves the base VM exactly as it was.
- **The save** (`macos_save_scratch_as_base`, both commands): delete the old base, clone the scratch
  VM into its place, with INT/TERM/HUP ignored. If that does not complete — including a failed clone
  that left a partial destination, which is never treated as saved — the scratch VM is kept and augur
  prints the `augur-vm` commands that finish the save, so at least one copy always survives. (In
  build the old base is already gone, deleted at the start with the operator's consent.) Update keeps
  the base VM's pinned SSH host key: the staging VM is a clone of it, so the key is unchanged.
- **One base writer at a time.** `build` and `update --macos` both replace the base VM and use the
  same fixed provisioning ports, so each holds the host-wide base-writer lock
  (`~/.augur/macos-base-writer.lock`) from before it touches any VM until it ends; a second build or
  update refuses naming the command that holds it, before cloning, stopping or deleting anything.
  Their EXIT traps therefore only ever discard a scratch VM their own process owns: under the lock, a
  staging VM that already exists (running or not) was left by a killed update and is stopped and
  removed before the new clone. Update never touches `augur-macos-build`. `install-cert --macos`
  writes into the base VM itself, so it holds the same lock for its whole trust window: an update
  can no longer stop the base VM under it, nor a build delete it.
- `ensure_macos_agent_bin` (project VMs): no self-install any more. A missing binary is an error
  pointing at `augur update --macos` / `augur build --macos`; `claude --macos` refuses, `up --macos`
  warns and continues (the VM is still usable with `shell --macos`). Base VMs built by an older
  augur get no compatibility path.
- **Deliberately no signature check at `claude --macos` launch.** A project VM is
  guest-controlled: the guest can fake `codesign` itself, so the check would prove nothing, and the
  agent is handed nothing the guest does not already hold. The check matters only where a binary is
  attached to the operator's TTY to capture a credential — `setup-token`, which now runs in a clone
  whose disk only augur has written.

### `claude`/`shell`/`up --macos` refuse a running VM booted with another egress mode

Recorded with this change because it closes the same "attach to a guest whose state augur did not
verify" class. `cmd_up_macos` writes the egress mode (`on`/`off`) to a host-side record
(`macos_egress_mode_file`) just before `augur-vm run`; `down`/`destroy` remove it. On a running VM,
`up`, `claude` and `shell --macos` compare it with the requested mode and, on a mismatch or a missing
record, refuse with `augur down --macos && augur up --macos [--no-egress]` and exit non-zero
without stopping the VM — the macOS peer of `require_running_container_current`. A missing record
(for example a VM started by an augur from before this change) is deliberately refused too, with a
message saying the mode is unknown and one restart fixes it. The
already-running `up` runs the boot self-test only when egress is on and the modes match, so a VM
started with `--no-egress` is no longer "detected" as a leak and stopped under the operator.

## Consequences

- `setup-token --macos` costs a clone, a cold boot and a deletion (CoW clone, so little disk) instead
  of reusing a running project VM. It no longer starts or stops the project VM.
- A project VM whose guest was compromised can no longer phish the operator's sign-in or see a
  credential through `setup-token`.
- The pinned Team ID becomes a maintained constant: if the vendor ever signs with another team,
  `build`/`update`/`setup-token --macos` fail closed until `agent_macos_signing_team` is updated.
- `update --macos` needs room for one CoW staging clone of the base VM while it runs.
- **Must be verified on a real Mac** (nothing here can run on the Linux CI tier): the Team ID
  (`codesign -dvv ~/.local/bin/claude` → `TeamIdentifier=`), that the requirement above accepts the
  installed binary through its `~/.local/bin` symlink, and a full `setup-token --macos` round trip
  including the cleanup.

## Enforced by

- `tests/52_macos_setup_token_unit.sh` — the signer check's verdicts (ad-hoc with "anthropic" in the
  Identifier, another team, a prefix-only team, a failed `--verify` all fail; the vendor team passes)
  and its exact requirement; `update --macos` never touching the base VM on failure and promoting
  the staging copy only after the check; `ensure_macos_agent_bin` never installing; and
  `setup-token --macos` using a throwaway clone of the base VM with no credentials, shares or
  project allowlist, launching the verified absolute path, and cleaning up on success, signature
  failure, self-test failure, credential-scrub failure and Ctrl-C, plus the stale-clone handling,
  the base-VM and VM-slot preflights, the credential scrub (run against a stand-in guest home), the
  clone taken only under the base-writer lock, and the host locks (atomic create, refusal of a live,
  empty or non-pid holder, race-safe reap, release only by the holder). For update: the build VM
  untouched, a running build, update or setup-token clone refused before any VM is touched, a
  killed update's staging VM replaced, an Xcode-selection failure fatal, and the save surviving an
  interrupt, a failed save and a partial one with the staging copy kept. For build and update with
  provisioning files present: every later step reaches a running VM, the signer check runs last
  (after the hook), a failing final check or hook saves nothing, and build keeps its VM on a failed
  save.
- `tests/51_macos_egress_mode_unit.sh` — the egress-mode record (keyed per project path) and the
  refusals on `up`, `claude` and `shell --macos`. Accepted trade-off: two concurrent `up --macos`
  for the same project can race the record; concurrent runs for one project are unsupported in
  both modes.
