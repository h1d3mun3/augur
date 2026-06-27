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
///   - `1.2.3.4:11434`  an IPv4 literal WITH a port: allow ONLY that IP on that port.
///                      A bare IP (no port) and IPv6 literals are NOT accepted (v1).
///
/// IP-literal rules are matched by `allowsIP`, NEVER by `allows` (a domain decision
/// must never resolve to an IP). They exist so an augur profile can permit a direct
/// host endpoint such as a LAN/Tailscale Ollama server (`192.168.1.50:11434`). A port
/// is mandatory so a rule can't silently open every port on a host; only IPv4 is
/// supported for now (the SOCKS atyp=4 IPv6 form needs canonicalization first).
///
/// Matching is case-insensitive and ignores a single trailing dot (FQDN form).
public struct Allowlist {
    /// A permitted IPv4 endpoint: this exact IP on this exact port.
    struct IPRule: Equatable { let ip: String; let port: UInt16 }

    /// Exact hosts that are allowed (from bare-host patterns and from the apex of
    /// a `.example.com` pattern).
    private let exact: Set<String>
    /// Suffix patterns. Each entry is a domain whose *subdomains* are allowed,
    /// e.g. `github.com` here allows `api.github.com`, `a.b.github.com`, …
    private let suffixes: [String]
    /// IP-literal allow rules. Consulted only by `allowsIP`, kept apart from the
    /// domain sets so a host that isn't a clean LDH name can never match a domain.
    private let ipRules: [IPRule]

    public init(patterns: [String]) {
        var exact = Set<String>()
        var suffixes = [String]()
        var ipRules = [IPRule]()
        for raw in patterns {
            let p = Allowlist.normalize(raw)
            guard !p.isEmpty else { continue }
            // An IP literal (optionally with a port) is not a domain pattern, so it
            // must be recognized before the `*.`/`.` domain branches.
            if let rule = Allowlist.parseIPRule(p) {
                ipRules.append(rule)
            } else if let rest = p.dropPrefixIfPresent("*.") {
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
        self.ipRules = ipRules
    }

    /// Parse raw `.augur.conf` text (comments, blank lines, one pattern per line).
    public init(confText: String) {
        self.init(patterns: Allowlist.patterns(fromConf: confText))
    }

    public var isEmpty: Bool { exact.isEmpty && suffixes.isEmpty && ipRules.isEmpty }

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

    /// The IP-literal decision, kept separate from `allows`: the Filter calls this
    /// for IP-literal destinations. An IP rule with a port allows only that port;
    /// a portless rule allows any port on that IP. A non-IP host never matches.
    public func allowsIP(_ host: String, port: UInt16) -> Bool {
        let h = Allowlist.normalize(host)
        guard !h.isEmpty, isIPLiteral(h) else { return false }
        for r in ipRules where r.ip == h && r.port == port {
            return true
        }
        return false
    }

    // MARK: - Matching helpers

    /// Parse an IP allow rule. v1 accepts ONLY `IPv4:port` (e.g. `192.168.1.50:11434`).
    /// Returns nil — so the pattern falls through to domain handling (where an IP can
    /// never match) — for anything else: a bare IP with no port (which would otherwise
    /// open every port on a host), and any IPv6 literal (bracketed or bare, whose
    /// textual SOCKS atyp=4 form is not yet canonicalized for safe matching).
    static func parseIPRule(_ pattern: String) -> IPRule? {
        guard !pattern.hasPrefix("[") else { return nil }   // no [IPv6]:port
        // Exactly one colon ⇒ host:port. (0 colons = bare IP → rejected; 2+ = IPv6.)
        let colonCount = pattern.reduce(0) { $1 == ":" ? $0 + 1 : $0 }
        guard colonCount == 1 else { return nil }
        let colon = pattern.firstIndex(of: ":")!
        let host = String(pattern[..<colon])
        let portPart = pattern[pattern.index(after: colon)...]
        // `host` has no colon here, so isIPLiteral is true only for an IPv4 literal.
        guard isIPLiteral(host), !portPart.isEmpty, portPart.allSatisfy(\.isNumber),
              let port = UInt16(portPart) else { return nil }
        return IPRule(ip: host, port: port)
    }

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
