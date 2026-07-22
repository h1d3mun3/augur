import XCTest
@testable import AugurProxyCore

/// Invariant I8 (docs/security-reviews/INVARIANTS.md): the proxy must refuse to dial
/// any non-public address, so an allowlisted name resolving to a host-local / LAN /
/// internal IP cannot be used for SSRF. These assert the classification directly.
final class AddressPolicyTests: XCTestCase {

    func testV4PrivateAndSpecialRangesAreNonPublic() {
        // RFC1918 + loopback + CGNAT + link-local (incl. cloud metadata) + special blocks.
        let nonPublic: [(UInt8, UInt8, UInt8, UInt8)] = [
            (10, 0, 0, 1), (10, 255, 255, 255),
            (172, 16, 0, 1), (172, 31, 255, 254),
            (192, 168, 1, 1),
            (127, 0, 0, 1),                 // loopback
            (169, 254, 169, 254),           // cloud metadata
            (100, 64, 0, 1), (100, 127, 255, 255), // CGNAT (Tailscale)
            (0, 0, 0, 0),                   // 0.0.0.0/8
            (192, 0, 0, 1),                 // IETF protocol
            (192, 88, 99, 1),               // 6to4 relay anycast
            (198, 18, 0, 1), (198, 19, 0, 1), // benchmark
            (224, 0, 0, 1),                 // multicast
            (255, 255, 255, 255),           // broadcast / reserved
        ]
        for (a, b, c, d) in nonPublic {
            XCTAssertTrue(AddressPolicy.isPrivateV4(a, b, c, d),
                          "\(a).\(b).\(c).\(d) must be classified non-public")
        }
    }

    func testV4PublicIsPublic() {
        // Globally-routable addresses, including the boundaries just outside each block.
        let publicAddrs: [(UInt8, UInt8, UInt8, UInt8)] = [
            (8, 8, 8, 8), (1, 1, 1, 1), (13, 107, 21, 200),
            (172, 15, 0, 1), (172, 32, 0, 1),   // just outside 172.16/12
            (100, 63, 0, 1), (100, 128, 0, 1),  // just outside 100.64/10 CGNAT
            (198, 17, 0, 1), (198, 20, 0, 1),   // just outside 198.18/15
            (192, 167, 0, 1), (192, 169, 0, 1), // just outside 192.168/16
            (169, 253, 0, 1), (169, 255, 0, 1), // just outside 169.254/16
        ]
        for (a, b, c, d) in publicAddrs {
            XCTAssertFalse(AddressPolicy.isPrivateV4(a, b, c, d),
                           "\(a).\(b).\(c).\(d) must be classified public")
        }
    }

    // Build a 16-byte IPv6 address from a leading prefix; remaining bytes default to 0.
    private func v6(_ prefix: [UInt8]) -> [UInt8] {
        precondition(prefix.count <= 16)
        return prefix + Array(repeating: 0, count: 16 - prefix.count)
    }

    // ::ffff:a.b.c.d (IPv4-mapped)
    private func mapped(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) -> [UInt8] {
        v6([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, a, b, c, d])
    }

    func testV6NonPublic() {
        XCTAssertTrue(AddressPolicy.isPrivateV6(v6([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]))) // ::1 loopback
        XCTAssertTrue(AddressPolicy.isPrivateV6(v6([]))) // ::
        XCTAssertTrue(AddressPolicy.isPrivateV6(mapped(127, 0, 0, 1)))  // mapped loopback
        XCTAssertTrue(AddressPolicy.isPrivateV6(mapped(10, 0, 0, 1)))   // mapped RFC1918
        XCTAssertTrue(AddressPolicy.isPrivateV6(v6([0x00, 0x64, 0xff, 0x9b]))) // 64:ff9b::/96 NAT64
        XCTAssertTrue(AddressPolicy.isPrivateV6(v6([0xfe, 0x80])))      // fe80::/10 link-local
        XCTAssertTrue(AddressPolicy.isPrivateV6(v6([0xfc, 0x00])))      // fc00::/7 ULA
        XCTAssertTrue(AddressPolicy.isPrivateV6(v6([0xfd, 0x00])))      // fd00::/8 ULA
        XCTAssertTrue(AddressPolicy.isPrivateV6(v6([0xff, 0x02])))      // multicast
        // Transition / deprecated forms that would otherwise fall through to "public".
        XCTAssertTrue(AddressPolicy.isPrivateV6(v6([0x20, 0x02, 127, 0, 0, 1]))) // 2002:7f00:0001:: 6to4-wrapped loopback
        XCTAssertTrue(AddressPolicy.isPrivateV6(v6([0x20, 0x02, 10, 0, 0, 1])))  // 6to4-wrapped RFC1918
        XCTAssertTrue(AddressPolicy.isPrivateV6(v6([0x20, 0x02, 169, 254, 169, 254]))) // 6to4-wrapped cloud metadata
        XCTAssertTrue(AddressPolicy.isPrivateV6(v6([0x20, 0x01, 0x00, 0x00]))) // 2001:0::/32 Teredo
        XCTAssertTrue(AddressPolicy.isPrivateV6(v6([0xfe, 0xc0])))      // fec0::/10 site-local (deprecated)
        XCTAssertTrue(AddressPolicy.isPrivateV6(v6([0xfe, 0xff])))      // fec0::/10 upper boundary
    }

    func testV6Public() {
        XCTAssertFalse(AddressPolicy.isPrivateV6(v6([0x20, 0x01, 0x48, 0x60, 0x48, 0x60, 0, 0,
                                                     0, 0, 0, 0, 0, 0, 0x88, 0x88]))) // 2001:4860:4860::8888
        XCTAssertFalse(AddressPolicy.isPrivateV6(mapped(8, 8, 8, 8))) // mapped PUBLIC stays public
        // 6to4 wrapping a PUBLIC v4 must stay public — the fix classifies by embedded v4, it does
        // NOT blanket-deny 2002::/16 (so legitimate 6to4-to-public is never over-blocked).
        XCTAssertFalse(AddressPolicy.isPrivateV6(v6([0x20, 0x02, 8, 8, 8, 8]))) // 2002:0808:0808:: (6to4 → 8.8.8.8)
        // The Teredo check is the EXACT 2001:0::/32, not the broad 2001::/16 — real global unicast
        // under 2001:: (e.g. 2001:4860:: Google) must remain public.
        XCTAssertFalse(AddressPolicy.isPrivateV6(v6([0x20, 0x01, 0x48, 0x60]))) // 2001:4860:: real global unicast
        XCTAssertFalse(AddressPolicy.isPrivateV6(v6([0x20, 0x01, 0x0d, 0xb8]))) // 2001:db8:: doc prefix (not Teredo)
    }
}
