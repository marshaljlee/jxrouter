import Foundation
import AppKit

/// Helper to identify which app is making a local network connection based on the source port.
struct AppIdentifier {
    
    struct AppInfo {
        let pid: pid_t
        let name: String
        let bundleIdentifier: String?
    }
    
    /// Finds the application information for a given local TCP source port.
    static func identifyApp(sourcePort: UInt16) -> AppInfo? {
        // Run lsof to find the PID associated with this specific local port.
        // We look for ESTABLISHED connections on this port.
        let process = Process()
        let pipe = Pipe()
        
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-i", "TCP:\(sourcePort)", "-P", "-n", "-l"]
        process.standardOutput = pipe
        
        do {
            try process.run()
            process.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return nil }
            
            let lines = output.components(separatedBy: .newlines)
            if lines.count > 1 {
                for line in lines.dropFirst() {
                    let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                    // lsof format: COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME
                    if parts.count >= 2 {
                        let appName = String(parts[0])
                        guard let pid = pid_t(parts[1]) else { continue }
                        
                        // We have the PID. Let's look up NSRunningApplication to get the bundle ID.
                        if let runningApp = NSRunningApplication(processIdentifier: pid) {
                            return AppInfo(
                                pid: pid,
                                name: runningApp.localizedName ?? appName,
                                bundleIdentifier: runningApp.bundleIdentifier
                            )
                        } else {
                            return AppInfo(pid: pid, name: appName, bundleIdentifier: nil)
                        }
                    }
                }
            }
        } catch {
            print("AppIdentifier error: \(error)")
        }
        return nil
    }
}
