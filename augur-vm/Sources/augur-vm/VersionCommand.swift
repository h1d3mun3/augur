import ArgumentParser
import Foundation

struct VersionCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "version",
        abstract: "Print augur-vm version."
    )
    func run() {
        print("augur-vm \(AugurVersion.string)")
    }
}
