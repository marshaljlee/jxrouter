import Foundation

/// Unified Agent Settings Configurator for JXRouter.
/// Supports programmatic routing configuration for Claude Code, Codex, and OpenCode,
/// following the proven non-destructive configuration pattern from JXServer's agent_launchers.
final class AgentSettingsManager {
    static let shared = AgentSettingsManager()

    private let fileManager = FileManager.default

    private func home() -> URL { fileManager.homeDirectoryForCurrentUser }

    // MARK: - OpenCode Configuration

    /// Write proxy routing configuration into OpenCode configuration file (`~/.opencode/config.json`)
    @discardableResult
    func applyOpenCode(proxyPort: Int, authToken: String) -> Bool {
        let dir = home().appendingPathComponent(".opencode")
        let configURL = dir.appendingPathComponent("config.json")

        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        var config: [String: Any] = [:]
        if let data = try? Data(contentsOf: configURL),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            config = parsed
        }

        // Configure custom provider pointing to local JXRouter
        var providers = config["providers"] as? [String: Any] ?? [:]
        providers["jxrouter"] = [
            "type": "openai",
            "baseURL": "http://127.0.0.1:\(proxyPort)/v1",
            "apiKey": authToken
        ]
        config["providers"] = providers

        if let outData = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys]) {
            do {
                try outData.write(to: configURL, options: .atomic)
                return true
            } catch {
                print("[AgentSettingsManager] Failed to write OpenCode config: \(error)")
            }
        }
        return false
    }

    // MARK: - Codex Configuration

    /// Write proxy routing configuration into Codex configuration file (`~/.codex/config.json`)
    @discardableResult
    func applyCodex(proxyPort: Int, authToken: String) -> Bool {
        let dir = home().appendingPathComponent(".codex")
        let configURL = dir.appendingPathComponent("config.json")

        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        var config: [String: Any] = [:]
        if let data = try? Data(contentsOf: configURL),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            config = parsed
        }

        config["apiBaseUrl"] = "http://127.0.0.1:\(proxyPort)/v1"
        config["apiKey"] = authToken

        if let outData = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys]) {
            do {
                try outData.write(to: configURL, options: .atomic)
                return true
            } catch {
                print("[AgentSettingsManager] Failed to write Codex config: \(error)")
            }
        }
        return false
    }
}

