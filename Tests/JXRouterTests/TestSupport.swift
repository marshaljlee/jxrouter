import Foundation

// MARK: - Stubs (only referenced as types by ConfigManager; never exercised)

/// Minimal stand-in so ConfigManager.swift compiles in the test bundle.
/// The app target compiles the real implementation.
class ProviderRouter {}

/// Minimal stand-in for the app's MessageTranslator.
enum MessageTranslator {
    static func isReasoningCapable(providerId: String, model: String) -> Bool { false }
}

// MARK: - In-memory Keychain backend

/// In-memory KeychainBackend so the tests never touch the real Keychain.
/// Mirrors KeychainManager's semantics: empty-value stores delete, retrieves
/// return nil while unavailable, setIfMissing only fills empty slots.
final class FakeKeychainBackend: KeychainBackend {
    private var store: [String: String] = [:]
    private var unavailableFlag: Bool

    init(unavailable: Bool = false, seeded: [String: String] = [:]) {
        unavailableFlag = unavailable
        store = seeded
    }

    var isUnavailable: Bool { unavailableFlag }

    func store(key: String, value: String) throws {
        guard !value.isEmpty else {
            try delete(key: key)
            return
        }
        store[key] = value
    }

    /// Mirrors the real backend: while unavailable, reads return nil/empty so
    /// the UI would show empty key fields — exactly the startup condition the
    /// guard protects against.
    func retrieve(key: String) -> String? {
        guard !unavailableFlag else { return nil }
        return store[key]
    }

    func delete(key: String) throws { store.removeValue(forKey: key) }

    func getAll() -> [String: String] {
        guard !unavailableFlag else { return [:] }
        return store
    }

    func setIfMissing(key: String, value: String) throws {
        if store[key] == nil, !value.isEmpty { store[key] = value }
    }

    func resetUnavailable() { unavailableFlag = false }

    /// Direct access for arranging/asserting test state.
    subscript(key: String) -> String? {
        get { store[key] }
        set { store[key] = newValue }
    }
}

// MARK: - ConfigManager factory

/// Every built-in Keychain account the app can import from the user's real
/// shell files (shellEnvKeyMap). Seeding all of them with sentinels makes the
/// init-time shell import a no-op, so tests stay hermetic regardless of what
/// the developer's own ~/.zshrc / config.env exports.
let allBuiltInChainKeys: [String] = [
    ConfigManager.KeychainKey.anthropic,
    ConfigManager.KeychainKey.openai,
    ConfigManager.KeychainKey.openrouter,
    ConfigManager.KeychainKey.opencode,
    ConfigManager.KeychainKey.nvidia,
    ConfigManager.KeychainKey.deepseek,
    ConfigManager.KeychainKey.gemini,
    ConfigManager.KeychainKey.mistral,
    ConfigManager.KeychainKey.codestral,
    ConfigManager.KeychainKey.cohere,
    ConfigManager.KeychainKey.groq,
    ConfigManager.KeychainKey.fireworks,
    ConfigManager.KeychainKey.sambanova,
    ConfigManager.KeychainKey.cerebras,
    ConfigManager.KeychainKey.huggingface,
    ConfigManager.KeychainKey.githubModels,
    ConfigManager.KeychainKey.wafer,
    ConfigManager.KeychainKey.kimi,
    ConfigManager.KeychainKey.kimiCode,
    ConfigManager.KeychainKey.minimax,
    ConfigManager.KeychainKey.xai,
    ConfigManager.KeychainKey.cloudflareApiToken,
    ConfigManager.KeychainKey.zai,
    ConfigManager.KeychainKey.ollamaCloud,
    ConfigManager.KeychainKey.aiGateway,
    ConfigManager.KeychainKey.custom,
]

/// Builds an isolated ConfigManager over a scratch UserDefaults suite and a
/// fake Keychain. The backend stays installed for the rest of the test —
/// callers must clear it in tearDown via `KeychainManager.testingBackend = nil`.
///
/// - Parameters:
///   - isUnavailableAtStartup: simulates a startup where Keychain reads timed
///     out (pending permission prompt), so `keychainReadHealthyAtStartup` is
///     false and the empty-save guard must engage.
///   - seed: explicit values that override the hermetic sentinels.
func makeConfig(
    isUnavailableAtStartup: Bool = false,
    seed: [String: String] = [:]
) -> (config: ConfigManager, keychain: FakeKeychainBackend) {
    var seeded = seed
    for chainKey in allBuiltInChainKeys where seeded[chainKey] == nil {
        seeded[chainKey] = "seed-\(chainKey)"
    }
    let keychain = FakeKeychainBackend(unavailable: isUnavailableAtStartup, seeded: seeded)
    ConfigManager.skipShellImport = true
    KeychainManager.testingBackend = keychain

    let suiteName = "JXRouterTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    let config = ConfigManager(defaults: defaults)

    // While the backend reports unavailable, init-time reads return nil, so
    // the shell-config import can fill slots from the developer's real shell
    // files (they land only in this in-memory fake — never the real Keychain).
    // Re-apply the explicit seed afterwards so the scenario is deterministic.
    for (chainKey, value) in seed {
        keychain[chainKey] = value
    }
    return (config, keychain)
}
