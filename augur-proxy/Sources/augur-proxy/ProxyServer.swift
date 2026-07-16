import Foundation
import AugurProxyCore
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Runs the listening sockets and brokers each connection through `Filter`. A
/// thread per connection keeps the implementation dependency-free; augur is a
/// single-developer tool, so concurrency is modest and this is plenty.
final class ProxyServer {
    let filter: Filter
    let log: DecisionLog
    let publicOnly: Bool
    /// Cap the number of concurrently active connections. Each in-flight connection
    /// costs ~2 threads (the handler plus the splice peer it spawns), so the process
    /// holds at most ~2× this many proxy threads — keep the value safely below the
    /// macOS per-process thread ceiling (`sysctl kern.num_taskthreads`). The accept
    /// loop blocks when the cap is reached, using the kernel's listen backlog as the
    /// wait queue. This bounds the thread growth that froze the proxy under heavy
    /// parallel workloads (e.g. many simultaneous agent tool calls). The value is
    /// tunable (--max-connections / AUGUR_PROXY_MAX_CONNECTIONS, see main.swift)
    /// because the right ceiling depends on the host and the workload's concurrency.
    private let connectionCap: DispatchSemaphore
    /// Observability sibling of `connectionCap` (which is the actual limiter): tracks how
    /// many handlers are running and logs an edge-triggered line when the ceiling is hit
    /// or cleared, so a saturated proxy is visible instead of just silently slow.
    private let gauge: InFlightGauge

    init(filter: Filter, log: DecisionLog, publicOnly: Bool, maxConnections: Int = 128) {
        self.filter = filter
        self.log = log
        self.publicOnly = publicOnly
        let cap = max(1, maxConnections)
        self.connectionCap = DispatchSemaphore(value: cap)
        self.gauge = InFlightGauge(ceiling: cap, log: log)
    }

