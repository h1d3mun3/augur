import Foundation

/// The private IPv4 ranges augur is willing to DIAL when an operator has EXPLICITLY
/// allowlisted the destination by IP (e.g. a LAN or Tailscale Ollama endpoint). This
/// is the "reachable private" set — deliberately positioned BETWEEN two extremes:
///
///   - BROADER than RFC1918 alone: it also admits CGNAT 100.64/10, which is the range
///     Tailscale hands out, so an operator can point at a tailnet peer for availability.
///   - NARROWER than `Sock.isPrivate` (all-non-public): it EXCLUDES loopback (127/8),
///     link-local (169.254/16 — incl. the cloud metadata address 169.254.169.254),
///     0/8, the IETF protocol/benchmark blocks, multicast and broadcast.
///
/// The exclusions are the security crux: `.augur.conf` / `.augur.llm` are guest- and
/// repo-writable, so an attacker-controlled IP rule must never relax the dial guard
/// onto host-local or metadata services. LAN and Tailscale never use those excluded
/// ranges, so admitting only RFC1918 + CGNAT serves the real use case without opening
/// an SSRF-to-host / SSRF-to-metadata hole.
public func isReachablePrivateIPv4(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) -> Bool {
    switch a {
    case 10:  return true                   // 10.0.0.0/8     (RFC1918)
    case 172: return b >= 16 && b <= 31      // 172.16.0.0/12  (RFC1918)
    case 192: return b == 168                // 192.168.0.0/16 (RFC1918)
    case 100: return b >= 64 && b <= 127     // 100.64.0.0/10  (CGNAT — Tailscale)
    default:  return false
    }
}
