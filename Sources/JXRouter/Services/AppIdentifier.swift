import Foundation
import AppKit

struct AppIdentifier {
    struct AppInfo {
        let name: String
        let bundleIdentifier: String?
    }

    static func identifyApp(sourcePort: UInt16) -> AppInfo? {
        // Use lsof to find which process owns the given port
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments = ["-i", "TCP:\(sourcePort)", "-s", "TCP:ESTABLISHED", "-n", "-P"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            guard let output = String(data: data, encoding: .utf8) else { return nil }
            let lines = output.components(separatedBy: "\n").dropFirst()
            guard let firstLine = lines.first else { return nil }
            let cols = firstLine.split(separator: " ", omittingEmptySubsequences: true)
            guard cols.count > 0 else { return nil }
            let pid = String(cols[1])

            // Find the app by PID
            let apps = NSWorkspace.shared.runningApplications
            if let app = apps.first(where: { String($0.processIdentifier) == pid }) {
                return AppInfo(name: app.localizedName ?? app.bundleIdentifier ?? "Unknown", bundleIdentifier: app.bundleIdentifier)
            }
            return AppInfo(name: pid, bundleIdentifier: nil)
        } catch {
            return nil
        }
    }
}
