import Foundation

// MARK: - Capability probing

/// The set of command-line flags a given llama-server build actually accepts.
///
/// JXRouter ships and updates llama.cpp itself, but it also drives an older
/// Homebrew binary if that is all a Mac has. Newer tuning flags (`--fit`,
/// `--cache-reuse`, `--ctx-checkpoints`, …) do not exist in older builds and
/// passing one makes the server exit on startup, so every optional flag is
/// gated on the binary's own `--help` output rather than a guessed version.
struct LlamaServerFeatureSet: Sendable {
    private let flags: Set<String>

    init(helpText: String) {
        var found = Set<String>()
        for token in helpText.split(whereSeparator: { $0.isWhitespace || $0 == "," }) {
            if token.hasPrefix("--") { found.insert(String(token.dropFirst(2))) }
        }
        flags = found
    }

    /// Permissive set used when `--help` can't be read at all.
    static var fallback: LlamaServerFeatureSet {
        LlamaServerFeatureSet(helpText: LlamaServerFeatureSet.knownFlags
            .map { "--\($0)" }.joined(separator: " "))
    }

    static let knownFlags = [
        "fit", "fit-target", "fit-ctx", "flash-attn", "context-shift", "cache-reuse",
        "ctx-checkpoints", "slot-prompt-similarity", "sleep-idle-seconds",
        "chat-template-kwargs", "reasoning", "reasoning-format", "jinja", "models-max",
        "timeout", "load-mode", "mmproj-offload", "cache-type-k", "cache-type-v",
        "spec-type", "spec-draft-n-max", "reasoning-effort",
    ]

    func supports(_ flag: String) -> Bool { flags.contains(flag) }
}

// MARK: - Tool strategy

/// How JXRouter gets a local model to emit tool calls Claude Code can use.
enum LocalToolStrategy: Sendable, Equatable {
    /// The GGUF's own `tokenizer.chat_template` already renders tools, so
    /// `--jinja` lets llama-server use it untouched — the model calls tools in
    /// the exact format it was trained for.
    case nativeEmbedded
    /// The model ships no tool-capable template: JXRouter supplies an agentic
    /// Jinja template for the model's family so tool calls still render.
    case agenticJinja(family: LocalChatTemplateEngine.ChatTemplateFamily)
}

// MARK: - Launch decisions

enum LocalContextMode: Sendable, Equatable {
    /// Omit `-c` and let llama.cpp fit the largest context that fits in memory,
    /// floored at `minimum`. A 262k-capable model gets a huge window on a big
    /// Mac and a smaller one on a small Mac instead of either wasting RAM or
    /// overflowing on Claude Code's first request.
    case auto(minimum: Int, recommended: Int)
    case explicit(Int)
}

enum LocalGPUMode: Sendable, Equatable {
    /// Let llama.cpp offload as many layers as fit.
    case auto
    case all
    case cpu
    case layers(Int)
}

struct LocalSamplingDefaults: Sendable, Equatable {
    var temp: Double? = 0.7
    var minP: Double? = 0.05
    var topP: Double? = 0.95
    var topK: Int? = 0
    var repeatPenalty: Double? = 1.05
    var repeatLastN: Int? = 256
}

/// A complete, ready-to-launch configuration derived from a local model's own
/// metadata. Selecting a model produces one of these; launching turns it into
/// llama-server arguments.
struct LocalModelPlan: Sendable {
    let modelPath: String
    let alias: String
    let modelName: String
    let architecture: String

    // Facts read from the GGUF header.
    let nativeContext: Int
    let embeddingLength: Int
    let blockCount: Int
    let isMixtureOfExperts: Bool
    let multimodalProjector: String?
    let isMultimodal: Bool

    // Launch decisions.
    let contextMode: LocalContextMode
    let gpuMode: LocalGPUMode
    let cacheTypeK: String
    let cacheTypeV: String
    let flashAttention: Bool
    let contextShift: Bool
    let threads: Int?
    let batchSize: Int?
    let ubatchSize: Int?

