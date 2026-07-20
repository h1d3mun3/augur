import Foundation

/// Append-only structured logging of allow/deny decisions. Deny lines are the
/// signal a user acts on (which domain to add to `.augur/allowlist.conf`), so they are
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
        write("ALLOW client=\(client) dst=\(Self.sanitize(host)):\(port) via=\(via)", onlyStderr: true, skipFile: true)
    }

    // `host` here may be a raw, fully attacker-controlled SOCKS domain (atyp=0x03) that
    // was never validated — that's *why* it's being denied. Sanitize it before it
    // reaches the append-only decision log: unescaped CR/LF would let a crafted domain
    // forge or split lines in the log a user greps to decide what to allowlist (#37).
    public func deny(client: String, host: String, port: UInt16, reason: String) {
        write("DENY  client=\(client) dst=\(Self.sanitize(host)):\(port) reason=\(reason)", onlyStderr: false, skipFile: false)
    }

    public func info(_ message: String) {
        write("INFO  \(message)", onlyStderr: false, skipFile: false)
    }

    /// Operational / liveness lines (capacity, thread pressure). Stderr-only and never
    /// written to the decision-log file, so they can't pollute the greppable DENY record
    /// the CLI parses. Mirrors `allow()`'s channel — use this, not `info()`, for anything
    /// high-frequency or contention-driven.
    public func status(_ message: String) {
        write("INFO  \(message)", onlyStderr: true, skipFile: true)
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

    /// Escape C0 controls (CR, LF, etc.) and DEL so untrusted text can't forge or split
    /// a log line. `\` is escaped first so the `\xNN` markers this inserts can't
    /// themselves be misread as escapes of attacker-supplied text.
    static func sanitize(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\\":
                out += "\\\\"
            case _ where scalar.value < 0x20 || scalar.value == 0x7F:
                out += String(format: "\\x%02x", scalar.value)
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}
