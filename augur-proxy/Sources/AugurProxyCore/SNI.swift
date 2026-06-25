import Foundation

/// Extracts the SNI host_name from a TLS ClientHello. We never decrypt — reading
/// the SNI is a plaintext peek used as a *secondary* signal (the primary control is
/// the by-name allowlist decision the proxy protocol already gave us). It also lets
/// a future transparent datapath (no proxy protocol) make a decision.
///
/// Returns nil on anything unexpected (not a ClientHello, truncated, ECH-hidden, no
/// SNI extension) so the caller fails closed.
public enum TLSClientHello {
    /// `bytes` should begin at the start of the TLS record (handshake type 0x16).
    public static func serverName(fromRecord bytes: [UInt8]) -> String? {
        // TLS record header: type(1) version(2) length(2)
        guard bytes.count >= 5, bytes[0] == 0x16 else { return nil }
        let recordLen = Int(bytes[3]) << 8 | Int(bytes[4])
        let body = Array(bytes[5...])
        guard body.count >= recordLen else { return nil }  // need the whole record
        return serverName(fromHandshake: Array(body[0..<recordLen]))
    }

    /// `bytes` begins at the handshake message (type 0x01 = client_hello).
    public static func serverName(fromHandshake bytes: [UInt8]) -> String? {
        var r = Reader(bytes)
        guard r.u8() == 0x01 else { return nil }       // client_hello
        guard let bodyLen = r.u24() else { return nil }
        guard r.remaining >= bodyLen else { return nil }
        _ = r.bytes(2)                                  // client_version
        _ = r.bytes(32)                                 // random
        guard let sidLen = r.u8v() else { return nil }  // session_id
        _ = r.bytes(Int(sidLen))
        guard let csLen = r.u16() else { return nil }   // cipher_suites
        _ = r.bytes(csLen)
        guard let cmLen = r.u8v() else { return nil }   // compression_methods
        _ = r.bytes(Int(cmLen))
        guard let extTotal = r.u16() else { return nil } // extensions
        var extRead = 0
        while extRead < extTotal {
            guard let extType = r.u16(), let extLen = r.u16() else { return nil }
            extRead += 4 + extLen
            if extType == 0x0000 {                       // server_name
                guard let ext = r.bytes(extLen) else { return nil }
                return parseServerNameExtension(ext)
            } else {
                guard r.bytes(extLen) != nil else { return nil }
            }
        }
        return nil
    }

    /// server_name extension body: list_len(2) [ type(1) name_len(2) name ]…
    static func parseServerNameExtension(_ bytes: [UInt8]) -> String? {
        var r = Reader(bytes)
        guard let listLen = r.u16(), r.remaining >= listLen else { return nil }
        guard let nameType = r.u8(), nameType == 0x00 else { return nil }  // host_name
        guard let nameLen = r.u16(), let name = r.bytes(nameLen) else { return nil }
        let host = String(decoding: name, as: UTF8.self)
        return host.isEmpty ? nil : host
    }
}

/// A tiny bounds-checked byte reader; every accessor returns nil past the end.
private struct Reader {
    private let b: [UInt8]
    private var i = 0
    init(_ bytes: [UInt8]) { b = bytes }
    var remaining: Int { b.count - i }

    mutating func u8() -> UInt8? { i < b.count ? { defer { i += 1 }; return b[i] }() : nil }
    mutating func u8v() -> UInt8? { u8() }
    mutating func u16() -> Int? {
        guard i + 2 <= b.count else { return nil }
        defer { i += 2 }; return Int(b[i]) << 8 | Int(b[i+1])
    }
    mutating func u24() -> Int? {
        guard i + 3 <= b.count else { return nil }
        defer { i += 3 }; return Int(b[i]) << 16 | Int(b[i+1]) << 8 | Int(b[i+2])
    }
    mutating func bytes(_ n: Int) -> [UInt8]? {
        guard n >= 0, i + n <= b.count else { return nil }
        defer { i += n }; return Array(b[i..<i+n])
    }
}
