import Foundation
import Virtualization

/// Boots a VM and keeps the process resident for its lifetime (the `run` command).
/// Headless mode (M2) parks on `dispatchMain()`; GUI mode (M3, see GUIRun.swift)
/// runs an AppKit window for manual Setup Assistant. Networking is NAT with the
/// VM's persisted MAC so `ip` can find the lease. A pidfile (run.pid) records the
/// host PID so `list` can report running state and `stop` (M4) can signal it.
final class RunSession: NSObject, VZVirtualMachineDelegate {
    static var shared: RunSession?

    let name: String
    let headless: Bool
    private let dirs: [String]
    /// When set, the guest NIC is bound to this vfkit unixgram socket (gvproxy) so
    /// all egress is filtered by the host; nil means plain NAT (no filtering).
    private let netVfkitSocket: String?

    var vm: VZVirtualMachine?
    var loadedConfig: VMConfig?
    private var signalSources: [DispatchSourceSignal] = []

    // GUI mode state (used from GUIRun.swift).
    var appDelegate: AnyObject?
    var guiWindow: AnyObject?
    var vmView: VZVirtualMachineView?
    var isTerminating = false
    var terminateReply: (() -> Void)?

    init(name: String, headless: Bool, dirs: [String], netVfkitSocket: String? = nil) {
        self.name = name
        self.headless = headless
        self.dirs = dirs
        self.netVfkitSocket = netVfkitSocket
    }

    /// Entry point: prepare, then either park headless or run the GUI app.
    /// Neither branch returns — the process exits via signals or the VM delegate.
    func run() throws {
        try prepare()
        if headless {
            scheduleBoot()
            dispatchMain()
        } else {
            runGUI()
        }
    }

    /// Synchronous setup done on the main thread before the run loop starts.
    func prepare() throws {
        try writePidfile()
        installSignalHandlers()
    }

    func scheduleBoot() {
        DispatchQueue.main.async { [self] in boot() }
    }

    // MARK: - Boot (headless)

    private func boot() {
        do {
            let config = try buildConfiguration()
            try config.validate()

            let vm = VZVirtualMachine(configuration: config)
            vm.delegate = self
            self.vm = vm

            FileHandle.standardError.write(Data("[augur-vm] booting '\(name)'…\n".utf8))
            vm.start { [self] result in
                if case let .failure(error) = result {
                    fail("failed to start VM: \(error.localizedDescription)")
                }
            }
        } catch {
            fail("\(error)")
        }
    }

    /// Build the runtime configuration from the bundle. A graphics device (virtual
    /// display) and input devices are attached in both modes; `headless` only governs
    /// whether a host-side AppKit window is shown (see `run()`).
    func buildConfiguration() throws -> VZVirtualMachineConfiguration {
        let cfg = try VMConfig.load(name)
        loadedConfig = cfg

        guard let hardwareModel = VZMacHardwareModel(dataRepresentation: cfg.hardwareModel) else {
            throw CLIError("config.json has an invalid hardware model")
        }
        guard let machineIdentifier = VZMacMachineIdentifier(dataRepresentation: cfg.machineIdentifier) else {
            throw CLIError("config.json has an invalid machine identifier")
        }

        let platform = VZMacPlatformConfiguration()
        platform.hardwareModel = hardwareModel
        platform.machineIdentifier = machineIdentifier
        platform.auxiliaryStorage = VZMacAuxiliaryStorage(contentsOf: Paths.nvram(name))

        let config = VZVirtualMachineConfiguration()
        config.platform = platform
        config.bootLoader = VZMacOSBootLoader()
        config.cpuCount = cfg.cpuCount
        config.memorySize = cfg.memorySize
        config.storageDevices = [
            VZVirtioBlockDeviceConfiguration(
                attachment: try VZDiskImageStorageDeviceAttachment(url: Paths.disk(name), readOnly: false)
            )
        ]

        let network = VZVirtioNetworkDeviceConfiguration()
        // Egress-filtered (vfkit/file-handle) when a socket is given, else plain NAT.
        // The persisted bundle (config.json) has no network field, so this choice is
        // purely runtime — base VMs and clones stay byte-compatible either way.
        if let socketPath = netVfkitSocket {
            FileHandle.standardError.write(Data("[augur-vm] egress-filtered networking via \(socketPath)\n".utf8))
            network.attachment = try NetworkAttachment.vfkit(socketPath: socketPath)
            // gvproxy reserves the deviceIP (192.168.127.2 — the SSH-forward target)
            // for this exact MAC via a default static DHCP lease, so the guest must
            // use it to receive that IP and be reachable. (Same MAC podman/vfkit use.)
            if let mac = VZMACAddress(string: NetworkAttachment.vfkitGuestMAC) {
                network.macAddress = mac
            }
        } else {
            network.attachment = NetworkAttachment.nat()
            if let mac = VZMACAddress(string: cfg.macAddress) {
                network.macAddress = mac
            }
        }
        config.networkDevices = [network]

        // Attach a graphics device (virtual display) and input devices even when headless.
        // macOS only brings up an Aqua (GUI) login session when a framebuffer exists, and
        // `xcodebuild test` needs that Aqua session to reach testmanagerd — without a display
        // device, auto-login never produces a console session and tests fail at launch with
        // "com.apple.testmanagerd.control ... No such process". `headless` only suppresses the
        // host-side AppKit window (see run()), not the display device the guest renders to.
        let graphics = VZMacGraphicsDeviceConfiguration()
        graphics.displays = [
            VZMacGraphicsDisplayConfiguration(
                widthInPixels: cfg.display.width,
                heightInPixels: cfg.display.height,
                pixelsPerInch: cfg.display.pixelsPerInch
            )
        ]
        config.graphicsDevices = [graphics]
        config.keyboards = [VZUSBKeyboardConfiguration()]
        config.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]