    /// Start a listener and dispatch accepted connections to `handler` on threads.
    func serve(addr: String, port: UInt16, name: String, handler: @escaping (Int32, String) -> Void) throws {
        let listenFD = try Sock.listen(addr: addr, port: port)
        log.info("\(name) listening on \(addr):\(port)")
        Thread.detachNewThread { [weak self] in
            while true {
                var ss = sockaddr_storage()
                var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
                let cfd = withUnsafeMutablePointer(to: &ss) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(listenFD, $0, &len) }
                }
                if cfd < 0 { continue }
                let client = Self.peerIP(&ss)
                guard let s = self else { close(cfd); return }
                // Block the accept loop (not the caller) when the cap is full.
                // The kernel's listen backlog queues further SYNs while we wait.
                s.connectionCap.wait()
                // The accept loop owns the slot release: if the worker thread can't be
                // started (the exact thread-pressure condition the cap guards against),
                // spawnDetached returns false and we reclaim the slot + close the fd
                // HERE. Were the release left to a worker that never ran, the slot would
                // leak and the accept loop would eventually deadlock on connectionCap.
                let started = PosixThread.spawnDetached {
                    s.gauge.acquired()
                    defer { s.gauge.released(); s.connectionCap.signal() }
                    handler(cfd, client)
                }
                if !started {
                    // Liveness event, not a decision — keep it off the DENY log file.
                    s.log.status("could not start handler thread; dropping connection from \(client)")
                    close(cfd)
                    s.connectionCap.signal()
                }
            }
        }
    }

    // MARK: - HTTP CONNECT / forward proxy (Apple Container datapath)

    func handleHTTP(_ cfd: Int32, client: String) {
        defer { close(cfd) }
        Sock.setReadTimeout(cfd, seconds: 15)   // a silent client can't pin a thread
        guard let (head, leftover) = readHTTPHead(cfd) else { return }
        guard let req = HTTPProxyRequest.parse(head: head) else {
            try? Sock.writeAll(cfd, Array("HTTP/1.1 400 Bad Request\r\n\r\n".utf8)); return
        }
        let dest = req.destination
        let verdict = filter.decide(dest, client: client)
        guard verdict.allowed else {
            log.deny(client: client, host: dest.host, port: dest.port, reason: verdict.reason)
            try? Sock.writeAll(cfd, Array("HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n".utf8))
            return
        }
        guard let upstream = try? Sock.connect(host: dest.host, port: dest.port, publicOnly: publicOnly) else {
            log.deny(client: client, host: dest.host, port: dest.port, reason: "upstream-unreachable")
            try? Sock.writeAll(cfd, Array("HTTP/1.1 502 Bad Gateway\r\n\r\n".utf8))
            return
        }
        defer { close(upstream) }
        log.allow(client: client, host: dest.host, port: dest.port, via: "http")

        switch req.kind {
        case .connect:
            try? Sock.writeAll(cfd, Array("HTTP/1.1 200 Connection Established\r\n\r\n".utf8))
            if !leftover.isEmpty { try? Sock.writeAll(upstream, leftover) }  // rare: data before 200
        case .absolute(let method, let target):
            // Rewrite absolute-URI request line to origin-form, then replay the head
            // and any coalesced body bytes upstream.
            let originHead = rewriteToOriginForm(head: head, method: method, target: target)
            try? Sock.writeAll(upstream, Array(originHead.utf8))
            if !leftover.isEmpty { try? Sock.writeAll(upstream, leftover) }
        }
        spliceBoth(cfd, upstream)
    }

    // MARK: - SOCKS5 (macOS datapath: gvproxy forwards guest TCP here, by name)

    func handleSocks(_ cfd: Int32, client: String) {
        defer { close(cfd) }
        Sock.setReadTimeout(cfd, seconds: 15)   // bound the handshake/peek wait
        // Greeting: VER NMETHODS METHODS...
        guard let greeting = try? Sock.read(cfd), greeting.count >= 2, greeting[0] == Socks5.version else { return }
        try? Sock.writeAll(cfd, [Socks5.version, Socks5.noAuth])

        // Request — accumulate until parseable.
        var buf = [UInt8]()
        var parsed: Destination?
        for _ in 0..<8 {
            guard let chunk = try? Sock.read(cfd), !chunk.isEmpty else { break }
            buf += chunk
            if let (dest, _) = Socks5.parseRequest(buf) { parsed = dest; break }
        }
        guard let dest = parsed else {
            try? Sock.writeAll(cfd, Socks5.reply(.generalFailure)); return
        }

        // The macOS datapath (gvproxy) only knows the destination IP, so it hands us
        // an IP-literal SOCKS request. We can't allowlist an IP by name, so we accept
        // the SOCKS connection, peek the first segment for a TLS SNI / HTTP Host,
        // allowlist by that domain, and dial UPSTREAM BY NAME (re-resolving) — so a
        // spoofed SNI just reaches the real allowed host and cannot exfil elsewhere.
        if dest.isIPLiteral {
            try? Sock.writeAll(cfd, Socks5.reply(.succeeded))   // client now sends ClientHello
            let (peekedHost, buffered) = peekHostname(cfd)
            guard let host = peekedHost else {
                log.deny(client: client, host: dest.host, port: dest.port, reason: "no-sni")
                return   // close → client sees a reset (effective deny)
            }
            let verdict = filter.decide(Destination(host: host, port: dest.port, isIPLiteral: false), client: client)
            guard verdict.allowed else {
                log.deny(client: client, host: host, port: dest.port, reason: verdict.reason)
                return
            }
            guard let upstream = try? Sock.connect(host: host, port: dest.port, publicOnly: publicOnly) else {
                log.deny(client: client, host: host, port: dest.port, reason: "upstream-unreachable")
                return
            }
            defer { close(upstream) }
            log.allow(client: client, host: host, port: dest.port, via: "socks-sni")
            try? Sock.writeAll(upstream, buffered)   // replay the peeked bytes
            spliceBoth(cfd, upstream)
            return
        }

        // Named destination (SOCKS atyp=domain, e.g. a future by-name caller).
        let verdict = filter.decide(dest, client: client)
        guard verdict.allowed else {
            log.deny(client: client, host: dest.host, port: dest.port, reason: verdict.reason)
            try? Sock.writeAll(cfd, Socks5.reply(.notAllowed)); return
        }
        guard let upstream = try? Sock.connect(host: dest.host, port: dest.port, publicOnly: publicOnly) else {
            log.deny(client: client, host: dest.host, port: dest.port, reason: "upstream-unreachable")
            try? Sock.writeAll(cfd, Socks5.reply(.hostUnreachable)); return
        }
        defer { close(upstream) }
        log.allow(client: client, host: dest.host, port: dest.port, via: "socks")
        try? Sock.writeAll(cfd, Socks5.reply(.succeeded))
        spliceBoth(cfd, upstream)
    }

    /// Read the first request segment and recover the destination domain from a TLS
    /// ClientHello SNI (443) or an HTTP `Host:` header (80). Returns the host (nil if
    /// none — fail closed) and ALL bytes read, so the caller can replay them upstream.
    /// Accumulates across reads in case the ClientHello spans segments.
    func peekHostname(_ cfd: Int32, limit: Int = 16 * 1024) -> (String?, [UInt8]) {
        // Bound the wait: a guest that connects but never sends a ClientHello must
        // not pin this thread. After the timeout we fall through and deny.
        Sock.setReadTimeout(cfd, seconds: 10)
        defer { Sock.setReadTimeout(cfd, seconds: 0) }   // clear for the splice phase
        var buf = [UInt8]()
        while buf.count < limit {
            guard let chunk = try? Sock.read(cfd), !chunk.isEmpty else { break }
            buf += chunk
            if let sni = TLSClientHello.serverName(fromRecord: buf) { return (sni, buf) }
            if let host = HTTPProxyRequest.hostFromOriginForm(buf) { return (host, buf) }
            // Heuristics to stop early: a TLS record that isn't a handshake, or a
            // complete HTTP head with no Host — both unrecoverable.
            if buf.first.map({ $0 != 0x16 }) == true, buf.contains(0x0A),
               HTTPProxyRequest.hostFromOriginForm(buf) == nil, looksLikeCompleteHTTPHead(buf) {
                break
            }
        }
        return (nil, buf)
    }

    private func looksLikeCompleteHTTPHead(_ b: [UInt8]) -> Bool {
        guard b.count >= 4 else { return false }
        for i in 0...(b.count - 4) where b[i]==13 && b[i+1]==10 && b[i+2]==13 && b[i+3]==10 { return true }
        return false
    }

    // MARK: - Helpers

    /// Read an HTTP request head (up to and including the blank line) plus any
    /// bytes that arrived in the same read AFTER it — a request body (POST/PUT) is
    /// often coalesced with the head, and the caller must forward those leftover
    /// bytes upstream too or the request hangs / loses its body.
    private func readHTTPHead(_ fd: Int32, limit: Int = 64 * 1024) -> (head: String, leftover: [UInt8])? {
        var data = [UInt8]()
        while data.count < limit {
            guard let chunk = try? Sock.read(fd), !chunk.isEmpty else { break }
            data += chunk
            if let r = findHeaderEnd(data) {
                return (String(decoding: data[0..<r], as: UTF8.self), Array(data[r...]))
            }
        }
        return data.isEmpty ? nil : (String(decoding: data, as: UTF8.self), [])
    }

    private func findHeaderEnd(_ b: [UInt8]) -> Int? {
        guard b.count >= 4 else { return nil }
        for i in 0...(b.count - 4) where b[i]==13 && b[i+1]==10 && b[i+2]==13 && b[i+3]==10 {
            return i + 4
        }
        return nil
    }

    private func rewriteToOriginForm(head: String, method: String, target: String) -> String {
        // Replace the absolute target with the origin-form path in the request line.
        guard let schemeRange = target.range(of: "://") else { return head }
        let afterScheme = target[schemeRange.upperBound...]
        let path = afterScheme.firstIndex(of: "/").map { String(afterScheme[$0...]) } ?? "/"
        guard let firstLineEnd = head.range(of: "\r\n") else { return head }
        let rest = head[firstLineEnd.upperBound...]
        return "\(method) \(path) HTTP/1.1\r\n\(rest)"
    }

    /// Bidirectional copy: one direction on this thread, the other on a new one.
    private func spliceBoth(_ a: Int32, _ b: Int32) {
        Sock.setReadTimeout(a, seconds: 0)   // established tunnel: no read timeout
        // Keepalives detect dead peers (crashed host, network partition) so stalled
        // splice threads unblock instead of holding their slot in connectionCap forever.
        Sock.setKeepAlive(a)
        Sock.setKeepAlive(b)
        let done = DispatchSemaphore(value: 0)
        // Use the CHECKED spawn for the a→b copier. Thread.detachNewThread silently no-ops
        // when pthread_create hits the per-process thread ceiling (EAGAIN) — done.signal()
        // would then never fire, this thread would block on done.wait() below forever, and
        // its connectionCap slot would leak, re-creating the accept-loop deadlock the cap
        // exists to prevent (just one layer lower). If the copier can't start, tear the
        // tunnel down: the caller's defers close both fds and the accept loop reclaims the
        // slot. Nothing is splicing yet (the b→a copy below hasn't started), so returning
        // here is a clean drop, not a half-open tunnel.
        guard PosixThread.spawnDetached({ Sock.splice(from: a, to: b); done.signal() }) else {
            log.status("splice copier could not start under thread pressure; dropping tunnel")
            return
        }
        Sock.splice(from: b, to: a)
        done.wait()
    }

    static func peerIP(_ ss: inout sockaddr_storage) -> String {
        var buf = [CChar](repeating: 0, count: 64)
        if Int32(ss.ss_family) == AF_INET {
            withUnsafePointer(to: &ss) {
                $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    var a = $0.pointee.sin_addr
                    inet_ntop(AF_INET, &a, &buf, socklen_t(buf.count))
                }
            }
        } else if Int32(ss.ss_family) == AF_INET6 {
            withUnsafePointer(to: &ss) {
                $0.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                    var a = $0.pointee.sin6_addr
                    inet_ntop(AF_INET6, &a, &buf, socklen_t(buf.count))
                }
            }
        }
        return String(cString: buf)
    }
}

