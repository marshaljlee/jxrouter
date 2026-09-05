import Foundation
import Observation
import Dispatch

/// Posted when the app re-imports API keys from the user's shell config files
/// (e.g. ~/.zshrc) while it is already running. `userInfo["imported"]` carries
/// the Keychain keys that were newly imported (e.g. "NVIDIA_NIM_API_KEY").
extension Notification.Name {
    static let jxproxyShellKeysImported = Notification.Name("JXProxyShellKeysImported")
    static let jxproxyFlushSettingsSave = Notification.Name("JXProxyFlushSettingsSave")
}

/// Per-provider reasoning pass-through policy.
///
/// - `.auto` (default): reasoning is requested/surfaced only for providers and
///   models that are reasoning-capable (`MessageTranslator.isReasoningCapable`).
/// - `.on`: always pass reasoning through (thinking blocks preserved).
/// - `.off`: never request or surface reasoning.
///
/// The global `ConfigManager.enableThinking` toggle acts as a master switch on
/// top of this per-provider policy.
enum ReasoningPolicy: String, CaseIterable {
    case auto = "auto"
    case on = "on"
    case off = "off"

    var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .on: return "On"
        case .off: return "Off"
        }
    }
}

/// A user-defined OpenAI-compatible provider (name + endpoint + key). The API
/// key is stored separately in the Keychain (account = customProviderKey(id));
/// the name and base URL live in a JSON list in UserDefaults.
struct CustomProviderDef: Identifiable, Codable, Equatable, Hashable {
    var id: String
    var name: String
    var baseUrl: String

    init(id: String, name: String, baseUrl: String) {
        self.id = id
        self.name = name
        self.baseUrl = baseUrl
    }
}

/// Shared configuration manager for JXProxy.
///
/// - **Secrets** (API keys, auth tokens) are stored in the macOS Keychain.
/// - **Non-secret settings** (ports, model prefs, provider config) are stored in UserDefaults.
/// - On first launch, migrates from legacy `~/.jxproxy/config.env`.
@Observable
final class ConfigManager: @unchecked Sendable {
    static let shared = ConfigManager()
    /// If true, shell config imports are skipped (used to keep unit tests hermetic).
    static var skipShellImport = false

    // MARK: - UserDefaults Keys
    private enum UDKey {
        static let port = "proxyPort"
        static let provider = "activeProvider"
        static let model = "activeModel"
        static let modelOpus = "modelOpus"
        static let modelSonnet = "modelSonnet"
        static let modelHaiku = "modelHaiku"
        static let enableThinking = "enableThinking"
        static let reasoningPolicyJSON = "reasoningPolicyJSON"
        static let fallbackProviders = "fallbackProviders"
        static let tierProvidersJSON = "tierProvidersJSON"
        static let openaiBaseUrl = "openaiBaseUrl"
        static let localLlmBaseUrl = "localLlmBaseUrl"
        static let localLlmModel = "localLlmModel"
        static let ggufModelPath = "ggufModelPath"
        static let ggufModelAlias = "ggufModelAlias"
        static let ggufGpuLayers = "ggufGpuLayers"
        static let ggufContextSize = "ggufContextSize"
        static let ggufPort = "ggufPort"
        static let ggufMmprojPath = "ggufMmprojPath"
        static let authToken = "authToken"
        static let authTokenResetDone = "authTokenResetDone"
        static let appRoutesJSON = "appRoutesJSON"
        static let hasMigrated = "hasMigratedFromConfigEnv"
        static let enabledProviders = "enabledProviders"
        static let visibleModels = "visibleModels"
        static let providerBackendUrls = "providerBackendUrls"
        static let customProviders = "customProvidersJSON"
        static let mitmHosts = "mitmHosts"
        static let botIntegrationEnabled = "botIntegrationEnabled"
        /// Whether intercepted OpenAI traffic (api.openai.com) is routed through
        /// the configured providers or passed through unmodified.
        static let routeOpenAI = "routeOpenAI"
    }

    // MARK: - Keychain Keys
    enum KeychainKey {
        static let openai = "OPENAI_API_KEY"
        static let openrouter = "OPENROUTER_API_KEY"
        static let opencode = "OPENCODE_API_KEY"
        static let anthropic = "ANTHROPIC_API_KEY"
        static let nvidia = "NVIDIA_NIM_API_KEY"
        static let deepseek = "DEEPSEEK_API_KEY"
        static let gemini = "GEMINI_API_KEY"
        static let mistral = "MISTRAL_API_KEY"
        static let codestral = "CODESTRAL_API_KEY"
        static let cohere = "COHERE_API_KEY"
        static let groq = "GROQ_API_KEY"
        static let fireworks = "FIREWORKS_API_KEY"
        static let sambanova = "SAMBANOVA_API_KEY"
        static let cerebras = "CEREBRAS_API_KEY"
        static let huggingface = "HUGGINGFACE_API_KEY"
        static let githubModels = "GITHUB_MODELS_TOKEN"
        static let wafer = "WAFER_API_KEY"
        static let kimi = "KIMI_API_KEY"
        static let kimiCode = "KIMI_CODE_API_KEY"
        static let minimax = "MINIMAX_API_KEY"
        static let xai = "XAI_API_KEY"
        static let cloudflareApiToken = "CLOUDFLARE_API_TOKEN"
        static let zai = "ZAI_API_KEY"
        static let ollamaCloud = "OLLAMA_API_KEY"
        static let aiGateway = "AI_GATEWAY_API_KEY"
        static let antigravity = "ANTIGRAVITY_API_KEY"
        static let custom = "CUSTOM_API_KEY"
        static let telegramBotToken = "TELEGRAM_BOT_TOKEN"
        static let authToken = "JXPROXY_AUTH_TOKEN"
    }

    /// UserDefaults key for storing API keys JSON dictionary.
    private static let udApiKeysKey = "apiKeysDict"

    private let defaults: UserDefaults

    // MARK: - Published Config

    /// Proxy listen port.
    var port: Int {
        get { defaults.integer(forKey: UDKey.port).nonzero ?? 5255 }
        set { defaults.set(newValue, forKey: UDKey.port); publish() }
    }

    /// Active provider identifier.
    var provider: String {
        get { defaults.string(forKey: UDKey.provider) ?? "opencode-zen" }
        set { defaults.set(newValue, forKey: UDKey.provider); publish() }
    }

    /// Default model name.
    var model: String {
        get { defaults.string(forKey: UDKey.model) ?? "" }
        set { defaults.set(newValue, forKey: UDKey.model); publish() }
    }

    /// Model override for opus-tier.
    var modelOpus: String {
        get { defaults.string(forKey: UDKey.modelOpus) ?? "" }
        set { defaults.set(newValue, forKey: UDKey.modelOpus); publish() }
    }

    /// Model override for sonnet-tier.
    var modelSonnet: String {
        get { defaults.string(forKey: UDKey.modelSonnet) ?? "" }
        set { defaults.set(newValue, forKey: UDKey.modelSonnet); publish() }
    }

    /// Model override for haiku-tier.
    var modelHaiku: String {
        get { defaults.string(forKey: UDKey.modelHaiku) ?? "" }
        set { defaults.set(newValue, forKey: UDKey.modelHaiku); publish() }
    }

    /// Master switch for pass-through reasoning content. When on, upstream
    /// `reasoning_content` (DeepSeek, OpenCode, etc.) is translated into Anthropic
    /// `thinking` blocks so thinking tokens are preserved; when off, reasoning is
    /// never requested or surfaced (except as a last resort in non-streaming
    /// responses whose content would otherwise be empty). Reasoning is also
    /// skipped for tool-calling turns — reasoning + function calling is
    /// unsupported by many upstream providers (e.g. DeepSeek-R1).
    /// The per-provider `ReasoningPolicy` (default `.auto`) refines this switch.
    var enableThinking: Bool {
        get { defaults.object(forKey: UDKey.enableThinking) as? Bool ?? true }
        set { defaults.set(newValue, forKey: UDKey.enableThinking); publish() }
    }

