import XCTest
@testable import AugurProxyCore

final class AllowlistTests: XCTestCase {
    func testExactHostOnly() {
        let a = Allowlist(patterns: ["github.com"])
        XCTAssertTrue(a.allows("github.com"))
        XCTAssertFalse(a.allows("api.github.com"), "bare host must NOT match subdomains")
        XCTAssertFalse(a.allows("evilgithub.com"))
    }

    func testWildcardSubdomainsOnly() {
        let a = Allowlist(patterns: ["*.github.com"])
        XCTAssertTrue(a.allows("api.github.com"))
        XCTAssertTrue(a.allows("a.b.github.com"))
        XCTAssertFalse(a.allows("github.com"), "*. must NOT match the apex")
        // The critical bypass case: suffix without a label boundary.
        XCTAssertFalse(a.allows("evilgithub.com"))
        XCTAssertFalse(a.allows("notgithub.com"))
        XCTAssertFalse(a.allows("github.com.evil.com"))
    }

    func testDotPrefixMatchesApexAndSubdomains() {
        let a = Allowlist(patterns: [".github.com"])
        XCTAssertTrue(a.allows("github.com"))
        XCTAssertTrue(a.allows("api.github.com"))
        XCTAssertFalse(a.allows("evilgithub.com"))
    }

    func testCaseAndTrailingDotInsensitive() {
        let a = Allowlist(patterns: ["GitHub.com"])
        XCTAssertTrue(a.allows("github.com"))
        XCTAssertTrue(a.allows("GITHUB.COM"))
        XCTAssertTrue(a.allows("github.com."))   // FQDN trailing dot
    }

    func testPortIsStripped() {
        let a = Allowlist(patterns: ["api.anthropic.com"])
        XCTAssertTrue(a.allows("api.anthropic.com:443"))
    }

    func testIPLiteralsNeverMatch() {
        let a = Allowlist(patterns: ["10.0.0.1", "1.2.3.4", "*.com"])
        XCTAssertFalse(a.allows("1.2.3.4"), "IP literal must never be an allowlist match")
        XCTAssertFalse(a.allows("10.0.0.1"))
        XCTAssertFalse(a.allows("::1"))
    }

    func testConfParsingStripsCommentsAndBlanks() {
        let conf = """
        # comment line
        api.anthropic.com   # trailing comment

           github.com
        """
        let a = Allowlist(confText: conf)
        XCTAssertTrue(a.allows("api.anthropic.com"))
        XCTAssertTrue(a.allows("github.com"))
        XCTAssertFalse(a.isEmpty)
    }

    func testEmptyConfDeniesEverything() {
        let a = Allowlist(confText: "# only comments\n\n")
        XCTAssertTrue(a.isEmpty)
        XCTAssertFalse(a.allows("github.com"))
    }

    func testSubdomainBoundaryHelper() {
        XCTAssertTrue(Allowlist.isSubdomain("api.github.com", of: "github.com"))
        XCTAssertFalse(Allowlist.isSubdomain("evilgithub.com", of: "github.com"))
        XCTAssertFalse(Allowlist.isSubdomain("github.com", of: "github.com"))
    }
}
