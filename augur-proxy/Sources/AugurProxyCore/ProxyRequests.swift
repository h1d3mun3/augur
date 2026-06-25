import Foundation

/// A connection's intended destination, as learned from the proxy protocol.
public struct Destination: Equatable {
    public let host: String      // hostname, or IP-literal string for atyp ip
    public let port: UInt16
    public let isIPLiteral: Bool
    public init(host: String, port: UInt16, isIPLiteral: Bool) {
        self.host = host
        self.port = port
        self.isIPLiteral = isIPLiteral
    }
}

// MARK: - HTTP forward proxy (Docker datapath)

/// Parses the first request line a client sends to an HTTP forward proxy. We only
/// need the destination authority; the rest of the headers are tunneled (CONNECT)
/// or forwarded (absolute-URI) unchanged.
public enum HTTPProxyRequest {
    public enum Kind: Equatable {
        case connect              // CONNECT host:port  → blind TLS/TCP tunnel
        case absolute(method: String, target: String)  // GET http://host/… → forward
    }

    public struct Parsed: Equatable {
        public let kind: Kind
        public let destination: Destination
    }

    /// Parse the request head (everything up to and including the blank line).
    /// Returns nil on anything malformed → caller denies (fail-closed).
    public static func parse(head: String) -> Parsed? {
        // Scan on UTF-8 bytes, not Characters: Swift fuses a CRLF into ONE grapheme
        // cluster, so a Character-level search for "\r"/"\n" never matches "\r\n".
        let bytes = Array(head.utf8)
        guard let nl = bytes.firstIndex(where: { $0 == 0x0D || $0 == 0x0A }) else { return nil }
        let requestLine = String(decoding: bytes[0..<nl], as: UTF8.self)
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0]).uppercased()
        let target = String(parts[1])

        if method == "CONNECT" {
            guard let dest = parseAuthority(target, defaultPort: 443) else { return nil }
            return Parsed(kind: .connect, destination: dest)
        }
        // Absolute-form: scheme://host[:port]/path
        guard let schemeRange = target.range(of: "://") else { return nil }
        let afterScheme = target[schemeRange.upperBound...]
        let authorityEnd = afterScheme.firstIndex(of: "/") ?? afterScheme.endIndex
        let authority = String(afterScheme[afterScheme.startIndex..<authorityEnd])
        let scheme = String(target[target.startIndex..<schemeRange.lowerBound]).lowercased()
        let defaultPort: UInt16 = scheme == "https" ? 443 : 80
        guard let dest = parseAuthority(authority, defaultPort: defaultPort) else { return nil }
        return Parsed(kind: .absolute(method: method, target: target), destination: dest)
    }

    /// Split `host:port` (or `[v6]:port`, or bare host) into a Destination.
    static func parseAuthority(_ authority: String, defaultPort: UInt16) -> Destination? {
        guard !authority.isEmpty else { return nil }
        // Strip userinfo if present (shouldn't be, but be safe).
        let auth = authority.split(separator: "@").last.map(String.init) ?? authority

        if auth.hasPrefix("[") {  // [IPv6]:port
            guard let close = auth.firstIndex(of: "]") else { return nil }
            let host = String(auth[auth.index(after: auth.startIndex)..<close])
            var port = defaultPort
            let rest = auth[auth.index(after: close)...]
            if rest.hasPrefix(":"), let p = UInt16(rest.dropFirst()) { port = p }
            return Destination(host: host, port: port, isIPLiteral: true)
        }

        if let colon = auth.lastIndex(of: ":"), !auth[auth.index(after: colon)...].isEmpty,
           auth[auth.index(after: colon)...].allSatisfy(\.isNumber) {
            let host = String(auth[..<colon])
            guard let port = UInt16(auth[auth.index(after: colon)...]), !host.isEmpty else { return nil }
            return Destination(host: host, port: port, isIPLiteral: isIPLiteral(host))
        }
        return Destination(host: auth, port: defaultPort, isIPLiteral: isIPLiteral(auth))
    }
}

// MARK: - SOCKS5 (macOS datapath: gvproxy forwards guest TCP here by name)

/// Minimal SOCKS5 server-side parsing (RFC 1928), no authentication. We only
/// support CONNECT. The value of SOCKS5 for us is `atyp == domain`: gvproxy
/// resolved the guest's hostname via the filtering DNS and hands it to us by name,
/// so we make the same allowlist decision as the Docker CONNECT path.
public enum Socks5 {
    public static let version: UInt8 = 0x05
    public static let noAuth: UInt8 = 0x00
    public static let cmdConnect: UInt8 = 0x01

    public enum Reply: UInt8 {
        case succeeded = 0x00
        case generalFailure = 0x01
        case notAllowed = 0x02
        case hostUnreachable = 0x04
        case commandNotSupported = 0x07
    }

    /// Parse the SOCKS5 request that follows the method-selection handshake.
    /// `bytes` must start at the request header (VER CMD RSV ATYP …).
    /// Returns the destination and the number of bytes consumed, or nil if more
    /// bytes are needed / the request is malformed.
    public static func parseRequest(_ bytes: [UInt8]) -> (Destination, consumed: Int)? {
        guard bytes.count >= 4 else { return nil }
        guard bytes[0] == version, bytes[1] == cmdConnect else { return nil }
        let atyp = bytes[3]
        var idx = 4
        let host: String
        let isIP: Bool
        switch atyp {
        case 0x01:  // IPv4
            guard bytes.count >= idx + 4 else { return nil }
            host = "\(bytes[idx]).\(bytes[idx+1]).\(bytes[idx+2]).\(bytes[idx+3])"
            isIP = true
            idx += 4
        case 0x03:  // domain
            guard bytes.count >= idx + 1 else { return nil }
            let len = Int(bytes[idx]); idx += 1
            guard bytes.count >= idx + len, len > 0 else { return nil }
            host = String(decoding: bytes[idx..<idx+len], as: UTF8.self)
            isIP = false
            idx += len
        case 0x04:  // IPv6
            guard bytes.count >= idx + 16 else { return nil }
            host = ipv6String(Array(bytes[idx..<idx+16]))
            isIP = true
            idx += 16
        default:
            return nil
        }
        guard bytes.count >= idx + 2 else { return nil }
        let port = UInt16(bytes[idx]) << 8 | UInt16(bytes[idx+1])
        idx += 2
        return (Destination(host: host, port: port, isIPLiteral: isIP), idx)
    }

    /// Build a SOCKS5 reply with a zeroed BND.ADDR (IPv4 0.0.0.0:0) — adequate for
    /// CONNECT replies; clients don't rely on the bound address here.
    public static func reply(_ reply: Reply) -> [UInt8] {
        [version, reply.rawValue, 0x00, 0x01, 0, 0, 0, 0, 0, 0]
    }

    static func ipv6String(_ b: [UInt8]) -> String {
        stride(from: 0, to: 16, by: 2)
            .map { String(format: "%x", UInt16(b[$0]) << 8 | UInt16(b[$0+1])) }
            .joined(separator: ":")
    }
}
