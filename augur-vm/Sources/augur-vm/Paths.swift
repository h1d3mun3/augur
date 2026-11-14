import Foundation

/// On-disk layout of a VM:
///   ~/.augur/vms/<name>/
///     config.json   cpu, memory, macAddress, hardwareModel(b64), machineIdentifier(b64)
///     disk.img      main APFS-clonable disk image
///     nvram.bin     VZMacAuxiliaryStorage
///     run.pid       pidfile/lock written by `run`; used for running-state + stop
///     run.id        a random id for the current boot, written by `run` before run.pid and
///                   removed just before it; the `augur` script ties per-boot host records to it
///     admin-password  the guest admin account's password (mode 600), written and read by the
///                   `augur` script, never by augur-vm; `clone` copies it with the rest
enum Paths {
    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    static var root: URL { home.appendingPathComponent(".augur/vms", isDirectory: true) }
    static func bundle(_ name: String) -> URL { root.appendingPathComponent(name, isDirectory: true) }
    static func config(_ name: String) -> URL { bundle(name).appendingPathComponent("config.json") }
    static func disk(_ name: String) -> URL { bundle(name).appendingPathComponent("disk.img") }
    static func nvram(_ name: String) -> URL { bundle(name).appendingPathComponent("nvram.bin") }
    static func pid(_ name: String) -> URL { bundle(name).appendingPathComponent("run.pid") }
    static func runID(_ name: String) -> URL { bundle(name).appendingPathComponent("run.id") }
}
