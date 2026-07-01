import Foundation

/// Non-public address classification for the proxy's SSRF guard (invariant I8 in
/// docs/security-reviews/INVARIANTS.md). An allowlisted *name* must never let the
/// guest reach a host-local / LAN / internal address: `Sock` refuses to dial any
/// address classified non-public here when `publicOnly` is set — and augur never
/// passes `--allow-private` on a production path, so this guard is always armed.
///
/// Lives in the testable core (not the executable target) precisely so these
/// classifications are unit-tested rather than only reviewed.
public enum AddressPolicy {
    /// IPv4 non-public classification, shared by the AF_INET and IPv4-mapped paths.
    public static func isPrivateV4(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) -> Bool {
        switch a {
        case 0:          return true                // 0.0.0.0/8
        case 10:         return true                // 10/8 private
        case 127:        return true                // loopback
        case 100:        return b >= 64 && b <= 127 // 100.64/10 CGNAT (Tailscale etc.)
        case 169:        return b == 254            // 169.254/16 link-local
        case 172:        return b >= 16 && b <= 31  // 172.16/12 private
        case 192:        return (b == 168)            // 192.168/16 private
                              || (b == 0 && c == 0)    // 192.0.0/24 IETF protocol
                              || (b == 88 && c == 99)   // 192.88.99/24 6to4 relay anycast (deprecated)
        case 198:        return b == 18 || b == 19   // 198.18/15 benchmark
        case 224...255:  return true                // 224/4 multicast + 240/4 reserved (incl. broadcast)
        default:         return false               // globally-routable public space
        }
    }

    /// IPv6 non-public classification over the 16 raw address bytes. Mirrors the
    /// AF_INET6 logic in `Sock.isPrivate`. IPv4-mapped / -compatible forms are
    /// classified by their embedded v4 so a mapped 127.0.0.1 / 10.x can't slip past
    /// as "public IPv6".
    public static func isPrivateV6(_ b: [UInt8]) -> Bool {
        precondition(b.count == 16, "IPv6 address must be 16 bytes")
        // First 10 bytes zero: ::, ::1 (loopback), IPv4-mapped (::ffff:0:0/96) and
        // IPv4-compatible (deprecated).
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
}
