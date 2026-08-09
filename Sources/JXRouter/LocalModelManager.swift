import Foundation
import Observation

/// Manages the local model servers JXProxy can start on this Mac: the Llama
/// desktop app (llama.app) and Ollama. Provides start/stop lifecycle and
/// status tracking. llama.app is launched as a GUI app whose built-in server
/// serves on port 8080; Ollama runs as a background server process.
@MainActor
@Observable
final class LocalModelManager {
    static let shared = LocalModelManager()

    // MARK: - State

    enum ServerStatus: Equatable {
        case stopped
        case starting
        case running(pid: Int32)
        case failed(String)
    }

    enum LocalProvider: String, CaseIterable {
        case llamaapp = "llamaapp"
        case ollama = "ollama"

        var serverName: String {
            switch self {
            case .llamaapp: return "Llama"
            case .ollama: return "ollama"
            }
        }

        var defaultPort: Int {
            switch self {
            case .llamaapp: return 8080
            case .ollama: return 11434
            }
        }

        var defaultHost: String { "127.0.0.1" }
    }

    var status: ServerStatus = .stopped
    var provider: LocalProvider = .llamaapp

    /// Whether the server is currently running (for UI state).
    var isRunning: Bool {
        if case .running = status { return true }
        return false
    }
    var port: Int = 8080
    var host: String = "127.0.0.1"

    /// Custom path to the Ollama binary. Empty = auto-search common locations.
    var customBinaryPath: String = ""

    private var process: Process?

    // MARK: - Lifecycle

    /// Start the local model server — launch the Llama app, or run Ollama in
    /// the background — and wait until its OpenAI-compatible endpoint answers.
    func start() async {
        guard process == nil || process?.isRunning != true else {
            print("[LocalModel] Already running")
            return
        }

        status = .starting

        switch provider {
        case .llamaapp:
            // If a server is already answering (the Llama app was started
            // manually), adopt it instead of relaunching — relaunching can
            // trigger the app to restart its server, which is exactly when
            // the llama.cpp fit-crash loop starts.
            if await healthCheck() {
                status = .running(pid: 0)
                print("[LocalModel] Llama local server already running (port \(port))")
                return
            }
            guard appInstalled("Llama") || appInstalled("LlamaChat") else {
                status = .failed("The Llama app is not installed. Install it from https://llama.com or the Mac App Store, then try again.")
                return
            }
            launchApp("Llama")
            print("[LocalModel] Launched Llama app; waiting for its local server on \(host):\(port)")
            if await waitForHealth(timeout: 30) {
                status = .running(pid: 0)
                print("[LocalModel] Llama local server is up (port \(port))")
            } else {
                status = .failed(diagnoseLlamaServerFailure())
            }
        case .ollama:
            guard let binPath = binaryPath() else {
                status = .failed("ollama not found. Install via: brew install ollama.")
                return
            }
            print("[LocalModel] Using binary: \(binPath)")

            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/bash")

            // Every argument (binary path, flags) is passed to bash as a
            // positional parameter expanded by "$@" — a path containing spaces
            // or shell metacharacters can no longer inject commands (CWE-78);
            // bash never re-parses them as script text.
            proc.arguments = [
                "-c", """
                nohup "$@" > /tmp/ollama-stdout.log 2> /tmp/ollama-stderr.log &
                echo $!
                """,
                "ollama", // $0
                binPath, "serve",
            ]

            let outPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = outPipe

            do {
                try proc.run()
                proc.waitUntilExit()

                let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                let pidStr = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard let pid = Int32(pidStr), pid > 0 else {
                    status = .failed("Failed to get ollama PID")
                    return
                }

                // Wait a moment for the server to bind
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if await healthCheck() {
                    status = .running(pid: pid)
                    process = proc
                    print("[LocalModel] ollama started (PID \(pid))")
                } else {
                    status = .failed("ollama started but the health check failed — check /tmp/ollama-stderr.log")
                    kill(pid: pid)
                }
            } catch {
                status = .failed("Failed to start: \(error.localizedDescription)")
            }
        }
    }

    /// Stop the local model server — quit the Llama app, or kill ollama.
    func stop() {
        if case .running(let pid) = status, pid > 0 {
            kill(pid: pid)
            print("[LocalModel] Server stopped (was PID \(pid))")
        }

        if provider == .llamaapp {
            // Quit the Llama app gracefully; its local server goes down with it.
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            task.arguments = ["-e", "tell application \"Llama\" to quit"]
            try? task.run()
            task.waitUntilExit()
        } else {
            let pkill = Process()
            pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            pkill.arguments = ["-f", provider.serverName]
            try? pkill.run()
            pkill.waitUntilExit()
        }

        process = nil
        status = .stopped
    }

