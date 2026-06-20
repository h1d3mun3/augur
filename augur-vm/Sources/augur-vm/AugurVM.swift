import ArgumentParser

// NOTE: this entry file is deliberately NOT named main.swift — @main cannot coexist
// with a file named main.swift (top-level-code conflict).
//
// This MUST be a synchronous ParsableCommand, not AsyncParsableCommand:
// AsyncParsableCommand.main() runs the command body inside a Swift Concurrency task
// (off the main thread), and run/create park the process with dispatchMain() /
// NSApplication.run(), both of which require the real main thread. A synchronous
// ParsableCommand.main() runs on the main thread, so those calls are valid.
@main
struct AugurVM: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "augur-vm",
        abstract: "Minimal Virtualization.framework VM tool — the macOS VM backend for augur.",
        version: "0.0.1 (M0)",
        subcommands: [
            // Implemented in M0:
            Version.self,
            ListCmd.self,
            Smoke.self,
            // Stubs (planned milestones):
            Create.self,   // M1
            SetCmd.self,   // M1
            Run.self,      // M2 (headless) / M3 (GUI)
            IP.self,       // M2
            Stop.self,     // M4
            DeleteCmd.self,// M4
            Clone.self,    // M4
        ]
    )
}
