import Foundation

/// Append-only structured logging of allow/deny decisions. Deny lines are the
/// signal a user acts on (which domain to add to `.augur.conf`), so they are
/// formatted to be greppable and the proxy also surfaces recent denies to the CLI.
public final class DecisionLog {
    private let handle: FileHandle?
    private let lock = NSLock()
    private let toStderr: Bool

    /// `path` nil → log to stderr only (useful for foreground/debug runs).
    public init(path: String?, alsoStderr: Bool = false) {
        self.toStderr = alsoStderr || path == nil
        if let path {
            let fm = FileManager.default
            if !fm.fileExists(atPath: path) {
                _ = fm.createFile(atPath: path, contents: nil)
            }
            self.handle = FileHandle(forWritingAtPath: path)
            _ = try? self.handle?.seekToEnd()
        } else {
            self.handle = nil
        }
    }

    public func allow(client: String, host: String, port: UInt16, via: String) {
        // Allows are high-volume; keep them out of the file, only emit when asked.
        write("ALLOW client=\(client) dst=\(host):\(port) via=\(via)", onlyStderr: true, skipFile: true)
    }

    public func deny(client: String, host: String, port: UInt16, reason: String) {
        write("DENY  client=\(client) dst=\(host):\(port) reason=\(reason)", onlyStderr: false, skipFile: false)
    }

    public func info(_ message: String) {
        write("INFO  \(message)", onlyStderr: false, skipFile: false)
    }

    private func write(_ body: String, onlyStderr: Bool, skipFile: Bool) {
        let line = "\(Self.timestamp()) \(body)\n"
        lock.lock(); defer { lock.unlock() }
        if !skipFile, let handle { try? handle.write(contentsOf: Data(line.utf8)) }
        if toStderr || onlyStderr { FileHandle.standardError.write(Data(line.utf8)) }
    }

    static func timestamp() -> String {
        let f = ISO8601DateFormatter()
        return f.string(from: Date())
    }
}