    // Tool calling.
    let toolStrategy: LocalToolStrategy
    let chatTemplateFile: String?
    let chatTemplateName: String?
    let chatTemplateKwargs: String?
    /// `chatTemplateKwargs` with `enable_thinking` added back, for llama-server
    /// builds too old to have `--reasoning` (which supersedes it).
    let legacyChatTemplateKwargs: String?
    /// True for a thinking-family model: agentic turns go faster and stay free
    /// of `<think>` noise around tool calls when reasoning is switched off.
    let disableThinking: Bool
    let reasoningFormat: String?

    /// `draft-mtp` when the GGUF carries its own MTP draft head; nil otherwise.
    let specType: String?
    /// Draft length for `specType`.
    let specDraftNMax: Int?
    /// True for a hybrid recurrent/attention stack.
    let isHybrid: Bool
    /// KV-caching layer count (`blockCount` for dense models).
    let attentionLayerCount: Int

    let sampling: LocalSamplingDefaults

    var isNativeToolCalling: Bool {
        if case .nativeEmbedded = toolStrategy { return true }
        return false
    }

    /// The context size this Mac can actually hold (used for display and as the
    /// floor handed to llama.cpp's fitter).
    var recommendedContext: Int {
        switch contextMode {
        case .auto(_, let recommended): return recommended
        case .explicit(let n): return n
        }
    }

