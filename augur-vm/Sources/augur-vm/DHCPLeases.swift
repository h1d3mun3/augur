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
/// sides are normalized before comparison. The last matching block wins (bootpd
/// appends, so the newest lease is last).
enum DHCPLeases {
    static let path = "/var/db/dhcpd_leases"

    static func ip(forMAC mac: String) -> String? {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let target = normalize(mac)
        var result: String?

        var currentIP: String?
        var currentMAC: String?
        for rawLine in contents.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line == "}" {
                if let currentMAC, currentMAC == target, let currentIP { result = currentIP }
                currentIP = nil
                currentMAC = nil
            } else if let value = line.dropPrefix("ip_address=") {
                currentIP = value
            } else if let value = line.dropPrefix("hw_address=") {
                // strip the "1," (hardware type) prefix if present
                currentMAC = normalize(value.contains(",") ? String(value.split(separator: ",").last ?? "") : value)
            }
        }
        return result
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
