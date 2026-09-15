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
    /// only — see boot()). Both nil unless `augur-vm run --provision-username` plus
    /// `--provision-password-stdin` was given (Run.swift's validate() guarantees they come as a
    /// pair), and always nil in a build whose SDK predates macOS 27, where those flags and the
    /// code behind them are compiled out entirely.
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

    /// How long `boot()` keeps retrying a start that failed *only* because another process
    /// still holds the bundle's auxiliary-storage lock — see handleStartFailure. Kept well
    /// under augur's own "waiting for SSH" budget so the caller never gives up (and tears the
    /// VM down) while a retry is still pending.
    private static let auxLockRetryLimit = 15
    private static let auxLockRetryDelay: TimeInterval = 2

    private func boot() { boot(attemptsLeft: RunSession.auxLockRetryLimit) }

    private func boot(attemptsLeft: Int) {
        do {
            let config = try buildConfiguration()
            try config.validate()

            let vm = VZVirtualMachine(configuration: config)
            vm.delegate = self
            self.vm = vm

            // Only the first attempt announces the boot; a retry is not a new boot.
            let announce = attemptsLeft == RunSession.auxLockRetryLimit

            // Compiled out when building against an SDK older than macOS 27, which has no
            // VZMacGuestProvisioningOptions to reference — see Run.swift for why the gate is
            // `compiler(>=6.4)` and why `@available` cannot do this job. With the feature out,
            // provisionUsername is always nil (its flags do not exist), so every boot takes the
            // plain start below.
            #if compiler(>=6.4)
            if let username = provisionUsername, let password = provisionPassword {
                // Only meaningful on the guest's FIRST boot after `create` — Virtualization
                // ignores these options on every later boot, and on a guest whose installed
                // OS predates macOS 27 (Run.swift's --no-graphics requirement plus this host
                // check are the only gates here; augur's `cmd_build_macos` is what also checks
                // the GUEST's OS version via `guest-os-version` before ever passing these flags —
                // see ADR-0018).
                guard #available(macOS 27, *) else {
                    fail("--provision-username/--provision-password-stdin need a macOS 27+ host (Virtualization's automated guest provisioning is unavailable on this host)")
                    return
                }
                if announce {
                    FileHandle.standardError.write(Data(
                        "[augur-vm] booting '\(name)'… (automated guest provisioning for '\(username)')\n".utf8))
                }
                let options = try provisioningStartOptions(username: username, password: password)
                vm.start(options: options) { [self] errorOrNil in
                    if let error = errorOrNil {
                        handleStartFailure(error, attemptsLeft: attemptsLeft)
                    }
                }
                return
            }
            #endif

            if announce {
                FileHandle.standardError.write(Data("[augur-vm] booting '\(name)'…\n".utf8))
            }
            vm.start { [self] result in
                if case let .failure(error) = result {
                    handleStartFailure(error, attemptsLeft: attemptsLeft)
                }
            }
        } catch {
            fail("\(error)")
        }
    }

    #if compiler(>=6.4)
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
    #endif

    /// A start that failed *only* because another process still holds this bundle's
    /// auxiliary-storage (nvram.bin) lock is retried, not reported. The usual holder is the
    /// `create` installer's own VM: Virtualization runs a guest inside a
    /// `com.apple.Virtualization.VirtualMachine` XPC service that outlives the `create`
    /// process which spawned it, so the lock can still be held for a while after `create`
    /// has exited and printed "created". A `run` issued immediately afterwards therefore
    /// loses a race it wins a moment later. `cmd_build_macos`'s automated path does exactly
    /// that; the manual Setup Assistant flow only ever got away with it because its
    /// "press Enter to open the VM window" prompt made a human sit out the window.
    private func handleStartFailure(_ error: Error, attemptsLeft: Int) {
        guard attemptsLeft > 0, isAuxiliaryStorageLockContention(error) else {
            fail(startFailureReport(error))
            return
        }
        if attemptsLeft == RunSession.auxLockRetryLimit {
            FileHandle.standardError.write(Data(
                "[augur-vm] '\(name)' auxiliary storage is locked by another process; retrying…\n".utf8))
        }
        // Drop the half-started VM so the next attempt rebuilds the configuration (and with
        // it the VZMacAuxiliaryStorage) from scratch rather than reusing a failed instance.
        vm = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + RunSession.auxLockRetryDelay) { [self] in
            boot(attemptsLeft: attemptsLeft - 1)
        }
    }

    /// True for the one start failure worth retrying: VZ could not take the auxiliary
    /// storage's advisory lock because someone else holds it. Keyed on the underlying POSIX
    /// errno (EAGAIN/EWOULDBLOCK, what a non-blocking flock returns under contention), never
    /// on the localized message, which is user-language dependent. The outer domain/code pair
    /// is VZErrorDomain/2 (`VZErrorInvalidVirtualMachineConfiguration`) as observed from the
    /// framework; matching it keeps an unrelated EAGAIN from being retried forever.
    private func isAuxiliaryStorageLockContention(_ error: Error) -> Bool {
        let ns = error as NSError
        guard ns.domain == "VZErrorDomain", ns.code == 2 else { return false }
        guard let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError else { return false }
        return underlying.domain == NSPOSIXErrorDomain && underlying.code == Int(EAGAIN)
    }

    /// Expand a `start` failure into something diagnosable (mirrors the install path's
    /// reporting). `localizedDescription` alone collapses distinct causes into one string —
    /// "Failed to lock auxiliary storage." says nothing about WHY the lock failed, while the
    /// underlying POSIX error separates "another process holds it" (EAGAIN/EWOULDBLOCK) from
    /// "we cannot open it for writing at all" (EACCES/EPERM).
    private func startFailureReport(_ error: Error) -> String {
        let ns = error as NSError
        var msg = "failed to start VM: \(error.localizedDescription)"
        msg += "\n  domain=\(ns.domain) code=\(ns.code)"
        if let reason = ns.localizedFailureReason {
            msg += "\n  reason: \(reason)"
        }
        // Bounded walk: this runs on the failure path, where spinning on a self-referential
        // error chain would replace a diagnosable message with a hang.
        var underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError
        var depth = 0
        while let u = underlying, depth < 5 {
            msg += "\n  underlying: \(u.domain) code=\(u.code) — \(u.localizedDescription)"
            underlying = u.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        msg += "\n  nvram: \(Paths.nvram(name).path)"
        return msg
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
