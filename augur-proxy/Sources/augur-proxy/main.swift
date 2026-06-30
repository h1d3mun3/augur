import Foundation
import AugurProxyCore
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

// augur-proxy — host-side egress filter.
//
//   augur-proxy --allowlist <path> [--listen 127.0.0.1]
//               [--http-port 0] [--socks-port 0]
//               [--log <path>] [--pidfile <path>] [--allow-private]
//
// At least one of --http-port / --socks-port must be non-zero. The allowlist file
// must exist (fail-closed: we refuse to run with no policy). Both datapaths share
// one Filter so Docker and macOS behave identically.
//
// Security contract for this filter: docs/security-reviews/INVARIANTS.md — a change
// that breaks an invariant there is a contract change (see that file's header).

struct Options {
    var allowlist = ""
    var listen = "127.0.0.1"
    var httpPort: UInt16 = 0
    var socksPort: UInt16 = 0
    var logPath: String? = nil
    var pidfile: String? = nil
    var publicOnly = true
}

func parseOptions() -> Options {
    var o = Options()
    var args = Array(CommandLine.arguments.dropFirst())
    func next(_ flag: String) -> String {
        guard !args.isEmpty else { die("missing value for \(flag)") }
        return args.removeFirst()
    }
    while !args.isEmpty {
        let a = args.removeFirst()
        switch a {
        case "--allowlist":   o.allowlist = next(a)
        case "--listen":      o.listen = next(a)
        case "--http-port":   o.httpPort = parsePort(next(a), a)
        case "--socks-port":  o.socksPort = parsePort(next(a), a)
        case "--log":         o.logPath = next(a)
        case "--pidfile":     o.pidfile = next(a)
        case "--allow-private": o.publicOnly = false
        case "-h", "--help":  printUsage(); exit(0)
        default: die("unknown argument: \(a)")
        }
    }
    return o
}

func printUsage() {
    FileHandle.standardError.write(Data("""
    usage: augur-proxy --allowlist <path> [--listen 127.0.0.1]
                       [--http-port N] [--socks-port N]
                       [--log <path>] [--pidfile <path>] [--allow-private]
    \n
    """.utf8))
}

func die(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("augur-proxy: \(msg)\n".utf8))
    exit(2)
}

func parsePort(_ s: String, _ flag: String) -> UInt16 {
    guard let v = UInt16(s) else { die("bad value for \(flag): \(s)") }
    return v
}

/// Read + parse the allowlist file. Returns nil if the file can't be read (the
/// caller fails closed by refusing to start / keeping the old policy on reload).
func loadAllowlist(_ path: String) -> Allowlist? {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
    return Allowlist(confText: text)
}

// ── Boot ──────────────────────────────────────────────────────────────────────

let opts = parseOptions()
guard !opts.allowlist.isEmpty else { die("--allowlist <path> is required") }
guard opts.httpPort != 0 || opts.socksPort != 0 else { die("set --http-port and/or --socks-port") }

guard let initialList = loadAllowlist(opts.allowlist) else {
    die("cannot read allowlist file: \(opts.allowlist) (refusing to start — fail closed)")
}

let log = DecisionLog(path: opts.logPath, alsoStderr: opts.logPath == nil)
let filter = Filter(allowlist: initialList)
let server = ProxyServer(filter: filter, log: log, publicOnly: opts.publicOnly)

if initialList.isEmpty {
    log.info("allowlist is empty — all egress will be DENIED")
}

// Pidfile (same convention as augur-vm's Registry: a live pid means running).
if let pidfile = opts.pidfile {
    try? "\(getpid())".write(toFile: pidfile, atomically: true, encoding: .utf8)
}

func cleanup() {
    if let pidfile = opts.pidfile { try? FileManager.default.removeItem(atPath: pidfile) }
}

// Declared before first use: file-scope `var`s in main.swift initialize in
// top-level execution order, so using this below its declaration reads uninit
// storage and crashes.
var signalSources: [DispatchSourceSignal] = []

for sig in [SIGINT, SIGTERM] {
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler { cleanup(); exit(0) }
    src.resume()
    signalSources.append(src)
}
// SIGPIPE would kill us when a peer closes mid-write; ignore and handle via errno.
signal(SIGPIPE, SIG_IGN)

// Hot-reload: poll the file's mtime; on change, reparse. A parse that yields an
// empty/garbage policy still applies (fail-closed); an unreadable file keeps the
// previous policy so we never fall open.
DispatchQueue.global().async {
    // Local (not a global func) so Swift's concurrency checker doesn't flag it as a
    // "concurrently-executed global function".
    func fileMtime(_ path: String) -> Double {
        var st = stat()
        guard stat(path, &st) == 0 else { return -1 }
        #if canImport(Darwin)
        return Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
        #else
        return Double(st.st_mtim.tv_sec) + Double(st.st_mtim.tv_nsec) / 1e9
        #endif
    }
    var last = fileMtime(opts.allowlist)
    while true {
        _ = sleep(2)
        let now = fileMtime(opts.allowlist)
        if now != last {
            last = now
            if let fresh = loadAllowlist(opts.allowlist) {
                filter.reload(fresh)
                log.info("allowlist reloaded (\(fresh.isEmpty ? "empty — DENY all" : "ok"))")
            } else {
                log.info("allowlist became unreadable — keeping previous policy")
            }
        }
        filter.pins.sweep()
    }
}

do {
    if opts.httpPort != 0 {
        try server.serve(addr: opts.listen, port: opts.httpPort, name: "http-connect") { fd, client in
            server.handleHTTP(fd, client: client)
        }
    }
    if opts.socksPort != 0 {
        try server.serve(addr: opts.listen, port: opts.socksPort, name: "socks5") { fd, client in
            server.handleSocks(fd, client: client)
        }
    }
} catch {
    die("\(error)")
}

log.info("augur-proxy ready (pid \(getpid()))")
dispatchMain()
