import XCTest
import Foundation

/// Tests for auto-detecting API keys from the user's shell configs
/// (~/.zshrc etc.): the parser's handling of real-world `export` lines, the
/// import-into-Keychain flow (empty slots only), and the lazy fallback in
/// `apiKey(for:)` that re-scans the configs at request time.
final class ShellKeyImportTests: XCTestCase {
    override func tearDown() {
        KeychainManager.testingBackend = nil
        super.tearDown()
    }

    // MARK: - Parser

    func testMergeShellEnvHandlesQuotesExportsAndInlineComments() {
        let (config, _) = makeConfig()
        let content = """
        # a comment line
        export ANTHROPIC_API_KEY="sk-ant-123" # my main key
        export OPENAI_API_KEY='sk-openai-456'
        NVIDIA_NIM_API_KEY=nvapi-plain789
        NVIDIA_API_KEY=nvapi-alias
        export DEEPSEEK_API_KEY=sk-deep-with-comment # trailing
        GEMINI_API_KEY="sk-gemini-unterminated
        """
        var env: [String: String] = [:]
        config.mergeShellEnv(&env, content)

        XCTAssertEqual(env["ANTHROPIC_API_KEY"], "sk-ant-123", "Inline comment after a quoted value must be stripped.")
        XCTAssertEqual(env["OPENAI_API_KEY"], "sk-openai-456", "Single-quoted values are supported.")
        XCTAssertEqual(env["NVIDIA_NIM_API_KEY"], "nvapi-plain789", "Bare unquoted values are supported.")
        XCTAssertEqual(env["NVIDIA_API_KEY"], "nvapi-alias")
        XCTAssertEqual(env["DEEPSEEK_API_KEY"], "sk-deep-with-comment", "Unquoted trailing comments must be stripped.")
        XCTAssertNil(env["GEMINI_API_KEY"], "Unterminated quotes must be skipped, not imported as garbage.")
    }

    func testMergeShellEnvSkipsUnexpandedSubstitutionsAndComments() {
        let (config, _) = makeConfig()
        let content = """
        export NVIDIA_NIM_API_KEY="$SOME_INDIRECT"
        export OPENAI_API_KEY="sk-ok"
        export OPENROUTER_API_KEY=`cat ~/.key`
        export DEEPSEEK_API_KEY="${DEEPSEEK_API_KEY:-fallback}"
        MISTRAL_API_KEY="value with # inside quotes"
        """
        var env: [String: String] = [:]
        config.mergeShellEnv(&env, content)

        XCTAssertNil(env["NVIDIA_NIM_API_KEY"], "Dollar substitution is unexpanded — must not be imported.")
        XCTAssertEqual(env["OPENAI_API_KEY"], "sk-ok")
        XCTAssertNil(env["OPENROUTER_API_KEY"], "Backticks are unexpanded — must not be imported.")
        XCTAssertNil(env["DEEPSEEK_API_KEY"], "Brace substitution is unexpanded — must not be imported.")
        XCTAssertEqual(env["MISTRAL_API_KEY"], "value with # inside quotes", "A # inside quotes is data, not a comment.")
    }

    // MARK: - Import into Keychain

    func testImportFillsEmptySlotsFromShellFile() throws {
        // Both slots are explicitly emptied — makeConfig seeds every other
        // built-in slot with a sentinel so only these can be imported.
        let (config, keychain) = makeConfig(seed: [
            ConfigManager.KeychainKey.nvidia: "",
            ConfigManager.KeychainKey.anthropic: "",
        ])
        let file = try writeTempShellConfig("""
        # my zshrc
        export NVIDIA_NIM_API_KEY="nvapi-from-zshrc" # free tier
        export ANTHROPIC_API_KEY="sk-ant-imported"
        """)
        config.shellConfigPaths = [file.path]

        let imported = config.importKeysFromShellConfigs()

        XCTAssertEqual(Set(imported), Set([
            ConfigManager.KeychainKey.nvidia,
            ConfigManager.KeychainKey.anthropic,
        ]), "Both empty slots should be imported and reported.")
        XCTAssertEqual(keychain[ConfigManager.KeychainKey.nvidia], "nvapi-from-zshrc")
        XCTAssertEqual(keychain[ConfigManager.KeychainKey.anthropic], "sk-ant-imported")
        XCTAssertEqual(config.apiKey(for: "nvidia-nim"), "nvapi-from-zshrc")
        try? FileManager.default.removeItem(at: file)
    }

