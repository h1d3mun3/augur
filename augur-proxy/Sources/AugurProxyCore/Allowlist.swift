import Foundation

/// The domain whitelist parsed from `.augur.conf`. This is the single security
/// decision point: `allows(_:)` returns true only for hosts that match a
/// configured pattern. A bug here is a bypass, so matching is intentionally
/// label-anchored and conservative — see the test suite for the cases that must hold
/// (notably `*.github.com` matching `api.github.com` but NOT `evilgithub.com`).
///
/// Pattern grammar (one per line in `.augur.conf`, `#` starts a comment):
///   - `example.com`    exact host only (the apex). Does NOT match subdomains.
///   - `*.example.com`  subdomains only (`api.example.com` yes; `example.com` no).
///   - `.example.com`   the apex AND every subdomain (a convenience for both).
///
/// Matching is case-insensitive and ignores a single trailing dot (FQDN form).
public struct Allowlist {
    /// Exact hosts that are allowed (from bare-host patterns and from the apex of
    /// a `.example.com` pattern).
    private let exact: Set<String>
    /// Suffix patterns. Each entry is a domain whose *subdomains* are allowed,
    /// e.g. `github.com` here allows `api.github.com`, `a.b.github.com`, …
    private let suffixes: [String]

    public init(patterns: [String]) {
        var exact = Set<String>()
        var suffixes = [String]()
        for raw in patterns {
            let p = Allowlist.normalize(raw)
            guard !p.isEmpty else { continue }
            if let rest = p.dropPrefixIfPresent("*.") {
                // subdomains only
                if !rest.isEmpty { suffixes.append(rest) }
            } else if let rest = p.dropPrefixIfPresent(".") {
                // apex + subdomains
                if !rest.isEmpty { exact.insert(rest); suffixes.append(rest) }
            } else {
                exact.insert(p)
            }
        }
        self.exact = exact
        self.suffixes = suffixes
    }

    /// Parse raw `.augur.conf` text (comments, blank lines, one pattern per line).
    public init(confText: String) {
        self.init(patterns: Allowlist.patterns(fromConf: confText))
    }

    public var isEmpty: Bool { exact.isEmpty && suffixes.isEmpty }

    /// The decision. `host` may carry a port (`example.com:443`) or a trailing dot.
    public func allows(_ host: String) -> Bool {
        let h = Allowlist.normalize(Allowlist.stripPort(host))
        guard !h.isEmpty else { return false }
        // An IP literal is never a domain match — it can only be allowed by the pin
        // table (handled by the caller), never by the allowlist.
        if isIPLiteral(h) { return false }
        // Decision chokepoint: never match a host that isn't a clean LDH hostname.
        // The dial uses this same string via getaddrinfo (which truncates at NUL),
        // so a malformed host must fail closed here too. See isValidHostname.
        guard isValidHostname(h) else { return false }
        if exact.contains(h) { return true }
        for base in suffixes where Allowlist.isSubdomain(h, of: base) {
            return true
        }
        return false
    }

    // MARK: - Matching helpers

    /// True iff `host` is a strict subdomain of `base` on a label boundary.
    /// `api.github.com` is a subdomain of `github.com`; `evilgithub.com` is NOT
    /// (the char before the suffix must be a `.`); `github.com` is NOT a subdomain
    /// of itself.
    static func isSubdomain(_ host: String, of base: String) -> Bool {
        guard host.count > base.count + 1 else { return false }
        guard host.hasSuffix(base) else { return false }
        // The character immediately before the matched suffix must be a label dot.
        let boundaryIndex = host.index(host.endIndex, offsetBy: -(base.count + 1))
        return host[boundaryIndex] == "."
    }

    // MARK: - Parsing

    /// Extract patterns from conf text: strip `#` comments, trim, drop blanks.
    public static func patterns(fromConf text: String) -> [String] {
        var out = [String]()
        for rawLine in text.split(whereSeparator: \.isNewline) {
            var line = String(rawLine)
            if let hash = line.firstIndex(of: "#") { line = String(line[..<hash]) }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { out.append(trimmed) }
        }
        return out
    }

    /// Lowercase and drop a single trailing dot. (Does not touch ports.)
    static func normalize(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces).lowercased()
        if t.hasSuffix(".") { t.removeLast() }
        return t
    }

    /// Drop a trailing `:port` if the part after the last colon is all digits.
    /// Leaves bracketed IPv6 literals (`[::1]:443`) and bare IPv6 alone enough for
    /// the IP-literal guard to reject them anyway.
    static func stripPort(_ host: String) -> String {
        guard let colon = host.lastIndex(of: ":") else { return host }
        let portPart = host[host.index(after: colon)...]
        if !portPart.isEmpty, portPart.allSatisfy({ $0.isNumber }) {
            let hostPart = String(host[..<colon])
            // Don't strip from a bare IPv6 literal like "::1" (multiple colons).
            if hostPart.contains(":") { return host }
            return hostPart
        }
        return host
    }
}

private extension String {
    /// If `self` starts with `prefix`, return the remainder, else nil.
    func dropPrefixIfPresent(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}

/// Rough IP-literal detection — anything that is a bare IPv4/IPv6 literal is not a
/// domain and must not be matched by the allowlist.
func isIPLiteral(_ s: String) -> Bool {
    let host = s.hasPrefix("[") && s.hasSuffix("]") ? String(s.dropFirst().dropLast()) : s
    if host.contains(":") { return true }   // any colon ⇒ IPv6 literal
    // IPv4: four dot-separated decimal octets.
    let parts = host.split(separator: ".", omittingEmptySubsequences: false)
    if parts.count == 4, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) && (Int($0) ?? 999) <= 255 }) {
        return true
    }
    return false
}
