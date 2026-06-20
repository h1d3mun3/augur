import Foundation

#if canImport(Darwin)
import Darwin
#endif

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

struct VMInfo {
    let name: String
    let running: Bool
}

/// Lightweight error carrying a human-readable message.
struct CLIError: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}

enum Registry {
    static func exists(_ name: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: Paths.bundle(name).path, isDirectory: &isDir) && isDir.boolValue
    }

    static func list() -> [VMInfo] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: Paths.root, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map { VMInfo(name: $0.lastPathComponent, running: isRunning($0.lastPathComponent)) }
            .sorted { $0.name < $1.name }
    }

    /// A VM is "running" if its pidfile points at a live process.
    static func isRunning(_ name: String) -> Bool {
        guard let s = try? String(contentsOf: Paths.pid(name), encoding: .utf8),
              let pid = pid_t(s.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        // signal 0 probes existence without delivering a signal.
        return kill(pid, 0) == 0
    }
}
