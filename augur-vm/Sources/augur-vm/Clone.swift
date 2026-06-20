import ArgumentParser
import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// `augur-vm clone <source> <destination>` — copy-on-write clone of a VM bundle
/// via APFS `clonefile(2)` (the `clone` command). The clone shares storage with the
/// source until written, so it is near-free on disk. The machine identifier is
/// intentionally preserved, which is fine for augur's isolated use.
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

        // Drop any stale pidfile inherited from the source so the clone reads as stopped.
        try? FileManager.default.removeItem(at: Paths.pid(destination))
        print("[augur-vm] cloned '\(source)' -> '\(destination)'.")
    }
}