    // MARK: - Per-Provider Reasoning Policy

    /// JSON dict of per-provider reasoning policies (provider id → auto/on/off).
    private var reasoningPolicyJSON: String {
        get { defaults.string(forKey: UDKey.reasoningPolicyJSON) ?? "{}" }
        set { defaults.set(newValue, forKey: UDKey.reasoningPolicyJSON) }
    }

    /// Stored per-provider reasoning policies. Absent providers default to `.auto`.
    var reasoningPolicies: [String: ReasoningPolicy] {
        get {
            guard let data = reasoningPolicyJSON.data(using: .utf8),
                  let raw = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return [:] }
            var result: [String: ReasoningPolicy] = [:]
            for (providerId, value) in raw {
                if let policy = ReasoningPolicy(rawValue: value) { result[providerId] = policy }
            }
            return result
        }
        set {
            var raw: [String: String] = [:]
            for (providerId, policy) in newValue { raw[providerId] = policy.rawValue }
            reasoningPolicyJSON = ((try? JSONSerialization.data(withJSONObject: raw)).flatMap { String(data: $0, encoding: .utf8) }) ?? "{}"
        }
    }

    /// Reasoning policy for a provider — defaults to `.auto` when unset.
    func reasoningPolicy(for providerId: String) -> ReasoningPolicy {
        reasoningPolicies[providerId] ?? .auto
    }

    /// Effective reasoning pass-through decision for a provider + resolved model.
    /// The global `enableThinking` toggle gates everything; otherwise the
    /// per-provider policy applies, with `.auto` deciding from provider/model
    /// capability.
    func reasoningEnabled(for providerId: String, model: String) -> Bool {
        guard enableThinking else { return false }
        switch reasoningPolicy(for: providerId) {
        case .on: return true
        case .off: return false
        case .auto: return MessageTranslator.isReasoningCapable(providerId: providerId, model: model)
        }
    }

    /// Comma-separated fallback provider names.
    var fallbackProviders: String {
        get {
            let raw = defaults.string(forKey: UDKey.fallbackProviders) ?? ""
            // Validate: strip any ids that don't match a real provider, so
            // stale entries like "nvidia" (should be "nvidia-nim") or "local"
            // (never a real id) are silently cleaned up.
            let valid = raw.components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && ProviderPreset.preset(for: $0) != nil }
            return valid.joined(separator: ",")
        }
        set { defaults.set(newValue, forKey: UDKey.fallbackProviders); publish() }
    }

    /// Per-tier provider selections (tier key → provider id) used by the four
    /// independent Provider+Model routing pairs (Default / Opus / Sonnet / Haiku).
    /// Absent tiers fall back to the primary provider at routing time.
    var tierProvidersJSON: String {
        get { defaults.string(forKey: UDKey.tierProvidersJSON) ?? "{}" }
        set { defaults.set(newValue, forKey: UDKey.tierProvidersJSON) }
    }

    /// Per-tier provider ids, or nil for a tier that uses the primary provider.
    func tierProvider(for tier: String) -> String? {
        guard let data = tierProvidersJSON.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return nil }
        let pid = dict[tier]
        // Legacy alias — llama.cpp was replaced by the Llama desktop app. The
        // primary provider is migrated on init; remap here too so per-tier
        // overrides saved before the rename (e.g. "llamacpp" pinned to Haiku)
        // resolve to the live provider instead of an unknown id.
        if pid == "llamacpp" { return "llamaapp" }
        return pid
    }

    /// Store a per-tier provider id (or remove it when empty).
    func setTierProvider(_ tier: String, _ providerId: String) {
        var dict: [String: String] = [:]
        if let data = tierProvidersJSON.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            dict = parsed
        }
        if providerId.isEmpty {
            dict.removeValue(forKey: tier)
        } else {
            dict[tier] = providerId
        }
        tierProvidersJSON = ((try? JSONSerialization.data(withJSONObject: dict))
            .flatMap { String(data: $0, encoding: .utf8) }) ?? "{}"
    }

    /// Base URL for OpenAI-compatible providers.
    var openaiBaseUrl: String {
        get { defaults.string(forKey: UDKey.openaiBaseUrl) ?? "https://api.openai.com/v1" }
        set { defaults.set(newValue, forKey: UDKey.openaiBaseUrl); publish() }
    }

    /// Base URL for local LLM (Llama.app, LM Studio, Ollama, etc.).
    var localLlmBaseUrl: String {
        get {
            let saved = defaults.string(forKey: UDKey.localLlmBaseUrl) ?? ""
            if !saved.isEmpty && saved != "http://127.0.0.1:11434/v1" {
                return saved
            }
            let livePort = LocalServerDiscovery.liveLlamaPort()
            return "http://127.0.0.1:\(livePort)/v1"
        }
        set { defaults.set(newValue, forKey: UDKey.localLlmBaseUrl); publish() }
    }

    /// Model name for local LLM.
    var localLlmModel: String {
        get {
            let saved = defaults.string(forKey: UDKey.localLlmModel) ?? ""
            if !saved.isEmpty && saved != "ollama/qwen3:latest" {
                return saved
            }
            let active = defaults.string(forKey: UDKey.model) ?? ""
            if !active.isEmpty && (active.hasPrefix("local/") || active.hasPrefix("llamaapp/")) {
                return active
            }
            return "local/ornith:Q8_0"
        }
        set { defaults.set(newValue, forKey: UDKey.localLlmModel); publish() }
    }

    // MARK: - GGUF (Direct llama-server hosting)

    /// Path to the selected GGUF model file.
    var ggufModelPath: String {
        get { defaults.string(forKey: UDKey.ggufModelPath) ?? "" }
        set { defaults.set(newValue, forKey: UDKey.ggufModelPath); publish() }
    }

    /// Model alias served by llama-server (what the OpenAI /v1/models reports).
    var ggufModelAlias: String {
        get { defaults.string(forKey: UDKey.ggufModelAlias) ?? "local-model" }
        set { defaults.set(newValue, forKey: UDKey.ggufModelAlias); publish() }
    }

    /// GPU layers to offload (-1 = all, 0 = CPU only, N = N layers).
    var ggufGpuLayers: Int {
        get { defaults.object(forKey: UDKey.ggufGpuLayers) as? Int ?? 0 }
        set { defaults.set(newValue, forKey: UDKey.ggufGpuLayers); publish() }
    }

    /// Context size override (0 = use the model's native context).
    var ggufContextSize: Int {
        get { defaults.object(forKey: UDKey.ggufContextSize) as? Int ?? 0 }
        set { defaults.set(newValue, forKey: UDKey.ggufContextSize); publish() }
    }

    /// Port the GGUF llama-server listens on.
    var ggufPort: Int {
        get { defaults.object(forKey: UDKey.ggufPort) as? Int ?? 8081 }
        set { defaults.set(newValue, forKey: UDKey.ggufPort); publish() }
    }

    /// Path to the multimodal projector (mmproj) GGUF file for vision models.
    var ggufMmprojPath: String {
        get { defaults.string(forKey: UDKey.ggufMmprojPath) ?? "" }
        set { defaults.set(newValue, forKey: UDKey.ggufMmprojPath); publish() }
    }

    /// Auth token for proxy authentication. Defaults to the documented token
    /// "jxproxy" (README, install.sh); a custom token can be set in Settings
    /// and is honored by the proxy and the regenerated launcher scripts.
    var authToken: String {
        get { defaults.string(forKey: UDKey.authToken) ?? "jxproxy" }
        set { defaults.set(newValue, forKey: UDKey.authToken); publish() }
    }

    /// Whether the remote web-control server (mobile web-wrapper apps) is
    /// enabled. Off by default — the listener binds all interfaces, so it is
    /// only exposed when the user explicitly turns it on.
    var webControlEnabled: Bool {
        get { defaults.object(forKey: "webControlEnabled") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "webControlEnabled"); publish() }
    }

    /// Port for the remote web-control server. Defaults to 5355 (the proxy's
    /// own port is 5255). LAN clients reach it at http://<mac-ip>:<port>.
    var webControlPort: Int {
        get { defaults.integer(forKey: "webControlPort").nonzero ?? 5355 }
        set { defaults.set(newValue, forKey: "webControlPort"); publish() }
    }

    /// JSON-encoded app routing rules.
    var appRoutesJSON: String {
        get { defaults.string(forKey: UDKey.appRoutesJSON) ?? "" }
        set { defaults.set(newValue, forKey: UDKey.appRoutesJSON); publish() }
    }

    /// Comma-separated enabled provider IDs.
    var enabledProviders: String {
        get { defaults.string(forKey: UDKey.enabledProviders) ?? "" }
        set { defaults.set(newValue, forKey: UDKey.enabledProviders) }
    }

    /// Semicolon-separated visible models mapping (provider=models).
    var visibleModelsRaw: String {
        get { defaults.string(forKey: UDKey.visibleModels) ?? "" }
        set { defaults.set(newValue, forKey: UDKey.visibleModels) }
    }

    /// Provider backend URLs as JSON dict.
    var providerBackendUrlsJSON: String {
        get { defaults.string(forKey: UDKey.providerBackendUrls) ?? "{}" }
        set { defaults.set(newValue, forKey: UDKey.providerBackendUrls) }
    }

    /// Comma-separated hostnames whose HTTPS traffic should be MITM-intercepted.
    /// Anthropic + OpenAI by default so the system-wide proxy routes both
    /// providers' connections through JXProxy; the classifier covers many more
    /// AI hosts regardless.
    var mitmHosts: Set<String> {
        get {
            let raw = defaults.string(forKey: UDKey.mitmHosts) ?? "api.anthropic.com,api.openai.com"
            return Set(raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        }
        set {
            defaults.set(newValue.joined(separator: ","), forKey: UDKey.mitmHosts)
        }
    }

    /// Whether Bot Integration is enabled.
    var botIntegrationEnabled: Bool {
        get { defaults.object(forKey: UDKey.botIntegrationEnabled) as? Bool ?? false }
        set { defaults.set(newValue, forKey: UDKey.botIntegrationEnabled); publish() }
    }

    /// Whether OpenAI connections (api.openai.com) are routed through the
    /// configured providers. Independent of Anthropic routing: when off, OpenAI
    /// traffic passes through unmodified (raw passthrough), so Codex/OpenAI
    /// SDK clients keep talking to the real OpenAI API while Claude still
    /// routes through the proxy. On by default to preserve existing behavior.
    var routeOpenAI: Bool {
        get { defaults.object(forKey: UDKey.routeOpenAI) as? Bool ?? true }
        set { defaults.set(newValue, forKey: UDKey.routeOpenAI); publish() }
    }

    // MARK: - API Key Import from Shell Configs

    /// Known shell-variable names mapped to their Keychain keys. GUI apps
    /// launched from the menu bar / Finder do NOT inherit the shell
    /// environment, so keys a user exports in ~/.zshrc were previously
    /// invisible to the app. This map lets those exports be picked up.
    private static let shellEnvKeyMap: [String: String] = [
        "ANTHROPIC_API_KEY": KeychainKey.anthropic,
        "OPENAI_API_KEY": KeychainKey.openai,
        "OPENROUTER_API_KEY": KeychainKey.openrouter,
        "OPENCODE_API_KEY": KeychainKey.opencode,
        "NVIDIA_NIM_API_KEY": KeychainKey.nvidia,
        // NVIDIA's other canonical variable name — many users export this one.
        "NVIDIA_API_KEY": KeychainKey.nvidia,
        "DEEPSEEK_API_KEY": KeychainKey.deepseek,
        "GEMINI_API_KEY": KeychainKey.gemini,
        "MISTRAL_API_KEY": KeychainKey.mistral,
        "CODESTRAL_API_KEY": KeychainKey.codestral,
        "COHERE_API_KEY": KeychainKey.cohere,
        "GROQ_API_KEY": KeychainKey.groq,
        "FIREWORKS_API_KEY": KeychainKey.fireworks,
        "SAMBANOVA_API_KEY": KeychainKey.sambanova,
        "CEREBRAS_API_KEY": KeychainKey.cerebras,
        "HUGGINGFACE_API_KEY": KeychainKey.huggingface,
        // HF_TOKEN is HuggingFace's canonical variable name.
        "HF_TOKEN": KeychainKey.huggingface,
        "XAI_API_KEY": KeychainKey.xai,
        "GITHUB_MODELS_TOKEN": KeychainKey.githubModels,
        "WAFER_API_KEY": KeychainKey.wafer,
        "KIMI_API_KEY": KeychainKey.kimi,
        "KIMI_CODE_API_KEY": KeychainKey.kimiCode,
        "MINIMAX_API_KEY": KeychainKey.minimax,
        "CLOUDFLARE_API_TOKEN": KeychainKey.cloudflareApiToken,
        "ZAI_API_KEY": KeychainKey.zai,
        "OLLAMA_API_KEY": KeychainKey.ollamaCloud,
        "AI_GATEWAY_API_KEY": KeychainKey.aiGateway,
        "ANTIGRAVITY_API_KEY": KeychainKey.antigravity,
    ]

    /// Shell config files scanned for `export KEY=…` lines, in order. Internal
    /// (not private) so tests can point the importer at temp files instead of
    /// the developer's real configs.
    private(set) var shellConfigPaths: [String] = [
        "~/.zshrc",
        "~/.zshenv",
        "~/.zprofile",
        "~/.bash_profile",
        "~/.bashrc",
        "~/.profile",
        // Legacy config file from the old app version (usually already
        // consumed by migrateFromConfigEnv — belt and suspenders).
        "~/.jxproxy/config.env",
    ]

    /// Import API keys from the user's shell configs into the Keychain.
    ///
    /// Why this exists: a menu-bar app like JXProxy is never launched from a
    /// shell, so `export ANTHROPIC_API_KEY=…` in ~/.zshrc never reaches the
    /// process environment — the keys were simply invisible to the app.
    /// This parses the config files directly (and merges the process
    /// environment for the case where the app WAS launched from a terminal).
    ///
    /// Rules (kept deliberately conservative):
    ///   • Only EMPTY Keychain slots are filled — existing keys are never
    ///     overwritten, so a key pasted in Settings always wins.
    ///   • Values containing unexpanded shell substitutions (`$…`, `` `… ``)
    ///     are skipped — importing a literal `$JXPROXY_AUTH_TOKEN` would store
    ///     garbage.
    ///   • Idempotent and cheap — safe to run on every launch, on Settings
    ///     open, on a ~/.zshrc file change, and on demand from a button.
    ///
    /// - Returns: the Keychain keys (e.g. "NVIDIA_NIM_API_KEY") that were
    ///   newly imported this call, so callers can surface "Imported …"
    ///   feedback. Empty when everything was already saved.
    @discardableResult
    func importKeysFromShellConfigs(paths: [String]? = nil) -> [String] {
        // If the Keychain is in its retry cooldown (a recent read timed out —
        // keychain locked at login, securityd stalled), probing every known
        // account would block up to 3 seconds each for nothing, and writes
        // would pile up prompts. Skip the pass; the recovery loop re-runs it
        // once the Keychain responds again.
        guard !KeychainManager.isUnavailable else { return [] }

        let files = paths ?? shellConfigPaths

        // If we are in hermetic test mode, filter out any default system files
        // and do NOT read from the host process environment.
        let filesToProcess: [String]
        if Self.skipShellImport {
            filesToProcess = files.filter { file in
                !file.hasPrefix("~/") && !file.contains("/Users/")
            }
            if filesToProcess.isEmpty {
                return []
            }
        } else {
            filesToProcess = files
        }

        var env: [String: String] = [:]
        // GUI apps launched from Finder never inherit the shell environment,
        // but when the app IS launched from a terminal the exported vars are
        // already there — merge them first so explicit shell-file exports
        // still win (last occurrence wins below).
        // Skip reading from the host process environment during hermetic tests.
        if !Self.skipShellImport {
            for (varName, _) in Self.shellEnvKeyMap {
                if let value = ProcessInfo.processInfo.environment[varName], !value.isEmpty {
                    env[varName] = value
                }
            }
        }
        for file in filesToProcess {
            let expanded = NSString(string: file).expandingTildeInPath
            guard let content = try? String(contentsOfFile: expanded, encoding: .utf8) else { continue }
            mergeShellEnv(&env, content)
        }

        var imported: [String] = []
        for (varName, chainKey) in Self.shellEnvKeyMap {
            guard let value = env[varName], !value.isEmpty,
                  getApiKey(chainKey: chainKey).isEmpty else { continue }
            setApiKey(chainKey: chainKey, value: value)
            imported.append(chainKey)
            print("[ConfigManager] Imported \(varName) from shell configs into the Keychain")
        }
        if !imported.isEmpty {
            print("[ConfigManager] Imported \(imported.count) API key(s) from shell configs")
        }
        return imported
    }

    /// Parse `KEY=value` and `export KEY="value"` lines into a dict (last
    /// occurrence wins). Handles single/double quotes and inline `#` comments
    /// (`export NVIDIA_NIM_API_KEY="nvapi-…" # my key`), and skips comments
    /// plus values containing unexpanded shell substitution (`$` or backticks).
    /// Internal (not private) so unit tests can exercise the parser directly.
    func mergeShellEnv(_ env: inout [String: String], _ content: String) {
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            var body = trimmed
            if body.hasPrefix("export ") { body = String(body.dropFirst(7)) }
            let parts = body.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let name = String(parts[0]).trimmingCharacters(in: .whitespaces)
            guard let value = Self.parseShellValue(String(parts[1])) else { continue }
            env[name] = value
        }
    }

    /// Extract the literal value from a `KEY=…` right-hand side. Strips a
    /// single pair of surrounding quotes and anything after the closing quote
    /// (a trailing `# comment` is common), or cuts an unquoted comment that
    /// starts after whitespace. Returns nil for unterminated quotes and for
    /// values containing unexpanded shell substitution (`$` or backticks).
    private static func parseShellValue(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespaces)
        if let first = value.first, first == "\"" || first == "'" {
            let rest = value.dropFirst()
            guard let close = rest.firstIndex(of: first) else { return nil }
            value = String(rest[..<close])
        } else if let hash = value.range(of: " #")?.lowerBound {
            // Unquoted values: a `#` after whitespace starts a comment.
            value = String(value[..<hash]).trimmingCharacters(in: .whitespaces)
        }
        // Never import unexpanded shell substitutions as a key.
        if value.contains("$") || value.contains("`") { return nil }
        guard !value.isEmpty else { return nil }
        return value
    }

    // MARK: - API Key Storage (UserDefaults)

    /// True when the Keychain answered the reads performed during this
    /// process's startup. When false, every key field loaded into the UI is an
    /// empty placeholder (reads timed out, e.g. a Keychain permission prompt
    /// pending), so an empty-value save is NOT evidence the user cleared the
    /// key — deleting would wipe the real stored secret.
    private var keychainReadHealthyAtStartup = false

    /// Store an API key securely in the Keychain.
    ///
    /// On Keychain failure the error is surfaced and the prior value is kept —
    /// secrets are never written to UserDefaults (ticket 0001).
    ///
    /// An empty value clears the stored key — but only when the Keychain was
    /// readable at startup. Otherwise the empty value is untrustworthy (the
    /// UI never saw the real key) and the existing secret is kept, so a
    /// transient startup read failure can never auto-wipe provider keys.
    func setApiKey(chainKey: String, value: String) {
        guard !value.isEmpty else {
            guard keychainReadHealthyAtStartup else {
                print("[ConfigManager] Refusing to clear \(chainKey) — Keychain was unreadable at startup; keeping the stored key to avoid data loss.")
                return
            }
            try? KeychainManager.delete(key: chainKey)
            return
        }
        do {
            try KeychainManager.store(key: chainKey, value: value)
        } catch {
            print("[ConfigManager] Failed to store key \(chainKey) in Keychain: \(error). Key was not saved.")
        }
    }

    /// Retrieve an API key securely from the Keychain.
    func getApiKey(chainKey: String) -> String {
        guard let keychainValue = KeychainManager.retrieve(key: chainKey), !keychainValue.isEmpty else {
            return ""
        }
        return keychainValue
    }

    /// Keychain account for a custom provider's API key.
    static func customProviderKey(_ id: String) -> String {
        "CUSTOM_PROVIDER_KEY_\(id)"
    }

    /// Convert a provider name into a URL-friendly slug.
    static func slugify(_ name: String) -> String {
        let lowered = name.lowercased()
        let allowed = lowered.filter { $0.isLetter || $0.isNumber || $0 == " " }
        let slug = allowed.split(separator: " ").joined(separator: "-")
        return slug.isEmpty ? "custom-provider" : slug
    }

    /// The id of the key-requiring built-in provider that a custom provider at
    /// `baseUrl` inherits its key from — the first endpoint match whose key is
    /// actually available — or nil. Surfaced in Settings so the user can see
    /// which verified key their custom provider is using.
    func inheritedKeySource(for customUrl: String) -> String? {
        let normalized = normalizedEndpoint(customUrl)
        guard !normalized.isEmpty else { return nil }
        // Only real built-ins inherit — the legacy "custom" preset is skipped
        // so a custom provider can never match against itself (no recursion).
        for preset in ProviderPreset.all where preset.requiresKey && preset.id != "custom" {
            if normalizedEndpoint(baseUrl(for: preset.id)) == normalized,
               !apiKey(for: preset.id).isEmpty {
                return preset.id
            }
        }
        return nil
    }

    /// API key of the key-requiring built-in provider whose endpoint exactly
    /// matches the given base URL, or "" when there is no match. Normalization
    /// compares host + path with the scheme and a trailing "/v1" stripped, so
    /// a custom provider at the built-in's URL inherits its verified key.
    private func keyForMatchingBuiltIn(_ customBaseUrl: String) -> String {
        guard let source = inheritedKeySource(for: customBaseUrl) else { return "" }
        return apiKey(for: source)
    }

    /// Lowercased host + path with scheme and trailing "/v1" (and slashes)
    /// removed, so "https://integrate.api.nvidia.com/v1" and
    /// "https://integrate.api.nvidia.com" compare equal.
    private func normalizedEndpoint(_ url: String) -> String {
        var s = url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.hasPrefix("https://") { s.removeFirst("https://".count) }
        else if s.hasPrefix("http://") { s.removeFirst("http://".count) }
        while s.hasSuffix("/") { s.removeLast() }
        if s.hasSuffix("/v1") { s = String(s.dropLast(3)) }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// Get the resolved API key for a given provider identifier.
    ///
    /// When the Keychain has no key for the provider, lazily re-scans the
    /// user's shell configs (debounced) before giving up — a menu-bar app can
    /// run for days, so a key the user just added to ~/.zshrc is picked up on
    /// the very next request without a relaunch. Import only fills empty
    /// Keychain slots, so this never overrides a key saved in Settings.
    func apiKey(for providerId: String) -> String {
        let key = resolvedApiKey(for: providerId)
        if key.isEmpty {
            shellFallbackImportIfNeeded()
            return resolvedApiKey(for: providerId)
        }
        return key
    }

    /// Last time the lazy shell fallback re-scanned the configs (debounce so
    /// a persistently-missing key doesn't re-parse the files on every request).
    private var lastShellFallbackImport = Date.distantPast

    /// Debounced re-scan of the shell configs, triggered only when a provider
    /// key resolves empty. Benign under races (worst case: one extra import).
    private func shellFallbackImportIfNeeded() {
        guard Date().timeIntervalSince(lastShellFallbackImport) > 3 else { return }
        lastShellFallbackImport = Date()
        importKeysFromShellConfigs()
    }

    /// The pure Keychain resolution for a provider (no shell fallback), kept
    /// separate so `apiKey(for:)` can lazily retry the shell import once.
    private func resolvedApiKey(for providerId: String) -> String {
        // Named custom providers first — each has its own Keychain account.
        // Fall through to the legacy "custom" account if the per-provider
        // account is empty (pre-migration setups stored the key there).
        if let def = customProviders.first(where: { $0.id == providerId }) {
            let key = getApiKey(chainKey: Self.customProviderKey(def.id))
            if !key.isEmpty { return key }
            let nameSlug = "custom-" + Self.slugify(def.name)
            if nameSlug != def.id {
                let aliasKey = getApiKey(chainKey: Self.customProviderKey(nameSlug))
                if !aliasKey.isEmpty { return aliasKey }
            }
            if def.id == "custom" {
                let legacy = getApiKey(chainKey: KeychainKey.custom)
                if !legacy.isEmpty { return legacy }
            }
            // A custom provider pointing at the SAME endpoint as a built-in
            // provider (e.g. a duplicate "Nvidia" entry at the NVIDIA NIM URL)
            // reuses that provider's key. Without this, a user who verified a
            // key on the built-in provider still gets "No API key entered" in
            // Test All Models — and 401s at runtime — for their custom twin.
            // Only an exact endpoint match inherits, so unrelated custom
            // gateways never pick up another provider's key.
            return keyForMatchingBuiltIn(def.baseUrl)
        }
        switch providerId {
        case "direct": return getApiKey(chainKey: KeychainKey.anthropic)
        case "openrouter": return getApiKey(chainKey: KeychainKey.openrouter)
        case "opencode-zen", "opencode-go": return getApiKey(chainKey: KeychainKey.opencode)
        case "openai": return getApiKey(chainKey: KeychainKey.openai)
        case "nvidia-nim": return getApiKey(chainKey: KeychainKey.nvidia)
        case "deepseek": return getApiKey(chainKey: KeychainKey.deepseek)
        case "gemini": return getApiKey(chainKey: KeychainKey.gemini)
        case "mistral": return getApiKey(chainKey: KeychainKey.mistral)
        case "codestral": return getApiKey(chainKey: KeychainKey.codestral)
        case "cohere": return getApiKey(chainKey: KeychainKey.cohere)
        case "groq": return getApiKey(chainKey: KeychainKey.groq)
        case "fireworks": return getApiKey(chainKey: KeychainKey.fireworks)
        case "sambanova": return getApiKey(chainKey: KeychainKey.sambanova)
        case "cerebras": return getApiKey(chainKey: KeychainKey.cerebras)
        case "huggingface": return getApiKey(chainKey: KeychainKey.huggingface)
        case "github-models": return getApiKey(chainKey: KeychainKey.githubModels)
        case "wafer": return getApiKey(chainKey: KeychainKey.wafer)
        case "kimi": return getApiKey(chainKey: KeychainKey.kimi)
        case "kimi-code": return getApiKey(chainKey: KeychainKey.kimiCode)
        case "minimax": return getApiKey(chainKey: KeychainKey.minimax)
        case "xai": return getApiKey(chainKey: KeychainKey.xai)
        case "cloudflare": return getApiKey(chainKey: KeychainKey.cloudflareApiToken)
        case "zai": return getApiKey(chainKey: KeychainKey.zai)
        case "ollama-cloud": return getApiKey(chainKey: KeychainKey.ollamaCloud)
        case "ai-gateway": return getApiKey(chainKey: KeychainKey.aiGateway)
        case "custom": return getApiKey(chainKey: KeychainKey.custom)
        case "antigravity": return getApiKey(chainKey: KeychainKey.antigravity)
        case "local", "ollama", "lmstudio", "llamaapp", "jan", "unsloth", "gguf": return ""
        case "gemini-oauth": return getApiKey(chainKey: "GEMINI_OAUTH_ACCESS_TOKEN")
        default: return ""
        }
    }

    /// One-time hygiene sweep: any legacy plaintext keys previously stored in the
    /// "apiKeysDict" UserDefaults key are migrated into the Keychain, then the
    /// dict is removed so secrets never persist in UserDefaults (ticket 0001).
    private func migrateLegacyApiKeysDict() {
        let legacy = defaults.dictionary(forKey: Self.udApiKeysKey)
        guard let dict = legacy as? [String: String] else {
            if legacy != nil { defaults.removeObject(forKey: Self.udApiKeysKey) }
            return
        }
        for (chainKey, value) in dict where !value.isEmpty {
            do {
                try KeychainManager.store(key: chainKey, value: value)
            } catch {
                print("[ConfigManager] Failed to migrate legacy key \(chainKey) from UserDefaults to Keychain: \(error)")
            }
        }
        defaults.removeObject(forKey: Self.udApiKeysKey)
    }

    // MARK: - Migration Flag

    var hasMigrated: Bool {
        get { defaults.bool(forKey: UDKey.hasMigrated) }
        set { defaults.set(newValue, forKey: UDKey.hasMigrated) }
    }

    // MARK: - Provider Router

    var providerRouter: ProviderRouter?

    /// Real latency measured by ProviderRouter (ms). Set by ProviderRouter on each successful round-trip.
    var lastLatencyMs: Double = 0.0

    // MARK: - Publish Callback

    var onConfigChanged: (() -> Void)?

    private func publish() {
        onConfigChanged?()
    }

    // MARK: - Initialization & Migration

    /// Internal so the unit-test target can construct isolated instances
    /// against a scratch UserDefaults suite (never the real preferences). The
    /// app always uses `shared`, which keeps `.standard`.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        // Hygiene sweep: migrate any legacy plaintext apiKeysDict into Keychain (ticket 0001).
        migrateLegacyApiKeysDict()

        if !hasMigrated {
            migrateFromConfigEnv()
            hasMigrated = true
        }

        // Live detection: menu-bar apps stay running for days, so a key the
        // user just added to ~/.zshrc must be picked up without a relaunch.
        // Only the app singleton (real .standard defaults) watches the files;
        // unit-test instances use scratch suites and stay hermetic.
        if defaults === UserDefaults.standard {
            startShellConfigWatcher()
            // The shell-config import is NOT run synchronously here. At app
            // launch (login item, keychain still settling / permission prompt
            // pending) a synchronous import would hit the Keychain dozens of
            // times — reads that time out and latch, writes that block — which
            // is exactly the "keeps asking for keychain password / no API key
            // installed" regression. It now runs on a background queue with
            // cooldown-based retries and self-heals item ACLs first.
            scheduleStartupKeychainRecovery()
        }

        // Snapshot Keychain health from the startup reads above: if they timed
        // out (permission prompt pending, securityd stalled), every key field
        // loaded into the UI is an empty placeholder and empty-value saves
        // must not delete the real stored secrets.
        keychainReadHealthyAtStartup = !KeychainManager.isUnavailable
        if !keychainReadHealthyAtStartup {
            print("[ConfigManager] Keychain was unreadable at startup — empty key fields are placeholders; refusing to clear stored keys this session.")
        }

        // Auth policy is the documented "jxproxy" default. One-time sweep:
        // clear any token minted by the earlier random-token protocol (32 hex
        // chars, stored in Keychain + UserDefaults) so the change takes effect
        // even on installs that already generated a token. Deliberately
        // customized tokens are left alone. Runs after migration so a legacy
        // config.env token is cleared too when it matches the minted format.
        if !defaults.bool(forKey: UDKey.authTokenResetDone) {
            let stored = defaults.string(forKey: UDKey.authToken)
            if let stored, stored.count == 32,
               stored.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil {
                try? KeychainManager.delete(key: KeychainKey.authToken)
                defaults.removeObject(forKey: UDKey.authToken)
            }
            defaults.set(true, forKey: UDKey.authTokenResetDone)
        }

        // llama.cpp was replaced by the Llama desktop app — migrate the stored
        // provider id so old installs keep routing to the same local server.
        if provider == "llamacpp" {
            provider = "llamaapp"
        }
    }

    /// Keeps the app's shell-config import fresh while it runs.
    private var shellConfigWatcher: ShellConfigWatcher?

    /// Start watching the shell config files for edits. When one changes, the
    /// import re-runs (fills only empty Keychain slots) and a notification is
    /// posted so the Settings UI can surface newly detected keys live.
    private func startShellConfigWatcher() {
        let paths = shellConfigPaths.map { NSString(string: $0).expandingTildeInPath }
        let watcher = ShellConfigWatcher(paths: paths) { [weak self] in
            guard let self else { return }
            let imported = self.importKeysFromShellConfigs()
            guard !imported.isEmpty else { return }
            print("[ConfigManager] Re-imported shell-config keys while running: \(imported.joined(separator: ", "))")
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .jxproxyShellKeysImported,
                    object: self,
                    userInfo: ["imported": imported]
                )
            }
        }
        watcher.start()
        shellConfigWatcher = watcher
    }

    // MARK: - Startup Keychain Recovery

    /// Number of recovery passes performed this session (bounded so a repair
    /// that can't complete never turns into a background prompt loop).
    private var keychainRecoveryPasses = 0

    /// Schedule the first startup recovery pass shortly after launch. Runs off
    /// the main thread so startup never blocks on (or prompts from) the
    /// Keychain.
    private func scheduleStartupKeychainRecovery() {
        let queue = DispatchQueue(label: "com.jxproxy.keychain-recovery")
        queue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.performKeychainRecoveryPass()
        }
    }

    /// One recovery pass: self-heal the items' access control (so reads never
    /// prompt), re-import keys from the shell configs into empty slots, and
    /// refresh the startup-health snapshot.
    ///
    /// The ACL self-heal runs at most ONCE per launch. Retrying it on a timer
    /// re-presented the "JXRouter wants to make changes to your keychain"
    /// password dialog on every pass when the user declined — the recurring
    /// macOS password prompt. One prompt-free attempt either repairs the
    /// items (unlocked keychain + the app trusted) or silently defers to the
    /// next launch.
    ///
    /// While the Keychain stays unavailable (locked at login, securityd
    /// stalled) the pass re-schedules itself for the read side only, so the
    /// app never stays key-less for the whole session — these re-runs are
    /// prompt-free.
    private func performKeychainRecoveryPass() {
        keychainRecoveryPasses += 1

        if keychainRecoveryPasses == 1 {
            // First pass: one prompt-free ACL self-heal attempt. The Keychain
            // reads below are also prompt-free (kSecUseAuthenticationUIFail),
            // so this pass can never trigger a password dialog.
            let repairsDone = KeychainManager.repairAccessControlForAllKeys()
            if !repairsDone {
                print("[ConfigManager] ACL repair incomplete (silent) — items not trusted by this build stay unreadable until re-entered; not retrying this session.")
            }
        }

        let imported = importKeysFromShellConfigs()
        if !imported.isEmpty {
            print("[ConfigManager] Startup recovery imported \(imported.count) key(s) from shell configs")
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .jxproxyShellKeysImported,
                    object: self,
                    userInfo: ["imported": imported]
                )
            }
        }

        // Refresh the health snapshot so the empty-save guard reflects the
        // CURRENT state (a benign race on a Bool — worst case one extra
        // refused delete, which is the safe direction).
        keychainReadHealthyAtStartup = !KeychainManager.isUnavailable

        // Reschedule ONLY for a genuinely unresponsive Keychain (reads still
        // failing). Pending ACL repairs are NEVER retried in-session — a
        // declined prompt must not become a prompt loop.
        let keychainStillDown = KeychainManager.isUnavailable && keychainRecoveryPasses < 30
        if keychainStillDown {
            print("[ConfigManager] Keychain still unavailable after pass \(keychainRecoveryPasses) — rescheduling read retry in 60s")
            DispatchQueue.global().asyncAfter(deadline: .now() + 60) { [weak self] in
                self?.performKeychainRecoveryPass()
            }
        }
    }

    /// Migrate secrets and settings from legacy `~/.jxproxy/config.env`.
    private func migrateFromConfigEnv() {
        let configPath = "\(NSHomeDirectory())/.jxproxy/config.env"
        guard FileManager.default.fileExists(atPath: configPath),
              let content = try? String(contentsOfFile: configPath, encoding: .utf8) else {
            return
        }

        let env = parseEnv(content)

        // Migrate secrets to Keychain
        tryMigrateKey(env: env, key: "OPENAI_API_KEY", chainKey: KeychainKey.openai)
        tryMigrateKey(env: env, key: "OPENROUTER_API_KEY", chainKey: KeychainKey.openrouter)
        tryMigrateKey(env: env, key: "OPENCODE_API_KEY", chainKey: KeychainKey.opencode)
        tryMigrateKey(env: env, key: "ANTHROPIC_API_KEY", chainKey: KeychainKey.anthropic)
        tryMigrateKey(env: env, key: "NVIDIA_NIM_API_KEY", chainKey: KeychainKey.nvidia)
        tryMigrateKey(env: env, key: "DEEPSEEK_API_KEY", chainKey: KeychainKey.deepseek)
        tryMigrateKey(env: env, key: "GEMINI_API_KEY", chainKey: KeychainKey.gemini)
        tryMigrateKey(env: env, key: "MISTRAL_API_KEY", chainKey: KeychainKey.mistral)
        tryMigrateKey(env: env, key: "CODESTRAL_API_KEY", chainKey: KeychainKey.codestral)
        tryMigrateKey(env: env, key: "COHERE_API_KEY", chainKey: KeychainKey.cohere)
        tryMigrateKey(env: env, key: "GROQ_API_KEY", chainKey: KeychainKey.groq)
        tryMigrateKey(env: env, key: "FIREWORKS_API_KEY", chainKey: KeychainKey.fireworks)
        tryMigrateKey(env: env, key: "SAMBANOVA_API_KEY", chainKey: KeychainKey.sambanova)
        tryMigrateKey(env: env, key: "CEREBRAS_API_KEY", chainKey: KeychainKey.cerebras)
        tryMigrateKey(env: env, key: "HUGGINGFACE_API_KEY", chainKey: KeychainKey.huggingface)
        tryMigrateKey(env: env, key: "GITHUB_MODELS_TOKEN", chainKey: KeychainKey.githubModels)
        tryMigrateKey(env: env, key: "WAFER_API_KEY", chainKey: KeychainKey.wafer)
        tryMigrateKey(env: env, key: "KIMI_API_KEY", chainKey: KeychainKey.kimi)
        tryMigrateKey(env: env, key: "KIMI_CODE_API_KEY", chainKey: KeychainKey.kimiCode)
        tryMigrateKey(env: env, key: "MINIMAX_API_KEY", chainKey: KeychainKey.minimax)
        tryMigrateKey(env: env, key: "XAI_API_KEY", chainKey: KeychainKey.xai)
        tryMigrateKey(env: env, key: "CLOUDFLARE_API_TOKEN", chainKey: KeychainKey.cloudflareApiToken)
        tryMigrateKey(env: env, key: "ZAI_API_KEY", chainKey: KeychainKey.zai)
        tryMigrateKey(env: env, key: "OLLAMA_API_KEY", chainKey: KeychainKey.ollamaCloud)
        tryMigrateKey(env: env, key: "AI_GATEWAY_API_KEY", chainKey: KeychainKey.aiGateway)

        // Migrate non-secret settings — only set if currently at defaults
        migrateValue(env: env, key: "JXPROXY_PORT", to: \.port, transform: { Int($0) ?? 5255 })
        migrateValue(env: env, key: "JXPROXY_PROVIDER", to: \.provider)
        migrateValue(env: env, key: "MODEL", to: \.model)
        migrateValue(env: env, key: "MODEL_OPUS", to: \.modelOpus)
        migrateValue(env: env, key: "MODEL_SONNET", to: \.modelSonnet)
        migrateValue(env: env, key: "MODEL_HAIKU", to: \.modelHaiku)
        migrateValue(env: env, key: "ENABLE_MODEL_THINKING", to: \.enableThinking, transform: { $0 != "false" })
        migrateValue(env: env, key: "FALLBACK_PROVIDERS", to: \.fallbackProviders)
        migrateValue(env: env, key: "OPENAI_BASE_URL", to: \.openaiBaseUrl)
        migrateValue(env: env, key: "LOCAL_LLM_BASE_URL", to: \.localLlmBaseUrl)
        migrateValue(env: env, key: "LOCAL_LLM_MODEL", to: \.localLlmModel)
        migrateValue(env: env, key: "JXPROXY_AUTH_TOKEN", to: \.authToken)
        migrateValue(env: env, key: "ENABLED_PROVIDERS", to: \.enabledProviders)
        migrateValue(env: env, key: "VISIBLE_MODELS", to: \.visibleModelsRaw)

        // Secrets have been migrated to the Keychain — remove the legacy
        // plaintext config.env (ticket 0018). Best-effort.
        do {
            try FileManager.default.removeItem(atPath: configPath)
            print("[ConfigManager] Removed legacy plaintext config.env at \(configPath) after successful migration.")
        } catch {
            print("[ConfigManager] Failed to remove legacy config.env at \(configPath): \(error)")
        }
    }

    private func parseEnv(_ content: String) -> [String: String] {
        var env: [String: String] = [:]
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let parts = trimmed.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                env[String(parts[0]).trimmingCharacters(in: .whitespaces)] =
                    String(parts[1]).trimmingCharacters(in: .whitespaces)
            }
        }
        return env
    }

    private func tryMigrateKey(env: [String: String], key: String, chainKey: String) {
        guard let value = env[key], !value.isEmpty,
              getApiKey(chainKey: chainKey).isEmpty else { return }
        setApiKey(chainKey: chainKey, value: value)
    }

    private func migrateValue<T>(env: [String: String], key: String, to kp: ReferenceWritableKeyPath<ConfigManager, T>) {
        guard let value = env[key] as? T else { return }
        self[keyPath: kp] = value
    }

    private func migrateValue<T>(env: [String: String], key: String, to kp: ReferenceWritableKeyPath<ConfigManager, T>, transform: (String) -> T) {
        guard let raw = env[key] else { return }
        self[keyPath: kp] = transform(raw)
    }

    // MARK: - Public API

    /// Get the resolved base URL for a given provider identifier.
    /// Checks providerBackendUrls first (user-configured override), then falls back
    /// to built-in defaults so every provider's URL is editable from the UI.
    func baseUrl(for providerId: String) -> String {
        // Named custom providers first — their endpoint is their own base URL.
        if let def = customProviders.first(where: { $0.id == providerId }), !def.baseUrl.isEmpty {
            return def.baseUrl
        }
        // User-configured override takes priority
        let overrides = providerBackendUrls
        if let custom = overrides[providerId], !custom.isEmpty {
            return custom
        }
        
        switch providerId {
        case "direct": return "https://api.anthropic.com"
        case "openrouter": return "https://openrouter.ai/api/v1"
        case "opencode-zen": return "https://opencode.ai/zen/v1"
        case "opencode-go": return "https://oai.opencode.ai/v1"
        case "openai": return openaiBaseUrl
        case "nvidia-nim": return "https://integrate.api.nvidia.com/v1"
        case "deepseek": return "https://api.deepseek.com/v1"
        // The API-key "gemini" preset goes through the OpenAI-compatible
        // surface, which is where the router's chat/completions path points
        // and which accepts bearer API keys.
        case "gemini": return "https://generativelanguage.googleapis.com/v1beta/openai"
        case "mistral": return "https://api.mistral.ai/v1"
        case "codestral": return "https://codestral.mistral.ai/v1"
        case "cohere": return "https://api.cohere.ai/v1"
        case "groq": return "https://api.groq.com/openai/v1"
        case "fireworks": return "https://api.fireworks.ai/inference/v1"
        case "sambanova": return "https://api.sambanova.ai/v1"
        case "cerebras": return "https://api.cerebras.ai/v1"
        case "huggingface": return "https://router.huggingface.co/v1"
        case "github-models": return "https://models.inference.ai.azure.com/v1"
        case "wafer": return "https://api.wafer.ch/v1"
        case "kimi": return "https://api.moonshot.cn/v1"
        case "kimi-code": return "https://api.kimi-coding.com/v1"
        case "minimax": return "https://api.minimax.chat/v1"
        case "xai": return "https://api.x.ai/v1"
        case "cloudflare": return "https://api.cloudflare.com/client/v4/ai/run"
        case "zai": return "https://api.z.ai/v1"
        case "ollama-cloud": return "https://ollama.com/api/chat"
        case "ai-gateway": return "https://gateway.ai.vercel.ai/v1"
        case "local", "ollama": return localLlmBaseUrl
        case "lmstudio": return "http://127.0.0.1:1234/v1"
        // llama.app's server port is NOT stable (it rebinds after relaunches,
        // observed 8080 → 9931) — resolve the LIVE port from the running
        // process so every caller (validation, health checks, model fetches)
        // talks to the real endpoint instead of a stale 8080.
        case "llamaapp": return "http://127.0.0.1:\(LocalServerDiscovery.liveLlamaPort())/v1"
        // Legacy alias — old installs stored "llamacpp" as the provider id.
        case "llamacpp": return "http://127.0.0.1:\(LocalServerDiscovery.liveLlamaPort())/v1"
        case "jan": return "http://127.0.0.1:1337/v1"
        case "unsloth": return "http://127.0.0.1:8000/v1"
        // Direct GGUF hosting via llama-server (Homebrew llama.cpp).
        case "gguf": return "http://127.0.0.1:\(ggufPort)/v1"
        case "gemini-oauth": return "https://generativelanguage.googleapis.com/v1beta/openai"
        case "antigravity": return "https://api.antigravity.dev/v1"
        case "custom":
            // The custom provider's endpoint lives in providerBackendUrls;
            // fall back to a sensible OpenAI-compatible default.
            return providerBackendUrls["custom"] ?? "https://api.openai.com/v1"
        default: return ""
        }
    }

    /// User-customised backend URLs per provider (stored as JSON dict).
    /// Keyed by provider ID, value is the custom base URL.
    var providerBackendUrls: [String: String] {
        get {
            let raw = defaults.string(forKey: UDKey.providerBackendUrls) ?? "{}"
            guard let data = raw.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
                return [:]
            }
            return dict
        }
        set {
            if let data = try? JSONSerialization.data(withJSONObject: newValue),
               let json = String(data: data, encoding: .utf8) {
                defaults.set(json, forKey: UDKey.providerBackendUrls)
            }
        }
    }

    // MARK: - Custom Providers (named OpenAI-compatible endpoints)

    /// JSON-encoded list of user-defined custom providers.
    var customProvidersJSON: String {
        get { defaults.string(forKey: UDKey.customProviders) ?? "[]" }
        set { defaults.set(newValue, forKey: UDKey.customProviders) }
    }

    /// User-defined custom providers (name + endpoint; keys in Keychain).
    var customProviders: [CustomProviderDef] {
        get {
            guard let data = customProvidersJSON.data(using: .utf8),
                  let list = try? JSONDecoder().decode([CustomProviderDef].self, from: data) else {
                return []
            }
            return list
        }
        set {
            if let data = try? JSONEncoder().encode(newValue),
               let json = String(data: data, encoding: .utf8) {
                customProvidersJSON = json
            }
        }
    }

    /// Add or update a custom provider and persist its API key in the Keychain.
    func upsertCustomProvider(_ def: CustomProviderDef, apiKey: String) {
        var list = customProviders
        if let idx = list.firstIndex(where: { $0.id == def.id }) {
            list[idx] = def
        } else {
            list.append(def)
        }
        customProviders = list
        setApiKey(chainKey: Self.customProviderKey(def.id), value: apiKey)
    }

    /// Remove a custom provider and its Keychain key.
    func removeCustomProvider(id: String) {
        customProviders = customProviders.filter { $0.id != id }
        try? KeychainManager.delete(key: Self.customProviderKey(id))
    }

    /// Resolve a friendly fallback provider name to a canonical provider ID.
    static func resolveProviderName(_ name: String) -> String {
        switch name.lowercased() {
        case "nvidia": return "nvidia-nim"
        case "ollama": return "local"
        // Legacy alias — llama.cpp was replaced by the Llama desktop app.
        case "llamacpp", "llama.cpp": return "llamaapp"
        default: return name
        }
    }

    // MARK: - Accessible Model List (gateway model discovery)

    /// Parse the stored `visibleModelsRaw` mapping ("provider=model,model;…")
    /// into a dictionary of provider id → visible model ids.
    private var parsedVisibleModels: [String: [String]] {
        var result: [String: [String]] = [:]
        for chunk in visibleModelsRaw.components(separatedBy: ";") {
            let parts = chunk.components(separatedBy: "=")
            if parts.count == 2 {
                result[parts[0]] = parts[1].components(separatedBy: ",").filter { !$0.isEmpty }
            }
        }
        return result
    }

    /// Whether a provider can actually serve requests right now. Keyless
    /// providers and custom providers the user added are always reachable;
    /// key-requiring providers need a non-empty API key.
    private func providerIsAccessible(_ pid: String) -> Bool {
        if customProviders.contains(where: { $0.id == pid }) { return true }
        let lookup = pid == "local" ? "ollama" : pid
        guard let preset = ProviderPreset.preset(for: lookup) else { return false }
        if !preset.requiresKey { return true }
        return !apiKey(for: pid).isEmpty
    }

    /// The model ids the user can actually reach — served by the proxy's
    /// `/v1/models` endpoints (Claude Code's gateway model discovery) so the
    /// model picker only lists models from providers that are configured and
    /// accessible. Previously every preset model from every provider was
    /// listed, so the picker showed dozens of models the user has no access to.
    ///
    /// Includes:
    /// - the four tier models the user explicitly configured (Default / Opus /
    ///   Sonnet / Haiku), and
    /// - preset + visible (live-fetched) models from the primary provider,
    ///   every configured fallback, every per-tier provider, and every custom
    ///   provider — restricted to providers that are accessible.
    func accessibleModels() -> [(id: String, ownedBy: String)] {
        // Sanitize model ids (newlines + stray whitespace can sneak in from
        // pasted values) and skip empty ones.
        let sanitize: (String) -> String = { $0.components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespaces) ?? $0 }
        var ids = Set<String>()
        var owned: [String: String] = [:]
        let add: (String, String) -> Void = { rawId, owner in
            let id = sanitize(rawId)
            guard !id.isEmpty else { return }
            ids.insert(id)
            owned[id] = owner
        }

        // 1. Explicitly configured tier models — always listed.
        for (m, owner) in [(model, "jxproxy"), (modelOpus, "jxproxy"), (modelSonnet, "jxproxy"), (modelHaiku, "jxproxy")] where !m.isEmpty {
            add(m, owner)
        }

        // 2. Providers in the routing path: primary + fallbacks + per-tier + custom.
        var providerIds = Set<String>()
        providerIds.insert(Self.resolveProviderName(provider))
        for fallback in fallbackProviders
            .components(separatedBy: ",")
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .filter({ !$0.isEmpty }) {
            providerIds.insert(Self.resolveProviderName(fallback))
        }
        for tier in ["opus", "sonnet", "haiku"] {
            if let pid = tierProvider(for: tier) { providerIds.insert(pid) }
        }
        for def in customProviders { providerIds.insert(def.id) }

        // 3. Each accessible provider contributes its preset + visible models.
        let visible = parsedVisibleModels
        for pid in providerIds where providerIsAccessible(pid) {
            let lookup = pid == "local" ? "ollama" : pid
            if let preset = ProviderPreset.preset(for: lookup) {
                for m in preset.models { add(m, pid) }
            }
            for m in (visible[pid] ?? []) + (visible[lookup] ?? []) {
                add(m, pid)
            }
        }

        return ids.sorted().map { (id: $0, ownedBy: owned[$0] ?? "jxproxy") }
    }
}

