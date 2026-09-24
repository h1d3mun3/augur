import Foundation

/// augur-vm's version. There is no augur-vm release independent from augur's own — the
/// repo-root `VERSION` file is augur's single source of truth (see the `augur` script's own
/// `augur_version()`) — so augur-vm reads it at runtime instead of carrying a hand-maintained
/// string. (Reading VERSION at runtime makes version drift structurally impossible instead of
/// relying on someone remembering to edit a second copy on release.)
enum AugurVersion {
    static let string: String = read() ?? "unknown"

    private static func read() -> String? {
        for url in candidateVERSIONURLs {
            guard let contents = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    /// Two layouts, checked in order:
    ///  1. Installed tree: `install` copies this binary to `~/.augur/augur-vm` and stamps
    ///     `~/.augur/VERSION` alongside it — the exact mechanism the `augur` script itself
    ///     relies on for `augur_version()` — so the executable's sibling VERSION is the
    ///     primary source.
    ///  2. Dev/checkout build (`scripts/build.sh`, plain `swift build`): the binary runs out
    ///     of `.build/...` with no sibling VERSION, so fall back to the repo-root VERSION
    ///     found via this source file's own compile-time path. `#filePath` resolves to this
    ///     file's absolute path on the machine that compiled it — always the machine we're
    ///     running on too, since augur-vm is never distributed as a prebuilt binary (the
    ///     README says to build it on the host).
    private static var candidateVERSIONURLs: [URL] {
        var urls: [URL] = []
        if let exe = Bundle.main.executableURL {
            urls.append(exe.deletingLastPathComponent().appendingPathComponent("VERSION"))
        }
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // this file
            .deletingLastPathComponent()   // Sources/augur-vm
            .deletingLastPathComponent()   // Sources
            .deletingLastPathComponent()   // augur-vm package dir -> repo root
        urls.append(repoRoot.appendingPathComponent("VERSION"))
        return urls
    }
}
