import Foundation

#if canImport(Darwin)
import Darwin
#endif

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
