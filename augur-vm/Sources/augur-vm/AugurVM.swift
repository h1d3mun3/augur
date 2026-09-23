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
        version: AugurVersion.string,
        // Every subcommand below is named `<Noun>Command` — see ADR-0020
        // (docs/decisions/0020-augur-vm-subcommand-naming.md) for why, and follow the
        // same shape for any new one rather than reopening that choice.
        subcommands: [
            VersionCommand.self,
            ListCommand.self,
            SmokeCommand.self,
            CreateCommand.self,
            SetCommand.self,
            RunCommand.self,
            IPCommand.self,
            GuestOSVersionCommand.self,
            StopCommand.self,
            DeleteCommand.self,
            CloneCommand.self,
        ]
    )
}
