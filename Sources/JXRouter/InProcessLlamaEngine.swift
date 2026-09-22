import Foundation

// MARK: - C ABI
//
// Mirrors `jx_llama_bridge.h`. The ABI passes only scalars and pointers:
// Swift's `@convention(c)` rejects by-value Swift structs as "not
// representable in Objective-C", so struct parameters are not an option.

private typealias JXProgressCallback = @convention(c) (Float, UnsafeMutableRawPointer?) -> Void
private typealias JXTokenCallback = @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void

private typealias FnVoidVoid = @convention(c) () -> Void
private typealias FnInit = @convention(c) () -> Int32
private typealias FnDefaultThreads = @convention(c) () -> Int32
private typealias FnLoad = @convention(c) (
    UnsafePointer<CChar>?, Int32, Int32, Int32, Int32, Int32, Int32,
    JXProgressCallback?, UnsafeMutableRawPointer?
) -> UnsafeMutableRawPointer?
private typealias FnRelease = @convention(c) (UnsafeMutableRawPointer?) -> Void
private typealias FnModelInt = @convention(c) (UnsafeMutableRawPointer?) -> Int32
private typealias FnModelVoid = @convention(c) (UnsafeMutableRawPointer?) -> Void
private typealias FnTemplate = @convention(c) (
    UnsafeMutableRawPointer?,
    UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
    UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
    Int32, Int32
) -> UnsafeMutablePointer<CChar>?
private typealias FnTokenize = @convention(c) (
    UnsafeMutableRawPointer?, UnsafePointer<CChar>?,
    UnsafeMutablePointer<Int32>?, Int32, Int32
) -> Int32
private typealias FnGenerate = @convention(c) (
    UnsafeMutableRawPointer?, UnsafePointer<CChar>?,
    Float, Float, Int32, Float, Int32, UInt32,
    JXTokenCallback?, UnsafeMutableRawPointer?, UnsafeMutablePointer<Int32>?
) -> Int32
private typealias FnLastError = @convention(c) () -> UnsafePointer<CChar>?

/// Bridges a Swift callback into a context-free C function pointer.
private final class JXTokenSink: @unchecked Sendable {
    var text = ""
    let onToken: ((String) -> Void)?
    init(_ onToken: ((String) -> Void)?) { self.onToken = onToken }
}

/// Same trick for the load-progress callback.
private final class JXProgressSink: @unchecked Sendable {
    let onProgress: (Float) -> Void
    init(_ onProgress: @escaping (Float) -> Void) { self.onProgress = onProgress }
}

/// Generation settings. Pure Swift — never crosses the C boundary.
struct JXSampling {
    var temperature: Float = 0.7
    var topP: Float = 0.9
    var topK: Int32 = 40
    var repeatPenalty: Float = 1.1
    var maxTokens: Int32 = 512
    var seed: UInt32 = 0
}

/// Load settings. Pure Swift — expanded to scalars at the call site.
struct JXLoadParams {
    var nCtx: Int32 = 0            // 0 = take from model
    var nBatch: Int32 = 2048
    var nUBatch: Int32 = 512
    var nGPULayers: Int32 = -1     // negative = all layers on GPU
    var nThreads: Int32 = 0        // 0 = engine default
    var flashAttn: Int32 = 0       // 0 = auto, 1 = on, 2 = off
}

// MARK: - Engine

/// In-process llama.cpp inference, loaded from an embedded dylib at runtime.
///
/// Why `dlopen` instead of a normal linked framework: the llama.cpp static
/// libraries are arm64-only, but the app ships universal. Linking them
/// directly would fail the x86_64 slice. Resolving the symbols at runtime
/// means the Intel build compiles and runs fine — `isAvailable` is simply
/// `false` there and the caller falls back to the `llama-server` subprocess.
///
/// Everything the model does stays inside this process: no child process, no
/// HTTP hop, no port to fight over.
final class InProcessLlamaEngine: @unchecked Sendable {

    enum EngineError: LocalizedError {
        case unavailable(String)
        case loadFailed(String)
        case noModel
        case generationFailed(String)

        var errorDescription: String? {
            switch self {
            case .unavailable(let s): return "In-process engine unavailable: \(s)"
            case .loadFailed(let s): return "Model load failed: \(s)"
            case .noModel: return "No model loaded"
            case .generationFailed(let s): return "Generation failed: \(s)"
            }
        }
    }

    static let shared = InProcessLlamaEngine()

    private(set) var isAvailable = false
    private(set) var unavailableReason: String?
    private(set) var loadedModelPath: String?

    private var handle: UnsafeMutableRawPointer?
    private var model: UnsafeMutableRawPointer?

