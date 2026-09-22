import ArgumentParser
import Foundation

/// VM listing. augur parses this positionally:
///   - `macos_vm_exists`  : awk 'NR>1 {print $2}'        → name is column 2
///   - `macos_vm_running` : awk 'NR>1 {print $2, $NF}'   → name col 2, state is last column
/// The `Source Name Disk Size State` columns (Source=local) keep a header on row 1
/// (skipped by NR>1) so the contract holds.
struct ListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List VMs (columns: Source Name Disk Size State)."
    )
    func run() {
        print("Source Name Disk Size State")
        for vm in Registry.list() {
            print("local \(vm.name) 0 0 \(vm.running ? "running" : "stopped")")
        }
    }
}
