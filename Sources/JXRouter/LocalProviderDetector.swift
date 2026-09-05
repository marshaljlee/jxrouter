import Foundation

/// A detected local model runtime (Ollama, llama.app, LM Studio, Jan …).
struct LocalRuntime: Identifiable, Sendable {
    enum State: Sendable {
        /// Server is running and answering on its port.
        case running
        /// Installed but not currently running.
        case installed
        /// Not found on this machine.
        case missing
    }

    let id: String       // provider id ("ollama", "llamaapp", "lmstudio", "jan")
    let name: String
    let port: Int
    let state: State
    let hint: String     // plain-language guidance for the user

    var isRunning: Bool { if case .running = state { return true }; return false }

    var stateLabel: String {
        switch state {
        case .running: return "Running"
        case .installed: return "Installed — not running"
        case .missing: return "Not detected"
        }
    }
}

/// Detects which local model servers are installed / running on this Mac.
/// Uses short HTTP probes and executable/app checks only — no admin rights.
struct LocalProviderDetector {

    /// Probe every known local runtime concurrently.
    static func detect() async -> [LocalRuntime] {
        async let gguf = probeGGUF()
        async let llama = probeLlamaApp()
        async let ollama = probeOllama()
        async let lmstudio = probeLMStudio()
        async let jan = probeJan()
        async let unsloth = probeUnsloth()
        return await [gguf, llama, ollama, lmstudio, jan, unsloth]
    }

    private static func probeGGUF() async -> LocalRuntime {
        let port = ConfigManager.shared.ggufPort > 0 ? ConfigManager.shared.ggufPort : 8081
        let healthOK = await httpOK("http://127.0.0.1:\(port)/health")
        let modelsOK: Bool
        if healthOK {
            modelsOK = true
        } else {
            modelsOK = await httpOK("http://127.0.0.1:\(port)/v1/models")
        }
        let running = healthOK || modelsOK
        let installed = running || (LocalModelManager.findLlamaServer() != nil)
        return LocalRuntime(
            id: "gguf", name: "GGUF (Direct)", port: port,
            state: state(running: running, installed: installed),
            hint: running
                ? "Ready — model is active in the built-in GGUF loader on port \(port)."
                : (installed
                    ? "Installed (llama.cpp) — select a GGUF model in Settings to load it."
                    : "Not detected. Install llama.cpp via `brew install llama.cpp`.")
        )
    }

    // MARK: - Individual probes

    private static func probeOllama() async -> LocalRuntime {
        let running = await httpOK("http://127.0.0.1:11434/api/tags")
        let installed = running || binaryInCommonPaths("ollama")
        return LocalRuntime(
            id: "ollama", name: "Ollama", port: 11434,
            state: state(running: running, installed: installed),
            hint: running
                ? "Ready — models are auto-fetched from the running server."
                : (installed
                    ? "Installed but not running. Start the Ollama menu-bar app or run `ollama serve`, then press Refresh."
                    : "Not detected. Install from https://ollama.com/download — JXProxy can guide you step by step.")
        )
    }

    private static func probeLlamaApp() async -> LocalRuntime {
        // llama.app exposes its models only while its local server is running.
        // Its port is NOT stable: historically 8080, but llama.app can pick a
        // different free port after a relaunch — resolve the live one.
        let port = LocalServerDiscovery.liveLlamaPort()
        let running = await httpOK("http://127.0.0.1:\(port)/health")
        // "Installed" covers the Llama desktop app (llama.app) and its
        // predecessor LlamaChat — both bundle llama.cpp and serve an
        // OpenAI-compatible API when their local server is on.
        let installed = running || appInstalled("Llama") || appInstalled("LlamaChat")
        return LocalRuntime(
            id: "llamaapp", name: "Llama (app)", port: port,
            state: state(running: running, installed: installed),
            hint: running
                ? "Ready — the loaded model is auto-fetched from llama.app's local server (port \(port))."
                : (installed
                    ? "Installed but its local server is not running. Open the Llama app, load a model, and make sure the local server is enabled (port \(port)), then press Refresh."
                    : "Not detected. Install the free Llama app from https://llama.com — JXProxy connects to its built-in OpenAI-compatible server (port \(port) when running).")
        )
    }

    private static func probeLMStudio() async -> LocalRuntime {
        let running = await httpOK("http://127.0.0.1:1234/v1/models")
        let installed = running || appInstalled("LM Studio")
        return LocalRuntime(
            id: "lmstudio", name: "LM Studio", port: 1234,
            state: state(running: running, installed: installed),
            hint: running
                ? "Ready — a model is loaded and its server is serving on port 1234."
                : (installed
                    ? "Installed but not serving. Open LM Studio, load a model, and enable the local server (Developer tab → Start Server), then press Refresh."
                    : "Not detected. LM Studio is a free app from https://lmstudio.ai — install it, load a model, and enable its local server.")
        )
    }

