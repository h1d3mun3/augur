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
            help: "Share a host directory as name:path (auto-mounted at /Volumes/My Shared Files/<name>). Repeatable.")
    var dirs: [String] = []

    @Option(name: .customLong("net-vfkit"),
            help: "Attach the guest NIC to this vfkit unixgram socket (gvproxy) instead of NAT, so all egress passes through the host egress filter. Without it, NAT is used (no filtering).")
    var netVfkit: String?

    func validate() throws {
        guard Registry.exists(name) else {
            throw ValidationError("No such VM: '\(name)'.")
        }
        guard !Registry.isRunning(name) else {
            throw ValidationError("VM '\(name)' is already running.")
        }
    }

    func run() throws {
        let session = RunSession(name: name, headless: noGraphics, dirs: dirs, netVfkitSocket: netVfkit)
        RunSession.shared = session   // retain across the VM's lifetime
        try session.run()             // headless: dispatchMain; GUI: NSApplication.run — neither returns
    }
}
