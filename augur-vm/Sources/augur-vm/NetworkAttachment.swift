import Foundation
import Virtualization
#if canImport(Darwin)
import Darwin
#endif

/// Builds the guest's network attachment. Two modes:
///
///  - NAT (default): `VZNATNetworkDeviceAttachment` — the existing behavior. The
///    guest reaches the internet directly through macOS's NAT; there is no egress
///    filtering. Used when `--net-vfkit` is absent.
///
///  - vfkit/file-handle (egress-filtered): `VZFileHandleNetworkDeviceAttachment`
///    over a connected `AF_UNIX`/`SOCK_DGRAM` socket whose other end is a
///    user-space network stack on the host (gvproxy). Every guest ethernet frame
///    is delivered to that host process, which is therefore the SOLE egress path —
///    so the augur-proxy allowlist holds even against a root agent in the guest,
///    with no host sudo and only the existing `com.apple.security.virtualization`
///    entitlement (bridged/vmnet modes, which need the Apple-gated
///    `com.apple.vm.networking`, are deliberately NOT used).
///
/// The frame transport matches the "vfkit" convention gvproxy speaks
/// (`gvproxy --listen-vfkit unixgram://<path>`): one datagram == one L2 frame.
enum NetworkAttachment {
    /// MAC the guest must present in vfkit/egress mode. gvproxy ships a default
    /// static DHCP lease mapping its deviceIP (192.168.127.2 — the host's
    /// SSH-forward target) to this MAC, so the guest receives that fixed IP and is
    /// reachable. This is the same MAC podman/vfkit guests use with gvproxy.
    static let vfkitGuestMAC = "5a:94:ef:e4:0c:ee"

    /// Connect to gvproxy's unixgram socket at `socketPath` and wrap the fd for VZ.
    /// The returned attachment retains ownership of the socket via the FileHandle.
    static func vfkit(socketPath: String) throws -> VZNetworkDeviceAttachment {
        let fd = socket(AF_UNIX, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw CLIError("vfkit: socket() failed: \(String(cString: strerror(errno)))") }

        // A datagram socket must have a local name so gvproxy can reply to it; bind
        // an abstract/temporary path, then connect to gvproxy's listening socket.
        let localPath = "\(NSTemporaryDirectory())augur-vfkit-\(getpid()).sock"
        unlink(localPath)
        try bindUnix(fd, path: localPath)
        try connectUnix(fd, path: socketPath)

        // Larger socket buffers: bulk transfers (git clone, brew bottles, multi-GB
        // simulator runtimes) otherwise drop frames on a SOCK_DGRAM transport.
        var bufSize: Int32 = 4 * 1024 * 1024
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &bufSize, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &bufSize, socklen_t(MemoryLayout<Int32>.size))

        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        return VZFileHandleNetworkDeviceAttachment(fileHandle: handle)
    }

    static func nat() -> VZNetworkDeviceAttachment {
        VZNATNetworkDeviceAttachment()
    }

    // MARK: - sockaddr_un helpers

    private static func bindUnix(_ fd: Int32, path: String) throws {
        try withSockaddrUn(path) { sa, len in
            guard bind(fd, sa, len) == 0 else {
                throw CLIError("vfkit: bind(\(path)) failed: \(String(cString: strerror(errno)))")
            }
        }
    }

    private static func connectUnix(_ fd: Int32, path: String) throws {
        try withSockaddrUn(path) { sa, len in
            guard connect(fd, sa, len) == 0 else {
                throw CLIError("vfkit: connect(\(path)) failed: \(String(cString: strerror(errno))) — is gvproxy listening?")
            }
        }
    }

    /// Fill a `sockaddr_un` with `path` and pass it to `body` as a generic sockaddr.
    private static func withSockaddrUn(_ path: String,
                                       _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> Void) throws {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        // macOS/BSD sockaddr_un carries sun_len; set it so bind/connect are happy.
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let cap = MemoryLayout.size(ofValue: addr.sun_path)
        let bytes = Array(path.utf8)
        guard bytes.count < cap else { throw CLIError("vfkit: socket path too long: \(path)") }
        withUnsafeMutablePointer(to: &addr.sun_path) { raw in
            raw.withMemoryRebound(to: CChar.self, capacity: cap) { dst in
                for (i, b) in bytes.enumerated() { dst[i] = CChar(bitPattern: b) }
                dst[bytes.count] = 0
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        try withUnsafePointer(to: &addr) {
            try $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { try body($0, len) }
        }
    }
}
