import Foundation
import AppKit

struct AppIdentifier {
    struct AppInfo {
        let name: String
        let bundleIdentifier: String?
        /// Owning process, when lsof could attribute the connection to one.
        let pid: Int32?

        /// Declared explicitly rather than relying on the synthesized memberwise
        /// initializer: a property with a default value (`= nil`) is *omitted*
        /// from the memberwise init, so `AppInfo(name:bundleIdentifier:pid:)`
        /// would not exist. `pid` defaults to nil so existing call sites are
        /// unaffected.
        init(name: String, bundleIdentifier: String?, pid: Int32? = nil) {
            self.name = name
            self.bundleIdentifier = bundleIdentifier
            self.pid = pid
        }
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
            let pidValue = Int32(pid)
            if let app = apps.first(where: { String($0.processIdentifier) == pid }) {
                return AppInfo(name: app.localizedName ?? app.bundleIdentifier ?? "Unknown",
                               bundleIdentifier: app.bundleIdentifier,
                               pid: pidValue)
            }
            return AppInfo(name: pid, bundleIdentifier: nil, pid: pidValue)
        } catch {
            return nil
        }
    }
}
