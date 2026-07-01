import Foundation

/// Resolves a guest IP by matching a MAC address against macOS's DHCP lease
/// database. With NAT networking, the host's bootpd records leases in
/// /var/db/dhcpd_leases as brace-delimited blocks:
///
///     {
///         name=my-vm
///         ip_address=192.168.64.5
///         hw_address=1,a:bb:c:dd:ee:ff
///         identifier=1,a:bb:c:dd:ee:ff
///         lease=0x...
///     }
///
/// Note `hw_address` is `1,<mac>` with leading zeros stripped per octet, so both
/// sides are normalized before comparison. Among blocks matching the MAC we return the
/// one with the newest `lease=` (expiry) time, NOT the last in file order: bootpd does
/// not guarantee append-only ordering, so after a NAT subnet change the same MAC can hold
/// several blocks with the current one not last (observed: a fresh 192.168.65.x lease
/// listed *before* a stale 192.168.64.x block). Trusting file order then returns a dead IP
/// that no longer answers ("Host is down"), so the VM is never reached.
enum DHCPLeases {
    static let path = "/var/db/dhcpd_leases"

    static func ip(forMAC mac: String) -> String? {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let target = normalize(mac)
        var bestIP: String?
        var bestLease: UInt64?   // nil until a matching block is seen; picks the max expiry

        var currentIP: String?
        var currentMAC: String?
        var currentLease: UInt64?
        for rawLine in contents.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line == "}" {
                if let currentMAC, currentMAC == target, let currentIP {
                    // Freshest lease wins. A block without a parseable `lease=` counts as 0,
                    // so a real expiry always beats it; among equal/absent values the later
                    // block in file order wins (>=), preserving the old behavior as a fallback.
                    let lease = currentLease ?? 0
                    if bestLease == nil || lease >= bestLease! {
                        bestLease = lease
                        bestIP = currentIP
                    }
                }
                currentIP = nil
                currentMAC = nil
                currentLease = nil
            } else if let value = line.dropPrefix("ip_address=") {
                currentIP = value
            } else if let value = line.dropPrefix("hw_address=") {
                // strip the "1," (hardware type) prefix if present
                currentMAC = normalize(value.contains(",") ? String(value.split(separator: ",").last ?? "") : value)
            } else if let value = line.dropPrefix("lease=") {
                currentLease = parseHexLease(value)
            }
        }
        return bestIP
    }

    /// Parse a `lease=0x…` hex expiry timestamp into a comparable integer (nil if malformed).
    static func parseHexLease(_ value: String) -> UInt64? {
        var s = value.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("0x") || s.hasPrefix("0X") { s = String(s.dropFirst(2)) }
        return UInt64(s, radix: 16)
    }

    /// Lowercase, strip leading zeros per octet — matching dhcpd_leases formatting.
    static func normalize(_ mac: String) -> String {
        mac.split(separator: ":").map { octet -> String in
            let s = octet.trimmingCharacters(in: .whitespaces)
            if let v = Int(s, radix: 16) { return String(v, radix: 16) }
            return s.lowercased()
        }.joined(separator: ":")
    }
}

private extension String {
    func dropPrefix(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}
