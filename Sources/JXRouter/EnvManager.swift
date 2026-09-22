import Foundation
import OSLog

/// Environment variables JXRouter exposes to the clients it launches.
///
/// Ported from 01.backup. The layering matters: defaults are overlaid by the
/// real process environment, which is overlaid by the user's config file, so
/// a value the user set in the app always wins over one inherited from a
/// shell. Sensitive keys are masked everywhere they surface.
actor EnvManager {

    static let shared = EnvManager()

    struct EnvVar: Identifiable, Equatable, Sendable {
        let id: String
        let key: String
        var value: String
        let isSensitive: Bool
        var source: EnvSource
        let helpDescription: String

        enum EnvSource: String, Sendable {
            case proxyConfig = "Proxy Config"
            case system = "System"
            case user = "User Set"
            case `default` = "Default"
        }

        /// Never leaks a secret into logs or the UI.
        var displayValue: String {
            isSensitive ? (value.isEmpty ? "" : "••••••••") : value
        }

        var description: String {
            "\(key)=\(isSensitive ? "***" : value) (\(source.rawValue))"
        }
    }

    private let log = Logger(subsystem: "com.marshaljlee.jxrouter", category: "env")

    private let configFileURL: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".jxproxy/config.env")
    }()

    private(set) var variables: [EnvVar] = []

    private init() {
        variables = Self.defaultVariables
    }

    // MARK: - Loading

    func load() {
        let env = ProcessInfo.processInfo.environment
        var loaded = Self.defaultVariables

        for i in loaded.indices {
            if let sysVal = env[loaded[i].key] {
                loaded[i].value = sysVal
                loaded[i].source = .system
            }
        }

        if let configVars = try? loadConfigFile() {
            for configVar in configVars {
                if let idx = loaded.firstIndex(where: { $0.key == configVar.key }) {
                    loaded[idx].value = configVar.value
                    loaded[idx].source = .user
                } else {
                    loaded.append(configVar)
                }
            }
        }
        variables = loaded
    }

    // MARK: - Mutation

    func update(key: String, value: String) {
        if let idx = variables.firstIndex(where: { $0.key == key }) {
            variables[idx].value = value
            variables[idx].source = .user
        } else {
            variables.append(EnvVar(id: key, key: key, value: value,
                                    isSensitive: Self.sensitiveKeys.contains(key),
                                    source: .user, helpDescription: "Custom variable"))
        }
        persist()
    }

    func resetToDefaults() {
        variables = Self.defaultVariables
        persist()
    }

    /// Resolved values, ready to be handed to a child process.
    func asDictionary() -> [String: String] {
        Dictionary(uniqueKeysWithValues: variables.map { ($0.key, $0.value) })
            .filter { !$0.value.isEmpty }
    }

    /// The copy-paste line for a shell session. Never written to any profile.
    func exportSnippet(host: String = "127.0.0.1", port: Int) -> String {
        let key = variables.first(where: { $0.key == "ANTHROPIC_API_KEY" })?.value ?? ""
        return "export ANTHROPIC_BASE_URL=\"http://\(host):\(port)\" ANTHROPIC_API_KEY=\"\(key)\""
    }

    // MARK: - Persistence

    private func persist() {
        do {
            let lines = variables
                .filter { $0.source != .default }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: "\n")
            let dir = configFileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            // Secrets live here — owner-only.
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            try lines.write(to: configFileURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configFileURL.path)
        } catch {
            log.error("failed to persist env config: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func loadConfigFile() throws -> [EnvVar] {
        let data = try Data(contentsOf: configFileURL)
        let content = String(data: data, encoding: .utf8) ?? ""
        return content
            .components(separatedBy: .newlines)
            .filter { $0.contains("=") && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
            .compactMap { line in
                let parts = line.split(separator: "=", maxSplits: 1)
                guard parts.count == 2 else { return nil }
                let key = String(parts[0]).trimmingCharacters(in: .whitespaces)
                let value = String(parts[1]).trimmingCharacters(in: .whitespaces)
                return EnvVar(id: key, key: key, value: value,
                              isSensitive: Self.sensitiveKeys.contains(key),
                              source: .user,
                              helpDescription: Self.descriptions[key] ?? "From config file")
            }
    }

    // MARK: - Defaults

    static let sensitiveKeys: Set<String> = [
        "ANTHROPIC_API_KEY", "OPENROUTER_API_KEY", "OPENAI_API_KEY",
        "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY",
    ]

    private static let descriptions: [String: String] = [
        "ANTHROPIC_BASE_URL": "Where Claude Code sends its requests",
        "ANTHROPIC_API_KEY": "Anthropic API authentication key",
        "OPENROUTER_API_KEY": "OpenRouter API authentication key",
        "OPENAI_API_KEY": "OpenAI API authentication key",
        "CLAUDE_CODE_DISABLE_TELEMETRY": "Disables Claude Code telemetry",
        "OTEL_SDK_DISABLED": "Disables OpenTelemetry SDK",
    ]

    static let defaultVariables: [EnvVar] = [
        EnvVar(id: "ANTHROPIC_BASE_URL", key: "ANTHROPIC_BASE_URL", value: "",
               isSensitive: false, source: .default,
               helpDescription: "Where Claude Code sends its requests"),
        EnvVar(id: "ANTHROPIC_API_KEY", key: "ANTHROPIC_API_KEY", value: "",
               isSensitive: true, source: .default,
               helpDescription: "Anthropic API authentication key"),
        EnvVar(id: "OPENROUTER_API_KEY", key: "OPENROUTER_API_KEY", value: "",
               isSensitive: true, source: .default,
               helpDescription: "OpenRouter API authentication key"),
        EnvVar(id: "OPENAI_API_KEY", key: "OPENAI_API_KEY", value: "",
               isSensitive: true, source: .default,
               helpDescription: "OpenAI API authentication key"),
        EnvVar(id: "CLAUDE_CODE_DISABLE_TELEMETRY", key: "CLAUDE_CODE_DISABLE_TELEMETRY",
               value: "true", isSensitive: false, source: .default,
               helpDescription: "Disables Claude Code telemetry"),
        EnvVar(id: "OTEL_SDK_DISABLED", key: "OTEL_SDK_DISABLED", value: "true",
               isSensitive: false, source: .default,
               helpDescription: "Disables OpenTelemetry SDK"),
    ]
}
