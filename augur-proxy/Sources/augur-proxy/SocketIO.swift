import Foundation
import AugurProxyCore
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Thin POSIX-socket helpers shared by the CONNECT and SOCKS servers. No
/// third-party networking dependency — the proxy stays a single lightweight
/// static binary that builds on both Linux (Docker host) and macOS (VM host).
enum Sock {
    /// Create, bind, and listen on `addr:port`. An IPv6 `addr` (e.g. "::") binds a
    /// DUAL-STACK socket (IPV6_V6ONLY off) so the proxy is reachable whether the
    /// client connects over IPv4 or IPv6 — needed because Docker Desktop may resolve
    /// host.docker.internal to an IPv6 host-gateway. Returns the listening fd.
    static func listen(addr: String, port: UInt16, backlog: Int32 = 128) throws -> Int32 {
        let isV6 = addr.contains(":")
        let fd = socket(isV6 ? AF_INET6 : AF_INET, sockStreamType, 0)
        guard fd >= 0 else { throw SockError("socket() failed: \(errnoString())") }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        let bindRet: Int32
        if isV6 {
            var off: Int32 = 0  // dual-stack: also accept IPv4 (as v4-mapped)
            setsockopt(fd, ipprotoIPV6, ipv6V6Only, &off, socklen_t(MemoryLayout<Int32>.size))
            var sa6 = sockaddr_in6()
            sa6.sin6_family = sa_family_t(AF_INET6)
            sa6.sin6_port = port.bigEndian
            guard inet_pton(AF_INET6, addr, &sa6.sin6_addr) == 1 else {
                close(fd); throw SockError("bad listen address: \(addr)")
            }
            bindRet = withUnsafePointer(to: &sa6) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        } else {
            var sa = sockaddr_in()
            sa.sin_family = sa_family_t(AF_INET)
            sa.sin_port = port.bigEndian
            guard inet_pton(AF_INET, addr, &sa.sin_addr) == 1 else {
                close(fd); throw SockError("bad listen address: \(addr)")
            }
            bindRet = withUnsafePointer(to: &sa) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard bindRet == 0 else { close(fd); throw SockError("bind(\(addr):\(port)) failed: \(errnoString())") }
        guard Glibc_listen(fd, backlog) == 0 else { close(fd); throw SockError("listen failed: \(errnoString())") }
        return fd
    }

    /// Connect to `host:port`, refusing non-public destinations when `publicOnly`.
    /// Resolves via getaddrinfo and tries addresses in order. Returns a connected fd.
    ///
    /// `lanException` carves a NARROW hole in the private-address guard: when set (the
    /// caller has confirmed `host` is an IP literal an allowlist IP rule explicitly
    /// permits), a destination in a reachable-private range (RFC1918 + CGNAT/Tailscale)
    /// is permitted; loopback, link-local/metadata, and PUBLIC addresses stay blocked
    /// even then — see `isReachablePrivate`. Containment does NOT rest on getaddrinfo
    /// returning the literal: `dialBlocked` re-vets EVERY resolved sockaddr below, so
    /// even if `host` somehow resolved elsewhere, a non-reachable-private result is
    /// still blocked.
    static func connect(host: String, port: UInt16, publicOnly: Bool, lanException: Bool = false) throws -> Int32 {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = sockStreamType
        var res: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(host, String(port), &hints, &res)
        guard rc == 0, let head = res else { throw SockError("resolve \(host) failed") }
        defer { freeaddrinfo(head) }

        var lastErr = "no address"
        var ai: UnsafeMutablePointer<addrinfo>? = head
        while let cur = ai {
            defer { ai = cur.pointee.ai_next }
            if let sa = cur.pointee.ai_addr, dialBlocked(sa, publicOnly: publicOnly, lanException: lanException) {
                lastErr = "destination resolves to a non-public address (blocked)"
                continue
            }
            let fd = socket(cur.pointee.ai_family, cur.pointee.ai_socktype, cur.pointee.ai_protocol)
            if fd < 0 { lastErr = errnoString(); continue }
            if Glibc_connect(fd, cur.pointee.ai_addr, cur.pointee.ai_addrlen) == 0 {
                return fd
            }
            lastErr = errnoString()
            close(fd)
        }
        throw SockError("connect \(host):\(port) failed: \(lastErr)")
    }

    /// Apply a receive timeout (seconds) so a peer that connects but never sends
    /// can't pin a handler thread forever (used while peeking SNI/Host).
    static func setReadTimeout(_ fd: Int32, seconds: Int) {
        var tv = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Read up to `max` bytes. Returns [] on clean EOF, throws on error.
    static func read(_ fd: Int32, max: Int = 65536) throws -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: max)
        let n = buf.withUnsafeMutableBytes { Glibc_read(fd, $0.baseAddress, max) }
        if n < 0 { throw SockError("read: \(errnoString())") }
        return Array(buf[0..<n])
    }

