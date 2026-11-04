import ArgumentParser
import Foundation

/// `augur-vm provisioning-support <name>` — can VM <name>'s first boot provision its admin
/// account automatically (`run --provision-username`, Virtualization's
/// `VZMacGuestProvisioningOptions`)? That needs all three of: a macOS 27+ host, a guest whose
/// installed macOS (captured at `create`) is 27+, and a binary built against the macOS 27 SDK.
///
/// Whenever it can answer, it prints exactly one token and exits 0:
///   supported  all three hold
///   host       the host is older than macOS 27
///   guest      the guest's installed macOS is older than 27, or unknown
///   sdk        host and guest qualify, but this binary was built without the feature
/// The checks run in that order, so `sdk` (fixed by rebuilding with Xcode 27+) is reported only
/// when rebuilding would actually enable the feature.
///
/// Any other outcome is an error, not an answer: a missing VM or unreadable config exits 1, and a
/// binary that predates this subcommand exits 64 (ArgumentParser's usage error). `augur` relies on
/// those staying distinct (see macos_setup_flow).
struct ProvisioningSupportCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "provisioning-support",
        abstract: "Report whether a VM's first boot can provision its account automatically (macOS 27+)."
    )

    @Argument(help: "VM name.")
    var name: String

    enum Answer: String {
        case supported, host, guest, sdk
    }

    // Deliberately checked in run(), not validate(): a validation failure exits 64, the same code
    // as a binary that has no such subcommand, and the caller must be able to tell them apart.
    func run() throws {
        guard Registry.exists(name) else {
            throw CLIError("No such VM: '\(name)'.")
        }
        let result = try answer()
        print(result.rawValue)
    }

    private func answer() throws -> Answer {
        // The same host check RunSession.boot() applies before using the provisioning options.
        // `#available` needs no macOS 27 SDK declarations, so it compiles under either SDK.
        guard #available(macOS 27, *) else { return .host }
        guard let guestMajor = try VMConfig.load(name).guestOSMajorVersion, guestMajor >= 27 else {
            return .guest
        }
        // The same condition that compiles the `run --provision-*` options in or out (see
        // RunCommand.swift for why it stands in for "built against the macOS 27 SDK").
        #if compiler(>=6.4)
        return .supported
        #else
        return .sdk
        #endif
    }
}
