import AppKit
import Foundation
import Virtualization

/// GUI run mode: an AppKit window hosting the VM's display so the user can complete
/// Setup Assistant manually (augur's GUI `run` step). Blocks in `NSApplication.run()`.
/// Closing the window (or the guest shutting itself down) terminates the process.
extension RunSession {
    func runGUI() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = MacAppDelegate(session: self)
        appDelegate = delegate          // retain for the app's lifetime
        app.delegate = delegate
        app.run()                        // serviced on the main run loop; never returns
    }

    func startGUIVM() {
        do {
            let config = try buildConfiguration()
            try config.validate()

            let vm = VZVirtualMachine(configuration: config)
            vm.delegate = self
            self.vm = vm

            let display = loadedConfig?.display ?? .default
            let frame = NSRect(x: 0, y: 0, width: display.width, height: display.height)

            let view = VZVirtualMachineView(frame: frame)
            view.virtualMachine = vm
            view.capturesSystemKeys = true
            vmView = view

            let window = NSWindow(
                contentRect: frame,
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "augur-vm: \(name)"
            window.contentView = view
            // NSWindow defaults isReleasedWhenClosed to true, which sends an extra
            // release on close that ARC doesn't account for — an over-release that
            // corrupts the heap and surfaces as a SIGSEGV in objc_release during a
            // later autorelease-pool drain. Disable it and retain the window ourselves.
            window.isReleasedWhenClosed = false
            guiWindow = window
            // Also suppress the close transform animation (one less object churning
            // through CoreAnimation while the window tears down).
            window.animationBehavior = .none
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)

            FileHandle.standardError.write(Data("[augur-vm] booting '\(name)' (GUI)…\n".utf8))
            vm.start { [self] result in
                if case let .failure(error) = result {
                    FileHandle.standardError.write(Data(
                        "[augur-vm] failed to start VM: \(error.localizedDescription)\n".utf8))
                    cleanup()
                    exit(1)
                }
            }
        } catch {
            FileHandle.standardError.write(Data("[augur-vm] \(error)\n".utf8))
            cleanup()
            exit(1)
        }
    }

    /// Begin a graceful shutdown when the app is asked to quit (window closed).
    func guiApplicationShouldTerminate(_ app: NSApplication) -> NSApplication.TerminateReply {
        if isTerminating { return .terminateNow }
        guard let vm, vm.state == .running else { cleanup(); return .terminateNow }

        isTerminating = true
        terminateReply = { app.reply(toApplicationShouldTerminate: true) }

        // Detach the view from the VM before the window tears down so frame delivery
        // stops feeding the closing window's layer tree (see window.animationBehavior).
        vmView?.virtualMachine = nil

        if vm.canRequestStop {
            try? vm.requestStop()
        } else {
            // Host-initiated stop does NOT invoke the guestDidStop delegate, so its
            // completion handler is the only signal — drive termination from it.
            vm.stop { [weak self] _ in self?.finishGUITermination() }
        }
        // Force power-off if the guest ignores the graceful request — common during
        // Setup Assistant, which doesn't honor the ACPI power button. Same caveat:
        // this host-initiated stop only reports back via the completion handler, so
        // wire it to finishGUITermination or the app hangs in .terminateLater forever.
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, let vm = self.vm, vm.state == .running else { return }
            vm.stop { [weak self] _ in self?.finishGUITermination() }
        }
        return .terminateLater
    }

    /// Called from the VM delegate once the guest has actually stopped.
    func finishGUITermination() {
        if let reply = terminateReply {
            terminateReply = nil
            reply()                              // we initiated the stop → let the app quit
        } else if !isTerminating {
            NSApplication.shared.terminate(nil)  // guest-initiated shutdown → quit the app
        }
        // else: reply already sent — ignore duplicate stop callbacks (graceful stop
        // and the 15s force-off racing to finish).
    }
}

final class MacAppDelegate: NSObject, NSApplicationDelegate {
    private let session: RunSession
    init(session: RunSession) { self.session = session }

    func applicationDidFinishLaunching(_ notification: Notification) {
        session.startGUIVM()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        session.guiApplicationShouldTerminate(sender)
    }
}