/// Thread-safe in-flight connection gauge, purely for observability — the actual limiter
/// is `ProxyServer.connectionCap` (a DispatchSemaphore). It emits ONE stderr-only line when
/// running handlers reach the ceiling and ONE when the episode clears, so a saturated proxy
/// is visible to an operator without polluting the greppable DENY log file (both go through
/// `DecisionLog.status`).
///
/// Hysteresis, not a bare edge trigger: once at capacity it stays "latched" until the count
/// drains to a low-water mark (half the ceiling) before it will log a fresh episode. Without
/// it, a proxy hovering at the ceiling would thrash the log as the count oscillates across
/// the boundary by one. The status line is emitted OUTSIDE the lock so the stderr write never
/// serializes the accept/handler paths.
final class InFlightGauge {
    private let lock = NSLock()
    private var count = 0
    private var latched = false
    private let ceiling: Int
    private let lowWater: Int
    private let log: DecisionLog

    init(ceiling: Int, log: DecisionLog) {
        self.ceiling = ceiling
        self.lowWater = ceiling / 2   // re-arm only after a genuine drain, not a 1-slot dip
        self.log = log
    }

    func acquired() {
        lock.lock()
        count += 1
        let announce = count >= ceiling && !latched
        if announce { latched = true }
        let now = count
        lock.unlock()
        if announce {
            log.status("reached capacity: \(now)/\(ceiling) connections in-flight; further connections queue on the listen backlog until a slot frees (raise --max-connections / AUGUR_PROXY_MAX_CONNECTIONS if sustained)")
        }
    }

    func released() {
        lock.lock()
        count -= 1
        let announce = latched && count <= lowWater
        if announce { latched = false }
        let now = count
        lock.unlock()
        if announce {
            log.status("recovered: \(now)/\(ceiling) connections in-flight")
        }
    }
}
