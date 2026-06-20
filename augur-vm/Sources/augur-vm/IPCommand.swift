import ArgumentParser
import Foundation

/// `augur-vm ip <name>` — print the running VM's IP (from the DHCP lease database).
struct IP: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ip",
        abstract: "Print a VM's IP address."
    )

    @Argument(help: "VM name.")
    var name: String

    func validate() throws {
        guard Registry.exists(name) else {
            throw ValidationError("No such VM: '\(name)'.")
        }
    }

    func run() throws {
        let cfg = try VMConfig.load(name)
        guard let ip = DHCPLeases.ip(forMAC: cfg.macAddress) else {
            FileHandle.standardError.write(Data(
                "[augur-vm] no DHCP lease found for '\(name)' (\(cfg.macAddress)) — is it booted?\n".utf8))
            throw ExitCode(1)
        }
        print(ip)
    }
}
