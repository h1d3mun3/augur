import Foundation
import Virtualization

/// Builds the `VZVirtualMachineConfiguration` boilerplate shared by install-time
/// (`InstallSession.buildBundleAndConfig`, Installer.swift) and run-time
/// (`RunSession.buildConfiguration`, RunSession.swift) VM configuration: the
/// `VZMacPlatformConfiguration` (hardware model + machine identifier + auxiliary
/// storage), the boot loader, CPU/memory, the single disk storage device, the
/// graphics device with one display, and the USB keyboard + pointing device.
///
/// Deliberately NOT built here: the network device and (for `RunSession`) the
/// directory-sharing device. Each call site attaches those itself on top of the
/// configuration this returns:
///   - Installer.swift always attaches a fixed, unfiltered NAT device — install
///     time has no untrusted guest workload yet, and VZ just needs a full device
///     set to avoid trapping on VM construction.
///   - RunSession.swift attaches the security-sensitive NAT-vs-vfkit choice (the
///     egress-filtering datapath reviewed under docs/security-reviews/), plus an
///     optional virtiofs directory-sharing device. That logic stays untouched at
///     its original call site — see RunSession.buildConfiguration().
enum VMConfigBuilder {
    static func build(
        hardwareModel: VZMacHardwareModel,
        machineIdentifier: VZMacMachineIdentifier,
        auxiliaryStorage: VZMacAuxiliaryStorage,
        cpuCount: Int,
        memorySize: UInt64,
        diskURL: URL,
        display: VMConfig.Display
    ) throws -> VZVirtualMachineConfiguration {
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

        let graphics = VZMacGraphicsDeviceConfiguration()
        graphics.displays = [
            VZMacGraphicsDisplayConfiguration(
                widthInPixels: display.width,
                heightInPixels: display.height,
                pixelsPerInch: display.pixelsPerInch
            )
        ]
        config.graphicsDevices = [graphics]

        config.keyboards = [VZUSBKeyboardConfiguration()]
        config.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]

        return config
    }
}
