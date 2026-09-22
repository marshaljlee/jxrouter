import Foundation
import AppKit

/// Turns the PIDs holding a port into something the user can act on.
///
/// The pre-flight `lsof` check yields bare PIDs, but "port in use by PID 4821"
/// doesn't tell anyone *what* to quit. `NSRunningApplication` resolves the
/// friendly name ("Claude Code") with no subprocess, so a port conflict at
/// startup stays cheap. Non-application processes (daemons, other users'
/// processes) aren't visible to it, so those fall back to the PID.
enum PortOwner {
    /// - Parameter pids: raw `lsof -ti` output, newline-separated.
    /// - Parameter limit: caps the list so the message stays readable when
    ///   several processes match.
    static func names(for pids: String, limit: Int = 3) -> [String] {
        let ids = pids
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .compactMap { Int32($0) }
        var names: [String] = []
        for pid in ids where pid > 0 {
            if let name = NSRunningApplication(processIdentifier: pid)?.localizedName,
               !name.isEmpty {
                names.append("\(name) (PID \(pid))")
            } else {
                names.append("PID \(pid)")
            }
            if names.count >= limit { break }
        }
        return names
    }

    /// The user-facing sentence for a port conflict.
    ///
    /// Lives here (rather than inline in `ProxyError.portInUse`) so the wording
    /// is covered by tests without pulling `ProxyServer` into the test bundle.
    static func conflictMessage(port: Int, pids: String, limit: Int = 3) -> String {
        let owners = names(for: pids, limit: limit)
        let who = owners.isEmpty ? "PID(s): \(pids)" : owners.joined(separator: ", ")
        return "Port \(port) is in use by \(who). Quit it, then click Restart."
    }
}
