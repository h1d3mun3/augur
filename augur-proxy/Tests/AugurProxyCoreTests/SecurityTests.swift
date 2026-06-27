import XCTest
@testable import AugurProxyCore

/// Regressions for the bypasses found by the adversarial egress review.
final class SecurityTests: XCTestCase {
    // MF1 — NUL/illegal-byte hostnames must be rejected so the allowlist decision
    // and the getaddrinfo dial can never disagree.
    func testHostnameValidation() {
        XCTAssertTrue(isValidHostname("api.github.com"))
        XCTAssertTrue(isValidHostname("example.com."))      // FQDN trailing dot
        XCTAssertTrue(isValidHostname("xn--80ak6aa92e.com")) // IDN punycode
        XCTAssertFalse(isValidHostname("example.com\u{0}.evil.com"), "NUL injection")
        XCTAssertFalse(isValidHostname("evil.com\u{0}"))
        XCTAssertFalse(isValidHostname("a..b"))             // empty label
        XCTAssertFalse(isValidHostname(".github.com"))      // leading dot
        XCTAssertFalse(isValidHostname("has space.com"))
        XCTAssertFalse(isValidHostname("under_score.com"))  // not LDH
        XCTAssertFalse(isValidHostname(""))
        XCTAssertFalse(isValidHostname(String(repeating: "a", count: 64) + ".com")) // label > 63
    }

    // The allowlist must never bless a NUL-injected host even if a pattern's
    // suffix appears in it (the getaddrinfo-truncation attack).
    func testAllowlistRejectsNULInjection() {
        let a = Allowlist(patterns: ["*.github.com", "github.com"])
        XCTAssertFalse(a.allows("evil.com\u{0}.github.com"))
        XCTAssertFalse(a.allows("github.com\u{0}.evil.com"))
        XCTAssertTrue(a.allows("api.github.com"))  // legit still works
    }

    // The SNI parser must drop a server_name that isn't a clean hostname.
    func testSNIRejectsNUL() {
        let bad = sniExtension(name: Array("example.com\u{0}.evil".utf8))
        XCTAssertNil(TLSClientHello.parseServerNameExtension(bad))
        let good = sniExtension(name: Array("example.com".utf8))
        XCTAssertEqual(TLSClientHello.parseServerNameExtension(good), "example.com")
    }

    // The explicit-IP dial exception admits RFC1918 + CGNAT (Tailscale), and NOTHING
    // else — loopback, link-local/metadata, and public addresses stay blocked even
    // when explicitly listed, so a guest-writable allowlist can't pivot via SSRF.
    func testReachablePrivateAdmitsRFC1918AndCGNAT() {
        // Admitted: the three RFC1918 blocks (incl. their edges).
        XCTAssertTrue(isReachablePrivateIPv4(10, 0, 0, 1))
        XCTAssertTrue(isReachablePrivateIPv4(10, 255, 255, 255))
        XCTAssertTrue(isReachablePrivateIPv4(172, 16, 0, 1))
        XCTAssertTrue(isReachablePrivateIPv4(172, 31, 255, 255))
        XCTAssertTrue(isReachablePrivateIPv4(192, 168, 1, 50))
        // Admitted: CGNAT 100.64/10 (Tailscale), incl. its edges.
        XCTAssertTrue(isReachablePrivateIPv4(100, 64, 0, 1))
        XCTAssertTrue(isReachablePrivateIPv4(100, 127, 255, 255))
        // Rejected: just outside CGNAT and just outside 172.16/12.
        XCTAssertFalse(isReachablePrivateIPv4(100, 63, 255, 255))
        XCTAssertFalse(isReachablePrivateIPv4(100, 128, 0, 1))
        XCTAssertFalse(isReachablePrivateIPv4(172, 15, 0, 1))
        XCTAssertFalse(isReachablePrivateIPv4(172, 32, 0, 1))
        // Rejected: loopback, link-local (incl. cloud metadata), 0/8.
        XCTAssertFalse(isReachablePrivateIPv4(127, 0, 0, 1))
        XCTAssertFalse(isReachablePrivateIPv4(169, 254, 169, 254), "cloud metadata must never be reachable")
        XCTAssertFalse(isReachablePrivateIPv4(169, 254, 0, 1))
        XCTAssertFalse(isReachablePrivateIPv4(0, 0, 0, 0))
        XCTAssertFalse(isReachablePrivateIPv4(192, 0, 0, 1), "192.0.0/24 is not 192.168/16")
        // Rejected: ordinary public addresses.
        XCTAssertFalse(isReachablePrivateIPv4(8, 8, 8, 8))
        XCTAssertFalse(isReachablePrivateIPv4(1, 1, 1, 1))
    }

    private func sniExtension(name: [UInt8]) -> [UInt8] {
        // server_name extension body: list_len(2) type(1)=host_name name_len(2) name
        let entry: [UInt8] = [0x00] + u16(name.count) + name
        return u16(entry.count) + entry
    }
    private func u16(_ v: Int) -> [UInt8] { [UInt8((v >> 8) & 0xff), UInt8(v & 0xff)] }
}
