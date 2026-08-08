import Foundation

/// A detected local model runtime (Ollama, llama.cpp, LM Studio, Jan …).
struct LocalRuntime: Identifiable, Sendable {
    enum State: Sendable {
        /// Server is running and answering on its port.
        case running
        /// Installed but not currently running.
        case installed
        /// Not found on this machine.
        case missing
    }

    let id: String       // provider id ("ollama", "llamacpp", "lmstudio", "jan")
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
        async let ollama = probeOllama()
        async let llamacpp = probeLlamaCpp()
        async let lmstudio = probeLMStudio()
        async let jan = probeJan()
        return await [ollama, llamacpp, lmstudio, jan]
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

    private static func probeLlamaCpp() async -> LocalRuntime {
        // llama.cpp models are only visible while its server is running.
        let running = await httpOK("http://127.0.0.1:8080/health")
        let installed = running || binaryInCommonPaths("llama-server")
        return LocalRuntime(
            id: "llamacpp", name: "llama.cpp", port: 8080,
            state: state(running: running, installed: installed),
            hint: running
                ? "Ready — the loaded model is auto-fetched."
                : (installed
                    ? "Installed but the server is not running. Click \"Run Local Model\" in Settings → General to start it, or run `llama-server -m <model.gguf>` yourself."
                    : "Not detected. llama-server isn't installed — JXProxy's local model setup tutorial will guide you (install, pick a .gguf, run).")
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
        FileManager.default.fileExists(atPath: "/Applications/\(name).app")
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
}
