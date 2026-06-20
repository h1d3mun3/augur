import ArgumentParser
import Foundation

/// `augur-vm delete <name>` — remove a VM bundle.
struct DeleteCmd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete a VM bundle."
    )

    @Argument(help: "VM name.")
    var name: String

    func validate() throws {
        guard Registry.exists(name) else {
            throw ValidationError("No such VM: '\(name)'.")
        }
        guard !Registry.isRunning(name) else {
            throw ValidationError("VM '\(name)' is running — stop it first.")
        }
    }

    func run() throws {
        try FileManager.default.removeItem(at: Paths.bundle(name))
        print("[augur-vm] deleted '\(name)'.")
    }
}
