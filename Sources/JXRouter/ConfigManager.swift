import Foundation
import Observation

/// Shared configuration manager for JXRouter.
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
        static let fallbackProviders = "fallbackProviders"
        static let openaiBaseUrl = "openaiBaseUrl"
        static let localLlmBaseUrl = "localLlmBaseUrl"
        static let localLlmModel = "localLlmModel"
        static let authToken = "authToken"
        static let appRoutesJSON = "appRoutesJSON"
        static let hasMigrated = "hasMigratedFromConfigEnv"
        static let enabledProviders = "enabledProviders"
        static let visibleModels = "visibleModels"
        static let providerBackendUrls = "providerBackendUrls"
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
        static let telegramBotToken = "TELEGRAM_BOT_TOKEN"
        static let adminPassword = "ADMIN_PASSWORD"
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
        get { defaults.string(forKey: UDKey.model) ?? "big-pickle" }
        set { defaults.set(newValue, forKey: UDKey.model); publish() }
    }

    /// Model override for opus-tier.
    var modelOpus: String {
        get { defaults.string(forKey: UDKey.modelOpus) ?? "opencode/big-pickle" }
        set { defaults.set(newValue, forKey: UDKey.modelOpus); publish() }
    }

    /// Model override for sonnet-tier.
    var modelSonnet: String {
        get { defaults.string(forKey: UDKey.modelSonnet) ?? "nvidia/nemotron-3-ultra-550b-a55b" }
        set { defaults.set(newValue, forKey: UDKey.modelSonnet); publish() }
    }

    /// Model override for haiku-tier.
    var modelHaiku: String {
        get { defaults.string(forKey: UDKey.modelHaiku) ?? "ollama/qwen3:latest" }
        set { defaults.set(newValue, forKey: UDKey.modelHaiku); publish() }
    }

    /// Enable model thinking / reasoning.
    var enableThinking: Bool {
        get { defaults.object(forKey: UDKey.enableThinking) as? Bool ?? true }
        set { defaults.set(newValue, forKey: UDKey.enableThinking); publish() }
    }

    /// Comma-separated fallback provider names.
    var fallbackProviders: String {
        get { defaults.string(forKey: UDKey.fallbackProviders) ?? "nvidia,local" }
        set { defaults.set(newValue, forKey: UDKey.fallbackProviders); publish() }
    }

    /// Base URL for OpenAI-compatible providers.
    var openaiBaseUrl: String {
        get { defaults.string(forKey: UDKey.openaiBaseUrl) ?? "https://integrate.api.nvidia.com/v1" }
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

    /// Auth token for proxy authentication.
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
    func setApiKey(chainKey: String, value: String) {
        let isEmpty = value.isEmpty
        if !isEmpty {
            do {
                try KeychainManager.store(key: chainKey, value: value)
            } catch {
                print("[ConfigManager] Failed to store key in Keychain, falling back to UserDefaults: \(error)")
                var keys = loadApiKeysDict()
                keys[chainKey] = value
                saveApiKeysDict(keys)
            }
        } else {
            try? KeychainManager.delete(key: chainKey)
            var keys = loadApiKeysDict()
            keys.removeValue(forKey: chainKey)
            saveApiKeysDict(keys)
        }
    }

    /// Retrieve an API key securely from the Keychain.
    func getApiKey(chainKey: String) -> String {
        // Try Keychain first (Primary Secure Storage)
        if let keychainValue = KeychainManager.retrieve(key: chainKey), !keychainValue.isEmpty {
            return keychainValue
        }
        
        // Fallback to UserDefaults (in case Keychain is unavailable)
        let keys = loadApiKeysDict()
        if let udValue = keys[chainKey], !udValue.isEmpty {
            // Attempt to migrate back to secure Keychain
            try? KeychainManager.store(key: chainKey, value: udValue)
            return udValue
        }
        
        return ""
    }

    /// Get the resolved API key for a given provider identifier.
    func apiKey(for providerId: String) -> String {
        switch providerId {
        case "direct": return getApiKey(chainKey: KeychainKey.anthropic)
        case "openrouter": return getApiKey(chainKey: KeychainKey.openrouter)
        case "opencode-zen", "opencode-go": return getApiKey(chainKey: KeychainKey.opencode)
        case "openai": return getApiKey(chainKey: KeychainKey.openai)
        case "nvidia-nim": return getApiKey(chainKey: KeychainKey.nvidia)
        case "local", "ollama": return ""
        default: return ""
        }
    }

    private func loadApiKeysDict() -> [String: String] {
        (defaults.dictionary(forKey: Self.udApiKeysKey) as? [String: String]) ?? [:]
    }

    private func saveApiKeysDict(_ dict: [String: String]) {
        defaults.set(dict, forKey: Self.udApiKeysKey)
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
        if !hasMigrated {
            migrateFromConfigEnv()
            hasMigrated = true
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
    func baseUrl(for providerId: String) -> String {
        switch providerId {
        case "direct": return "https://api.anthropic.com"
        case "openrouter": return "https://openrouter.ai/api/v1"
        case "opencode-zen": return "https://opencode.ai/zen/v1"
        case "opencode-go": return "https://opencode.ai/zen/go/v1"
        case "openai", "nvidia-nim": return openaiBaseUrl
        case "local", "ollama": return localLlmBaseUrl
        default: return ""
        }
    }

    /// Resolve a friendly fallback provider name to a canonical provider ID.
    static func resolveProviderName(_ name: String) -> String {
        switch name.lowercased() {
        case "nvidia": return "openai"
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
