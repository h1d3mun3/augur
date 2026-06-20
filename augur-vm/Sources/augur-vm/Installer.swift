import Foundation
import Virtualization

/// Drives `VZMacOSInstaller` to install macOS from an IPSW onto a fresh bundle.
///
/// VZ delivers all callbacks on the VM's queue (the main DispatchQueue by default),
/// so the whole flow runs on `DispatchQueue.main` and the caller parks the process
/// with `dispatchMain()`. Completion handlers terminate the process via `exit()`.
/// `InstallSession.shared` retains the session (and its VM/installer/observation)
/// for the lifetime of the install.
final class InstallSession {
    static var shared: InstallSession?

    private let name: String
    private let ipswURL: URL
    private let diskSizeGB: UInt64

    private var vm: VZVirtualMachine?
    private var installer: VZMacOSInstaller?
    private var observation: NSKeyValueObservation?

    init(name: String, ipswURL: URL, diskSizeGB: UInt64) {
        self.name = name
        self.ipswURL = ipswURL
        self.diskSizeGB = diskSizeGB
    }

    func start() {
        VZMacOSRestoreImage.load(from: ipswURL) { [self] result in
            DispatchQueue.main.async { [self] in
                switch result {
                case .failure(let error):
                    fail("failed to load restore image: \(error.localizedDescription)")
                case .success(let image):
                    proceed(with: image)
                }
            }
        }
    }

    // MARK: - Install

    private func proceed(with image: VZMacOSRestoreImage) {
        guard let requirements = image.mostFeaturefulSupportedConfiguration else {
            fail("this IPSW has no configuration supported by the current host")
            return
        }
        guard requirements.hardwareModel.isSupported else {
            fail("the IPSW's hardware model is not supported on this host")
            return
        }

        do {
            let config = try buildBundleAndConfig(requirements: requirements)
            try config.validate()

            let vm = VZVirtualMachine(configuration: config)
            self.vm = vm

            let installer = VZMacOSInstaller(virtualMachine: vm, restoringFromImageAt: ipswURL)
            self.installer = installer

            observation = installer.progress.observe(\.fractionCompleted, options: [.initial, .new]) { progress, _ in
                let pct = Int(progress.fractionCompleted * 100)
                FileHandle.standardError.write(Data("\r[augur-vm] installing macOS… \(pct)%   ".utf8))
            }

            installer.install { [self] result in
                observation = nil
                switch result {
                case .failure(let error):
                    let ns = error as NSError
                    var msg = "\ninstall failed: \(error.localizedDescription)"
                    msg += "\n  domain=\(ns.domain) code=\(ns.code)"
                    if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
                        msg += "\n  underlying: \(underlying.domain) code=\(underlying.code) — \(underlying.localizedDescription)"
                    }
                    fail(msg)
                case .success:
                    FileHandle.standardError.write(Data("\n".utf8))
                    print("[augur-vm] created '\(name)'")
                    exit(0)
                }
            }
        } catch {
            fail(error.localizedDescription)
        }
    }

    /// Create the bundle directory, disk image, NVRAM, persist config.json, and
    /// return the runtime configuration used to install (platform + boot + disk).
    private func buildBundleAndConfig(requirements: VZMacOSConfigurationRequirements) throws -> VZVirtualMachineConfiguration {
        let hardwareModel = requirements.hardwareModel

        let cpuCount = Clamp.cpuCount(min: requirements.minimumSupportedCPUCount)
        let memorySize = Clamp.memorySize(min: requirements.minimumSupportedMemorySize)

        let bundle = Paths.bundle(name)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)

        // Sparse disk image of the requested size.
        let diskURL = Paths.disk(name)
        FileManager.default.createFile(atPath: diskURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: diskURL)
        try handle.truncate(atOffset: diskSizeGB * 1024 * 1024 * 1024)
        try handle.close()

        let machineIdentifier = VZMacMachineIdentifier()
        let auxiliaryStorage = try VZMacAuxiliaryStorage(
            creatingStorageAt: Paths.nvram(name),
            hardwareModel: hardwareModel,
            options: []
        )
        let macAddress = VZMACAddress.randomLocallyAdministered().string

        let persisted = VMConfig(
            cpuCount: cpuCount,
            memorySize: memorySize,
            macAddress: macAddress,
            diskSizeGB: diskSizeGB,
            hardwareModel: hardwareModel.dataRepresentation,
            machineIdentifier: machineIdentifier.dataRepresentation,
            display: .default
        )
        try persisted.save(name)

        // Minimal install-time configuration: no network or graphics needed to
        // install; `run` (M2/M3) rebuilds a full runtime config from the bundle.
        let platform = VZMacPlatformConfiguration()
        platform.hardwareModel = hardwareModel
        platform.machineIdentifier = machineIdentifier
        platform.auxiliaryStorage = auxiliaryStorage

        let config = VZVirtualMachineConfiguration()
        config.platform = platform
        config.bootLoader = VZMacOSBootLoader()
        config.cpuCount = cpuCount
        config.memorySize = memorySize
        config.storageDevices = [
            VZVirtioBlockDeviceConfiguration(
                attachment: try VZDiskImageStorageDeviceAttachment(url: diskURL, readOnly: false)
            )
        ]

        // The installer needs the same device set a bootable macOS VM has — a minimal
        // config (platform + boot + disk only) makes VZ trap (SIGTRAP) when the VM is
        // constructed. Mirror Apple's install sample: graphics, NAT network, and USB
        // keyboard + pointing device.
        let graphics = VZMacGraphicsDeviceConfiguration()
        graphics.displays = [
            VZMacGraphicsDisplayConfiguration(
                widthInPixels: persisted.display.width,
                heightInPixels: persisted.display.height,
                pixelsPerInch: persisted.display.pixelsPerInch
            )
        ]
        config.graphicsDevices = [graphics]

        let network = VZVirtioNetworkDeviceConfiguration()
        network.attachment = VZNATNetworkDeviceAttachment()
        if let mac = VZMACAddress(string: macAddress) {
            network.macAddress = mac
        }
        config.networkDevices = [network]

        config.keyboards = [VZUSBKeyboardConfiguration()]
        config.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]

        return config
    }

    private func fail(_ message: String) {
        FileHandle.standardError.write(Data("[augur-vm] \(message)\n".utf8))
        exit(1)
    }
}

/// CPU/memory clamping shared by create (and later `set` validation).
enum Clamp {
    static func cpuCount(min minimum: Int, desired: Int = 4) -> Int {
        let lower = max(minimum, VZVirtualMachineConfiguration.minimumAllowedCPUCount)
        let upper = min(VZVirtualMachineConfiguration.maximumAllowedCPUCount,
                        ProcessInfo.processInfo.processorCount)
        return Swift.max(lower, Swift.min(desired, Swift.max(lower, upper)))
    }

    static func memorySize(min minimum: UInt64, desired: UInt64 = 4 * 1024 * 1024 * 1024) -> UInt64 {
        let lower = Swift.max(minimum, VZVirtualMachineConfiguration.minimumAllowedMemorySize)
        let upper = VZVirtualMachineConfiguration.maximumAllowedMemorySize
        return Swift.min(Swift.max(lower, desired), upper)
    }
}
