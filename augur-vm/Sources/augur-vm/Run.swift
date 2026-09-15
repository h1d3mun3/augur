import ArgumentParser
import Foundation

/// `augur-vm run <name> [--no-graphics] [--dir=name:path ...]`
/// Headless (`--no-graphics`) parks on dispatchMain; without it a GUI window opens.
struct Run: ParsableCommand {
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

    // Automated guest setup (VZMacGuestProvisioningOptions, macOS 27+ host only). Only
    // meaningful on the guest's FIRST boot after `create` — the framework ignores these
    // once a guest has already been provisioned. See RunSession.swift and ADR-0018.
    @Option(name: .customLong("provision-username"),
            help: "Create this account automatically on first boot instead of waiting for a manually-run Setup Assistant. Requires --provision-password, --no-graphics, and a macOS 27+ host; has no effect on a guest whose OS predates macOS 27 (see `augur-vm guest-os-version`).")
    var provisionUsername: String?

    @Option(name: .customLong("provision-password"), help: "Password for --provision-username.")
    var provisionPassword: String?

    @Option(name: .customLong("provision-full-name"), help: "Full name for --provision-username.")
    var provisionFullName: String = "augur"

    func validate() throws {
        guard Registry.exists(name) else {
            throw ValidationError("No such VM: '\(name)'.")
        }
        guard !Registry.isRunning(name) else {
            throw ValidationError("VM '\(name)' is already running.")
        }
        guard (provisionUsername == nil) == (provisionPassword == nil) else {
            throw ValidationError("--provision-username and --provision-password must be given together.")
        }
        if provisionUsername != nil, !noGraphics {
            throw ValidationError("--provision-username/--provision-password require --no-graphics (automated setup has no manual GUI step).")
        }
    }

    func run() throws {
        let session = RunSession(
            name: name, headless: noGraphics, dirs: dirs, netVfkitSocket: netVfkit, netAllowNAT: netNAT,
            provisionUsername: provisionUsername, provisionPassword: provisionPassword,
            provisionFullName: provisionFullName
        )
        RunSession.shared = session   // retain across the VM's lifetime
        try session.run()             // headless: dispatchMain; GUI: NSApplication.run — neither returns
    }
}
