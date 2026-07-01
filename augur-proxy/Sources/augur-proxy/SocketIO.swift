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
    static func connect(host: String, port: UInt16, publicOnly: Bool) throws -> Int32 {
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
            if publicOnly, let sa = cur.pointee.ai_addr, isPrivate(sa) {
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

    /// True for any destination that is NOT a globally-routable public address, so
    /// the proxy refuses to be tricked into reaching host-local / LAN / internal
    /// services (SSRF) — even via an allowlisted name that resolves to such an IP.
    static func isPrivate(_ sa: UnsafePointer<sockaddr>) -> Bool {
        switch Int32(sa.pointee.sa_family) {
        case AF_INET:
            let v = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }
            return AddressPolicy.isPrivateV4(UInt8(v >> 24), UInt8((v >> 16) & 0xff),
                                             UInt8((v >> 8) & 0xff), UInt8(v & 0xff))
        case AF_INET6:
            return sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { p in
                var addr = p.pointee.sin6_addr
                let b = withUnsafeBytes(of: &addr) { Array($0) }
                return AddressPolicy.isPrivateV6(b)
            }
        default:
            return true   // unknown family: refuse
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
