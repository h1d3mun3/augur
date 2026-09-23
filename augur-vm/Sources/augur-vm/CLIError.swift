import Foundation

/// Lightweight error carrying a human-readable message.
struct CLIError: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}
