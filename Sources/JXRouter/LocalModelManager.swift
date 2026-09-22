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

    /// True while a GGUF model is being loaded — i.e. while the Settings
    /// progress bar should be on screen.
    var isLoadingModel: Bool = false
    /// 0…1 fraction of the model mapped in so far.
    var loadFraction: Double = 0
    /// What llama-server is doing right now ("Loading weights", …).
    var loadPhaseLabel: String = ""
    /// "6.2 GB / 10.5 GB" — empty when the file size is unknown.
    var loadBytesText: String = ""
    /// False when the percentage is a time-based estimate, not a measurement.
    var loadProgressIsMeasured: Bool = false

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

    /// KV cache K quantization (e.g. "q8_0", "q4_0", "f16", empty = preset).
    var ggufCacheTypeK: String = ""

    /// KV cache V quantization (e.g. "q8_0", "q4_0", "f16", empty = preset).
    var ggufCacheTypeV: String = ""

    /// Flash Attention (default true per reference guide).
    var ggufFlashAttn: Bool = true

    /// Context shift (default true per reference guide).
    var ggufContextShift: Bool = true

    /// Qwen3.5 model file path (set when user selects Qwen3.5).
    var qwen3ModelPath: String = ""

    /// Qwen3.5 multimodal projector path (--mmproj).
    var qwen3MmprojPath: String = ""

    /// Chat template override for Qwen3.5 (empty = auto-detect via LlamaPresetSettings).
    var qwen3ChatTemplate: String = ""

    /// Context size override for Qwen3.5 (0 = use model's default).
    var qwen3CtxSize: Int = 0

    private var process: Process?
    /// In-process llama.cpp server, when that path is in use instead of a
    /// spawned `llama-server`. Nil whenever the subprocess path is serving.
    private var inferenceServer: LocalInferenceServer?

    /// Pipe carrying llama-server's stderr during a load (tee'd to the log).
    private var loadPipe: Pipe?
    /// Samples the child's resident size to drive the load progress bar.
    private var loadMonitor: ModelLoadMonitor?

    // MARK: - Lifecycle

    /// Start the local model server — launch the Llama app, or run Ollama in
    /// the background — and wait until its OpenAI-compatible endpoint answers.
    func start(forceRestart: Bool = false) async {
        if forceRestart {
            stop()
            try? await Task.sleep(nanoseconds: 300_000_000)
        } else {
            guard process == nil || process?.isRunning != true else {
                print("[LocalModel] Already running")
                return
            }
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
            await startGGUF(forceRestart: forceRestart)
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
        endLoadProgress()
        if let inferenceServer {
            inferenceServer.stop()
            self.inferenceServer = nil
            print("[LocalModel] In-process engine stopped")
        }
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
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak proc, weak self] in
                    if let proc, proc.isRunning {
                        self?.kill(pid: proc.processIdentifier)
                    }
                }
            }
            killProcessOnPort(port: port)
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

    /// Kill any process currently listening on a TCP port.
    func killProcessOnPort(port: Int) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments = ["-ti", "tcp:\(port)"]
        let pipe = Pipe()
        task.standardOutput = pipe
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                let pids = output.split(separator: "\n").compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
                for pid in pids {
                    print("[LocalModel] Terminating process on port \(port) (PID \(pid))")
                    kill(pid: pid)
                }
            }
        } catch {
            print("[LocalModel] Failed to check port \(port) listeners: \(error)")
        }
    }

    /// Kill conflicting local llama workers holding device memory to avoid Metal GPU OOM.
    func killConflictingLocalServers(exceptPort: Int) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-axo", "pid,command="]
        let pipe = Pipe()
        task.standardOutput = pipe
        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            if let output = String(data: data, encoding: .utf8) {
                let lines = output.split(separator: "\n")
                for line in lines {
                    let str = String(line).trimmingCharacters(in: .whitespaces)
                    guard str.contains("llama serve") || str.contains("llama-server") else { continue }
                    // Keep idle master preset router on 9931, but kill active worker processes
                    if str.contains("--models-preset") && str.contains("--port 9931") {
                        continue
                    }
                    if str.contains("--port \(exceptPort)") {
                        continue
                    }
                    let parts = str.split(separator: " ")
                    if let first = parts.first, let pid = Int32(first) {
                        print("[LocalModel] Terminating conflicting llama worker (PID \(pid)) to reclaim GPU memory")
                        kill(pid: pid)
                    }
                }
            }
        } catch {
            print("[LocalModel] Failed to check conflicting servers: \(error)")
        }
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
    ///
    /// Every launch setting is derived from the model's own GGUF metadata by
    /// `LocalModelAutoConfig` — context size, GPU offload, chat template and
    /// tool-call format — so a freshly selected model serves Claude Code with a
    /// context it can actually hold and calls tools in its native format.
    private func startGGUF(forceRestart: Bool = false) async {
        // Fall back to persisted config when the manager's fields are unset.
        if selectedGGUFPath.isEmpty { selectedGGUFPath = ConfigManager.shared.ggufModelPath }
        if ggufModelAlias.isEmpty || ggufModelAlias == "local-model" {
            let cfgAlias = ConfigManager.shared.ggufModelAlias
            if !cfgAlias.isEmpty && cfgAlias != "local-model" { ggufModelAlias = cfgAlias }
        }
        if ggufMmprojPath.isEmpty { ggufMmprojPath = ConfigManager.shared.ggufMmprojPath }
        if ggufChatTemplate.isEmpty { ggufChatTemplate = ConfigManager.shared.ggufChatTemplate }
        if ggufCacheTypeK.isEmpty { ggufCacheTypeK = ConfigManager.shared.ggufCacheTypeK }
        if ggufCacheTypeV.isEmpty { ggufCacheTypeV = ConfigManager.shared.ggufCacheTypeV }

        guard !selectedGGUFPath.isEmpty else {
            status = .failed("No GGUF model file selected. Pick a model first.")
            return
        }

        guard FileManager.default.isReadableFile(atPath: selectedGGUFPath) else {
            status = .failed("Cannot read GGUF model file: \(selectedGGUFPath)")
            return
        }

        // In-process engine: no child process, no port juggling, no runtime to
        // install. Falls through to llama-server when the embedded dylib is
        // unavailable (Intel) or the user has turned it off.
        if ConfigManager.shared.preferInProcessEngine, InProcessLlamaEngine.shared.isAvailable {
            await startInProcess(forceRestart: forceRestart)
            return
        }

        // Resolve the llama.cpp runtime: bundled in the app > installed by
        // JXRouter > already on this Mac.
        let rt = LlamaRuntime.shared
        if rt.runtime == nil { await rt.resolve() }
        guard let serverPath = rt.runtime?.path ?? findLlamaServer() else {
            status = .failed("llama-server is not available. Install the built-in llama.cpp runtime in Settings ▸ Local Models.")
            return
        }

        if ggufModelAlias.isEmpty || ggufModelAlias == "local-model" {
            ggufModelAlias = Self.alias(fromModelPath: selectedGGUFPath)
        }

        if forceRestart {
            print("[LocalModel] Force restart requested for GGUF model — clearing port \(port)")
            if let proc = process, proc.isRunning { proc.terminate() }
            killProcessOnPort(port: port)
            try? await Task.sleep(nanoseconds: 500_000_000)
        } else if await healthCheck() {
            // Adopt a server already serving the requested model.
            let (livePath, liveAlias) = await detectRunningGGUF(customPort: port)
            let pathMatches = (livePath != nil && livePath == selectedGGUFPath)
            let aliasMatches = (liveAlias != nil && liveAlias == ggufModelAlias)
            if pathMatches || aliasMatches {
                status = .running(pid: 0)
                print("[LocalModel] llama-server already running on port \(port) with matching model: \(liveAlias ?? ggufModelAlias)")
                return
            } else {
                print("[LocalModel] llama-server on port \(port) is serving a different model (\(liveAlias ?? "unknown")). Restarting…")
                killProcessOnPort(port: port)
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }

        // Free up Metal GPU device memory by terminating other local llama workers.
        killConflictingLocalServers(exceptPort: port)

        let overrides = LocalModelAutoConfig.Overrides(
            contextSize: ggufContextSize > 0 ? ggufContextSize : ConfigManager.shared.ggufContextSize,
            gpuLayers: gpuLayerOverride(),
            cacheTypeK: ggufCacheTypeK,
            cacheTypeV: ggufCacheTypeV,
            flashAttention: ggufFlashAttn && ConfigManager.shared.ggufFlashAttn,
            contextShift: ggufContextShift && ConfigManager.shared.ggufContextShift,
            chatTemplate: ggufChatTemplate,
            mmprojPath: ggufMmprojPath
        )
        let plan = LocalModelAutoConfig.plan(
            forModelPath: selectedGGUFPath,
            alias: ggufModelAlias,
            overrides: overrides
        )

        // Persist the projector decision. A stale incompatible mmproj left in
        // the config is exactly what aborted llama-server on every launch.
        let resolvedMmproj = plan.multimodalProjector ?? ""
        if ConfigManager.shared.ggufMmprojPath != resolvedMmproj {
            ConfigManager.shared.ggufMmprojPath = resolvedMmproj
        }
        ggufMmprojPath = resolvedMmproj

        // Route Claude Code at this model before launching, so traffic lands
        // on it the moment the server answers.
        LocalModelAutoConfig.applyRouting(plan, port: port)

        let binary = serverPath
        let features = await Task.detached(priority: .utility) {
            LocalModelAutoConfig.featureSet(forBinaryAt: binary)
        }.value
        let args = LocalModelAutoConfig.arguments(
            for: plan, port: port, binaryPath: binary, features: features
        )

        // Progress reporting. llama.cpp prints no percentage while loading, so
        // the bar is driven by the child's resident size — see
        // ModelLoadProgress for why that is the only real signal available.
        let modelBytes = (try? FileManager.default.attributesOfItem(atPath: selectedGGUFPath)[.size] as? NSNumber)?.int64Value ?? 0
        let monitor = ModelLoadMonitor(modelBytes: modelBytes) { [weak self] progress in
            Task { @MainActor in self?.applyLoadProgress(progress) }
        }
        loadMonitor?.cancel()
        loadMonitor = monitor
        isLoadingModel = true
        loadFraction = 0
        loadPhaseLabel = ModelLoadProgress.Phase.launching.label
        loadBytesText = modelBytes > 0 ? "0 / \(Self.byteString(modelBytes))" : ""
        loadProgressIsMeasured = false

        print("[LocalModel] Launching llama-server: \(binary)")
        print("[LocalModel]   Model:  \(plan.modelPath)  [\(plan.architecture)]")
        print("[LocalModel]   Alias:  \(plan.alias)   Port: \(port)")
        print("[LocalModel]   \(plan.summary.replacingOccurrences(of: "\n", with: " | "))")

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)

        // Redirect stdout/stderr to log files
        let stdoutPath = "/tmp/llama-server-stdout.log"
        let stderrPath = "/tmp/llama-server-stderr.log"
        FileManager.default.createFile(atPath: stdoutPath, contents: nil)
        FileManager.default.createFile(atPath: stderrPath, contents: nil)

        let stdoutHandle = FileHandle(forWritingAtPath: stdoutPath) ?? FileHandle.standardOutput
        let stderrHandle = FileHandle(forWritingAtPath: stderrPath) ?? FileHandle.standardError
        proc.standardOutput = stdoutHandle
        // stderr runs through a pipe so load milestones can be read as they
        // happen, and is tee'd into the log file that diagnoseGGUFFailure(:)
        // reads after a launch that never came up.
        let stderrPipe = Pipe()
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak monitor] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            stderrHandle.write(data)
            guard let text = String(data: data, encoding: .utf8) else { return }
            for line in text.split(separator: "\n") where !line.isEmpty {
                monitor?.note(line: String(line))
            }
        }
        proc.standardError = stderrPipe
        proc.arguments = args

        do {
            try proc.run()
            process = proc
            loadPipe = stderrPipe
            monitor.attach(pid: proc.processIdentifier)
            print("[LocalModel] llama-server launched (PID \(proc.processIdentifier))")

            if await waitForHealth(timeout: 180) {
                monitor.finish()
                status = .running(pid: proc.processIdentifier)
                print("[LocalModel] llama-server is up (port \(port))")
                // Let the bar rest at 100% long enough to read, then retire it.
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    self?.endLoadProgress()
                }
            } else {
                let diag = diagnoseGGUFFailure(stderrPath: stderrPath)
                monitor.cancel()
                endLoadProgress()
                status = .failed(diag)
                proc.terminate()
                process = nil
            }
        } catch {
            monitor.cancel()
            endLoadProgress()
            status = .failed("Failed to launch llama-server: \(error.localizedDescription)")
            process = nil
        }
    }

    // MARK: - In-Process GGUF Hosting

    /// Serve the GGUF from inside this process via the embedded llama.cpp.
    ///
    /// The server speaks the same HTTP surface as `llama-server`, so the health
    /// checks, adoption logic and provider routing above are unchanged.
    private func startInProcess(forceRestart: Bool) async {
        if forceRestart {
            inferenceServer?.stop()
            inferenceServer = nil
        } else if await healthCheck() {
            status = .running(pid: 0)
            print("[LocalModel] in-process server already serving on port \(port)")
            return
        }

        let cfg = LocalInferenceServer.Config(
            port: UInt16(max(1, min(65535, port))),
            modelPath: selectedGGUFPath,
            modelAlias: ggufModelAlias,
            nCtx: Int32(ggufContextSize),
            nBatch: 2048,
            nUBatch: 512,
            nGPULayers: Int32(ggufGpuLayers),
            flashAttn: ggufFlashAttn
        )

        isLoadingModel = true
        loadFraction = 0
        loadPhaseLabel = "Loading weights"
        loadProgressIsMeasured = true
        loadBytesText = ""

        let server = LocalInferenceServer()
        do {
            try await server.start(cfg) { [weak self] fraction in
                // The engine reports on the main queue already, but hop
                // explicitly so main-actor isolation is provable.
                Task { @MainActor in
                    guard let self else { return }
                    self.loadFraction = max(self.loadFraction, fraction)
                    self.loadPhaseLabel = "Loading weights"
                    self.loadProgressIsMeasured = true
                }
            }
        } catch {
            endLoadProgress()
            status = .failed("In-process engine failed: \(error.localizedDescription). Disable it in Settings ▸ System to use llama-server instead.")
            return
        }

        inferenceServer = server
        endLoadProgress()

        guard await waitForHealth(timeout: 10) else {
            server.stop()
            inferenceServer = nil
            status = .failed("In-process engine loaded the model but the server did not answer on port \(port).")
            return
        }

        status = .running(pid: 0)
        print("[LocalModel] in-process llama.cpp serving \(ggufModelAlias) on port \(port)")
    }

    /// Publish one load-progress sample from the monitor on the main actor.
    private func applyLoadProgress(_ progress: ModelLoadProgress) {
        // Never move backwards: resident size can dip when the kernel
        // compresses or reclaims pages, and that must not drag the bar back.
        loadFraction = max(loadFraction, progress.fraction)
        loadPhaseLabel = progress.phase.label
        loadProgressIsMeasured = progress.isMeasured
        loadBytesText = progress.bytesTotal > 0
            ? "\(Self.byteString(progress.bytesLoaded)) / \(Self.byteString(progress.bytesTotal))"
            : ""
    }

    /// Retire the progress bar and release the stderr pipe handler.
    private func endLoadProgress() {
        loadMonitor?.cancel()
        loadMonitor = nil
        if let pipe = loadPipe {
            pipe.fileHandleForReading.readabilityHandler = nil
            loadPipe = nil
        }
        isLoadingModel = false
        loadFraction = 0
        loadPhaseLabel = ""
        loadBytesText = ""
        loadProgressIsMeasured = false
    }

    /// Human-readable size for the load progress readout.
    ///
    /// Formatted inline rather than through a cached `ByteCountFormatter`: a
    /// static stored property on a @MainActor type is main-actor isolated, so
    /// reaching it from a nonisolated helper warns now and breaks in Swift 6.
    nonisolated static func byteString(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        return String(format: "%.0f MB", Double(bytes) / 1_048_576)
    }

    /// GPU offload override: "auto" wins whenever either source asks for it.
    private func gpuLayerOverride() -> Int {
        let auto = LocalModelAutoConfig.autoGPULayers
        if ggufGpuLayers == auto || ConfigManager.shared.ggufGpuLayers == auto { return auto }
        return ConfigManager.shared.ggufGpuLayers
    }

    /// A router-safe alias derived from a model filename.
    nonisolated static func alias(fromModelPath path: String) -> String {
        let stem = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let cleaned = stem
            .replacingOccurrences(of: #"[^a-zA-Z0-9_-]"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return cleaned.isEmpty ? "local-model" : cleaned
    }

    /// Whether a GGUF's embedded chat template (tokenizer.chat_template) renders
    /// OpenAI-style tool calls. Detection matches actual Jinja tool SYNTAX
    /// (iteration over `tools`, `tool_calls` conditionals, `<|tool|>` markers) —
    /// a bare prose word like "tools" inside a description must not count.
    /// Tool-capable native templates are used as-is with --jinja; models
    /// without them get the exported agentic family template instead.
    nonisolated static func embeddedTemplateSupportsTools(_ template: String) -> Bool {
        guard !template.isEmpty else { return false }
        let syntaxMarkers = [
            "for tool in tools",          // Jinja loop over tool definitions
            "tools is not none",           // ChatML tool branch
            "tools is defined",
            "tool_calls",                  // assistant tool-call rendering
            "tool_call",                   // singular variant
            "<|tool|>",                    // ChatML tool markers
            "<tool_call>",                 // XML-style tool markers
            "function_call",              // Hermes/Functionary style
            "tool use",                    // Anthropic-style markers
        ]
        return syntaxMarkers.contains { template.contains($0) }
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

    /// Find the llama-server binary.
    ///
    /// Prefers the runtime JXRouter bundles or installs for itself (those are
    /// the copies it can update), then falls back to a Homebrew / system copy.
    nonisolated static func findLlamaServer() -> String? {
        if let resolved = LlamaRuntime.bestAvailablePath() { return resolved }

        // Legacy search: only reached when no candidate answered `--version`.
        let candidates = [
            "/opt/homebrew/bin/llama-server",
            "/usr/local/bin/llama-server",
            "/opt/homebrew/bin/llama",
            "/usr/local/bin/llama",
        ]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) { return c }

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
        if let p = path, !p.isEmpty, FileManager.default.isExecutableFile(atPath: p) { return p }
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

// MARK: - Llama.app Preset & Configuration Mirror

/// Reads and mirrors model presets and runtime configurations from llama.app
/// (~/.config/llama/models.user.ini and ~/Library/Application Support/Llama/models.ini)
/// so that JXRouter's built-in GGUF model loader runs with identical, battle-tested
/// hardware acceleration, context lengths, chat templates, and sampling parameters.
struct LlamaPresetSettings: Sendable {
    var contextSize: Int = 262144
    var batchSize: Int = 2048
    var ubatchSize: Int = 2048
    var threads: Int = 12
    var threadsBatch: Int = 12
    var flashAttn: Bool = true
    var contextShift: Bool = true
    var cacheTypeK: String? = "q8_0"
    var cacheTypeV: String? = "q8_0"
    var loadMode: String? = "mlock"
    var chatTemplateFile: String?
    var chatTemplateKwargs: String?
    var reasoningFormat: String?
    var mmproj: String?
    var aliases: [String] = []
    var fitTarget: Int? = 1024
    var specDefault: Bool = true
    var temp: Double? = 0.8
    var minP: Double? = 0.05
    var topP: Double? = 0.95
    var topK: Int? = 0
    var repeatPenalty: Double? = 1.05
    var repeatLastN: Int? = 256
    var dryMultiplier: Double? = 0.8
    var dryBase: Double? = 1.75
    var dryAllowedLength: Int? = 2
    var sleepIdleSeconds: Int? = -1
    var presetFilePath: String?
}

enum LlamaModelPresetReader {
    static let userPresetPath = NSString(string: "~/.config/llama/models.user.ini").expandingTildeInPath
    static let appPresetPath = NSString(string: "~/Library/Application Support/Llama/models.ini").expandingTildeInPath

    /// Resolves the best preset settings for a given model path and alias.
    static func resolvePreset(modelPath: String, alias: String = "") -> LlamaPresetSettings {
        var settings = LlamaPresetSettings()

        // 1. Determine which preset file to reference for --models-preset
        if FileManager.default.isReadableFile(atPath: userPresetPath) {
            settings.presetFilePath = userPresetPath
        } else if FileManager.default.isReadableFile(atPath: appPresetPath) {
            settings.presetFilePath = appPresetPath
        }

        // 2. Parse INI files: base app preset first, user preset overrides on top
        let appSections = parseIni(filePath: appPresetPath)
        let userSections = parseIni(filePath: userPresetPath)

        // Merge global [*] sections
        if let globalApp = appSections["*"] {
            apply(section: globalApp, to: &settings)
        }
        if let globalUser = userSections["*"] {
            apply(section: globalUser, to: &settings)
        }

        // Match model-specific sections
        let modelStem = URL(fileURLWithPath: modelPath).deletingPathExtension().lastPathComponent

        // Search app sections then user sections for best matching section
        if let matched = findMatchingSection(sections: appSections, modelPath: modelPath, modelStem: modelStem, alias: alias) {
            apply(section: matched, to: &settings)
        }
        if let matched = findMatchingSection(sections: userSections, modelPath: modelPath, modelStem: modelStem, alias: alias) {
            apply(section: matched, to: &settings)
        }

        // 3. Auto-discover companion Jinja chat templates if not explicitly specified in INI
        if settings.chatTemplateFile == nil || !FileManager.default.fileExists(atPath: settings.chatTemplateFile ?? "") {
            if let companionJinja = findCompanionJinjaTemplate(modelPath: modelPath, modelStem: modelStem, alias: alias) {
                settings.chatTemplateFile = companionJinja
                if settings.chatTemplateKwargs == nil {
                    settings.chatTemplateKwargs = #"{"tool_call_format":"xml","enable_thinking":false,"plain_language":false,"reasoning_effort":"low"}"#
                }
                if settings.reasoningFormat == nil {
                    // "deepseek", matching `LocalModelAutoConfig` and
                    // llama.cpp's own default (common/common.h:664).
                    // "deepseek-legacy" leaves <think> inline in streaming
                    // deltas; "deepseek" lifts them into
                    // `message.reasoning_content` instead, which keeps agentic
                    // turns free of reasoning noise in the content stream.
                    settings.reasoningFormat = "deepseek"
                }
            }
        }

        return settings
    }

    /// Parses an INI file into a dictionary of section names -> key-value pairs.
    static func parseIni(filePath: String) -> [String: [String: String]] {
        guard let data = FileManager.default.contents(atPath: filePath),
              let content = String(data: data, encoding: .utf8) else {
            return [:]
        }
        var sections: [String: [String: String]] = [:]
        var currentSection = ""

        let lines = content.components(separatedBy: .newlines)
        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix(";") || line.hasPrefix("#") {
                continue
            }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                let sectionName = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                currentSection = sectionName
                if sections[currentSection] == nil {
                    sections[currentSection] = [:]
                }
                continue
            }
            if let eqIdx = line.firstIndex(of: "=") {
                let key = String(line[..<eqIdx]).trimmingCharacters(in: .whitespaces).lowercased()
                let value = String(line[line.index(after: eqIdx)...]).trimmingCharacters(in: .whitespaces)
                if !currentSection.isEmpty {
                    sections[currentSection, default: [:]][key] = value
                }
            }
        }
        return sections
    }

    /// Finds a section matching a model by its file path, stem, or alias.
    static func findMatchingSection(
        sections: [String: [String: String]],
        modelPath: String,
        modelStem: String,
        alias: String
    ) -> [String: String]? {
        let cleanModelPath = modelPath.lowercased()
        let cleanModelStem = modelStem.lowercased()
        let cleanAlias = alias.lowercased()

        // 1. Exact model path match in section key `model`
        for (_, dict) in sections {
            if let m = dict["model"]?.lowercased(), m == cleanModelPath {
                return dict
            }
        }

        // Helper to normalize section name / alias:
        // "local/ornith:q8_0" -> ("ornith", "q8_0")
        func parseSectionHeader(_ raw: String) -> (base: String, quant: String?) {
            var s = raw.lowercased()
            if s.hasPrefix("local/") {
                s = String(s.dropFirst(6))
            }
            if let colonIdx = s.firstIndex(of: ":") {
                let base = String(s[..<colonIdx]).trimmingCharacters(in: .whitespaces)
                let quant = String(s[s.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
                return (base, quant.isEmpty ? nil : quant)
            }
            return (s.trimmingCharacters(in: .whitespaces), nil)
        }

        // 2. Exact or normalized section header / alias match
        for (sec, dict) in sections {
            let s = sec.lowercased()
            if s == "*" { continue }
            if s == cleanAlias || s == cleanModelStem || s.contains(cleanModelStem) || (!cleanAlias.isEmpty && s.contains(cleanAlias)) {
                return dict
            }

            // Check normalized header: e.g. [local/ornith:Q8_0] -> base "ornith", quant "q8_0"
            let parsed = parseSectionHeader(s)
            if !parsed.base.isEmpty {
                let baseMatches = cleanModelStem.contains(parsed.base) || (!cleanAlias.isEmpty && cleanAlias.contains(parsed.base))
                if baseMatches {
                    if let quant = parsed.quant {
                        if cleanModelStem.contains(quant) || (!cleanAlias.isEmpty && cleanAlias.contains(quant)) {
                            return dict
                        }
                    } else {
                        return dict
                    }
                }
            }

            // Check explicit alias list in section body: alias = local/ornith:Q8_0, ornith
            if let aliases = dict["alias"]?.lowercased() {
                let parts = aliases.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                for p in parts {
                    if p == cleanAlias || p == cleanModelStem || cleanModelStem.contains(p) || (!cleanAlias.isEmpty && cleanAlias.contains(p)) {
                        return dict
                    }
                    let parsedPart = parseSectionHeader(p)
                    if !parsedPart.base.isEmpty && (cleanModelStem.contains(parsedPart.base) || (!cleanAlias.isEmpty && cleanAlias.contains(parsedPart.base))) {
                        if let quant = parsedPart.quant {
                            if cleanModelStem.contains(quant) || (!cleanAlias.isEmpty && cleanAlias.contains(quant)) {
                                return dict
                            }
                        } else {
                            return dict
                        }
                    }
                }
            }
        }

        return nil
    }

    /// Applies key-value settings from an INI section onto `LlamaPresetSettings`.
    static func apply(section: [String: String], to settings: inout LlamaPresetSettings) {
        if let val = section["ctx-size"] ?? section["ctx_size"], let intVal = Int(val), intVal > 0 {
            settings.contextSize = intVal
        }
        if let val = section["batch-size"] ?? section["batch"], let intVal = Int(val), intVal > 0 {
            settings.batchSize = intVal
        }
        if let val = section["ubatch-size"] ?? section["ubatch"], let intVal = Int(val), intVal > 0 {
            settings.ubatchSize = intVal
        }
        if let val = section["threads"], let intVal = Int(val), intVal > 0 {
            settings.threads = intVal
        }
        if let val = section["threads-batch"] ?? section["threads_batch"], let intVal = Int(val), intVal > 0 {
            settings.threadsBatch = intVal
        }
        if let val = section["flash-attn"] ?? section["flash_attn"] {
            settings.flashAttn = (val == "1" || val.lowercased() == "true" || val.lowercased() == "on")
        }
        if let val = section["context-shift"] ?? section["context_shift"] {
            settings.contextShift = (val == "1" || val.lowercased() == "true" || val.lowercased() == "on")
        }
        if let val = section["cache-type-k"] ?? section["cache_type_k"] {
            settings.cacheTypeK = val
        }
        if let val = section["cache-type-v"] ?? section["cache_type_v"] {
            settings.cacheTypeV = val
        }
        if let val = section["load-mode"] ?? section["load_mode"] {
            settings.loadMode = val
        }
        if let val = section["chat-template-file"] ?? section["chat_template_file"] {
            let expanded = NSString(string: val).expandingTildeInPath
            if FileManager.default.fileExists(atPath: expanded) {
                settings.chatTemplateFile = expanded
            }
        }
        if let val = section["chat-template-kwargs"] ?? section["chat_template_kwargs"] {
            settings.chatTemplateKwargs = val
        }
        if let val = section["reasoning-format"] ?? section["reasoning_format"] {
            settings.reasoningFormat = val
        }
        if let val = section["mmproj"] {
            let expanded = NSString(string: val).expandingTildeInPath
            if FileManager.default.fileExists(atPath: expanded) {
                settings.mmproj = expanded
            }
        }
        if let val = section["alias"] {
            settings.aliases = val.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        if let val = section["fit-target"] ?? section["fit_target"], let intVal = Int(val) {
            settings.fitTarget = intVal
        }
        if let val = section["temperature"] ?? section["temp"], let d = Double(val) {
            settings.temp = d
        }
        if let val = section["min-p"] ?? section["min_p"], let d = Double(val) {
            settings.minP = d
        }
        if let val = section["top-p"] ?? section["top_p"], let d = Double(val) {
            settings.topP = d
        }
        if let val = section["top-k"] ?? section["top_k"], let intVal = Int(val) {
            settings.topK = intVal
        }
        if let val = section["repeat-penalty"] ?? section["repeat_penalty"], let d = Double(val) {
            settings.repeatPenalty = d
        }
        if let val = section["repeat-last-n"] ?? section["repeat_last_n"], let intVal = Int(val) {
            settings.repeatLastN = intVal
        }
        if let val = section["dry-multiplier"] ?? section["dry_multiplier"], let d = Double(val) {
            settings.dryMultiplier = d
        }
        if let val = section["dry-base"] ?? section["dry_base"], let d = Double(val) {
            settings.dryBase = d
        }
        if let val = section["dry-allowed-length"] ?? section["dry_allowed_length"], let intVal = Int(val) {
            settings.dryAllowedLength = intVal
        }
        if let val = section["sleep-idle-seconds"] ?? section["sleep_idle_seconds"], let intVal = Int(val) {
            settings.sleepIdleSeconds = intVal
        }
    }

    /// Automatically discovers companion Jinja templates in ~/Models or adjacent folders.
    static func findCompanionJinjaTemplate(modelPath: String, modelStem: String, alias: String) -> String? {
        let name = (modelStem + " " + alias + " " + modelPath).lowercased()

        let searchDirs = [
            NSString(string: "~/Models/MiniCPM5-Fixed-Chat-Templates").expandingTildeInPath,
            NSString(string: "~/Models/Qwen-Fixed-Chat-Templates").expandingTildeInPath,
            URL(fileURLWithPath: modelPath).deletingLastPathComponent().path
        ]

        if name.contains("minicpm") {
            let path = "\(searchDirs[0])/chat_template.jinja"
            if FileManager.default.fileExists(atPath: path) { return path }
        }

        if name.contains("qwen") || name.contains("ornith") {
            let path = "\(searchDirs[1])/chat_template.jinja"
            if FileManager.default.fileExists(atPath: path) { return path }
        }

        // Check model's own directory
        let localJinja = "\(searchDirs[2])/chat_template.jinja"
        if FileManager.default.fileExists(atPath: localJinja) {
            return localJinja
        }

        return nil
    }
}

