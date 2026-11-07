import Foundation

/// AMEEM v3.0 — dialect-aware tool-call recovery (G-02, G-06, G-08).
///
/// Failure Mode A, the dominant one: the model emits a well-formed tool call,
/// the server's parser does not recognise the shape, and the call is filed under
/// the message `content` channel instead of `tool_calls`. Nothing executes,
/// nothing errors, the turn reports success.
///
/// A template mismatch does not truncate a call — it **reroutes** it (C-15). The
/// remedy is therefore recovery, not prompt engineering: re-prompting cannot
/// recover a call that was already discarded.
///
/// A recovery layer must be driven by the dialect the template actually teaches,
/// not by one hardcoded shape (G-02). Four shapes exist in the wild; a parser
/// that knows one loses the other three silently.
enum AMEEMDialect: String, Sendable {
    /// `<function name="f"><param name="k">v</param></function>`
    case tagTaggedName = "TAG_TAGGED_NAME"
    /// `<tool_call><function=f><parameter=k>v</parameter></function></tool_call>`
    case tagTaggedEq = "TAG_TAGGED_EQ"
    /// `<function=f>{"k": "v"}</function>`
    case tagJSON = "TAG_JSON"
    /// `{"name": "f", "arguments": {...}}`
    case jsonNative = "JSON_NATIVE"
}

enum AMEEMRecovery {

    // MARK: - Dialect detection

