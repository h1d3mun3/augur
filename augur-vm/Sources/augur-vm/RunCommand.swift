import ArgumentParser
import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// `augur-vm run <name> [--no-graphics] [--dir=name:path ...]`
/// Headless (`--no-graphics`) parks on dispatchMain; without it a GUI window opens.
struct RunCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Boot a VM and keep it running (--no-graphics headless, or a GUI window)."
    )

    @Argument(help: "VM name.")
    var name: String

    @Flag(name: .customLong("no-graphics"), help: "Run headless (no GUI window).")
    var noGraphics = false

    @Option(name: .customLong("dir"), parsing: .singleValue,
            help: "Share a host directory as name:path[:ro] (auto-mounted at /Volumes/My Shared Files/<name>; append :ro for read-only). Repeatable.")
    var dirs: [String] = []

    @Option(name: .customLong("net-vfkit"),
            help: "Attach the guest NIC to this vfkit unixgram socket (gvproxy) so all egress passes through the host egress filter. This is the default datapath; omitting it requires --net-nat.")
    var netVfkit: String?

    @Flag(name: .customLong("net-nat"),
          help: "Use unfiltered NAT instead of the egress-filtered socket. Opt-in only: without this flag a socket (--net-vfkit) is required, so a forgotten flag fails closed rather than silently granting full network access.")
    var netNAT = false

    @Option(name: .customLong("provision-full-name"), help: "Full name for --provision-username.")
    var provisionFullName: String = "augur"

    // ── Automated guest setup — macOS 27 SDK only ───────────────────────────────
    // `VZMacGuestProvisioningOptions` is declared only in the macOS 27 SDK, so on an older SDK
    // the symbol does not exist and no amount of `@available` helps: that gates RUNTIME
    // availability, for calling a newer API from a build that has its declaration. Building
    // augur-vm against the macOS 26 SDK therefore has to compile the feature out entirely
    // rather than fail — `install` builds this from source on every macOS host, and augur
    // supports macOS 26+, so a hard reference would take all of `--macos` mode down there.
    //
    // `compiler(>=6.4)` stands in for "the macOS 27 SDK": Swift has no SDK-version conditional,
    // and Xcode ships the two together (Xcode 26.6 → Swift 6.3.3 + macOS 26 SDK; Xcode 27 →
    // Swift 6.4 + macOS 27 SDK). It is checked here rather than via a `-D` from a build script
    // because augur-vm is built from three different entry points (install → scripts/build.sh,
    // the Makefile's `make unit`, and a plain `swift build`) and only a source-level condition
    // covers all of them identically.
    //
    // These options are gated too, not just their implementation, so `run --help` is an honest
    // report of what this binary can do — which is what augur probes before choosing the
    // automated path (see vm_cli_supports_provisioning).
    #if compiler(>=6.4)
    // Only meaningful on the guest's FIRST boot after `create` — the framework ignores these
    // once a guest has already been provisioned. See RunSession.swift and ADR-0018.
    @Option(name: .customLong("provision-username"),
            help: "Create this account automatically on first boot instead of waiting for a manually-run Setup Assistant. Requires --provision-password-stdin, --no-graphics, and a macOS 27+ host; has no effect on a guest whose OS predates macOS 27 (see `augur-vm guest-os-version`).")
    var provisionUsername: String?

    // The password is read from stdin, never taken as an option: a process's arguments are
    // observable (`ps`), so `--provision-password <secret>` would expose the new account's
    // credential to anything running as this user for the lifetime of the boot. Mirrors how
    // `augur` already hands secrets to a child — piped in, not spelled out on the command line.
    @Flag(name: .customLong("provision-password-stdin"),
          help: "Read the password for --provision-username from stdin (e.g. `printf %s \"$pw\" | augur-vm run …`). Trailing newlines are stripped.")
    var provisionPasswordStdin = false

    private func validateProvisioning() throws {
        guard (provisionUsername == nil) != provisionPasswordStdin else {
            throw ValidationError("--provision-username and --provision-password-stdin must be given together.")
        }
        if provisionUsername != nil, !noGraphics {
            throw ValidationError("--provision-username/--provision-password-stdin require --no-graphics (automated setup has no manual GUI step).")
        }
        // Without this, a --provision-password-stdin run launched from a terminal (no pipe)
        // would block on a read that never sees EOF, looking like a VM that hangs before it
        // boots rather than a caller that forgot to pipe the password in.
        if provisionPasswordStdin, isatty(FileHandle.standardInput.fileDescriptor) == 1 {
            throw ValidationError("--provision-password-stdin needs the password piped in, not a terminal.")
        }
    }

    private func readProvisioningPassword() throws -> String {
        let raw = FileHandle.standardInput.readDataToEndOfFile()
        guard let text = String(data: raw, encoding: .utf8) else {
            throw CLIError("the password on stdin is not valid UTF-8")
        }
        // Only trailing newlines: a password may legitimately start or end with other
        // characters, and `printf '%s'` (what augur uses) sends none of these at all.
        let trimmed = text.trimmingCharacters(in: CharacterSet(charactersIn: "\r\n"))
        guard !trimmed.isEmpty else {
            throw CLIError("no password was read from stdin")
        }
        return trimmed
    }
    #endif

    func validate() throws {
        guard Registry.exists(name) else {
            throw ValidationError("No such VM: '\(name)'.")
        }
        guard !Registry.isRunning(name) else {
            throw ValidationError("VM '\(name)' is already running.")
        }
        #if compiler(>=6.4)
        try validateProvisioning()
        #endif
    }

    func run() throws {
        var username: String?
        var password: String?
        #if compiler(>=6.4)
        if let requested = provisionUsername {
            username = requested
            password = try readProvisioningPassword()
        }
        #endif

        let session = RunSession(
            name: name, headless: noGraphics, dirs: dirs, netVfkitSocket: netVfkit, netAllowNAT: netNAT,
            provisionUsername: username, provisionPassword: password,
            provisionFullName: provisionFullName
        )
        RunSession.shared = session   // retain across the VM's lifetime
        try session.run()             // headless: dispatchMain; GUI: NSApplication.run — neither returns
    }
}
