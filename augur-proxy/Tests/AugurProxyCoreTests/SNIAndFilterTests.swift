import XCTest
@testable import AugurProxyCore

final class SNIAndFilterTests: XCTestCase {
    /// Build a minimal TLS ClientHello record carrying a single server_name.
    private func clientHello(serverName: String) -> [UInt8] {
        let nameBytes = Array(serverName.utf8)
        // server_name extension body
        var ext: [UInt8] = []
        let entry: [UInt8] = [0x00] + u16(nameBytes.count) + nameBytes      // type host_name + name
        ext += u16(entry.count) + entry                                     // server_name_list
        var extension0000: [UInt8] = u16(0x0000) + u16(ext.count) + ext     // extension header

        var body: [UInt8] = []
        body += [0x03, 0x03]                 // client_version TLS1.2
        body += [UInt8](repeating: 0, count: 32)  // random
        body += [0x00]                       // session_id len 0
        body += u16(2) + [0x13, 0x01]        // cipher_suites: one suite
        body += [0x01, 0x00]                 // compression_methods: len 1, null
        body += u16(extension0000.count) + extension0000  // extensions

        let handshake: [UInt8] = [0x01] + u24(body.count) + body  // client_hello
        let record: [UInt8] = [0x16, 0x03, 0x01] + u16(handshake.count) + handshake
        return record
    }

    private func u16(_ v: Int) -> [UInt8] { [UInt8((v >> 8) & 0xff), UInt8(v & 0xff)] }
    private func u24(_ v: Int) -> [UInt8] { [UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)] }

    func testExtractSNIFromRecord() {
        let record = clientHello(serverName: "api.anthropic.com")
        XCTAssertEqual(TLSClientHello.serverName(fromRecord: record), "api.anthropic.com")
    }

    func testNonClientHelloReturnsNil() {
        XCTAssertNil(TLSClientHello.serverName(fromRecord: [0x17, 0x03, 0x03, 0x00, 0x01, 0x00]))
        XCTAssertNil(TLSClientHello.serverName(fromRecord: [0x16]))  // truncated
    }

    // MARK: Filter (the unified decision)
    func testFilterAllowsByName() {
        let f = Filter(allowlist: Allowlist(patterns: ["*.github.com", "github.com"]))
        XCTAssertTrue(f.decide(Destination(host: "api.github.com", port: 443, isIPLiteral: false), client: "c").allowed)
        XCTAssertFalse(f.decide(Destination(host: "evil.com", port: 443, isIPLiteral: false), client: "c").allowed)
    }

    func testFilterDeniesUnpinnedIPLiteral() {
        let f = Filter(allowlist: Allowlist(patterns: ["github.com"]))
        let v = f.decide(Destination(host: "1.2.3.4", port: 443, isIPLiteral: true), client: "c")
        XCTAssertFalse(v.allowed)
        XCTAssertEqual(v.reason, "ip-literal")
    }

    func testFilterAllowsPinnedIPLiteral() {
        let pins = PinTable()
        let f = Filter(allowlist: Allowlist(patterns: ["github.com"]), pins: pins)
        pins.pin(ip: "140.82.121.4", forClient: "c", domain: "github.com", ttl: 60)
        XCTAssertTrue(f.decide(Destination(host: "140.82.121.4", port: 443, isIPLiteral: true), client: "c").allowed)
        // A pin for a non-allowlisted domain must still be denied.
        pins.pin(ip: "9.9.9.9", forClient: "c", domain: "evil.com", ttl: 60)
        XCTAssertFalse(f.decide(Destination(host: "9.9.9.9", port: 443, isIPLiteral: true), client: "c").allowed)
    }

    func testFilterAllowsIPRuleWithPort() {
        let f = Filter(allowlist: Allowlist(patterns: ["192.168.1.50:11434"]))
        XCTAssertTrue(f.decide(Destination(host: "192.168.1.50", port: 11434, isIPLiteral: true), client: "c").allowed)
        // Same IP, wrong port → denied.
        XCTAssertFalse(f.decide(Destination(host: "192.168.1.50", port: 22, isIPLiteral: true), client: "c").allowed)
        // Different IP → denied.
        XCTAssertFalse(f.decide(Destination(host: "192.168.1.60", port: 11434, isIPLiteral: true), client: "c").allowed)
    }

    func testDecideDialScopesTheExplicitIPException() {
        let pins = PinTable()
        let f = Filter(allowlist: Allowlist(patterns: ["192.168.1.50:11434", "github.com"]), pins: pins)
        // Explicitly-listed IP:port → allowed AND eligible for the dial exception.
        let ok = f.decideDial(Destination(host: "192.168.1.50", port: 11434, isIPLiteral: true), client: "c")
        XCTAssertTrue(ok.verdict.allowed); XCTAssertTrue(ok.explicitIP)
        // Wrong port / wrong IP → not allowed, not eligible.
        XCTAssertFalse(f.decideDial(Destination(host: "192.168.1.50", port: 22, isIPLiteral: true), client: "c").explicitIP)
        XCTAssertFalse(f.decideDial(Destination(host: "10.0.0.1", port: 11434, isIPLiteral: true), client: "c").explicitIP)
        // A domain is allowed by name but is never an explicit IP.
        let dom = f.decideDial(Destination(host: "github.com", port: 443, isIPLiteral: false), client: "c")
        XCTAssertTrue(dom.verdict.allowed); XCTAssertFalse(dom.explicitIP)
        // Allowed via a DNS pin (not an explicit IP rule) → allowed but NOT eligible:
        // the private-dial guard must stay on for the rebinding case.
        pins.pin(ip: "10.9.9.9", forClient: "c", domain: "github.com", ttl: 60)
        let pinned = f.decideDial(Destination(host: "10.9.9.9", port: 443, isIPLiteral: true), client: "c")
        XCTAssertTrue(pinned.verdict.allowed); XCTAssertFalse(pinned.explicitIP)
    }

    func testPinExpiry() {
        var now = Date(timeIntervalSince1970: 1000)
        let pins = PinTable(clock: { now })
        pins.pin(ip: "1.1.1.1", forClient: "c", domain: "github.com", ttl: 10)
        XCTAssertEqual(pins.domain(forIP: "1.1.1.1", client: "c"), "github.com")
        now = Date(timeIntervalSince1970: 1000 + 30 + 5 + 1)  // past max(ttl,30)+grace
        XCTAssertNil(pins.domain(forIP: "1.1.1.1", client: "c"))
    }

    func testHotReloadSwapsPolicy() {
        let f = Filter(allowlist: Allowlist(patterns: ["github.com"]))
        XCTAssertFalse(f.decide(Destination(host: "npmjs.org", port: 443, isIPLiteral: false), client: "c").allowed)
        f.reload(Allowlist(patterns: ["npmjs.org"]))
        XCTAssertTrue(f.decide(Destination(host: "npmjs.org", port: 443, isIPLiteral: false), client: "c").allowed)
        XCTAssertFalse(f.decide(Destination(host: "github.com", port: 443, isIPLiteral: false), client: "c").allowed)
    }
}
