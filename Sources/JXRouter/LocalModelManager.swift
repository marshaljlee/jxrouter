import Foundation
import Observation

/// Manages a local model server (llama-server or ollama) as a background process.
/// Provides start/stop lifecycle and status tracking.
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
        case llamacpp = "llamacpp"
        case ollama = "ollama"

        var serverName: String {
            switch self {
            case .llamacpp: return "llama-server"
            case .ollama: return "ollama"
            }
        }

        var defaultPort: Int {
            switch self {
            case .llamacpp: return 8080
            case .ollama: return 11434
            }
        }

        var defaultHost: String { "127.0.0.1" }
    }

    var status: ServerStatus = .stopped
    var provider: LocalProvider = .llamacpp
    var modelPath: String = ""
    var port: Int = 8080
    var host: String = "127.0.0.1"

    /// Preferred model directory — used as the starting point for file picker.
    var modelDirectory: String {
        get { UserDefaults.standard.string(forKey: "localModelDir") ?? "~/.local/share/llama.cpp" }
        set { UserDefaults.standard.set(newValue, forKey: "localModelDir") }
    }

    /// Custom path to the server binary. Empty = auto-search common locations.
    var customBinaryPath: String = ""

    private var process: Process?
    private var stdoutPipe: Pipe?

    // MARK: - Lifecycle

    /// Start the local model server.
    func start() async {
        guard process == nil || process?.isRunning != true else {
            print("[LocalModel] Already running")
            return
        }

        guard !modelPath.isEmpty else {
            status = .failed("No model file selected")
            return
        }

        let resolvedPath = NSString(string: modelPath).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: resolvedPath) else {
            status = .failed("Model file not found: \(resolvedPath)")
            return
        }

        guard let binPath = which(provider.serverName) else {
            status = .failed("\(provider.serverName) not found. Install via: brew install \(provider == .llamacpp ? "llama.cpp" : "ollama")")
            return
        }
        print("[LocalModel] Using binary: \(binPath)")

        status = .starting

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")

        switch provider {
        case .llamacpp:
            let ctxSize = 8192
            proc.arguments = [
                "-c", """
                nohup \(binPath) \
                    --host \(host) \
                    --port \(port) \
                    --model \(resolvedPath) \
                    --ctx-size \(ctxSize) \
                    > /tmp/llama-server-stdout.log 2> /tmp/llama-server-stderr.log &
                echo $!
                """
            ]
        case .ollama:
            proc.arguments = [
                "-c", """
                nohup \(binPath) serve \
                    > /tmp/ollama-stdout.log 2> /tmp/ollama-stderr.log &
                echo $!
                """
            ]
        }

        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = outPipe

        do {
            try proc.run()
            proc.waitUntilExit()

            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            let pidStr = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard let pid = Int32(pidStr), pid > 0 else {
                status = .failed("Failed to get server PID")
                return
            }

            // Wait a moment for the server to bind
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if await healthCheck() {
                status = .running(pid: pid)
                process = proc
                print("[LocalModel] Server started (PID \(pid))")
            } else {
                status = .failed("Server started but health check failed — check /tmp/\(provider.serverName)-stderr.log")
                kill(pid: pid)
            }
        } catch {
            status = .failed("Failed to start: \(error.localizedDescription)")
        }
    }

    /// Stop the local model server.
    func stop() {
        if case .running(let pid) = status {
            kill(pid: pid)
            print("[LocalModel] Server stopped (was PID \(pid))")
        }

        // Also try pkill as a safety net
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-f", provider.serverName]
        try? pkill.run()
        pkill.waitUntilExit()

        process = nil
        status = .stopped
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

    // MARK: - Helpers

    private func kill(pid: Int32) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/kill")
        task.arguments = ["-9", "\(pid)"]
        try? task.run()
        task.waitUntilExit()
    }

    /// Find the server binary. Checks custom path first, then common Homebrew
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

    func setModelPathFromFile(_ path: String) {
        modelPath = path
        // Infer provider from file extension and location
        if path.lowercased().hasSuffix(".gguf") {
            provider = .llamacpp
        }
        // Save the directory for next time
        modelDirectory = (path as NSString).deletingLastPathComponent
    }
}
