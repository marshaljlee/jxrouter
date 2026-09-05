import Foundation
import Observation

/// Manages the local model servers JXProxy can start on this Mac: the Llama
/// desktop app (llama.app), Ollama, and direct GGUF models via `llama-server`
/// (the Homebrew llama.cpp server binary). Provides start/stop lifecycle and
/// status tracking. llama.app is launched as a GUI app whose built-in server
/// serves on port 8080; Ollama runs as a background server process; GGUF models
/// are served directly by an in-process `llama-server` child process.
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
        /// Direct GGUF hosting via llama-server (Homebrew llama.cpp)
        case gguf = "gguf"

        var serverName: String {
            switch self {
            case .llamaapp: return "Llama"
            case .ollama: return "ollama"
            case .gguf: return "llama-server"
            }
        }

        var defaultPort: Int {
            switch self {
            case .llamaapp: return 9931
            case .ollama: return 11434
            case .gguf: return 8081
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
    var port: Int = 9931
    var host: String = "127.0.0.1"

    /// Custom path to the Ollama binary. Empty = auto-search common locations.
    var customBinaryPath: String = ""

    /// The selected GGUF model file path (set when the user picks a model).
    var selectedGGUFPath: String = ""

    /// The model name alias to register with llama-server (defaults to filename stem).
    var ggufModelAlias: String = "local-model"

    /// GPU layers to offload (default: 0 = CPU only, -1 = all layers).
    var ggufGpuLayers: Int = 0

    /// Context size override (0 = use model's default).
    var ggufContextSize: Int = 0

    /// Chat template override for llama-server (empty = auto-detect via LocalChatTemplateEngine).
    var ggufChatTemplate: String = ""

    /// Path to a multimodal projector file (--mmproj). Empty = auto-detect matching projector.
    var ggufMmprojPath: String = ""

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
        case .gguf:
            await startGGUF()
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

    /// Stop the local model server — quit the Llama app, kill ollama, or
    /// terminate the llama-server child process (GGUF).
    func stop() {
        if case .running(let pid) = status, pid > 0 {
            kill(pid: pid)
            print("[LocalModel] Server stopped (was PID \(pid))")
        }

        switch provider {
        case .llamaapp:
            // Quit the Llama app gracefully; its local server goes down with it.
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            task.arguments = ["-e", "tell application \"Llama\" to quit"]
            do {
                try task.run()
                task.waitUntilExit()
            } catch {
                print("[LocalModel] Failed to quit Llama app: \(error)")
            }
        case .gguf:
            // llama-server child process — terminate it directly if tracked.
            if let proc = process, proc.isRunning {
                proc.terminate()
                // Give it a moment to clean up, then force-kill if needed.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak proc, weak self] in
                    if let proc, proc.isRunning {
                        self?.kill(pid: proc.processIdentifier)
                    }
                }
            }
        case .ollama:
            let pkill = Process()
            pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            pkill.arguments = ["-f", provider.serverName]
            do {
                try pkill.run()
                pkill.waitUntilExit()
            } catch {
                print("[LocalModel] Failed to pkill \(provider.serverName): \(error)")
            }
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

    /// Start the GGUF model server (llama-server) with the selected model.
    /// Discovers the llama-server binary, launches it as a child process, and
    /// waits for the OpenAI-compatible endpoint to answer.
    private func startGGUF() async {
        guard !selectedGGUFPath.isEmpty else {
            status = .failed("No GGUF model file selected. Pick a model first.")
            return
        }

        guard FileManager.default.isReadableFile(atPath: selectedGGUFPath) else {
            status = .failed("Cannot read GGUF model file: \(selectedGGUFPath)")
            return
        }

        guard let serverPath = findLlamaServer() else {
            status = .failed("llama-server not found. Install via: brew install llama.cpp")
            return
        }

        // If a server is already answering on our port, adopt it
        if await healthCheck() {
            status = .running(pid: 0)
            let (_, liveAlias) = await detectRunningGGUF(customPort: port)
            print("[LocalModel] llama-server already running on port \(port): \(liveAlias ?? ggufModelAlias)")
            return
        }

        print("[LocalModel] Launching llama-server: \(serverPath)")
        print("[LocalModel]   Model: \(selectedGGUFPath)")
        print("[LocalModel]   Port: \(port)")
        print("[LocalModel]   Alias: \(ggufModelAlias)")
        print("[LocalModel]   GPU layers: \(ggufGpuLayers)")
        print("[LocalModel]   Context size: \(ggufContextSize)")

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: serverPath)

        var args: [String] = []
        if serverPath.hasSuffix("/llama") && !serverPath.hasSuffix("llama-server") {
            args.append("serve")
        }
        args.append(contentsOf: ["-m", selectedGGUFPath])
        args.append(contentsOf: ["--host", "127.0.0.1"])
        args.append(contentsOf: ["--port", "\(port)"])
        args.append(contentsOf: ["-a", ggufModelAlias])

        // Multimodal projector (mmproj) support for vision models
        let effectiveMmproj = !ggufMmprojPath.isEmpty
            ? ggufMmprojPath
            : GGUFModelScanner.findMatchingMmproj(forModelPath: selectedGGUFPath)

        if let mmproj = effectiveMmproj, !mmproj.isEmpty, FileManager.default.isReadableFile(atPath: mmproj) {
            args.append(contentsOf: ["--mmproj", mmproj])
            if ggufGpuLayers != 0 {
                args.append("--mmproj-offload")
            }
            print("[LocalModel]   Multimodal projector (mmproj): \(mmproj)")
        }

        // GPU offloading
        if ggufGpuLayers > 0 {
            args.append(contentsOf: ["-ngl", "\(ggufGpuLayers)"])
        } else if ggufGpuLayers == -1 {
            args.append(contentsOf: ["-ngl", "999"])
        }

        // Context size override
        if ggufContextSize > 0 {
            args.append(contentsOf: ["-c", "\(ggufContextSize)"])
        }

        // Chat template resolution & Jinja activation
        let effectiveTemplate = !ggufChatTemplate.isEmpty
            ? ggufChatTemplate
            : LocalChatTemplateEngine.detectLlamaServerTemplate(forPath: selectedGGUFPath, alias: ggufModelAlias)
        args.append("--jinja")
        args.append(contentsOf: ["--chat-template", effectiveTemplate])

        print("[LocalModel]   Chat template: \(effectiveTemplate) (Jinja enabled)")

        // Reasonable defaults for an API server
        args.append(contentsOf: ["-to", "600"]) // 10min timeout for long context
        // `--parallel` enables multiple concurrent requests (Claude Code often
        // fires parallel tool calls) — the server's default of 1 would serialize
        // them and stall tool-calling turns.
        args.append(contentsOf: ["--parallel", "4"])

        proc.arguments = args

        // Redirect stdout/stderr to log files
        let stdoutPath = "/tmp/llama-server-stdout.log"
        let stderrPath = "/tmp/llama-server-stderr.log"
        FileManager.default.createFile(atPath: stdoutPath, contents: nil)
        FileManager.default.createFile(atPath: stderrPath, contents: nil)

        let stdoutHandle = FileHandle(forWritingAtPath: stdoutPath) ?? FileHandle.standardOutput
        let stderrHandle = FileHandle(forWritingAtPath: stderrPath) ?? FileHandle.standardError
        proc.standardOutput = stdoutHandle
        proc.standardError = stderrHandle

        do {
            try proc.run()
            process = proc
            print("[LocalModel] llama-server launched (PID \(proc.processIdentifier))")

            if await waitForHealth(timeout: 60) {
                status = .running(pid: proc.processIdentifier)
                print("[LocalModel] llama-server is up (port \(port))")
            } else {
                // Read stderr for diagnostics
                let diag = diagnoseGGUFFailure(stderrPath: stderrPath)
                status = .failed(diag)
                proc.terminate()
                process = nil
            }
        } catch {
            status = .failed("Failed to launch llama-server: \(error.localizedDescription)")
            process = nil
        }
    }

    /// Diagnose why llama-server failed to start by reading stderr.
    private func diagnoseGGUFFailure(stderrPath: String) -> String {
        guard let data = FileManager.default.contents(atPath: stderrPath),
              let text = String(data: data, encoding: .utf8) else {
            return "llama-server failed to start (no diagnostic output available)"
        }
        let lines = text.split(separator: "\n").map(String.init)
        // Grab the last few error-looking lines
        let relevant = lines.filter { line in
            let l = line.lowercased()
            return l.contains("error") || l.contains("failed") || l.contains("assert")
                || l.contains("out of memory") || l.contains("cannot") || l.contains("unable")
        }
        if let last = relevant.last {
            return "llama-server error: \(last.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
        if let last = lines.last {
            return "llama-server: \(last.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
        return "llama-server failed to start (check /tmp/llama-server-stderr.log)"
    }

    /// Find the llama-server binary. Checks Homebrew and common locations.
    nonisolated static func findLlamaServer() -> String? {
        let candidates = [
            "/opt/homebrew/bin/llama-server",
            "/usr/local/bin/llama-server",
            "/opt/homebrew/bin/llama",
            "/usr/local/bin/llama",
        ]
        for c in candidates {
            if FileManager.default.isExecutableFile(atPath: c) {
                // If the binary is `llama` (the multi-call binary), we need
                // to invoke it as `llama-server` — symlink or rename.
                if c.hasSuffix("llama-server") { return c }
                // The `llama` multi-call binary accepts `server` as subcommand
                if c.hasSuffix("llama") {
                    // Check if there's a llama-server symlink
                    let serverLink = c.replacingOccurrences(of: "/llama", with: "/llama-server")
                    if FileManager.default.isExecutableFile(atPath: serverLink) {
                        return serverLink
                    }
                    // Fall back to using `llama server` via shell
                    return c
                }
            }
        }
        // Try `which` with a proper PATH
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        task.arguments = ["llama-server"]
        task.environment = ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"]
        let pipe = Pipe()
        task.standardOutput = pipe
        do {
            try task.run()
            task.waitUntilExit()
        } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let p = path, !p.isEmpty, FileManager.default.isExecutableFile(atPath: p) {
            return p
        }
        return nil
    }

    nonisolated func findLlamaServer() -> String? {
        Self.findLlamaServer()
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
        // llama.app's server port is not stable (it can move after relaunches)
        // — resolve the live port so the health check matches reality.
        let effectivePort = provider == .llamaapp ? LocalServerDiscovery.liveLlamaPort() : port
        let baseURL = "http://\(host):\(effectivePort)"
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

    /// Re-check whether the local server is actually answering, so the UI
    /// ("Llama not running" etc.) reflects reality. llama.app is frequently
    /// started manually outside JXProxy — its live port is discovered from
    /// the running process, so a manual start is adopted as "running" instead
    /// of being reported as stopped. An in-flight start is never overridden.
    func refreshStatus() async {
        guard provider == .llamaapp || provider == .gguf else { return }
        let effectivePort = provider == .llamaapp ? LocalServerDiscovery.liveLlamaPort() : port
        if await healthCheck() {
            if !isRunning {
                status = .running(pid: 0)
                print("[LocalModel] Adopted \(provider.serverName) server already running on port \(effectivePort)")
            }
            if provider == .gguf {
                await detectRunningGGUF(customPort: effectivePort)
            }
        } else if case .running(0) = status {
            status = .stopped
        }
    }

    /// Check any running local model server regardless of current provider.
    func detectAnyRunningServer() async {
        let ggufCheckPort = port > 0 ? port : ConfigManager.shared.ggufPort
        await detectRunningGGUF(customPort: ggufCheckPort)
        await refreshStatus()
    }

    /// Discovers any running llama-server on the configured port (or port 8081)
    /// and queries its live loaded model metadata (/props and /v1/models).
    @discardableResult
    func detectRunningGGUF(customPort: Int? = nil) async -> (modelPath: String?, modelAlias: String?) {
        let checkPort = customPort ?? (port > 0 ? port : 8081)
        let baseURL = "http://127.0.0.1:\(checkPort)"

        guard let propsURL = URL(string: "\(baseURL)/props"),
              let modelsURL = URL(string: "\(baseURL)/v1/models") else {
            return (nil, nil)
        }

        var detectedPath: String?
        var detectedAlias: String?

        // 1. Try /props (llama-server specific endpoint giving model_path, model_alias, etc.)
        do {
            var req = URLRequest(url: propsURL)
            req.timeoutInterval = 1.5
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let alias = json["model_alias"] as? String, !alias.isEmpty {
                    detectedAlias = alias
                }
                if let path = json["model_path"] as? String, !path.isEmpty {
                    detectedPath = path
                }
            }
        } catch {}

        // 2. Try /v1/models if alias or path not found
        if detectedAlias == nil || detectedPath == nil {
            do {
                var req = URLRequest(url: modelsURL)
                req.timeoutInterval = 1.5
                let (data, resp) = try await URLSession.shared.data(for: req)
                if let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let list = (json["data"] as? [[String: Any]]) ?? (json["models"] as? [[String: Any]]) ?? []
                    if let first = list.first {
                        let id = (first["id"] as? String) ?? (first["name"] as? String) ?? (first["model"] as? String)
                        if detectedAlias == nil { detectedAlias = id }
                    }
                }
            } catch {}
        }

        if let alias = detectedAlias, !alias.isEmpty {
            self.ggufModelAlias = alias
            ConfigManager.shared.ggufModelAlias = alias
            if let path = detectedPath, !path.isEmpty {
                self.selectedGGUFPath = path
                ConfigManager.shared.ggufModelPath = path
            }
            if !isRunning {
                self.status = .running(pid: 0)
            }
            print("[LocalModel] Detected running GGUF server on port \(checkPort): alias='\(alias)', path='\(detectedPath ?? "unknown")'")
            return (detectedPath, detectedAlias)
        }

        return (nil, nil)
    }

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
        case .gguf:
            // GGUF needs a selected model file AND the llama-server binary.
            guard !selectedGGUFPath.isEmpty, FileManager.default.isReadableFile(atPath: selectedGGUFPath) else {
                return .needsInstall
            }
            return findLlamaServer() != nil ? .ready : .needsInstall
        }
    }

    // MARK: - Helpers

    private func launchApp(_ name: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-a", name]
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            print("[LocalModel] Failed to open app \(name): \(error)")
        }
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
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            print("[LocalModel] Failed to kill PID \(pid): \(error)")
        }
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
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            print("[LocalModel] which lookup failed: \(error)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let p = path, !p.isEmpty, FileManager.default.isExecutableFile(atPath: p) {
            print("[LocalModel] Found binary at: \(p)")
            return p
        }

        return nil
    }
}