        let shares = try parseShares()
        if !shares.isEmpty {
            // A single virtiofs device using the automount tag makes the macOS guest
            // mount every share under "/Volumes/My Shared Files/<name>" — the path
            // augur's ~/workspace symlink targets, so it keeps working unchanged.
            let fsDevice = VZVirtioFileSystemDeviceConfiguration(
                tag: VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag)
            fsDevice.share = VZMultipleDirectoryShare(directories: shares)
            config.directorySharingDevices = [fsDevice]
        }

        return config
    }

    /// Parse `--dir name:path` specs into virtiofs shares (split on the first colon).
    private func parseShares() throws -> [String: VZSharedDirectory] {
        var shares: [String: VZSharedDirectory] = [:]
        for spec in dirs {
            guard let colon = spec.firstIndex(of: ":") else {
                throw CLIError("--dir must be in name:path form: '\(spec)'")
            }
            let shareName = String(spec[..<colon])
            let path = String(spec[spec.index(after: colon)...])
            guard !shareName.isEmpty, !path.isEmpty else {
                throw CLIError("--dir must be in name:path form: '\(spec)'")
            }
            shares[shareName] = VZSharedDirectory(
                url: URL(fileURLWithPath: path), readOnly: false)
        }
        return shares
    }

    // MARK: - Lifecycle

    private func writePidfile() throws {
        try "\(getpid())".write(to: Paths.pid(name), atomically: true, encoding: .utf8)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: Paths.pid(name))
    }

    private func installSignalHandlers() {
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in self?.requestStop() }
            source.resume()
            signalSources.append(source)
        }
    }

    private func requestStop() {
        guard let vm else { cleanup(); exit(0) }
        if vm.canRequestStop, (try? vm.requestStop()) != nil {
            return   // guestDidStop / didStopWithError will finish up
        }
        vm.stop { [self] _ in cleanup(); exit(0) }
    }

    private func fail(_ message: String) {
        FileHandle.standardError.write(Data("[augur-vm] \(message)\n".utf8))
        cleanup()
        exit(1)
    }

    // MARK: - VZVirtualMachineDelegate

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        FileHandle.standardError.write(Data("[augur-vm] '\(name)' stopped.\n".utf8))
        cleanup()
        if headless { exit(0) } else { finishGUITermination() }
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        FileHandle.standardError.write(Data(
            "[augur-vm] VM stopped with error: \(error.localizedDescription)\n".utf8))
        cleanup()
        if headless { exit(1) } else { finishGUITermination() }
    }
}
