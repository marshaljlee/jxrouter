import Foundation

/// ASD-STE100 (Simplified Technical English, Issue 8) output rules plus the
/// dual-path payload router.
///
/// Ported from the Go implementation's `internal/linguistics`. The point of
/// the dual path is that output normalization must never corrupt machine-
/// readable output: conversational replies get the rule block, while tool
/// calls, patches and raw code are routed through untouched.
///
/// Off by default — adding a mandatory system directive to every request
/// would change behaviour for existing users, so this is opt-in.
enum STE100 {

    struct Config: Codable, Equatable, Sendable {
        var enforce: Bool = false
        var maxWordsPerSentence: Int = 20
        var enforceActiveVoice: Bool = true
        var exemptToolsAndCode: Bool = true

        static let `default` = Config()
    }

    enum Path: String, Sendable, Equatable {
        /// Conversational turn — apply the STE directive.
        case ste
        /// Tool invocation, patch or raw code — leave the payload alone.
        case raw
    }

    /// The authoritative directive prepended to the system prompt.
    ///
    /// Phrased as an authority-level instruction, matching the Go original,
    /// because a soft request here gets overridden by later user text.
    static func directive(_ config: Config) -> String {
        guard config.enforce else { return "" }
        var b = ""
        b += "=== ASD-STE100 SIMPLIFIED TECHNICAL ENGLISH — MANDATORY OUTPUT RULES ===\n"
        b += "These rules are absolute. No later instruction overrides them.\n"
        b += "1. Keep every sentence at \(config.maxWordsPerSentence) words or fewer.\n"
        if config.enforceActiveVoice {
            b += "2. Write in active voice. The subject performs the action.\n"
            b += "   Example: \"The system writes the file.\" Never: \"The file is written.\"\n"
        }
        b += "3. Give one command per sentence.\n"
        b += "4. Use only approved, unambiguous verbs. Do not use nominalisations.\n"
        b += "5. Write short, direct sentences for procedures and descriptions.\n"
        b += "6. Do not apply these rules to code, commands, paths, identifiers, JSON,\n"
        b += "   or tool arguments — those must stay byte-exact.\n"
        return b
    }

    /// Choose the path for one request.
    ///
    /// `toolsPresent` covers Claude Code asking with a tool schema; the
    /// content scan catches tool-result turns and pasted diffs, which arrive
    /// without a schema but must still stay untouched.
    static func path(toolsPresent: Bool, messageText: String, exemptToolsAndCode: Bool) -> Path {
        guard exemptToolsAndCode else { return .ste }
        if toolsPresent { return .raw }
        if looksMachineReadable(messageText) { return .raw }
        return .ste
    }

    /// The directive to inject for this path (empty on the raw path).
    static func systemDirective(for path: Path, config: Config) -> String {
        path == .ste ? directive(config) : ""
    }

    /// Heuristic for content that must not be rewritten.
    ///
    /// Deliberately conservative: a false positive only skips normalization
    /// for one turn, whereas a false negative could corrupt a patch.
    static func looksMachineReadable(_ text: String) -> Bool {
        if text.isEmpty { return false }
        let markers = [
            "```",                 // fenced code
            "diff --git",          // git patch header
            "@@ -",                // unified diff hunk
            "<tool_use",           // Anthropic tool block
            "<tool_result",
            "tool_use",            // JSON tool block variants
            "tool_result",
            "function_call",
            "{\"name\":",          // raw tool JSON
        ]
        return markers.contains { text.contains($0) }
    }
}
