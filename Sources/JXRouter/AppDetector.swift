import Foundation

@MainActor
@Observable
final class AppDetector {
    var detectedApps: [String] = []
    private var timer: Timer?
    var port: Int = 5255
    
    func start(port: Int) {
        self.port = port
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in
            Task { @MainActor in
                self.detectApps()
            }
        }
        detectApps() // Initial run
    }
    
    func stop() {
        timer?.invalidate()
        timer = nil
        detectedApps.removeAll()
    }
    
    private func detectApps() {
        let process = Process()
        let pipe = Pipe()
        
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-i", ":\(port)", "-P", "-n"]
        process.standardOutput = pipe
        
        do {
            try process.run()
            process.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return }
            
            var apps: Set<String> = []
            let lines = output.components(separatedBy: .newlines)
            
            if lines.count > 1 {
                for line in lines.dropFirst() {
                    let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                    if parts.count > 0 {
                        let appName = String(parts[0])
                        // Exclude our own app name
                        if appName != "jxproxy" && appName != "JXProxy" && !appName.isEmpty {
                            apps.insert(appName)
                        }
                    }
                }
            }
            
            self.detectedApps = Array(apps).sorted()
        } catch {
            print("AppDetector error: \(error)")
        }
    }
}