    func testImportNeverOverwritesAnExistingKey() throws {
        let (config, keychain) = makeConfig(seed: [ConfigManager.KeychainKey.nvidia: "sk-already-saved"])
        let file = try writeTempShellConfig("export NVIDIA_NIM_API_KEY=\"nvapi-different\"")
        config.shellConfigPaths = [file.path]

        let imported = config.importKeysFromShellConfigs()

        XCTAssertTrue(imported.isEmpty, "A key already saved in the Keychain must never be overwritten.")
        XCTAssertEqual(keychain[ConfigManager.KeychainKey.nvidia], "sk-already-saved",
                       "A key pasted in Settings always wins over the shell config.")
        try? FileManager.default.removeItem(at: file)
    }

    func testImportSkipsShellSubstitutionValues() throws {
        let (config, keychain) = makeConfig(seed: [ConfigManager.KeychainKey.nvidia: ""])
        let file = try writeTempShellConfig("export NVIDIA_NIM_API_KEY=\"$NVIDIA_KEY\"")
        config.shellConfigPaths = [file.path]

        config.importKeysFromShellConfigs()

        let stored = keychain[ConfigManager.KeychainKey.nvidia]
        XCTAssertTrue(stored == nil || stored?.isEmpty == true,
                      "Unexpanded substitutions must not be stored as literal keys.")
        XCTAssertEqual(config.apiKey(for: "nvidia-nim"), "")
        try? FileManager.default.removeItem(at: file)
    }

    // MARK: - Lazy fallback in apiKey(for:)

    func testApiKeyForLazilyImportsFromShellConfigAtRequestTime() throws {
        let (config, _) = makeConfig(seed: [ConfigManager.KeychainKey.nvidia: ""])
        let file = try writeTempShellConfig("export NVIDIA_NIM_API_KEY=\"nvapi-just-added\"")
        config.shellConfigPaths = [file.path]

        // Simulates a request arriving after the user added the key to ~/.zshrc
        // while the app was already running: the empty Keychain slot is
        // re-scanned on demand.
        let resolved = config.apiKey(for: "nvidia-nim")

        XCTAssertEqual(resolved, "nvapi-just-added")
        try? FileManager.default.removeItem(at: file)
    }

    func testImportSkippedWhileKeychainUnavailableThenRecovers() throws {
        // Keychain timed out (locked at login, prompt pending): the import must
        // NOT probe every slot — that read/write storm was the per-launch
        // keychain-password-prompt + "no API key installed" regression. Once
        // the keychain responds again, the same import fills the empty slot.
        let (config, keychain) = makeConfig(
            isUnavailableAtStartup: true,
            seed: [ConfigManager.KeychainKey.nvidia: ""]
        )
        let file = try writeTempShellConfig("export NVIDIA_NIM_API_KEY=\"nvapi-after-recovery\"")
        config.shellConfigPaths = [file.path]

        // While unavailable: the import is a guarded no-op — no prompt storm,
        // nothing written (the slot stays empty).
        XCTAssertEqual(config.importKeysFromShellConfigs(), [])
        XCTAssertEqual(keychain[ConfigManager.KeychainKey.nvidia], "",
                       "The empty slot must stay empty during the cooldown — no import storm.")

        // Keychain recovers (login completes / prompt approved): the recovery
        // pass re-runs the import and the key lands.
        keychain.resetUnavailable()
        let imported = config.importKeysFromShellConfigs()
        XCTAssertEqual(imported, [ConfigManager.KeychainKey.nvidia])
        XCTAssertEqual(config.apiKey(for: "nvidia-nim"), "nvapi-after-recovery")
        try? FileManager.default.removeItem(at: file)
    }

    func testApiKeyForLazyFallbackRespectsExistingKey() throws {
        let (config, _) = makeConfig(seed: [ConfigManager.KeychainKey.nvidia: "sk-manual"])
        let file = try writeTempShellConfig("export NVIDIA_NIM_API_KEY=\"nvapi-other\"")
        config.shellConfigPaths = [file.path]

        XCTAssertEqual(config.apiKey(for: "nvidia-nim"), "sk-manual",
                       "The lazy fallback must never override a saved key.")
        try? FileManager.default.removeItem(at: file)
    }

    // MARK: - Helpers

    private func writeTempShellConfig(_ content: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("jxproxy-shellconfig-\(UUID().uuidString).txt")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
