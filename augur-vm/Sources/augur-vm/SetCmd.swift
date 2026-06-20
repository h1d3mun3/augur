import ArgumentParser
import Foundation

/// `augur-vm set <name> [--cpu N] [--memory MB]`
/// Memory is given in MB, e.g. `--memory 8192`.
struct SetCmd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Set CPU count and/or memory (MB) on an existing VM."
    )

    @Argument(help: "VM name.")
    var name: String

    @Option(help: "Number of virtual CPUs.")
    var cpu: Int?

    @Option(help: "Memory in megabytes (MB).")
    var memory: UInt64?

    func validate() throws {
        guard Registry.exists(name) else {
            throw ValidationError("No such VM: '\(name)'.")
        }
        guard cpu != nil || memory != nil else {
            throw ValidationError("Nothing to set — pass --cpu and/or --memory.")
        }
    }

    func run() throws {
        var config = try VMConfig.load(name)
        if let cpu { config.cpuCount = cpu }
        if let memory { config.memorySize = memory * 1024 * 1024 }   // MB → bytes
        try config.save(name)
        print("[augur-vm] updated '\(name)' (cpu=\(config.cpuCount), memory=\(config.memorySize / 1024 / 1024) MB)")
    }
}
