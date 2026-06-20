import ArgumentParser
import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// `augur-vm stop <name>` — signal the resident `run` process to shut down the
/// guest gracefully, blocking until it stops (the `stop` command).
struct Stop: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop",
        abstract: "Stop a running VM."
    )

    @Argument(help: "VM name.")
    var name: String

    func validate() throws {
        guard Registry.exists(name) else {
            throw ValidationError("No such VM: '\(name)'.")
        }
    }

    func run() throws {
        guard Registry.isRunning(name), let pid = readPid() else {
            print("[augur-vm] '\(name)' is not running.")
            return
        }

        // SIGTERM → the run process calls requestStop() for a graceful guest shutdown.
        kill(pid, SIGTERM)

        var waited = 0.0
        while Registry.isRunning(name), waited < 30 {
            usleep(500_000)
            waited += 0.5
        }

        if Registry.isRunning(name) {
            if let pid = readPid() { kill(pid, SIGKILL) }
            try? FileManager.default.removeItem(at: Paths.pid(name))
            FileHandle.standardError.write(Data(
                "[augur-vm] '\(name)' did not stop in time; force-killed.\n".utf8))
        } else {
            print("[augur-vm] '\(name)' stopped.")
        }
    }

    private func readPid() -> pid_t? {
        guard let s = try? String(contentsOf: Paths.pid(name), encoding: .utf8) else { return nil }
        return pid_t(s.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