    private var _init: FnInit?
    private var _shutdown: FnVoidVoid?
    private var _defaultThreads: FnDefaultThreads?
    private var _load: FnLoad?
    private var _release: FnRelease?
    private var _nCtx: FnModelInt?
    private var _nCtxTrain: FnModelInt?
    private var _nVocab: FnModelInt?
    private var _clearKV: FnModelVoid?
    private var _cancel: FnModelVoid?
    private var _template: FnTemplate?
    private var _tokenize: FnTokenize?
    private var _generate: FnGenerate?
    private var _lastError: FnLastError?

    /// Serialises access to llama.cpp: it is not re-entrant, and generation
    /// blocks for its whole duration.
    private let queue = DispatchQueue(label: "com.jxrouter.llama.inprocess", qos: .userInitiated)

    private init() { bind() }

    deinit {
        if let model, let _release { _release(model) }
        if let handle { dlclose(handle) }
    }

    // MARK: - Binding

    private func bind() {
        guard let path = Self.dylibPath() else {
            unavailableReason = "libjxllama.dylib not found in the app bundle"
            isAvailable = false
            return
        }
        guard let h = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
            let msg = String(cString: dlerror())
            unavailableReason = "dlopen failed: \(msg)"
            isAvailable = false
            return
        }
        handle = h

        // Every symbol must resolve; a partial bind would crash later.
        let required: [(String, UnsafeMutableRawPointer?)] = [
            ("jxllm_init", dlsym(h, "jxllm_init")),
            ("jxllm_shutdown", dlsym(h, "jxllm_shutdown")),
            ("jxllm_default_threads", dlsym(h, "jxllm_default_threads")),
            ("jxllm_load", dlsym(h, "jxllm_load")),
            ("jxllm_release", dlsym(h, "jxllm_release")),
            ("jxllm_n_ctx", dlsym(h, "jxllm_n_ctx")),
            ("jxllm_n_ctx_train", dlsym(h, "jxllm_n_ctx_train")),
            ("jxllm_n_vocab", dlsym(h, "jxllm_n_vocab")),
            ("jxllm_clear_kv", dlsym(h, "jxllm_clear_kv")),
            ("jxllm_cancel", dlsym(h, "jxllm_cancel")),
            ("jxllm_apply_chat_template", dlsym(h, "jxllm_apply_chat_template")),
            ("jxllm_tokenize", dlsym(h, "jxllm_tokenize")),
            ("jxllm_generate", dlsym(h, "jxllm_generate")),
            ("jxllm_last_error", dlsym(h, "jxllm_last_error")),
        ]
        if let missing = required.first(where: { $0.1 == nil }) {
            unavailableReason = "missing symbol \(missing.0)"
            isAvailable = false
            dlclose(h)
            handle = nil
            return
        }

        func sym<T>(_ name: String) -> T? {
            guard let p = dlsym(h, name) else { return nil }
            return unsafeBitCast(p, to: T.self)
        }
        _init = sym("jxllm_init")
        _shutdown = sym("jxllm_shutdown")
        _defaultThreads = sym("jxllm_default_threads")
        _load = sym("jxllm_load")
        _release = sym("jxllm_release")
        _nCtx = sym("jxllm_n_ctx")
        _nCtxTrain = sym("jxllm_n_ctx_train")
        _nVocab = sym("jxllm_n_vocab")
        _clearKV = sym("jxllm_clear_kv")
        _cancel = sym("jxllm_cancel")
        _template = sym("jxllm_apply_chat_template")
        _tokenize = sym("jxllm_tokenize")
        _generate = sym("jxllm_generate")
        _lastError = sym("jxllm_last_error")

