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

    init(filter: Filter, log: DecisionLog, publicOnly: Bool) {
        self.filter = filter
        self.log = log
        self.publicOnly = publicOnly
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
                guard self != nil else { close(cfd); return }
                Thread.detachNewThread { handler(cfd, client) }
            }
        }
    }

    // MARK: - HTTP CONNECT / forward proxy (Docker datapath)

    func handleHTTP(_ cfd: Int32, client: String) {
        defer { close(cfd) }
        Sock.setReadTimeout(cfd, seconds: 15)   // a silent client can't pin a thread
        guard let (head, leftover) = readHTTPHead(cfd) else { return }
        guard let req = HTTPProxyRequest.parse(head: head) else {
            try? Sock.writeAll(cfd, Array("HTTP/1.1 400 Bad Request\r\n\r\n".utf8)); return
        }
        let dest = req.destination
        let decision = filter.decideDial(dest, client: client)
        guard decision.verdict.allowed else {
            log.deny(client: client, host: dest.host, port: dest.port, reason: decision.verdict.reason)
            try? Sock.writeAll(cfd, Array("HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n".utf8))
            return
        }
        // An explicitly-listed IP endpoint may be a LAN/Tailscale address (e.g. a local
        // Ollama); permit the reachable-private dial for it while keeping the SSRF guard
        // for everything else.
        guard let upstream = try? Sock.connect(host: dest.host, port: dest.port, publicOnly: publicOnly, lanException: decision.explicitIP) else {
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
            let decision = filter.decideDial(dest, client: client)
            // An explicitly-listed IP endpoint (e.g. a LAN/Tailscale Ollama from an
            // augur profile): honor the IP rule directly — there is no name to recover —
            // and permit the reachable-private dial. No SNI/Host peek, so plain-HTTP-to-IP works.
            if decision.explicitIP && decision.verdict.allowed {
                guard let upstream = try? Sock.connect(host: dest.host, port: dest.port, publicOnly: publicOnly, lanException: true) else {
                    log.deny(client: client, host: dest.host, port: dest.port, reason: "upstream-unreachable")
                    try? Sock.writeAll(cfd, Socks5.reply(.hostUnreachable)); return
                }
                defer { close(upstream) }
                try? Sock.writeAll(cfd, Socks5.reply(.succeeded))
                log.allow(client: client, host: dest.host, port: dest.port, via: "socks-ip")
                spliceBoth(cfd, upstream)
                return
            }
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
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread { Sock.splice(from: a, to: b); done.signal() }
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
