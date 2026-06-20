import ArgumentParser
import Foundation

/// `augur-vm create <name> --from-ipsw <path> [--disk-size <GB>]`
struct Create: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create a VM by installing macOS from an IPSW restore image."
    )

    @Argument(help: "VM name.")
    var name: String

    @Option(name: .customLong("from-ipsw"), help: "Path to a macOS .ipsw restore image.")
    var fromIpsw: String

    @Option(name: .customLong("disk-size"), help: "Disk size in GB.")
    var diskSize: UInt64 = 90

    func validate() throws {
        guard !Registry.exists(name) else {
            throw ValidationError("VM '\(name)' already exists.")
        }
        guard FileManager.default.fileExists(atPath: fromIpsw) else {
            throw ValidationError("IPSW not found: \(fromIpsw)")
        }
        guard diskSize > 0 else {
            throw ValidationError("--disk-size must be greater than 0.")
        }
    }

    func run() throws {
        let ipswURL = URL(fileURLWithPath: fromIpsw)
        let session = InstallSession(name: name, ipswURL: ipswURL, diskSizeGB: diskSize)
        InstallSession.shared = session   // retain across the async install
        session.start()
        // Install runs on the main queue; completion handlers exit the process.
        dispatchMain()
    }
}
