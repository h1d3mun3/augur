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

    func validate() throws {
        guard Registry.exists(name) else {
            throw ValidationError("No such VM: '\(name)'.")
        }
        guard !Registry.isRunning(name) else {
            throw ValidationError("VM '\(name)' is already running.")
        }
    }

    func run() throws {
        let session = RunSession(name: name, headless: noGraphics, dirs: dirs, netVfkitSocket: netVfkit, netAllowNAT: netNAT)
        RunSession.shared = session   // retain across the VM's lifetime
        try session.run()             // headless: dispatchMain; GUI: NSApplication.run — neither returns
    }
}
