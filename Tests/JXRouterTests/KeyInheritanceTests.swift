import XCTest
@testable import JXRouter

/// Tests for the endpoint-matching key inheritance: a custom provider whose
/// base URL matches a built-in provider's endpoint inherits its API key
/// automatically (e.g. a custom provider pointing at api.deepseek.com
/// picks up the DeepSeek key without re-entry).
final class KeyInheritanceTests: XCTestCase {

    override func tearDown() {
        KeychainManager.testingBackend = nil
        super.tearDown()
    }

    // MARK: - inheritedKeySource

    func testInheritedKeySourceMatchesBuiltInEndpoint() {
        let (config, _) = makeConfig(seed: [
            ConfigManager.KeychainKey.deepseek: "sk-deep-inherited",
        ])
        let source = config.inheritedKeySource(for: "https://api.deepseek.com/v1")
        XCTAssertEqual(source, "deepseek", "Should recognise the DeepSeek endpoint")
    }

    func testInheritedKeySourceReturnsNilForUnknownEndpoint() {
        let (config, _) = makeConfig()
        let source = config.inheritedKeySource(for: "https://totally-unknown-api.example.com/v1")
        XCTAssertNil(source, "An unknown endpoint must not inherit")
    }

    func testInheritedKeySourceSkipsCustomPreset() {
        let (config, _) = makeConfig()
        // The legacy "custom" preset is explicitly excluded from inheritance.
        let source = config.inheritedKeySource(for: "https://custom-endpoint.example.com/v1")
        XCTAssertNil(source, "The 'custom' preset must not be an inheritance source")
    }

    // MARK: - apiKey(for:) inheritance path

    func testApiKeyForCustomProviderFallsBackToInheritedKey() {
        let (config, _) = makeConfig(seed: [
            ConfigManager.KeychainKey.nvidia: "nvapi-from-inheritance",
            ConfigManager.KeychainKey.deepseek: "",
            ConfigManager.KeychainKey.custom: "",
        ])
        // Register a custom provider whose URL matches NVIDIA's endpoint.
        let def = CustomProviderDef(
            id: "custom-inherit",
            name: "My NVIDIA Proxy",
            baseUrl: "https://integrate.api.nvidia.com/v1"
        )
        config.upsertCustomProvider(def, apiKey: "")
        let resolved = config.apiKey(for: "custom-inherit")
        XCTAssertEqual(resolved, "nvapi-from-inheritance",
                       "A custom provider at the same endpoint should inherit the built-in key")
    }

    func testApiKeyForCustomProviderPrefersExplicitKeyOverInherited() {
        let (config, _) = makeConfig(seed: [
            ConfigManager.KeychainKey.nvidia: "nvapi-inherited",
            ConfigManager.KeychainKey.custom: "",
        ])
        let def = CustomProviderDef(
            id: "custom-explicit",
            name: "My NVIDIA Proxy",
            baseUrl: "https://integrate.api.nvidia.com/v1"
        )
        config.upsertCustomProvider(def, apiKey: "nvapi-explicit")
        XCTAssertEqual(config.apiKey(for: "custom-explicit"), "nvapi-explicit",
                       "An explicit key always wins over the inherited one")
    }
}
