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

    private func sniExtension(name: [UInt8]) -> [UInt8] {
        // server_name extension body: list_len(2) type(1)=host_name name_len(2) name
        let entry: [UInt8] = [0x00] + u16(name.count) + name
        return u16(entry.count) + entry
    }
    private func u16(_ v: Int) -> [UInt8] { [UInt8((v >> 8) & 0xff), UInt8(v & 0xff)] }
}
