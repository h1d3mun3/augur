import ArgumentParser
import Foundation
import Virtualization
#if canImport(Darwin)
import Darwin
#endif

/// `augur-vm clone <source> <destination>` — copy-on-write clone of a VM bundle
/// via APFS `clonefile(2)` (the `clone` command). The clone shares storage with the
/// source until written, so it is near-free on disk. `machineIdentifier` and
/// `macAddress` are regenerated on the destination's config.json so the clone can
/// run concurrently with the source without colliding (see issue #67).
struct Clone: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clone",
        abstract: "Copy-on-write clone a VM (APFS clonefile)."
    )

    @Argument(help: "Source VM name.")
    var source: String

    @Argument(help: "Destination VM name.")
    var destination: String

    func validate() throws {
        guard Registry.exists(source) else {
            throw ValidationError("No such VM: '\(source)'.")
        }
        guard !Registry.exists(destination) else {
            throw ValidationError("VM '\(destination)' already exists.")
        }
    }

    func run() throws {
        try FileManager.default.createDirectory(at: Paths.root, withIntermediateDirectories: true)

        let srcPath = Paths.bundle(source).path
        let dstPath = Paths.bundle(destination).path
        let result = srcPath.withCString { s in
            dstPath.withCString { d in clonefile(s, d, 0) }
        }
        guard result == 0 else {
            throw CLIError("clone failed: \(String(cString: strerror(errno)))")
        }

        // clonefile(2) copies config.json byte-for-byte, so the destination starts out
        // with the source's exact machineIdentifier/macAddress. Regenerate both so the
        // clone is a distinct instance: same macAddress collides on the shared NAT
        // segment (augur-vm ip resolves by MAC), and Virtualization.framework does not
        // support running two live VMs with the same VZMacMachineIdentifier.
        var config = try VMConfig.load(destination)
        config.machineIdentifier = VZMacMachineIdentifier().dataRepresentation
        config.macAddress = VZMACAddress.randomLocallyAdministered().string
        try config.save(destination)

        // Drop any stale pidfile inherited from the source so the clone reads as stopped.
        try? FileManager.default.removeItem(at: Paths.pid(destination))
        print("[augur-vm] cloned '\(source)' -> '\(destination)'.")
    }
}