    /// Write all bytes (handles partial writes).
    static func writeAll(_ fd: Int32, _ bytes: [UInt8]) throws {
        var off = 0
        try bytes.withUnsafeBytes { raw in
            while off < bytes.count {
                let n = Glibc_write(fd, raw.baseAddress!.advanced(by: off), bytes.count - off)
                if n <= 0 { throw SockError("write: \(errnoString())") }
                off += n
            }
        }
    }

    /// Copy bytes one way until EOF, then half-close the destination's write side.
    static func splice(from src: Int32, to dst: Int32) {
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = buf.withUnsafeMutableBytes { Glibc_read(src, $0.baseAddress, $0.count) }
            if n <= 0 { break }
            var off = 0
            var failed = false
            buf.withUnsafeBytes { raw in
                while off < n {
                    let w = Glibc_write(dst, raw.baseAddress!.advanced(by: off), n - off)
                    if w <= 0 { failed = true; break }
                    off += w
                }
            }
            if failed { break }
        }
        shutdown(dst, shutWrite)
    }

    /// The single dial gate, as a pure decision over a resolved `sockaddr` (so the
    /// tests exercise it directly):
    ///   - `--allow-private` (publicOnly == false): nothing is blocked.
    ///   - `lanException` (the destination is an IP literal an IP rule explicitly
    ///     permits): allow ONLY a reachable-private address (RFC1918 / CGNAT). A
    ///     PUBLIC IP is blocked here too — an IP rule is for a vetted private/tailnet
    ///     endpoint, not an arbitrary public exfil target (use a domain for those) —
    ///     and so are loopback / link-local / metadata.
    ///   - otherwise (domains, DNS-pinned IPs): the standard guard blocks all private.
    static func dialBlocked(_ sa: UnsafePointer<sockaddr>, publicOnly: Bool, lanException: Bool) -> Bool {
        guard publicOnly else { return false }            // --allow-private: nothing blocked
        if lanException { return !isReachablePrivate(sa) } // explicit IP rule: reachable-private only
        return isPrivate(sa)                               // normal path: block all non-public
    }

    /// True for the private ranges augur will dial under an explicit-IP `lanException`:
    /// RFC1918 + CGNAT/Tailscale IPv4, including the IPv4-mapped IPv6 form. Native IPv6
    /// literals are unsupported as IP rules in v1 (see `Allowlist.parseIPRule`), so the
    /// non-mapped AF_INET6 case returns false. Strictly narrower than `isPrivate` — see
    /// `isReachablePrivateIPv4` for why loopback/link-local/metadata are excluded.
    static func isReachablePrivate(_ sa: UnsafePointer<sockaddr>) -> Bool {
        switch Int32(sa.pointee.sa_family) {
        case AF_INET:
            let v = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }
            return isReachablePrivateIPv4(UInt8(v >> 24), UInt8((v >> 16) & 0xff),
                                          UInt8((v >> 8) & 0xff), UInt8(v & 0xff))
        case AF_INET6:
            return sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { p in
                var addr = p.pointee.sin6_addr
                let b = withUnsafeBytes(of: &addr) { Array($0) }
                // Only IPv4-mapped (::ffff:a.b.c.d) is classified; native IPv6 is not a
                // valid IP rule in v1, so anything else is not reachable-private.
                if b[0...9].allSatisfy({ $0 == 0 }), b[10] == 0xff, b[11] == 0xff {
                    return isReachablePrivateIPv4(b[12], b[13], b[14], b[15])
                }
                return false
            }
        default:
            return false
        }
    }

    /// True for any destination that is NOT a globally-routable public address, so
    /// the proxy refuses to be tricked into reaching host-local / LAN / internal
    /// services (SSRF) — even via an allowlisted name that resolves to such an IP.
    static func isPrivate(_ sa: UnsafePointer<sockaddr>) -> Bool {
        switch Int32(sa.pointee.sa_family) {
        case AF_INET:
            let v = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }
            return isPrivateV4(UInt8(v >> 24), UInt8((v >> 16) & 0xff),
                               UInt8((v >> 8) & 0xff), UInt8(v & 0xff))
        case AF_INET6:
            return sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { p in
                var addr = p.pointee.sin6_addr
                let b = withUnsafeBytes(of: &addr) { Array($0) }
                // First 10 bytes zero: ::, ::1 (loopback), IPv4-mapped (::ffff:0:0/96)
                // and IPv4-compatible (deprecated) — classify the embedded v4 so a
                // mapped 127.0.0.1 / 10.x can't slip past as "public IPv6".
                if b[0...9].allSatisfy({ $0 == 0 }) {
                    if b[10] == 0xff && b[11] == 0xff { return isPrivateV4(b[12], b[13], b[14], b[15]) }
                    return true   // ::, ::1, v4-compat — never public
                }
                if b[0] == 0x00 && b[1] == 0x64 && b[2] == 0xff && b[3] == 0x9b { return true } // 64:ff9b::/96 NAT64
                if b[0] == 0xfe && (b[1] & 0xc0) == 0x80 { return true } // fe80::/10 link-local
                if (b[0] & 0xfe) == 0xfc { return true } // fc00::/7 ULA
                if b[0] == 0xff { return true } // multicast
                return false
            }
        default:
            return true   // unknown family: refuse
        }
    }

    /// IPv4 non-public classification, shared by the AF_INET and IPv4-mapped paths.
    static func isPrivateV4(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) -> Bool {
        switch a {
        case 0:          return true               // 0.0.0.0/8
        case 10:         return true               // 10/8 private
        case 127:        return true               // loopback
        case 100:        return b >= 64 && b <= 127 // 100.64/10 CGNAT (Tailscale etc.)
        case 169:        return b == 254           // 169.254/16 link-local
        case 172:        return b >= 16 && b <= 31  // 172.16/12 private
        case 192:        return (b == 168)          // 192.168/16 private
                              || (b == 0 && c == 0)  // 192.0.0/24 IETF protocol
        case 198:        return b == 18 || b == 19   // 198.18/15 benchmark
        case 255:        return b == 255 && c == 255 && d == 255 // broadcast
        default:         return a >= 240            // 240/4 reserved (incl. 255/8)
        }
    }
}

struct SockError: Error, CustomStringConvertible {
    let message: String
    init(_ m: String) { message = m }
    var description: String { message }
}

func errnoString() -> String { String(cString: strerror(errno)) }

// Cross-platform aliases (Glibc vs Darwin differ in a few symbol shapes).
#if canImport(Glibc)
let sockStreamType = Int32(SOCK_STREAM.rawValue)
let shutWrite = Int32(SHUT_WR)
let ipprotoIPV6 = Int32(IPPROTO_IPV6)
let ipv6V6Only = Int32(IPV6_V6ONLY)
let Glibc_listen = Glibc.listen
let Glibc_connect = Glibc.connect
let Glibc_read = Glibc.read
let Glibc_write = Glibc.write
#elseif canImport(Darwin)
let sockStreamType = SOCK_STREAM
let shutWrite = SHUT_WR
let ipprotoIPV6 = Int32(IPPROTO_IPV6)
let ipv6V6Only = Int32(IPV6_V6ONLY)
let Glibc_listen = Darwin.listen
let Glibc_connect = Darwin.connect
let Glibc_read = Darwin.read
let Glibc_write = Darwin.write
#endif
