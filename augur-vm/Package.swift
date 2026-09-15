// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "augur-vm",
    // macOS 13 (Ventura): VZMultipleDirectoryShare + macOSGuestAutomountTag (M5),
    // VZMacOSInstaller / NAT / restore-image are macOS 12+ but we standardize on 13.
    // (RunSession.swift additionally uses VZMacGuestProvisioningOptions, macOS 27+ only — gated
    // at runtime with `#available`/`@available`, not via this deployment target, so a host below
    // macOS 27 still builds and runs everything else unchanged. See ADR-0018.)
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    ],
    targets: [
        .executableTarget(
            name: "augur-vm",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/augur-vm"
        ),
    ]
)
