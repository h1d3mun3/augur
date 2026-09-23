import Foundation

/// On-disk layout of a VM:
///   ~/.augur/vms/<name>/
///     config.json   cpu, memory, macAddress, hardwareModel(b64), machineIdentifier(b64)
///     disk.img      main APFS-clonable disk image
///     nvram.bin     VZMacAuxiliaryStorage
///     run.pid       pidfile/lock written by `run`; used for running-state + stop
enum Paths {
    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    static var root: URL { home.appendingPathComponent(".augur/vms", isDirectory: true) }
    static func bundle(_ name: String) -> URL { root.appendingPathComponent(name, isDirectory: true) }
    static func config(_ name: String) -> URL { bundle(name).appendingPathComponent("config.json") }
    static func disk(_ name: String) -> URL { bundle(name).appendingPathComponent("disk.img") }
    static func nvram(_ name: String) -> URL { bundle(name).appendingPathComponent("nvram.bin") }
    static func pid(_ name: String) -> URL { bundle(name).appendingPathComponent("run.pid") }
}
