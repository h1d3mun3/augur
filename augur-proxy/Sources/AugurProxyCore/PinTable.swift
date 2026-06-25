import Foundation

/// Records IP addresses the filtering DNS handed out for *allowed* names, so a
/// later TCP connection to that IP (e.g. an IP-literal connect, or a client that
/// resolved a name itself) can be allowed even though we only see an IP. Pins are
/// per-client and expire. This is defense-in-depth that also enables IP-literal
/// connects to legitimately-resolved hosts; the by-name allowlist remains primary.
///
/// Thread-safe: the DNS responder writes pins and connection handlers read them
/// concurrently.
public final class PinTable {
    private struct Pin { let domain: String; let expiry: Date }
    // client IP → (dest IP → pin)
    private var pins: [String: [String: Pin]] = [:]
    private let lock = NSLock()
    private let clock: () -> Date

    public init(clock: @escaping () -> Date = Date.init) { self.clock = clock }

    /// Pin `ip` for `client`, resolved from `domain`, valid for `ttl` seconds
    /// (with a floor so very short TTLs still allow the connection to be made).
    public func pin(ip: String, forClient client: String, domain: String, ttl: TimeInterval) {
        let expiry = clock().addingTimeInterval(max(ttl, 30) + 5)
        lock.lock(); defer { lock.unlock() }
        pins[client, default: [:]][ip] = Pin(domain: domain, expiry: expiry)
    }

    /// The domain a live pin maps `ip` to for `client`, or nil if none/expired.
    public func domain(forIP ip: String, client: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let p = pins[client]?[ip] else { return nil }
        guard p.expiry > clock() else { return nil }
        return p.domain
    }

    /// Drop expired entries (call periodically; bounded memory for long sessions).
    public func sweep() {
        let now = clock()
        lock.lock(); defer { lock.unlock() }
        for (client, byIP) in pins {
            let live = byIP.filter { $0.value.expiry > now }
            if live.isEmpty { pins[client] = nil } else { pins[client] = live }
        }
    }
}