    /// Build a specific, actionable failure message when the Llama app's local
    /// server doesn't come up. llama.app shells out to the Homebrew llama.cpp
    /// binary, which aborts on startup when the loaded model + context size
    /// doesn't fit in available memory — that abort-loop shows up as a fresh
    /// crash report and/or a "failed to fit" line in /tmp/llama-server.log.
    private func diagnoseLlamaServerFailure() -> String {
        let logTail = tailLog("/tmp/llama-server.log", lines: 40)
        let recentCrash = recentCrashReport(for: "llama", within: 180)
        let logText = logTail.joined(separator: "\n").lowercased()
        let fitFailure = logText.contains("failed to fit")
            || logText.contains("fit params")
            || logText.contains("not enough memory")
            || logText.contains("out of memory")
            || logText.contains("ggml_assert")
        let relevantLogLine = logTail.last { $0.lowercased().contains("fit")
            || $0.lowercased().contains("memory")
            || $0.lowercased().contains("error")
            || $0.lowercased().contains("assert") }

        if recentCrash || fitFailure {
            var msg = "The Llama app's server crashed on startup — its loaded model (and context size) doesn't fit in available memory. "
            if let line = relevantLogLine, !line.isEmpty {
                msg += "Server log: \"\(line.trimmingCharacters(in: .whitespacesAndNewlines))\". "
            }
            msg += "Fix: in the Llama app, load a smaller model or reduce the context length, and quit other memory-heavy apps before starting. "
            msg += "If it still crashes, update llama.cpp: `brew upgrade llama.cpp`."
            return msg
        }

        if let line = relevantLogLine, !line.isEmpty {
            return "The Llama app is running but its local server isn't answering on port \(port). Server log: \"\(line.trimmingCharacters(in: .whitespacesAndNewlines))\". Open the app, load a model, and make sure the local server is enabled."
        }

        return "The Llama app is running but its local server isn't answering on port \(port). Open the app, load a model, and make sure the local server is enabled."
    }

    /// Last N non-empty lines of a log file (best-effort, read-only).
    private func tailLog(_ path: String, lines: Int) -> [String] {
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8) else { return [] }
        let all = text.split(separator: "\n").map(String.init)
        return Array(all.suffix(lines))
    }

    /// Whether macOS recorded a crash report for the given process name in the
    /// last `within` seconds — i.e. the server is crash-looping, not just slow.
    private func recentCrashReport(for processName: String, within: TimeInterval) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dir = "\(home)/Library/Logs/DiagnosticReports"
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return false }
        let cutoff = Date().addingTimeInterval(-within)
        for file in files where file.hasPrefix(processName + "-") && file.hasSuffix(".ips") {
            let url = URL(fileURLWithPath: "\(dir)/\(file)")
            if let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
               mod > cutoff {
                return true
            }
        }
        return false
    }

    /// Health-check against the server's OpenAI-compatible endpoint.
    private func healthCheck() async -> Bool {
        let baseURL = "http://\(host):\(port)"
        guard let url = URL(string: "\(baseURL)/health") ?? URL(string: "\(baseURL)/v1/models") else { return false }

        for _ in 0..<10 {
            do {
                var req = URLRequest(url: url)
                req.timeoutInterval = 2
                let (_, resp) = try await URLSession.shared.data(for: req)
                if let http = resp as? HTTPURLResponse, http.statusCode == 200 {
                    return true
                }
            } catch {}
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return false
    }

    /// Poll the health endpoint until it answers or the timeout elapses.
    private func waitForHealth(timeout: Int) async -> Bool {
        let deadline = Date().addingTimeInterval(TimeInterval(timeout))
        while Date() < deadline {
            if await healthCheck() { return true }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return false
    }

    // MARK: - Readiness & Auto-Detect

    enum LocalModelReadiness {
        /// The app/binary is available — can start now.
        case ready
        /// The Llama app or Ollama binary is not installed — show the onboarding tutorial.
        case needsInstall
    }

    /// Path to the Ollama binary if present (custom override or common locations).
    func binaryPath() -> String? {
        which("ollama")
    }

    /// Whether the local LLM can be started right now.
    func readiness() -> LocalModelReadiness {
        switch provider {
        case .llamaapp:
            return (appInstalled("Llama") || appInstalled("LlamaChat")) ? .ready : .needsInstall
        case .ollama:
            return binaryPath() != nil ? .ready : .needsInstall
        }
    }

    // MARK: - Helpers

    private func launchApp(_ name: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-a", name]
        try? task.run()
        task.waitUntilExit()
    }

    private func appInstalled(_ name: String) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return FileManager.default.fileExists(atPath: "/Applications/\(name).app")
            || FileManager.default.fileExists(atPath: "\(home)/Applications/\(name).app")
    }

    private func kill(pid: Int32) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/kill")
        task.arguments = ["-9", "\(pid)"]
        try? task.run()
        task.waitUntilExit()
    }

    /// Find the Ollama binary. Checks custom path first, then common Homebrew
    /// and local install locations. macOS apps don't inherit the user's shell
    /// PATH, so `which` from a subprocess would miss Homebrew paths.
    private func which(_ name: String) -> String? {
        // Custom path override
        if !customBinaryPath.isEmpty {
            let expanded = NSString(string: customBinaryPath).expandingTildeInPath
            if FileManager.default.isExecutableFile(atPath: expanded) { return expanded }
        }

        // Common install locations — checked first since macOS apps run with
        // a restricted PATH that doesn't include Homebrew directories.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "\(home)/.local/bin/\(name)",
            "\(home)/homebrew/bin/\(name)",
        ]
        for c in candidates {
            if FileManager.default.isExecutableFile(atPath: c) {
                print("[LocalModel] Found binary at: \(c)")
                return c
            }
        }

        // Fallback: try `which` with an explicit PATH that includes Homebrew
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        task.arguments = [name]
        task.environment = ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"]
        let pipe = Pipe()
        task.standardOutput = pipe
        try? task.run()
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let p = path, !p.isEmpty, FileManager.default.isExecutableFile(atPath: p) {
            print("[LocalModel] Found binary at: \(p)")
            return p
        }

        return nil
    }
}
