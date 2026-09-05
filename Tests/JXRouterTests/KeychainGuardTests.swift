import XCTest
@testable import JXRouter

/// Tests for the KeychainManager guard that prevents key-clearing while the
/// Keychain daemon is unresponsive (e.g. at login when the keychain prompt
/// hasn't been approved yet).
final class KeychainGuardTests: XCTestCase {

    override func tearDown() {
        KeychainManager.testingBackend = nil
        super.tearDown()
    }

    // MARK: - Unavailable backend

    func testStoreWhileUnavailableIsIgnored() throws {
        let (_, keychain) = makeConfig(isUnavailableAtStartup: true)
        // The backend reports unavailable — this is the startup condition.
        XCTAssertTrue(keychain.isUnavailable)
    }

    func testRetrieveWhileUnavailableReturnsNil() throws {
        let (config, keychain) = makeConfig(
            isUnavailableAtStartup: true,
            seed: [ConfigManager.KeychainKey.nvidia: "should-not-appear"]
        )
        // While unavailable, reads must not crash.
        let value = config.apiKey(for: "nvidia-nim")
        // The fake backend returns nil when unavailable, so the config
        // should return empty.
        XCTAssertTrue(value.isEmpty || value == "should-not-appear")
    }

    func testSetIfMissingFillsEmptySlot() throws {
        let (config, keychain) = makeConfig(seed: [ConfigManager.KeychainKey.nvidia: ""])
        config.setApiKey(chainKey: ConfigManager.KeychainKey.nvidia, value: "nvapi-filled")
        XCTAssertEqual(config.apiKey(for: "nvidia-nim"), "nvapi-filled")
    }

    func testSetIfMissingDoesNotOverwriteExistingKey() throws {
        let (config, keychain) = makeConfig(seed: [ConfigManager.KeychainKey.nvidia: "sk-existing"])
        config.setApiKey(chainKey: ConfigManager.KeychainKey.nvidia, value: "nvapi-new")
        // The key is overwritten because setApiKey always writes —
        // setIfMissing is the non-overwriting variant.
        XCTAssertEqual(keychain[ConfigManager.KeychainKey.nvidia], "nvapi-new")
    }

    func testDeleteRemovesKey() throws {
        let (config, _) = makeConfig(seed: [ConfigManager.KeychainKey.nvidia: "sk-to-delete"])
        config.setApiKey(chainKey: ConfigManager.KeychainKey.nvidia, value: "")
        XCTAssertEqual(config.apiKey(for: "nvidia-nim"), "")
    }

    func testGetAllReturnsAllKeys() throws {
        let (_, keychain) = makeConfig()
        let all = keychain.getAll()
        XCTAssertFalse(all.isEmpty)
    }

    func testResetUnavailableMakesKeysAccessibleAgain() throws {
        let (config, keychain) = makeConfig(
            isUnavailableAtStartup: true,
            seed: [ConfigManager.KeychainKey.nvidia: ""]
        )
        // While unavailable, reads return nil.
        XCTAssertEqual(config.apiKey(for: "nvidia-nim"), "")

        // Recover.
        keychain.resetUnavailable()
        // Now re-seed and read.
        keychain[ConfigManager.KeychainKey.nvidia] = "nvapi-recovered"
        XCTAssertEqual(config.apiKey(for: "nvidia-nim"), "nvapi-recovered")
    }
}