    /// A few lines for the settings UI explaining what was chosen.
    var summary: String {
        var lines: [String] = []
        switch contextMode {
        case .auto(let minimum, let recommended):
            lines.append("Context: auto — ~\(recommended.formatted()) tokens, floor \(minimum.formatted())")
        case .explicit(let n):
            lines.append("Context: \(n.formatted()) tokens")
        }
        switch gpuMode {
        case .auto: lines.append("Offload: auto (as many layers as fit)")
        case .all: lines.append("Offload: all layers on GPU")
        case .cpu: lines.append("Offload: CPU only")
        case .layers(let n): lines.append("Offload: \(n) layers on GPU")
        }
        switch toolStrategy {
        case .nativeEmbedded: lines.append("Tools: native (model's own template)")
        case .agenticJinja(let f): lines.append("Tools: JXRouter agentic template (\(f.rawValue))")
        }
        if isMultimodal, let mm = multimodalProjector {
            lines.append("Vision: \((mm as NSString).lastPathComponent)")
        }
        if isHybrid {
            lines.append("Attention: hybrid — \(attentionLayerCount) of \(blockCount) layers cached")
        }
        if let spec = specType, spec == "draft-mtp" {
            lines.append("Decode: MTP self-speculation (model's own draft head)")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Builder

enum LocalModelAutoConfig {

    /// Explicit user choices; anything left at its default is derived from the model.
    struct Overrides: Sendable {
        /// 0 = auto-fit, otherwise an exact context size.
        var contextSize: Int = 0
        /// -2 = auto, -1 = all layers, 0 = CPU only, >0 = exact layer count.
        var gpuLayers: Int = -2
        var cacheTypeK: String = ""
        var cacheTypeV: String = ""
        var flashAttention: Bool = true
        var contextShift: Bool = true
        /// "" = auto, "agentic-qwen" / "agentic-llama3", a .jinja path, or a
        /// built-in llama-server template name such as "chatml".
        var chatTemplate: String = ""
        /// Opt in to MTP self-speculation for models that ship a draft head.
        /// Off by default: measured on an M2 Max it is a net loss, because the
        /// draft pass is a full forward and acceptance was only 0.575
        /// (13.57 -> 10.40 tok/s). Cheap to revisit on faster GPUs.
        var enableMTP: Bool = false
        var mmprojPath: String = ""
        var threads: Int = 0
    }

    static let autoGPULayers = -2

    /// Derive a full launch plan for a model from its own GGUF metadata.
    static func plan(forModelPath path: String,
                     alias: String,
                     overrides: Overrides = Overrides()) -> LocalModelPlan {
        let url = URL(fileURLWithPath: path)
        let meta = GGUFParser.metadata(from: url)
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let fileSize = (attrs?[.size] as? Int64) ?? 0

        let nativeContext = meta.contextLength > 0 ? meta.contextLength : 32_768
        let architecture = meta.architecture.isEmpty
            ? GGUFModelScanner.readGGUFMetadata(path: path, fileSize: fileSize).architecture
            : meta.architecture

        // ---- Context -------------------------------------------------------
        let uncapped = recommendedContext(native: nativeContext,
                                          meta: meta,
                                          modelBytes: fileSize)
        let recommended = min(uncapped, Self.autoContextCeiling)
        let contextMode: LocalContextMode = overrides.contextSize > 0
            ? .explicit(overrides.contextSize)
            : .auto(minimum: min(nativeContext, recommended, 65_536), recommended: recommended)

        // ---- GPU -----------------------------------------------------------
        let gpuMode: LocalGPUMode
        switch overrides.gpuLayers {
        case Self.autoGPULayers: gpuMode = .auto
        case -1: gpuMode = .all
        case 0: gpuMode = .cpu
        default: gpuMode = .layers(overrides.gpuLayers)
        }

        // ---- Vision --------------------------------------------------------
        // A projector is only accepted when its projection width matches the
        // text model's embedding length, otherwise llama.cpp aborts on load.
        let projector: String? = {
            if !overrides.mmprojPath.isEmpty {
                if GGUFModelScanner.projectorFits(modelPath: path, projectorPath: overrides.mmprojPath) {
                    return overrides.mmprojPath
                }
                print("[AutoConfig] Ignoring incompatible projector \(overrides.mmprojPath)")
            }
            return GGUFModelScanner.findMatchingMmproj(forModelPath: path)
        }()

        // ---- Tool calling --------------------------------------------------
        let family = detectFamily(architecture: architecture, name: meta.name,
                                  path: path, alias: alias)
        let embeddedSupportsTools = LocalModelManager.embeddedTemplateSupportsTools(meta.chatTemplate)
        let keepNative = overrides.chatTemplate.isEmpty || overrides.chatTemplate == "auto"
        let strategy: LocalToolStrategy = (embeddedSupportsTools && keepNative)
            ? .nativeEmbedded
            : .agenticJinja(family: family)

        var templateFile: String?
        var templateName: String?
        var kwargs: String?
        var reasoningFormat: String?

        switch overrides.chatTemplate {
        case "agentic-qwen", "agentic-chatml":
            templateFile = LocalChatTemplateEngine.exportAgenticTemplate(for: .chatml)
        case "agentic-llama3":
            templateFile = LocalChatTemplateEngine.exportAgenticTemplate(for: .llama3)
        case let custom where custom.hasSuffix(".jinja") || FileManager.default.fileExists(atPath: custom):
            templateFile = custom
        case let named where !named.isEmpty && named != "auto":
            // A llama-server built-in name (`chatml`, `llama3`, …): passed with
            // `--chat-template <name>`; JXRouter's XML kwargs don't apply to it.
            templateName = named
        default:
            if case .agenticJinja(let f) = strategy {
                templateFile = LocalChatTemplateEngine.exportAgenticTemplate(for: f)
            }
        }

        let isThinking = isThinkingFamily(architecture: architecture, name: meta.name,
                                          path: path, alias: alias)

        // `--reasoning off` supersedes `enable_thinking` in chat-template-kwargs,
        // which llama.cpp now logs as deprecated. `legacyKwargs` keeps the old
        // spelling for binaries with no `--reasoning` flag at all.
        let legacyKwargs: String?

        if templateName != nil {
            // Built-in template: only thinking control is meaningful.
            kwargs = nil
            legacyKwargs = isThinking ? #"{"enable_thinking":false}"# : nil
            reasoningFormat = isThinking ? "deepseek" : nil
        } else {
            switch strategy {
            case .nativeEmbedded:
                // A model's own template reads `enable_thinking`, never
                // `tool_call_format` — passing the latter is a no-op. It must
                // still be set explicitly: Qwen3.5-family templates default
                // thinking ON at `xhigh` effort when the flag is undefined, and
                // `--reasoning off` does not reach a template llama.cpp did not
                // classify as a reasoning model.
                kwargs = isThinking ? #"{"enable_thinking":false}"# : nil
                legacyKwargs = isThinking ? #"{"enable_thinking":false}"# : nil
                reasoningFormat = isThinking ? "deepseek" : nil
            case .agenticJinja:
                kwargs = #"{"tool_call_format":"xml","plain_language":false,"reasoning_effort":"low"}"#
                legacyKwargs = #"{"tool_call_format":"xml","enable_thinking":false,"plain_language":false,"reasoning_effort":"low"}"#
                reasoningFormat = isThinking ? "deepseek" : "none"
            }
        }

        // ---- Speculative decoding ------------------------------------------
        // A GGUF reporting `nextn_predict_layers` carries its own MTP draft
        // head, so llama-server can self-draft: several tokens proposed per
        // forward pass, verified in one batched pass, no second model resident.
        // Kept opt-in — see `Overrides.enableMTP` for the measurement.
        let specType: String? = (overrides.enableMTP && meta.nextnPredictLayers > 0)
            ? "draft-mtp" : nil
        let specDraftNMax: Int? = specType == nil ? nil : 3

        return LocalModelPlan(
            modelPath: path,
            alias: alias,
            modelName: meta.name.isEmpty ? (path as NSString).lastPathComponent : meta.name,
            architecture: architecture,
            nativeContext: nativeContext,
            embeddingLength: meta.embeddingLength,
            blockCount: meta.blockCount,
            isMixtureOfExperts: meta.expertCount > 0,
            multimodalProjector: projector,
            isMultimodal: projector != nil || meta.hasVisionEncoder,
            contextMode: contextMode,
            gpuMode: gpuMode,
            cacheTypeK: overrides.cacheTypeK.isEmpty ? "q8_0" : overrides.cacheTypeK,
            cacheTypeV: overrides.cacheTypeV.isEmpty ? "q8_0" : overrides.cacheTypeV,
            flashAttention: overrides.flashAttention,
            contextShift: overrides.contextShift,
            threads: overrides.threads > 0 ? overrides.threads : nil,
            batchSize: nil,
            ubatchSize: nil,
            toolStrategy: strategy,
            chatTemplateFile: templateFile,
            chatTemplateName: templateName,
            chatTemplateKwargs: kwargs,
            legacyChatTemplateKwargs: legacyKwargs,
            disableThinking: isThinking,
            reasoningFormat: reasoningFormat,
            specType: specType,
            specDraftNMax: specDraftNMax,
            isHybrid: meta.isHybrid,
            attentionLayerCount: meta.attentionLayerCount,
            sampling: LocalSamplingDefaults()
        )
    }

    // MARK: - Context sizing

    private static let gibibyte: Double = 1024 * 1024 * 1024

    /// This Mac's inference-relevant profile, read once.
    ///
    /// Used for the memory reserve below. `HardwareProfile.current()` is a
    /// handful of sysctl calls, so it is cached rather than re-read per plan.
    private static let hardware = HardwareProfile.current()

    /// Largest window auto mode will aim for, even when the model and this Mac
    /// could technically hold more.
    ///
    /// Measured on a 32 GB M2 Max: a 262,144-token window cost ~8 GB of KV
    /// beside 10.5 GB of weights, which drove the machine into 17 GB of swap
    /// and made every request look like a hang. Raise it deliberately, per Mac.
    private static let autoContextCeiling = 65_536

    /// Largest context this Mac can hold for a model, from its real dimensions.
    ///
    /// KV cache cost per token = layers × kv-heads × head-dim × 2 (K and V) ×
    /// bytes-per-element. Budget = installed RAM − model weights − a reserve for
    /// macOS, JXRouter and the compute graph. Without this, a 262k-native model
    /// on a 16 GB Mac asks for ~11 GB of KV cache and gets killed.
    static func recommendedContext(native: Int, meta: GGUFParser.Metadata, modelBytes: Int64) -> Int {
        guard meta.blockCount > 0, meta.embeddingLength > 0 else { return native }

        let kvHeads = meta.attentionHeadCountKV > 0 ? meta.attentionHeadCountKV
                    : (meta.attentionHeadCount > 0 ? meta.attentionHeadCount : 0)
        let headCount = meta.attentionHeadCount > 0 ? meta.attentionHeadCount : 1
        guard kvHeads > 0 else { return native }

        let headDim = max(meta.embeddingLength / headCount, 64)
        let bytesPerElement: Double = 1.06 // q8_0, including its block scale
        // Hybrid stacks cache only their full-attention layers. Counting every
        // block would shrink the window ~4x on a 65-block model with interval 4.
        let kvLayers = meta.attentionLayerCount > 0 ? meta.attentionLayerCount : meta.blockCount
        let perToken = Double(kvLayers) * Double(kvHeads) * Double(headDim) * 2 * bytesPerElement
        guard perToken > 0 else { return native }

        // Reserve headroom from the machine's real profile rather than a flat
        // 3 GiB. `reservedBytes` scales with installed RAM (20%, floored at
        // 6 GiB, capped at half): a unified-memory Mac shares RAM with the GPU,
        // so the flat reserve under-counted and is what let a 262k window push
        // this machine into swap. Falls back to the old numbers if sysctl
        // returns nothing usable.
        let ram = hardware.totalRAMBytes > 0
            ? Double(hardware.totalRAMBytes)
            : Double(ProcessInfo.processInfo.physicalMemory)
        let reserve = hardware.totalRAMBytes > 0
            ? Double(hardware.reservedBytes)
            : 3.0 * gibibyte
        let usable = max(ram - Double(modelBytes) - reserve, gibibyte)

        let byMemory = Int(usable / perToken)
        let ceiling = min(native, byMemory)
        // Round down to a 4096 boundary and never go below a usable window.
        let rounded = max((ceiling / 4096) * 4096, 8192)
        return min(rounded, native)
    }

    // MARK: - Family detection

    /// Template family from GGUF architecture first (authoritative), then the
    /// model name / path heuristics already used elsewhere.
    static func detectFamily(architecture: String,
                             name: String,
                             path: String,
                             alias: String) -> LocalChatTemplateEngine.ChatTemplateFamily {
        let arch = architecture.lowercased()
        func archContains(_ needles: [String]) -> Bool { needles.contains { arch.contains($0) } }

        if archContains(["qwen", "chatml", "yi"]) { return .chatml }
        if archContains(["deepseek"]) { return .deepseek3 }
        if archContains(["llama"]) {
            // llama.cpp reports a bare "llama" for Llama-2 and Llama-3 alike;
            // the name/path tells them apart.
            let hint = (name + " " + path + " " + alias).lowercased()
            if hint.contains("llama-2") || hint.contains("llama2") || hint.contains("codellama") {
                return .llama2
            }
            return .llama3
        }
        if archContains(["mistral", "mixtral", "codestral", "devstral"]) { return .mistral }
        if archContains(["gemma"]) { return .gemma }
        if archContains(["phi4"]) { return .phi4 }
        if archContains(["phi3", "phi"]) { return .phi3 }
        if archContains(["command-r", "c4ai"]) { return .commandR }
        if archContains(["minicpm"]) { return .chatml }
        return LocalChatTemplateEngine.detectTemplate(forModelName: "\(name) \(path) \(alias)")
    }

    /// Models whose template emits `<think>…</think>` that must be extracted
    /// into `reasoning_content` instead of leaking into the visible answer.
    static func isThinkingFamily(architecture: String, name: String, path: String, alias: String) -> Bool {
        let haystack = (architecture + " " + name + " " + path + " " + alias).lowercased()
        return haystack.contains("qwen3")
            || haystack.contains("deepseek")
            || haystack.contains("ornith")
    }

    // MARK: - Arguments

    /// Turn a plan into llama-server arguments, skipping flags the binary lacks.
    static func arguments(for plan: LocalModelPlan,
                          port: Int,
                          binaryPath: String,
                          features: LlamaServerFeatureSet) -> [String] {
        var args: [String] = []

        if binaryPath.hasSuffix("/llama") && !binaryPath.hasSuffix("llama-server") {
            args.append("serve")
        }

        args.append(contentsOf: ["-m", plan.modelPath])
        args.append(contentsOf: ["--host", "127.0.0.1"])
        args.append(contentsOf: ["--port", "\(port)"])
        args.append(contentsOf: ["-a", plan.alias])

        if let mmproj = plan.multimodalProjector, !mmproj.isEmpty {
            args.append(contentsOf: ["--mmproj", mmproj])
            if case .cpu = plan.gpuMode {
                // CPU-only: the projector stays on the CPU too.
            } else if features.supports("mmproj-offload") {
                args.append("--mmproj-offload")
            }
        }

        // ---- Context & offload --------------------------------------------
        // In auto mode both `-c` and `-ngl` are omitted so llama.cpp's fitter
        // picks the largest context and layer count that fit in memory. Pinning
        // them (as JXRouter used to) is what produced both the 128k overflows
        // on Claude Code's first request and the accidental CPU-only runs.
        let fits = features.supports("fit")
        switch plan.contextMode {
        case .auto(let minimum, let recommended):
            // Only hand sizing to the fitter when this Mac can afford the
            // model's whole native window. `-fit` measures *device* memory, not
            // the machine's real headroom, so in every other case the window is
            // pinned: otherwise a 262k-native model on a 32 GB Mac wins the
            // allocation and loses the machine to swapping.
            if fits, recommended >= plan.nativeContext {
                args.append(contentsOf: ["-fit", "on"])
                if features.supports("fit-ctx") {
                    args.append(contentsOf: ["-fitc", "\(minimum)"])
                }
            } else {
                args.append(contentsOf: ["-c", "\(recommended)"])
            }
        case .explicit(let size):
            args.append(contentsOf: ["-c", "\(size)"])
        }

        switch plan.gpuMode {
        case .auto:
            // `auto` is a newer value; older builds only accept a number.
            args.append(contentsOf: ["-ngl", fits ? "auto" : "999"])
        case .all:
            args.append(contentsOf: ["-ngl", "999"])
        case .cpu:
            args.append(contentsOf: ["-ngl", "0"])
        case .layers(let n):
            args.append(contentsOf: ["-ngl", "\(n)"])
        }

        if plan.contextShift, features.supports("context-shift") {
            args.append("--context-shift")
        }
        if plan.flashAttention, features.supports("flash-attn") {
            args.append(contentsOf: ["-fa", "on"])
        }
        if features.supports("cache-type-k") {
            args.append(contentsOf: ["-ctk", plan.cacheTypeK])
        }
        if features.supports("cache-type-v") {
            args.append(contentsOf: ["-ctv", plan.cacheTypeV])
        }
        if let threads = plan.threads {
            args.append(contentsOf: ["-t", "\(threads)"])
        }

        // ---- Chat template / tool calling ---------------------------------
        if features.supports("jinja") { args.append("--jinja") }
        if let file = plan.chatTemplateFile, !file.isEmpty {
            args.append(contentsOf: ["--chat-template-file", file])
        } else if let name = plan.chatTemplateName, !name.isEmpty {
            args.append(contentsOf: ["--chat-template", name])
        }
        // llama.cpp deprecates `enable_thinking` in favour of `--reasoning`.
        if plan.disableThinking, features.supports("reasoning") {
            args.append(contentsOf: ["--reasoning", "off"])
        }
        let resolvedKwargs = features.supports("reasoning")
            ? plan.chatTemplateKwargs
            : (plan.legacyChatTemplateKwargs ?? plan.chatTemplateKwargs)
        if let resolvedKwargs, !resolvedKwargs.isEmpty,
           features.supports("chat-template-kwargs") {
            args.append(contentsOf: ["--chat-template-kwargs", resolvedKwargs])
        }
        if let reasoning = plan.reasoningFormat, !reasoning.isEmpty,
           features.supports("reasoning-format") {
            args.append(contentsOf: ["--reasoning-format", reasoning])
        }

        // ---- Prompt cache reuse -------------------------------------------
        // Claude Code re-sends a ~100k-token prefix every turn; without reuse
        // each turn re-prefills from scratch (minutes per message).
        if features.supports("slot-prompt-similarity") {
            args.append(contentsOf: ["--slot-prompt-similarity", "0.1"])
        }
        if features.supports("cache-reuse") {
            args.append(contentsOf: ["--cache-reuse", "256"])
        }
        if features.supports("ctx-checkpoints") {
            args.append(contentsOf: ["--ctx-checkpoints", "8"])
        }

        // ---- Speculative decoding -----------------------------------------
        // Only for models that ship a draft head; a separate draft model would
        // double the resident set and is never chosen automatically.
        if let spec = plan.specType, !spec.isEmpty, features.supports("spec-type") {
            args.append(contentsOf: ["--spec-type", spec])
            if let n = plan.specDraftNMax, features.supports("spec-draft-n-max") {
                args.append(contentsOf: ["--spec-draft-n-max", "\(n)"])
            }
        }

        // ---- Sampling ------------------------------------------------------
        let s = plan.sampling
        if let v = s.temp { args.append(contentsOf: ["--temp", String(format: "%.2f", v)]) }
        if let v = s.minP { args.append(contentsOf: ["--min-p", String(format: "%.2f", v)]) }
        if let v = s.topP { args.append(contentsOf: ["--top-p", String(format: "%.2f", v)]) }
        if let v = s.topK { args.append(contentsOf: ["--top-k", "\(v)"]) }
        if let v = s.repeatPenalty { args.append(contentsOf: ["--repeat-penalty", String(format: "%.2f", v)]) }
        if let v = s.repeatLastN { args.append(contentsOf: ["--repeat-last-n", "\(v)"]) }

        // Keep the weights resident: llama.cpp defaults to plain mmap, which
        // lets macOS page a multi-gigabyte model out mid-session and stall
        // Claude Code for minutes on the next turn.
        if features.supports("load-mode") {
            args.append(contentsOf: ["--load-mode", "mlock"])
        }

        // ---- Lifetime & slotting ------------------------------------------
        // One dedicated slot so the whole context serves the active session,
        // and no idle unload — the model stays resident until the app quits.
        if features.supports("timeout") { args.append(contentsOf: ["-to", "3600"]) }
        if features.supports("sleep-idle-seconds") {
            args.append(contentsOf: ["--sleep-idle-seconds", "-1"])
        }
        args.append(contentsOf: ["--parallel", "1"])
        if features.supports("models-max") {
            args.append(contentsOf: ["--models-max", "1"])
        }
        return args
    }

    // MARK: - Feature probing

    private static var featureCache: [String: LlamaServerFeatureSet] = [:]
    private static let featureLock = NSLock()

    /// Read `--help` from a llama-server binary (cached per path).
    static func featureSet(forBinaryAt path: String) -> LlamaServerFeatureSet {
        featureLock.lock()
        let cached = featureCache[path]
        featureLock.unlock()
        if let cached { return cached }

        let (_, output) = LlamaRuntime.run(path, args: ["--help"], timeout: 20)
        let set = output.isEmpty ? LlamaServerFeatureSet.fallback : LlamaServerFeatureSet(helpText: output)

        featureLock.lock()
        featureCache[path] = set
        featureLock.unlock()
        return set
    }
}

// MARK: - Applying a plan to app state

extension LocalModelAutoConfig {

    /// Provider ids that mean "a model running on this Mac".
    ///
    /// A Claude tier pointed at one of these (or unset) is safely redirected to
    /// the GGUF runtime when a local model is chosen — otherwise picking a
    /// model would leave Sonnet traffic going to, say, llama.app. A tier
    /// pointed at a cloud provider is deliberately left alone so a paid
    /// fallback for hard tasks survives.
    static let localProviderIDs: Set<String> = [
        "", "local", "ollama", "lmstudio", "llamaapp", "jan", "unsloth", "gguf"
    ]

    /// Point the router at this model so Claude Code traffic reaches it: the
    /// primary provider becomes GGUF, the model alias is written to the
    /// default, Opus, Sonnet and Haiku tiers, and every derived setting is
    /// persisted so a relaunch keeps working.
    @MainActor
    static func applyRouting(_ plan: LocalModelPlan, port: Int) {
        let cfg = ConfigManager.shared
        let mgr = LocalModelManager.shared

        mgr.provider = .gguf
        mgr.port = port
        mgr.selectedGGUFPath = plan.modelPath
        mgr.ggufModelAlias = plan.alias

        cfg.provider = "gguf"
        cfg.model = plan.alias
        cfg.modelOpus = plan.alias
        cfg.modelSonnet = plan.alias
        cfg.modelHaiku = plan.alias
        cfg.ggufModelPath = plan.modelPath
        cfg.ggufModelAlias = plan.alias
        cfg.ggufPort = port

        // Redirect local tiers (and unset ones) at the GGUF runtime.
        for tier in ["opus", "sonnet", "haiku"] {
            let current = cfg.tierProvider(for: tier) ?? ""
            if localProviderIDs.contains(current), current != "gguf" {
                cfg.setTierProvider(tier, "gguf")
            }
        }

        print("[AutoConfig] Routed Claude -> gguf:\(plan.alias) on port \(port)")
        print("[AutoConfig] \(plan.summary.replacingOccurrences(of: "\n", with: " | "))")
    }
}