        _ = _init?()
        isAvailable = true
    }

    /// Where the dylib lives. `Contents/Frameworks` is the canonical spot; the
    /// Application Support path lets a locally-built dylib override it.
    static func dylibPath() -> String? {
        let fm = FileManager.default
        var candidates: [String] = []
        if let fw = Bundle.main.privateFrameworksPath {
            candidates.append((fw as NSString).appendingPathComponent("libjxllama.dylib"))
        }
        if let res = Bundle.main.resourcePath {
            candidates.append((res as NSString).appendingPathComponent("libjxllama.dylib"))
        }
        if let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            candidates.append(appSupport
                .appendingPathComponent("JXRouter/llama-cpp/libjxllama.dylib").path)
        }
        return candidates.first { fm.fileExists(atPath: $0) }
    }

    private func lastError() -> String? {
        guard let _lastError, let c = _lastError() else { return nil }
        return String(cString: c)
    }

    // MARK: - Model

    var nCtx: Int32 { guard let model, let _nCtx else { return 0 }; return _nCtx(model) }
    var nCtxTrain: Int32 { guard let model, let _nCtxTrain else { return 0 }; return _nCtxTrain(model) }

    /// Load a GGUF. `onProgress` is called on the main thread with 0…1.
    func load(modelPath: String,
              params: JXLoadParams? = nil,
              onProgress: ((Double) -> Void)? = nil) async throws {
        guard isAvailable, let _load else {
            throw EngineError.unavailable(unavailableReason ?? "not bound")
        }

        let p = params ?? JXLoadParams()

        // Non-capturing C callback; context rides in `user`.
        let box = JXProgressSink { value in
            let d = Double(value)
            DispatchQueue.main.async { onProgress?(d) }
        }
        let user = Unmanaged.passUnretained(box).toOpaque()

        let callback: JXProgressCallback = { value, ctx in
            guard let ctx else { return }
            Unmanaged<JXProgressSink>.fromOpaque(ctx).takeUnretainedValue().onProgress(value)
        }

        let result: UnsafeMutableRawPointer? = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UnsafeMutableRawPointer?, Error>) in
            queue.async {
                // Keep the box alive across the blocking call.
                _ = box
                let m = _load(modelPath,
                              p.nCtx, p.nBatch, p.nUBatch,
                              p.nGPULayers, p.nThreads, p.flashAttn,
                              callback, user)
                cont.resume(returning: m)
            }
        }

        guard let m = result else {
            throw EngineError.loadFailed(lastError() ?? "unknown error")
        }

        if let old = model, let _release { _release(old) }
        model = m
        loadedModelPath = modelPath
    }

    func unload() {
        guard let m = model else { return }
        queue.sync {
            _release?(m)
        }
        model = nil
        loadedModelPath = nil
    }

    func clearKV() { if let model { _clearKV?(model) } }
    func cancel() { if let model { _cancel?(model) } }

    // MARK: - Generation

    /// Apply the model's chat template to role/message pairs.
    func applyChatTemplate(roles: [String], messages: [String], addAssistant: Bool) -> String? {
        guard isAvailable, let model, let _template, roles.count == messages.count else { return nil }
        // strdup so the buffers outlive the call; a Swift String's utf8CString
        // pointer is only valid inside its own closure.
        var rolePtrs: [UnsafeMutablePointer<CChar>?] = roles.map { strdup($0) }
        var msgPtrs: [UnsafeMutablePointer<CChar>?] = messages.map { strdup($0) }
        defer {
            rolePtrs.forEach { free($0) }
            msgPtrs.forEach { free($0) }
        }

        guard let out = rolePtrs.withUnsafeMutableBufferPointer({ rp in
            msgPtrs.withUnsafeMutableBufferPointer { mp in
                _template(model, rp.baseAddress, mp.baseAddress, Int32(messages.count), addAssistant ? 1 : 0)
            }
        }) else { return nil }
        defer { free(out) }
        return String(cString: out)
    }

    /// Number of tokens `text` would consume. Used for budget checks.
    func tokenCount(_ text: String) -> Int32 {
        guard isAvailable, let model, let _tokenize else { return 0 }
        return text.withCString { _tokenize(model, $0, nil, 0, 1) }
    }

    /// Generate text. `onToken` fires on the main thread as pieces arrive.
    /// Returns the generated text and the token count.
    @discardableResult
    func generate(prompt: String,
                  sampling: JXSampling? = nil,
                  onToken: ((String) -> Void)? = nil) async throws -> (text: String, tokens: Int32) {
        guard isAvailable, let _generate else {
            throw EngineError.unavailable(unavailableReason ?? "not bound")
        }
        guard let model else { throw EngineError.noModel }

        let s = sampling ?? JXSampling()

        // The callback must capture nothing — a @convention(c) function
        // pointer cannot be formed from a capturing closure — so the sink
        // carries both the accumulator and the Swift callback, and is reached
        // through the `user` pointer.
        let sink = JXTokenSink(onToken)
        let callback: JXTokenCallback = { piece, user in
            guard let piece, let user else { return }
            let sink = Unmanaged<JXTokenSink>.fromOpaque(user).takeUnretainedValue()
            let chunk = String(cString: piece)
            sink.text += chunk
            if let cb = sink.onToken {
                DispatchQueue.main.async { cb(chunk) }
            }
        }
        let user = Unmanaged.passUnretained(sink).toOpaque()

        // Heap slot rather than a captured `var`: an escaping closure may not
        // legally mutate a captured local, and llama.cpp writes this directly.
        let outTokens = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
        outTokens.initialize(to: 0)
        defer { outTokens.deallocate() }

        let rc: Int32 = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int32, Error>) in
            queue.async {
                let code = prompt.withCString { cstr in
                    _generate(model, cstr,
                              s.temperature, s.topP, s.topK, s.repeatPenalty,
                              s.maxTokens, s.seed,
                              callback, user, outTokens)
                }
                cont.resume(returning: code)
            }
        }

        if rc < 0 {
            throw EngineError.generationFailed(lastError() ?? "rc=\(rc)")
        }
        return (sink.text, outTokens.pointee)
    }
}
