// swift-tools-version:5.9
import PackageDescription

// augur-proxy — the host-side egress filter shared by both augur modes.
//
// Deliberately a SEPARATE package from augur-vm: augur-vm imports
// Virtualization.framework and is macOS-only, but this proxy must also run on a
// Linux host (Docker Engine). So it is cross-platform and has NO third-party
// dependencies — POSIX sockets only — to stay lightweight and build offline.
let package = Package(
    name: "augur-proxy",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "augur-proxy", targets: ["augur-proxy"]),
        .library(name: "AugurProxyCore", targets: ["AugurProxyCore"]),
    ],
    targets: [
        .target(name: "AugurProxyCore"),
        .executableTarget(
            name: "augur-proxy",
            dependencies: ["AugurProxyCore"]
        ),
        .testTarget(
            name: "AugurProxyCoreTests",
            dependencies: ["AugurProxyCore"]
        ),
    ]
)