// MARK: - Helpers

extension Int {
    /// Return self if non-zero, otherwise nil.
    fileprivate var nonzero: Int? { self == 0 ? nil : self }
}

/// Watches the shell config files for edits while the app runs, firing
/// `onChange` when any of them is touched. Uses a lightweight mtime poll
/// rather than a DispatchSource fd watch: editors commonly save via
/// write-temp-then-rename (atomic saves), which a single fd watch can miss or
/// lose after the inode is replaced — a stat every few seconds catches every
/// real edit and costs almost nothing.
final class ShellConfigWatcher {
    private var timer: DispatchSourceTimer?
    private let paths: [String]
    private var lastModified: [String: Date?]
    private let onChange: () -> Void

    init(paths: [String], onChange: @escaping () -> Void) {
        self.paths = paths
        self.onChange = onChange
        lastModified = Dictionary(uniqueKeysWithValues: paths.map { ($0, Self.modDate($0)) })
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(
            queue: DispatchQueue(label: "com.jxproxy.shell-config-watch", qos: .utility)
        )
        timer.schedule(deadline: .now() + 3, repeating: 5, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            self?.poll()
        }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func poll() {
        var changed = false
        for path in paths {
            let current = Self.modDate(path)
            if current != lastModified[path] ?? nil {
                lastModified[path] = current
                changed = true
            }
        }
        if changed {
            onChange()
        }
    }

    private static func modDate(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
    }
}

