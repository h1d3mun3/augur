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
