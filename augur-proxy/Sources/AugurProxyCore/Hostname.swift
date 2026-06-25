import Foundation

/// Strict LDH (letters/digits/hyphen) hostname validation. This is security
/// critical: the SAME host string is used for the allowlist decision AND for the
/// upstream `getaddrinfo` dial, and `getaddrinfo` truncates a C string at the
/// first NUL. Without this check, an SNI/Host of `evil.com\u{0}.github.com` would
/// match `*.github.com` (the allowlist sees the whole string) yet dial `evil.com`
/// (getaddrinfo stops at the NUL) — a full egress bypass. Every host recovered
/// from an untrusted stream (SNI, HTTP Host, CONNECT authority) must pass this
/// before it is used for anything; a reject fails closed.
public func isValidHostname(_ s: String) -> Bool {
    var host = s
    if host.hasSuffix(".") { host.removeLast() }   // tolerate one FQDN trailing dot
    let bytes = Array(host.utf8)
    guard !bytes.isEmpty, bytes.count <= 253 else { return false }

    var labelLen = 0
    for b in bytes {
        if b == 0x2E {                              // '.'
            if labelLen == 0 { return false }       // empty label (leading dot / "..")
            labelLen = 0
            continue
        }
        let isLDH = (b >= 0x41 && b <= 0x5A)        // A-Z
                 || (b >= 0x61 && b <= 0x7A)        // a-z
                 || (b >= 0x30 && b <= 0x39)        // 0-9
                 || b == 0x2D                       // '-'
        guard isLDH else { return false }           // rejects NUL, spaces, etc.
        labelLen += 1
        if labelLen > 63 { return false }
    }
    return labelLen > 0                             // reject a trailing empty label
}
