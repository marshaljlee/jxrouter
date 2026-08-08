import Foundation
import Observation

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
        static let authToken = "authToken"
        static let authTokenResetDone = "authTokenResetDone"
        static let appRoutesJSON = "appRoutesJSON"
        static let hasMigrated = "hasMigratedFromConfigEnv"
        static let enabledProviders = "enabledProviders"
        static let visibleModels = "visibleModels"
        static let providerBackendUrls = "providerBackendUrls"
        static let customProviders = "customProvidersJSON"
        static let mitmHosts = "mitmHosts"
        static let dnsRedirect = "dnsRedirectEnabled"
        static let botIntegrationEnabled = "botIntegrationEnabled"
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
        static let custom = "CUSTOM_API_KEY"
        static let telegramBotToken = "TELEGRAM_BOT_TOKEN"
        static let adminPassword = "ADMIN_PASSWORD"
        static let authToken = "JXPROXY_AUTH_TOKEN"
    }

    /// UserDefaults key for storing API keys JSON dictionary.
    private static let udApiKeysKey = "apiKeysDict"

    private let defaults = UserDefaults.standard

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
        get { defaults.string(forKey: UDKey.fallbackProviders) ?? "nvidia,local" }
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
        return dict[tier]
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

    /// Base URL for local LLM (Ollama, etc.).
    var localLlmBaseUrl: String {
        get { defaults.string(forKey: UDKey.localLlmBaseUrl) ?? "http://127.0.0.1:11434/v1" }
        set { defaults.set(newValue, forKey: UDKey.localLlmBaseUrl); publish() }
    }

    /// Model name for local LLM.
    var localLlmModel: String {
        get { defaults.string(forKey: UDKey.localLlmModel) ?? "ollama/qwen3:latest" }
        set { defaults.set(newValue, forKey: UDKey.localLlmModel); publish() }
    }

    /// Auth token for proxy authentication. Defaults to the documented token
    /// "jxproxy" (README, install.sh); a custom token can be set in Settings
    /// and is honored by the proxy and the regenerated launcher scripts.
    var authToken: String {
        get { defaults.string(forKey: UDKey.authToken) ?? "jxproxy" }
        set { defaults.set(newValue, forKey: UDKey.authToken); publish() }
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
    var mitmHosts: Set<String> {
        get {
            let raw = defaults.string(forKey: UDKey.mitmHosts) ?? "api.anthropic.com"
            return Set(raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        }
        set {
            defaults.set(newValue.joined(separator: ","), forKey: UDKey.mitmHosts)
        }
    }

    /// Whether DNS redirection is enabled (redirects AI API hostnames to local proxy).
    var dnsRedirectEnabled: Bool {
        get { defaults.object(forKey: UDKey.dnsRedirect) as? Bool ?? true }
        set { defaults.set(newValue, forKey: UDKey.dnsRedirect); publish() }
    }

    /// Whether Bot Integration is enabled.
    var botIntegrationEnabled: Bool {
        get { defaults.object(forKey: UDKey.botIntegrationEnabled) as? Bool ?? false }
        set { defaults.set(newValue, forKey: UDKey.botIntegrationEnabled); publish() }
    }

    // MARK: - API Key Storage (UserDefaults)

    /// Store an API key securely in the Keychain.
    ///
    /// On Keychain failure the error is surfaced and the prior value is kept —
    /// secrets are never written to UserDefaults (ticket 0001).
    func setApiKey(chainKey: String, value: String) {
        guard !value.isEmpty else {
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

    /// Get the resolved API key for a given provider identifier.
    func apiKey(for providerId: String) -> String {
        // Named custom providers first — each has its own Keychain account.
        // Fall through to the legacy "custom" account if the per-provider
        // account is empty (pre-migration setups stored the key there).
        if let def = customProviders.first(where: { $0.id == providerId }) {
            let key = getApiKey(chainKey: Self.customProviderKey(def.id))
            if !key.isEmpty { return key }
            if def.id == "custom" {
                let legacy = getApiKey(chainKey: KeychainKey.custom)
                if !legacy.isEmpty { return legacy }
            }
            return key
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
        case "local", "ollama", "lmstudio", "llamacpp", "jan": return ""
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

    private init() {
        // Hygiene sweep: migrate any legacy plaintext apiKeysDict into Keychain (ticket 0001).
        migrateLegacyApiKeysDict()

        if !hasMigrated {
            migrateFromConfigEnv()
            hasMigrated = true
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
        case "gemini": return "https://generativelanguage.googleapis.com/v1beta"
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
        case "llamacpp": return "http://127.0.0.1:8080/v1"
        case "jan": return "http://127.0.0.1:1337/v1"
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
        default: return name
        }
    }
}

// MARK: - Helpers

extension Int {
    /// Return self if non-zero, otherwise nil.
    fileprivate var nonzero: Int? { self == 0 ? nil : self }
}
