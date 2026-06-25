import XCTest
@testable import AugurProxyCore

final class ProxyRequestsTests: XCTestCase {
    // MARK: HTTP CONNECT / forward
    func testConnectLine() {
        let p = HTTPProxyRequest.parse(head: "CONNECT api.anthropic.com:443 HTTP/1.1\r\nHost: api.anthropic.com:443\r\n\r\n")
        XCTAssertEqual(p?.kind, .connect)
        XCTAssertEqual(p?.destination, Destination(host: "api.anthropic.com", port: 443, isIPLiteral: false))
    }

    func testConnectDefaultPort() {
        let p = HTTPProxyRequest.parse(head: "CONNECT example.com HTTP/1.1\r\n\r\n")
        XCTAssertEqual(p?.destination.port, 443)
    }

    func testAbsoluteForm() {
        let p = HTTPProxyRequest.parse(head: "GET http://registry.npmjs.org/foo HTTP/1.1\r\nHost: registry.npmjs.org\r\n\r\n")
        XCTAssertEqual(p?.destination, Destination(host: "registry.npmjs.org", port: 80, isIPLiteral: false))
        if case .absolute(let m, _) = p?.kind { XCTAssertEqual(m, "GET") } else { XCTFail("expected absolute") }
    }

    func testConnectIPLiteral() {
        let p = HTTPProxyRequest.parse(head: "CONNECT 1.2.3.4:443 HTTP/1.1\r\n\r\n")
        XCTAssertEqual(p?.destination.isIPLiteral, true)
    }

    func testMalformedReturnsNil() {
        XCTAssertNil(HTTPProxyRequest.parse(head: "GARBAGE\r\n\r\n"))
        XCTAssertNil(HTTPProxyRequest.parse(head: ""))
    }

    // MARK: SOCKS5
    func testSocksDomainRequest() {
        // VER CMD RSV ATYP LEN "github.com" PORT(443)
        let host = Array("github.com".utf8)
        var req: [UInt8] = [0x05, 0x01, 0x00, 0x03, UInt8(host.count)]
        req += host
        req += [0x01, 0xBB]   // 443
        let parsed = Socks5.parseRequest(req)
        XCTAssertEqual(parsed?.0, Destination(host: "github.com", port: 443, isIPLiteral: false))
        XCTAssertEqual(parsed?.consumed, req.count)
    }

    func testSocksIPv4Request() {
        let req: [UInt8] = [0x05, 0x01, 0x00, 0x01, 93, 184, 216, 34, 0x01, 0xBB]
        let parsed = Socks5.parseRequest(req)
        XCTAssertEqual(parsed?.0, Destination(host: "93.184.216.34", port: 443, isIPLiteral: true))
    }

    func testSocksIncompleteReturnsNil() {
        let host = Array("github.com".utf8)
        let partial: [UInt8] = [0x05, 0x01, 0x00, 0x03, UInt8(host.count)] + Array(host.prefix(3))
        XCTAssertNil(Socks5.parseRequest(partial))
    }

    func testSocksRejectsNonConnect() {
        let req: [UInt8] = [0x05, 0x02, 0x00, 0x01, 1, 2, 3, 4, 0x00, 0x50]  // cmd=BIND
        XCTAssertNil(Socks5.parseRequest(req))
    }

    // MARK: origin-form Host (transparent SOCKS peek, plaintext port 80)
    func testHostFromOriginForm() {
        let req = Array("GET /repo/file HTTP/1.1\r\nHost: raw.githubusercontent.com\r\nUser-Agent: x\r\n\r\n".utf8)
        XCTAssertEqual(HTTPProxyRequest.hostFromOriginForm(req), "raw.githubusercontent.com")
    }

    func testHostFromOriginFormStripsPort() {
        let req = Array("GET / HTTP/1.1\r\nHost: example.com:8080\r\n\r\n".utf8)
        XCTAssertEqual(HTTPProxyRequest.hostFromOriginForm(req), "example.com")
    }

    func testHostFromOriginFormRejectsTLS() {
        // A TLS record (starts 0x16) must not be parsed as HTTP.
        XCTAssertNil(HTTPProxyRequest.hostFromOriginForm([0x16, 0x03, 0x01, 0x00, 0x05]))
    }

    func testHostFromOriginFormNoHostYet() {
        XCTAssertNil(HTTPProxyRequest.hostFromOriginForm(Array("GET / HTTP/1.1\r\n".utf8)))
    }
}