    private static let reFnNameAttr = try? NSRegularExpression(
        pattern: #"<function\s+name\s*=\s*"([^"]+)"\s*>([\s\S]*?)</function>"#)
    private static let reParamNameAttr = try? NSRegularExpression(
        pattern: #"<param\s+name\s*=\s*"([^"]+)"\s*>([\s\S]*?)</param>"#)
    private static let reFnEq = try? NSRegularExpression(
        pattern: #"<function\s*=\s*([A-Za-z0-9_.\-]+)\s*>([\s\S]*?)</function>"#)
    private static let reParamEq = try? NSRegularExpression(
        pattern: #"<parameter\s*=\s*([A-Za-z0-9_.\-]+)\s*>([\s\S]*?)</parameter>"#)
    private static let reCDATA = try? NSRegularExpression(pattern: #"<!\[CDATA\[([\s\S]*?)\]\]>"#)
    private static let reJSONCall = try? NSRegularExpression(
        pattern: #"\{\s*"name"\s*:\s*"([^"]+)"\s*,\s*"arguments"\s*:\s*(\{[\s\S]*?\})\s*\}"#)

    /// Infer the tool-call dialect from the prompt the template produced.
    ///
    /// The template writes its own instruction example into the system turn, so
    /// the rendered prompt is the authoritative statement of the dialect — but
    /// only if the *example it teaches* is read, not a word that appears
    /// anywhere in the document.
    static func detectDialect(renderedPrompt: String) -> AMEEMDialect? {
        guard !renderedPrompt.isEmpty else { return nil }
        if matches(reFnNameAttr, renderedPrompt) { return .tagTaggedName }
        if matches(reFnEq, renderedPrompt) {
            // Decide from the BODY of the matched construct. A prompt that
            // embeds a tool schema as JSON contains `"parameters"` regardless of
            // the dialect it teaches, so a global substring test classifies an
            // XML template as JSON — and `recoverToolCalls` then runs
            // `json.loads` over `<parameter=k>v</parameter>`, fails, and drops
            // every call. Measured on a real template that teaches
            // `<function=f><parameter=k>v</parameter></function>`.
            for (_, body) in captures(reFnEq, renderedPrompt, groupCount: 2) {
                if body.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") {
                    return .tagJSON
                }
            }
            return .tagTaggedEq
        }
        if matches(reJSONCall, renderedPrompt) { return .jsonNative }
        return nil
    }

    // MARK: - Recovery

    /// Convert a text-channel tool call into a structured OpenAI `tool_calls`
    /// entry.
    ///
    /// G-08: recover, do not merely nudge. Extraction costs nothing and cannot
    /// be refused; a correction prompt costs a round trip and depends on the
    /// model complying.
    /// G-06: every recovered name is filtered against the tools actually
    /// offered, so prose that merely *documents* tool syntax stays inert.
    static func recoverToolCalls(
        content: String,
        dialect: AMEEMDialect?,
        offeredTools: Set<String>
    ) -> [[String: Any]] {
        guard !content.isEmpty, let dialect else { return [] }

        var found: [(name: String, args: [String: Any])] = []

        switch dialect {
        case .tagTaggedName:
            for (fn, body) in captures(reFnNameAttr, content, groupCount: 2) {
                found.append((fn.trimmingCharacters(in: .whitespaces),
                              paramPairs(reParamNameAttr, body)))
            }
        case .tagTaggedEq:
            for (fn, body) in captures(reFnEq, content, groupCount: 2) {
                found.append((fn.trimmingCharacters(in: .whitespaces),
                              paramPairs(reParamEq, body)))
            }
        case .tagJSON:
            for (fn, rawJSON) in captures(reFnEq, content, groupCount: 2) {
                if let obj = jsonObject(rawJSON) {
                    found.append((fn.trimmingCharacters(in: .whitespaces), obj))
                } else {
                    print("[AMEEM] G-08: unparseable JSON args for \(fn)")
                }
            }
        case .jsonNative:
            for (fn, rawJSON) in captures(reJSONCall, content, groupCount: 2) {
                if let obj = jsonObject(rawJSON) {
                    found.append((fn.trimmingCharacters(in: .whitespaces), obj))
                } else {
                    print("[AMEEM] G-08: unparseable JSON args for \(fn)")
                }
            }
        }

        var calls: [[String: Any]] = []
        for (index, entry) in found.enumerated() {
            guard offeredTools.contains(entry.name) else {
                print("[AMEEM] G-06: refused recovery of un-offered tool \(entry.name)")
                continue
            }
            let argsData = (try? JSONSerialization.data(withJSONObject: entry.args)) ?? Data("{}".utf8)
            let argsString = String(data: argsData, encoding: .utf8) ?? "{}"
            calls.append([
                "id": "call_ameem_\(index)",
                "type": "function",
                "function": ["name": entry.name, "arguments": argsString],
            ])
        }
        return calls
    }

    // MARK: - Helpers

    private static func matches(_ regex: NSRegularExpression?, _ text: String) -> Bool {
        guard let regex else { return false }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.firstMatch(in: text, options: [], range: range) != nil
    }

    /// All `(group1, group2)` capture pairs.
    private static func captures(
        _ regex: NSRegularExpression?, _ text: String, groupCount: Int
    ) -> [(String, String)] {
        guard let regex else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var out: [(String, String)] = []
        for match in regex.matches(in: text, options: [], range: range) {
            guard match.numberOfRanges > groupCount,
                  let g1 = Range(match.range(at: 1), in: text),
                  let g2 = Range(match.range(at: 2), in: text) else { continue }
            out.append((String(text[g1]), String(text[g2])))
        }
        return out
    }

    /// `(key, value)` pairs for a `<param…>`/`<parameter…>` block, with CDATA
    /// unwrapped.
    private static func paramPairs(
        _ regex: NSRegularExpression?, _ body: String
    ) -> [String: Any] {
        var out: [String: Any] = [:]
        for (key, value) in captures(regex, body, groupCount: 2) {
            out[key.trimmingCharacters(in: .whitespaces)] = stripCDATA(value)
        }
        return out
    }

    private static func stripCDATA(_ value: String) -> String {
        guard let regex = reCDATA else { return value.trimmingCharacters(in: .whitespacesAndNewlines) }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        if let match = regex.firstMatch(in: value, options: [], range: range),
           let inner = Range(match.range(at: 1), in: value) {
            return String(value[inner]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func jsonObject(_ raw: String) -> [String: Any]? {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj
    }
}
