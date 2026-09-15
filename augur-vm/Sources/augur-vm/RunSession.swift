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
    /// all egress is filtered by the host. This is the default datapath: if it is
    /// nil and NAT was not explicitly requested, the boot fails closed.
    private let netVfkitSocket: String?
    /// Opt-in to unfiltered NAT. Without it (and without a vfkit socket) the VM
    /// refuses to boot rather than silently granting the guest full network access.
    private let netAllowNAT: Bool
    /// Automated first-boot account setup (VZMacGuestProvisioningOptions, macOS 27+ host
    /// only — see boot()). Both nil unless `augur-vm run --provision-username/--provision-password`
    /// was given; Run.swift's validate() guarantees they're either both set or both nil.
    private let provisionUsername: String?
    private let provisionPassword: String?
    private let provisionFullName: String

    var vm: VZVirtualMachine?
    var loadedConfig: VMConfig?
    private var signalSources: [DispatchSourceSignal] = []

    // GUI mode state (used from GUIRun.swift).
    var appDelegate: AnyObject?
    var guiWindow: AnyObject?
    var vmView: VZVirtualMachineView?
    var isTerminating = false
    var terminateReply: (() -> Void)?

    init(
        name: String, headless: Bool, dirs: [String], netVfkitSocket: String? = nil, netAllowNAT: Bool = false,
        provisionUsername: String? = nil, provisionPassword: String? = nil, provisionFullName: String = "augur"
    ) {
        self.name = name
        self.headless = headless
        self.dirs = dirs
        self.netVfkitSocket = netVfkitSocket
        self.netAllowNAT = netAllowNAT
        self.provisionUsername = provisionUsername
        self.provisionPassword = provisionPassword
        self.provisionFullName = provisionFullName
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

            if let username = provisionUsername, let password = provisionPassword {
                // Only meaningful on the guest's FIRST boot after `create` — Virtualization
                // ignores these options on every later boot, and on a guest whose installed
                // OS predates macOS 27 (Run.swift's --no-graphics requirement plus this host
                // check are the only gates here; augur's `cmd_build_macos` is what also checks
                // the GUEST's OS version via `guest-os-version` before ever passing these flags —
                // see ADR-0018).
                guard #available(macOS 27, *) else {
                    fail("--provision-username/--provision-password need a macOS 27+ host (Virtualization's automated guest provisioning is unavailable on this host)")
                    return
                }
                FileHandle.standardError.write(Data(
                    "[augur-vm] booting '\(name)'… (automated guest provisioning for '\(username)')\n".utf8))
                let options = try provisioningStartOptions(username: username, password: password)
                vm.start(options: options) { [self] errorOrNil in
                    if let error = errorOrNil {
                        fail("failed to start VM: \(error.localizedDescription)")
                    }
                }
            } else {
                FileHandle.standardError.write(Data("[augur-vm] booting '\(name)'…\n".utf8))
                vm.start { [self] result in
                    if case let .failure(error) = result {
                        fail("failed to start VM: \(error.localizedDescription)")
                    }
                }
            }
        } catch {
            fail("\(error)")
        }
    }

    /// Builds start options that provision the guest's admin account on first boot
    /// (`VZMacGuestProvisioningOptions`, macOS 27+ host and guest only — see boot()).
    /// `logsInAutomatically` replaces augur's kcpassword hack (the legacy manual-Setup-
    /// Assistant path in `cmd_build_macos` still needs that hack; this path doesn't), and
    /// `enablesRemoteLogin` replaces the manual "System Settings → Sharing → Remote Login"
    /// step, so the caller can go straight to a headless boot and wait for SSH.
    @available(macOS 27, *)
    private func provisioningStartOptions(username: String, password: String) throws -> VZMacOSVirtualMachineStartOptions {
        let provisioning = VZMacGuestProvisioningOptions()
        provisioning.fullName = provisionFullName
        provisioning.username = username
        provisioning.password = password
        provisioning.logsInAutomatically = true
        provisioning.enablesRemoteLogin = true

        let options = VZMacOSVirtualMachineStartOptions()
        try options.setGuestProvisioning(provisioning)
        return options
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
        // Networking is fail-closed: the egress-filtered (vfkit/file-handle) datapath
        // is the default, and unfiltered NAT must be opted into with --net-nat. A run
        // with neither a vfkit socket nor --net-nat refuses to boot, so a forgotten
        // flag never silently grants the guest full internet (and the persisted disk
        // may carry injected ~/.augur-env secrets). The persisted bundle (config.json)
        // has no network field, so this choice is purely runtime — base VMs and clones
        // stay byte-compatible either way.
        if netAllowNAT {
            network.attachment = NetworkAttachment.nat()
            if let mac = VZMACAddress(string: cfg.macAddress) {
                network.macAddress = mac
            }
        } else {
            guard let socketPath = netVfkitSocket else {
                throw CLIError("egress-filtered networking requires --net-vfkit <socket>; pass --net-nat to opt into unfiltered NAT")
            }
            FileHandle.standardError.write(Data("[augur-vm] egress-filtered networking via \(socketPath)\n".utf8))
            network.attachment = try NetworkAttachment.vfkit(socketPath: socketPath)
            // gvproxy reserves the deviceIP (192.168.127.2 — the SSH-forward target)
            // for this exact MAC via a default static DHCP lease, so the guest must
            // use it to receive that IP and be reachable. (Same MAC podman/vfkit use.)
            if let mac = VZMACAddress(string: NetworkAttachment.vfkitGuestMAC) {
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

    /// Parse `--dir name:path[:ro]` specs into virtiofs shares. The name is split
    /// off the first colon (so the path may itself contain colons); an optional
    /// trailing `:ro` marks the share read-only. Shares are read-write by default,
    /// so existing `name:path` specs are unaffected. Read-only shares let augur
    /// expose host config (e.g. gh-config) the guest may read but must not tamper.
    private func parseShares() throws -> [String: VZSharedDirectory] {
        var shares: [String: VZSharedDirectory] = [:]
        for spec in dirs {
            guard let colon = spec.firstIndex(of: ":") else {
                throw CLIError("--dir must be in name:path[:ro] form: '\(spec)'")
            }
            let shareName = String(spec[..<colon])
            var path = String(spec[spec.index(after: colon)...])
            var readOnly = false
            if path.hasSuffix(":ro") {
                readOnly = true
                path = String(path.dropLast(3))
            }
            guard !shareName.isEmpty, !path.isEmpty else {
                throw CLIError("--dir must be in name:path[:ro] form: '\(spec)'")
            }
            shares[shareName] = VZSharedDirectory(
                url: URL(fileURLWithPath: path), readOnly: readOnly)
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
