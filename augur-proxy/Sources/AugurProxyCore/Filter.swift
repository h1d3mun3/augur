import Foundation

/// The unified allow/deny decision used by every datapath (Docker CONNECT and
/// macOS SOCKS). Both hand us a `Destination`; we apply the same rules so behavior
/// is identical across modes. Fail-closed: anything not positively allowed is
/// denied.
public struct Verdict: Equatable {
    public let allowed: Bool
    public let reason: String        // for logging when denied; "" when allowed
    public static func allow() -> Verdict { Verdict(allowed: true, reason: "") }
    public static func deny(_ reason: String) -> Verdict { Verdict(allowed: false, reason: reason) }
}

/// Holds the policy and makes decisions. The `Allowlist` is swapped atomically on
/// hot-reload (a new `Filter` is published behind a lock by the server).
public final class Filter {
    public private(set) var allowlist: Allowlist
    public let pins: PinTable
    private let lock = NSLock()

    public init(allowlist: Allowlist, pins: PinTable = PinTable()) {
        self.allowlist = allowlist
        self.pins = pins
    }

    /// Atomically replace the allowlist (hot-reload). Never widens mid-request:
    /// a request reads `allowlist` once under the lock.
    public func reload(_ newList: Allowlist) {
        lock.lock(); defer { lock.unlock() }
        self.allowlist = newList
    }

    private func currentList() -> Allowlist {
        lock.lock(); defer { lock.unlock() }
        return allowlist
    }

    /// Decide whether `client` may reach `dest`.
    public func decide(_ dest: Destination, client: String) -> Verdict {
        evaluate(dest, client: client, list: currentList())
    }

    /// A decision plus whether it was reached via an EXPLICIT IP rule. Both are
    /// computed from the SAME allowlist snapshot, so a hot-reload landing between the
    /// two can't mix policies (the server needs both to gate the private-dial
    /// exception, and must not read the allowlist twice).
    public struct DialDecision: Equatable {
        public let verdict: Verdict
        /// `dest` is an IP literal an IP rule permits → eligible for the private-dial
        /// exception (NOT merely allowed via a DNS pin, which keeps the full guard).
        public let explicitIP: Bool
    }

    /// The decision the datapaths use: verdict + explicit-IP flag under one lock.
    public func decideDial(_ dest: Destination, client: String) -> DialDecision {
        let list = currentList()
        let explicitIP = dest.isIPLiteral && list.allowsIP(dest.host, port: dest.port)
        return DialDecision(verdict: evaluate(dest, client: client, list: list), explicitIP: explicitIP)
    }

    /// The pure decision over a fixed allowlist snapshot (pins are independently
    /// thread-safe). Shared by `decide` and `decideDial`.
    private func evaluate(_ dest: Destination, client: String, list: Allowlist) -> Verdict {
        if dest.isIPLiteral {
            // Allow an IP-literal connect when the policy explicitly lists this IP:port
            // (e.g. a LAN/Tailscale LLM endpoint added by an augur profile)…
            if list.allowsIP(dest.host, port: dest.port) { return .allow() }
            // …or when the filtering DNS recently handed this client that exact IP for
            // an allowed name (pin). Failing both, deny — this blocks IP-literal exfil
            // and ECH-hidden direct connects.
            if let domain = pins.domain(forIP: dest.host, client: client), list.allows(domain) {
                return .allow()
            }
            return .deny("ip-literal")
        }
        if list.allows(dest.host) { return .allow() }
        return .deny("not-in-allowlist")
    }
}
