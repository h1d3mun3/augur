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
        let list = currentList()
        if dest.isIPLiteral {
            // IP-literal connects are denied unless a live pin maps this exact IP (for this
            // client) to an allowed name. NOTE: no production datapath populates the pin
            // table today — augur-proxy runs no DNS responder, and the macOS filtering DNS
            // is gvproxy's separate process — so in practice this branch ALWAYS denies
            // (fail-secure: IP-literal exfil and ECH-hidden direct connects are blocked
            // unconditionally). The pin lookup is kept as a tested scaffold; should a future
            // datapath populate it, the `list.allows(domain)` re-check here keeps it safe.
            if let domain = pins.domain(forIP: dest.host, client: client), list.allows(domain) {
                return .allow()
            }
            return .deny("ip-literal")
        }
        if list.allows(dest.host) { return .allow() }
        return .deny("not-in-allowlist")
    }
}
