import ArgumentParser
import Foundation

/// `augur-vm guest-os-version <name>` — print the installed guest's major macOS version
/// (e.g. "27"), captured at `create` time from the IPSW's restore image. Exits 1 with no
/// stdout if the VM doesn't exist or predates this field (an older bundle's config.json
/// has no `guestOSMajorVersion`) — callers (e.g. `augur`'s `cmd_build_macos`) treat that
/// the same as "not eligible for automated provisioning" and fall back to the manual
/// Setup Assistant flow.
struct GuestOSVersionCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "guest-os-version",
        abstract: "Print a VM's installed guest macOS major version."
    )

    @Argument(help: "VM name.")
    var name: String

    func validate() throws {
        guard Registry.exists(name) else {
            throw ValidationError("No such VM: '\(name)'.")
        }
    }

    func run() throws {
        guard let major = try VMConfig.load(name).guestOSMajorVersion else {
            throw ExitCode(1)
        }
        print(major)
    }
}
