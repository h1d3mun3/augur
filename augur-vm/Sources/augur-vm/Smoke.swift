import ArgumentParser
import Foundation
import Virtualization
import Security

/// M0 acceptance test: proves (1) Virtualization.framework links and loads, and
/// (2) the running binary actually carries the com.apple.security.virtualization
/// entitlement. Reading our own code signature avoids having to boot a real VM just
/// to validate the signing pipeline — that comes at M1.
struct Smoke: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "smoke",
        abstract: "Verify VZ links and the virtualization entitlement is embedded."
    )

    func run() throws {
        // 1. Linkage: touching a static VZ symbol forces the framework to load.
        let minCPU = VZVirtualMachineConfiguration.minimumAllowedCPUCount
        let minMem = VZVirtualMachineConfiguration.minimumAllowedMemorySize
        print("Virtualization.framework: linked (min cpu=\(minCPU), min mem=\(minMem) bytes)")

        // 2. Entitlement: inspect our own signature for the virtualization key.
        let key = "com.apple.security.virtualization" as CFString
        var hasEntitlement = false
        if let task = SecTaskCreateFromSelf(nil),
           let value = SecTaskCopyValueForEntitlement(task, key, nil) {
            hasEntitlement = (value as? Bool) ?? false
        }

        guard hasEntitlement else {
            FileHandle.standardError.write(Data(
                """
                Entitlement com.apple.security.virtualization: MISSING ✗
                  Re-sign with: scripts/build.sh
                  (codesign --force --sign - --entitlements augur-vm.entitlements <binary>)

                """.utf8))
            throw ExitCode(1)
        }

        print("Entitlement com.apple.security.virtualization: PRESENT ✓")
        print("M0 smoke: OK")
    }
}
