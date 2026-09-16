import Foundation

/// Persisted VM description (config.json in the bundle). `hardwareModel` and
/// `machineIdentifier` hold the raw `dataRepresentation` bytes of the matching VZ
/// types; JSONEncoder serializes `Data` as base64 by default.
struct VMConfig: Codable {
    var cpuCount: Int
    var memorySize: UInt64        // bytes
    var macAddress: String        // e.g. " aa:bb:cc:dd:ee:ff"
    var diskSizeGB: UInt64
    var hardwareModel: Data       // VZMacHardwareModel.dataRepresentation
    var machineIdentifier: Data   // VZMacMachineIdentifier.dataRepresentation
    var display: Display
    /// The installed guest's major OS version (e.g. 27 for macOS 27.x), captured from
    /// `VZMacOSRestoreImage.operatingSystemVersion` at `create` time. Optional so bundles
    /// created before this field existed still decode (Codable defaults a missing key to
    /// nil for an Optional property). Used to decide whether the guest supports automated
    /// `VZMacGuestProvisioningOptions` setup on its first boot (needs guest macOS 27+, in
    /// addition to a macOS 27+ host) — see `guest-os-version` and ADR-0018.
    var guestOSMajorVersion: Int? = nil

    struct Display: Codable {
        var width: Int
        var height: Int
        var pixelsPerInch: Int

        static let `default` = Display(width: 1920, height: 1080, pixelsPerInch: 80)
    }

    static func load(_ name: String) throws -> VMConfig {
        let data = try Data(contentsOf: Paths.config(name))
        return try JSONDecoder().decode(VMConfig.self, from: data)
    }

    func save(_ name: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Paths.config(name))
    }
}
