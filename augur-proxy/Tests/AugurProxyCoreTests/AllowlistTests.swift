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

    func testIPRuleWithPortAllowsOnlyThatPort() {
        let a = Allowlist(patterns: ["192.168.1.50:11434"])
        XCTAssertTrue(a.allowsIP("192.168.1.50", port: 11434))
        XCTAssertFalse(a.allowsIP("192.168.1.50", port: 22), "a pinned-port rule must not open other ports")
        XCTAssertFalse(a.allowsIP("192.168.1.51", port: 11434), "must not open a different IP")
        XCTAssertFalse(a.allows("192.168.1.50"), "an IP rule must never become a domain match")
        XCTAssertFalse(a.isEmpty)
    }

    func testPortlessIPRuleIsNotHonored() {
        // A bare IP (no port) must NOT become an IP rule — it would otherwise open
        // every port on a host. It is simply inert (never matches anything).
        let a = Allowlist(patterns: ["10.0.0.5"])
        XCTAssertFalse(a.allowsIP("10.0.0.5", port: 11434))
        XCTAssertFalse(a.allowsIP("10.0.0.5", port: 443))
        XCTAssertFalse(a.allows("10.0.0.5"))
    }

    func testIPv6RuleIsNotHonored() {
        // IPv6 literals (bracketed or bare) are not accepted as IP rules in v1.
        let a = Allowlist(patterns: ["[fd00::1]:11434", "fd00::2"])
        XCTAssertFalse(a.allowsIP("fd00::1", port: 11434))
        XCTAssertFalse(a.allowsIP("fd00::2", port: 11434))
    }

    func testDomainRuleNeverAllowsIP() {
        let a = Allowlist(patterns: ["api.anthropic.com"])
        XCTAssertFalse(a.allowsIP("1.2.3.4", port: 443))
    }

    func testHostnameWithPortIsADomainNotAnIPRule() {
        // A hostname authority stays a domain (port stripped by `allows`), and is
        // never mistaken for an IP rule.
        let a = Allowlist(patterns: ["ollama.local"])
        XCTAssertTrue(a.allows("ollama.local:11434"))
        XCTAssertFalse(a.allowsIP("ollama.local", port: 11434))
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