    private static func probeJan() async -> LocalRuntime {
        let running = await httpOK("http://127.0.0.1:1337/v1/models")
        let installed = running || appInstalled("Jan")
        return LocalRuntime(
            id: "jan", name: "Jan", port: 1337,
            state: state(running: running, installed: installed),
            hint: running
                ? "Ready — Jan's OpenAI-compatible server is serving on port 1337."
                : (installed
                    ? "Installed but not serving. Open Jan, load a model, and enable its local API server (Settings → Advanced → Enable Local API Server), then press Refresh."
                    : "Not detected. Jan is a free app from https://jan.ai — install it and enable its local API server.")
        )
    }

    private static func probeUnsloth() async -> LocalRuntime {
        let running = await httpOK("http://127.0.0.1:8000/v1/models")
        // Unsloth is typically installed via pip; check for the unsloth package.
        let installed = running || pipPackageInstalled("unsloth")
        return LocalRuntime(
            id: "unsloth", name: "Unsloth", port: 8000,
            state: state(running: running, installed: installed),
            hint: running
                ? "Ready — Unsloth's FastAPI server is serving on port 8000."
                : (installed
                    ? "Unsloth is installed. Start the server: `python -m unsloth serve --port 8000`, then press Refresh."
                    : "Not detected. Install via: `pip install unsloth` — then start the server.")
        )
    }

    // MARK: - Helpers

    private static func state(running: Bool, installed: Bool) -> LocalRuntime.State {
        if running { return .running }
        return installed ? .installed : .missing
    }

    private static func httpOK(_ urlString: String) async -> Bool {
        guard let url = URL(string: urlString) else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 2
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse { return (200...299).contains(http.statusCode) }
            return false
        } catch {
            return false
        }
    }

    private static func appInstalled(_ name: String) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return FileManager.default.fileExists(atPath: "/Applications/\(name).app")
            || FileManager.default.fileExists(atPath: "\(home)/Applications/\(name).app")
    }

    private static func binaryInCommonPaths(_ name: String) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "\(home)/.local/bin/\(name)",
            "\(home)/homebrew/bin/\(name)",
        ]
        return candidates.contains { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func pipPackageInstalled(_ name: String) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = ["pip3", "show", name]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }
}

/// Resolves llama.app's LIVE server port. llama.app's built-in server is the
/// source of the "llamaapp" local provider, and its port is not stable:
/// historically 8080, but after a relaunch it can bind a different free port
/// (observed moving 8080 → 9931), which silently breaks every hardcoded-8080
/// caller. Reading the running `llama serve --models-preset` process's --port
/// finds the real endpoint; the result is cached briefly since ports change
/// only across launches.
enum LocalServerDiscovery {
    private static var cache: (port: Int, at: Date)?

    /// The live llama.app server port (default 9931, with fallback to live scan or 9931).
    static func liveLlamaPort() -> Int {
        if let c = cache, Date().timeIntervalSince(c.at) < 15 { return c.port }
        let port = scanLlamaServePort() ?? 9931
        print("[LocalModel] llama.app live port = \(port) (cached for 15s)")
        cache = (port, Date())
        return port
    }

    private static func scanLlamaServePort() -> Int? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-axo", "command="]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        do {
            try task.run()
        } catch {
            return nil
        }
        // Drain the pipe BEFORE waiting for exit: `ps -axo command=` on a busy
        // Mac emits well over the 64KB pipe buffer (observed 187KB), and
        // calling waitUntilExit() first deadlocks — ps blocks writing to the
        // full pipe while we block waiting for it to exit. Read to EOF, then
        // reap.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n")
        
        // Pass 1: Prioritize the primary `--models-preset` master server (default port 9931 in llama.app)
        for line in lines {
            let l = String(line)
            guard l.contains("llama serve") && l.contains("--models-preset") else { continue }
            let parts = l.split(separator: " ")
            if let idx = parts.firstIndex(of: "--port"), idx + 1 < parts.count,
               let port = Int(parts[idx + 1]), port > 0 {
                return port
            }
        }
        
        // Pass 2: Check any running `llama serve` process
        for line in lines {
            let l = String(line)
            guard l.contains("llama serve") else { continue }
            let parts = l.split(separator: " ")
            if let idx = parts.firstIndex(of: "--port"), idx + 1 < parts.count,
               let port = Int(parts[idx + 1]), port > 0 {
                return port
            }
        }
        return nil
    }
}
