import Foundation

/// OpenCode Zen free-tier client shim.
///
/// ## The problem
///
/// Zen's anonymous ("free tier") endpoint — no credential, or the literal
/// `Authorization: Bearer public` the CLI itself sends — refuses any request it
/// does not believe came from the OpenCode client:
///
/// ```
/// HTTP 403 {"type":"error","error":{"type":"FreeTierError",
///   "message":"Error from provider (Console): OpenCode's free tier can only
///              be used from within OpenCode"}}
/// ```
///
/// ## The gates (all bisected live against
/// `https://opencode.ai/zen/v1/chat/completions`, 2026-10-07)
///
/// Four independent checks, each of which alone produces that 403:
///
/// 1. **`User-Agent`** must be `opencode/<semver>` with `<semver> >= 1.18.0`.
///    A bare `opencode`, a third-party agent, or a version below the floor is
///    refused — below the floor with `426 UpgradeRequired`, otherwise `403`.
/// 2. **`x-opencode-session`** must match `/^ses_[0-9a-f]{12}[0-9A-Za-z]{14}$/`.
///    Missing, a UUID, or the wrong length is refused with `403`.
/// 3. **`tools`** must declare both `bash` and `read`. Matching is
///    case-sensitive, so Claude Code's `Bash`/`Read` do **not** satisfy it, and
///    a request with 0–1 tools, or with either name absent, is refused with
///    `403`. Extra and unknown tool names are allowed.
/// 4. **`stream`** must be `true`. `"stream": false` is refused with `403`.
///
/// Gates 3 and 4 are why a header alone is not enough: conforming the *body* is
/// mandatory, and both conformance steps are visible to the model. The shim
/// therefore also owns the way back — `stripSyntheticToolCalls` and
/// `StreamFilter` delete any call to a tool the caller never offered, and
/// `aggregate` folds the forced SSE stream back into one JSON body for a
/// non-streaming client.
///
/// A configured API key routes to the paid path, which enforces none of this;
/// `applies(providerId:baseUrl:apiKey:)` returns false there and the request is
/// left untouched.
enum OpenCodeZenShim {

    // MARK: - Constants

    /// The `User-Agent` the shim presents. Zen's floor is 1.18.0; this tracks the
    /// current v2-era CLI build (1.18.35 on `dev`) comfortably above it. A caller
    /// that already sends a *newer* conforming agent keeps it
    /// (see `userAgent(existing:)`).
    static let defaultUserAgent = "opencode/1.18.35"

    /// Zen refuses anything older with `426 UpgradeRequired`.
    static let minimumVersion: (major: Int, minor: Int, patch: Int) = (1, 18, 0)

    /// The two names gate 3 demands. Lowercase, exactly as the CLI's own tool
    /// set spells them.
    static let syntheticToolNames: Set<String> = ["bash", "read"]

    // MARK: - Applicability

    /// True for the Zen presets and for any custom provider whose base URL
    /// points at opencode.ai.
    static func isZenEndpoint(providerId: String, baseUrl: String) -> Bool {
        providerId.hasPrefix("opencode") || baseUrl.contains("opencode.ai")
    }

    /// True when the request will travel the anonymous free tier. An empty key
    /// and the literal `public` are the same thing to the gateway (the CLI
    /// sends `apiKey: "public"` when it has no credential).
    static func isAnonymous(apiKey: String) -> Bool {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty || key == "public"
    }

    /// The single predicate every call site should use: is this a Zen free-tier
    /// request that needs the client fingerprint?
    static func applies(providerId: String, baseUrl: String, apiKey: String) -> Bool {
        isZenEndpoint(providerId: providerId, baseUrl: baseUrl) && isAnonymous(apiKey: apiKey)
    }

    // MARK: - Session identity

    private static let base62: [Character] =
        Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
    private static let lowercaseHex: [Character] = Array("0123456789abcdef")

    private static let lock = NSLock()
    private static var sessionByOrigin: [String: String] = [:]

    /// A conforming `ses_` id. The 12 hex characters are the current epoch
    /// milliseconds — the "descending" time prefix the gateway expects — and
    /// the 14 base62 characters are random.
    static func makeSessionId(now: Date = Date()) -> String {
        let millis = UInt64(max(0, now.timeIntervalSince1970) * 1000) & 0xFFFF_FFFF_FFFF
        var hex = String(millis, radix: 16)
        while hex.count < 12 { hex = "0" + hex }
        hex = String(hex.suffix(12))
        let suffix = String((0..<14).map { _ in base62[Int.random(in: 0..<base62.count)] })
        return "ses_\(hex)\(suffix)"
    }

    /// The exact shape the gateway accepts. Written out by hand rather than as
    /// a regex so the rule is auditable in one place.
    static func isValidSessionId(_ value: String) -> Bool {
        let prefix = "ses_"
        guard value.hasPrefix(prefix) else { return false }
        let body = Array(value.dropFirst(prefix.count))
        guard body.count == 26 else { return false }
        for (index, character) in body.enumerated() {
            if index < 12 {
                guard lowercaseHex.contains(character) else { return false }
            } else {
                guard base62.contains(character) else { return false }
            }
        }
        return true
    }

    /// One session id per origin, kept for the life of the process. The gateway
    /// only checks the *shape*, but a stable id is what gives the upstream's
    /// sticky provider routing its prompt-cache affinity — the real CLI uses one
    /// id per session for exactly this reason.
    static func sessionId(for origin: String) -> String {
        lock.lock(); defer { lock.unlock() }
        if let existing = sessionByOrigin[origin] { return existing }
        let created = makeSessionId()
        sessionByOrigin[origin] = created
        return created
    }

    /// Test hook: forget every cached session id.
    static func resetSessions() {
        lock.lock(); defer { lock.unlock() }
        sessionByOrigin.removeAll()
    }

    /// A per-request id. Not gated by Zen, but the CLI sends one and the
    /// gateway logs it.
    static func makeRequestId() -> String {
        "msg_" + String((0..<24).map { _ in lowercaseHex[Int.random(in: 0..<16)] })
    }

    // MARK: - User-Agent

    /// Parses `opencode/<major>.<minor>[.<patch>]`, case-insensitively.
    static func version(fromUserAgent value: String) -> (major: Int, minor: Int, patch: Int)? {
        let parts = value.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].lowercased() == "opencode" else { return nil }
        let numbers = parts[1].split(separator: ".")
        guard numbers.count >= 2 else { return nil }
        guard let major = Int(numbers[0]), let minor = Int(numbers[1]) else { return nil }
        let patch = numbers.count >= 3 ? (Int(numbers[2].prefix(while: { $0.isNumber })) ?? 0) : 0
        return (major, minor, patch)
    }

    static func meetsFloor(_ version: (major: Int, minor: Int, patch: Int)) -> Bool {
        if version.major != minimumVersion.major { return version.major > minimumVersion.major }
        if version.minor != minimumVersion.minor { return version.minor > minimumVersion.minor }
        return version.patch >= minimumVersion.patch
    }

    /// Keep a caller-supplied agent only when it already passes the floor —
    /// presenting the newest identity available is the point of the shim.
    static func userAgent(existing: String?) -> String {
        guard let existing,
              let version = version(fromUserAgent: existing),
              meetsFloor(version) else { return defaultUserAgent }
        return existing
    }

    // MARK: - Headers

    /// The full client fingerprint, as a dictionary fragment.
    static func fingerprint(origin: String, hasKey: Bool, existingUserAgent: String?) -> [String: String] {
        let session = sessionId(for: origin)
        var headers: [String: String] = [
            "User-Agent": userAgent(existing: existingUserAgent),
            "x-opencode-session": session,
            "x-opencode-session-id": session,
            "x-opencode-request": makeRequestId(),
            "x-opencode-client": "cli",
            // v2-era CLI also stamps these two with the session id. They are not
            // gating (the gateway passes without them), but mirroring the client
            // we imitate keeps the fingerprint faithful to OpenCode v2.
            "x-session-affinity": session,
            "X-Session-Id": session,
        ]
        // The CLI presents `Bearer public` when it holds no credential. Zen
        // treats an absent header and `public` identically; sending it matches
        // the client we are imitating and makes the tier explicit in logs.
        if !hasKey { headers["Authorization"] = "Bearer public" }
        return headers
    }

    static func apply(to headers: inout [String: String], origin: String, hasKey: Bool) {
        let fingerprint = fingerprint(origin: origin, hasKey: hasKey,
                                      existingUserAgent: headers["User-Agent"])
        for (key, value) in fingerprint { headers[key] = value }
    }

    static func apply(to request: inout URLRequest, origin: String, hasKey: Bool) {
        let fingerprint = fingerprint(origin: origin, hasKey: hasKey,
                                      existingUserAgent: request.value(forHTTPHeaderField: "User-Agent"))
        for (key, value) in fingerprint { request.setValue(value, forHTTPHeaderField: key) }
    }

    // MARK: - Body conformance (gates 3 and 4)

    /// The declaration the gate looks for. Deliberately schema-less and
    /// undescribed: the gateway matches the *name* only, and a tool with no
    /// description and no parameters is the least likely thing for a model to
    /// call — which matters, because the model does see this.
    static func syntheticDeclaration(name: String) -> [String: Any] {
        ["type": "function",
         "function": ["name": name,
                      "parameters": ["type": "object", "properties": [String: Any]()]]]
    }

    /// Satisfies gates 3 and 4 on an OpenAI-shaped body.
    ///
    /// Returns `true` when `stream` had to be forced on — i.e. the caller asked
    /// for a non-streaming answer and the caller must now fold the SSE reply
    /// back into one JSON body (`aggregate`).
    @discardableResult
    static func conform(body: inout [String: Any]) -> Bool {
        var tools = (body["tools"] as? [[String: Any]]) ?? []
        var present: Set<String> = []
        for tool in tools {
            if let name = (tool["function"] as? [String: Any])?["name"] as? String {
                present.insert(name)
            }
        }
        for name in syntheticToolNames.sorted() where !present.contains(name) {
            tools.append(syntheticDeclaration(name: name))
        }
        body["tools"] = tools

        let wasStreaming = (body["stream"] as? Bool) ?? false
        body["stream"] = true
        return !wasStreaming
    }

    /// Names the shim declared that the caller did not. A call to one of these
    /// is an artefact of the shim and must never reach the client.
    static func syntheticNamesNotOffered(by offered: Set<String>) -> Set<String> {
        syntheticToolNames.subtracting(offered)
    }

    /// Tool names present in an OpenAI-shaped `tools` array.
    static func toolNames(inOpenAITools tools: Any?) -> Set<String> {
        var names: Set<String> = []
        for tool in (tools as? [[String: Any]]) ?? [] {
            if let name = (tool["function"] as? [String: Any])?["name"] as? String {
                names.insert(name)
            }
        }
        return names
    }

    // MARK: - Response de-conformance

    /// Removes calls to the shim's own tools from a complete `chat.completion`
    /// body. A turn whose only calls were synthetic is not a tool turn, so its
    /// `finish_reason` drops back to `stop`.
    static func stripSyntheticToolCalls(fromBody body: Data, offered: Set<String>) -> Data {
        let blocked = syntheticNamesNotOffered(by: offered)
        guard !blocked.isEmpty,
              var root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              var choices = root["choices"] as? [[String: Any]] else { return body }

        var changed = false
        for index in choices.indices {
            guard var message = choices[index]["message"] as? [String: Any],
                  let calls = message["tool_calls"] as? [[String: Any]] else { continue }
            let kept = calls.filter { call in
                let name = (call["function"] as? [String: Any])?["name"] as? String ?? ""
                return !blocked.contains(name)
            }
            guard kept.count != calls.count else { continue }
            changed = true
            if kept.isEmpty {
                message.removeValue(forKey: "tool_calls")
                if (message["content"] as? String)?.isEmpty ?? true { message["content"] = "" }
                choices[index]["finish_reason"] = "stop"
            } else {
                message["tool_calls"] = kept
            }
            choices[index]["message"] = message
        }

        guard changed else { return body }
        root["choices"] = choices
        return (try? JSONSerialization.data(withJSONObject: root)) ?? body
    }

    /// Filters synthetic tool-call deltas out of an OpenAI SSE chunk *before*
    /// translation.
    ///
    /// A class, not a struct, because a tool call arrives spread across many
    /// chunks — the name in the first delta, the arguments after it — so the
    /// filter has to remember which `index` values it has already condemned.
    /// Lock-guarded for the same reason `AMEEMFirewall` is: the stream pump runs
    /// on its own task.
    final class StreamFilter: @unchecked Sendable {
        private let blocked: Set<String>
        private var droppedIndices: Set<Int> = []
        private var seenIndices: Set<Int> = []
        private let lock = NSLock()

        init(offered: Set<String>) {
            self.blocked = syntheticNamesNotOffered(by: offered)
        }

        var isActive: Bool { !blocked.isEmpty }

        /// Mutates `chunk` in place. Safe to call on a chunk with no tool calls.
        func filter(_ chunk: inout [String: Any]) {
            guard !blocked.isEmpty,
                  var choices = chunk["choices"] as? [[String: Any]] else { return }

            lock.lock(); defer { lock.unlock() }

            var touched = false
            for index in choices.indices {
                var choice = choices[index]

                if var delta = choice["delta"] as? [String: Any],
                   let calls = delta["tool_calls"] as? [[String: Any]], !calls.isEmpty {
                    var kept: [[String: Any]] = []
                    for call in calls {
                        let callIndex = call["index"] as? Int ?? 0
                        seenIndices.insert(callIndex)
                        if droppedIndices.contains(callIndex) { touched = true; continue }
                        let name = (call["function"] as? [String: Any])?["name"] as? String ?? ""
                        if !name.isEmpty, blocked.contains(name) {
                            droppedIndices.insert(callIndex)
                            touched = true
                            continue
                        }
                        kept.append(call)
                    }
                    if kept.count != calls.count {
                        if kept.isEmpty {
                            delta.removeValue(forKey: "tool_calls")
                        } else {
                            delta["tool_calls"] = kept
                        }
                        choice["delta"] = delta
                    }
                }

                // The terminal chunk carries `finish_reason` with an empty
                // delta. If every call in the stream was synthetic, the turn is
                // not a tool turn and must not be reported as one.
                if (choice["finish_reason"] as? String) == "tool_calls",
                   !seenIndices.isEmpty,
                   seenIndices.subtracting(droppedIndices).isEmpty {
                    choice["finish_reason"] = "stop"
                    touched = true
                }

                choices[index] = choice
            }

            if touched { chunk["choices"] = choices }
        }
    }

    /// Wraps a raw OpenAI SSE stream, dropping synthetic tool-call deltas as
    /// they pass. Used by the raw-passthrough path, which relays the upstream
    /// stream to the client verbatim and so has no translation step to hook.
    ///
    /// Line-buffered: a chunk boundary can split an SSE line, and a half-parsed
    /// JSON payload would be relayed corrupted.
    static func filtering(_ input: AsyncStream<Data>, offered: Set<String>) -> AsyncStream<Data> {
        let filter = StreamFilter(offered: offered)
        guard filter.isActive else { return input }

        let (output, continuation) = AsyncStream<Data>.makeStream(of: Data.self)
        Task {
            var buffer = Data()
            for await chunk in input {
                buffer.append(chunk)
                while let range = buffer.range(of: Data("\n".utf8)) {
                    let line = buffer.subdata(in: buffer.startIndex..<range.upperBound)
                    buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                    continuation.yield(rewrite(sseLine: line, filter: filter))
                }
            }
            if !buffer.isEmpty { continuation.yield(rewrite(sseLine: buffer, filter: filter)) }
            continuation.finish()
        }
        return output
    }

    /// Rewrites one SSE line. Non-`data:` lines (comments, `event:`, blank
    /// separators) and unparseable payloads pass through byte-for-byte.
    private static func rewrite(sseLine: Data, filter: StreamFilter) -> Data {
        guard let text = String(data: sseLine, encoding: .utf8) else { return sseLine }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("data:") else { return sseLine }
        var payload = trimmed.dropFirst("data:".count)
        if payload.hasPrefix(" ") { payload = payload.dropFirst() }
        guard payload != "[DONE]",
              var chunk = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any]
        else { return sseLine }

        filter.filter(&chunk)
        guard let encoded = try? JSONSerialization.data(withJSONObject: chunk),
              let encodedText = String(data: encoded, encoding: .utf8) else { return sseLine }
        return Data("data: \(encodedText)\n\n".utf8)
    }

    // MARK: - SSE aggregation (gate 4, for a non-streaming caller)

    /// Folds an OpenAI SSE stream into a single `chat.completion` body.
    ///
    /// Gate 4 forces every Zen free-tier request to stream, so a client that
    /// asked for `stream: false` would otherwise receive an SSE body it cannot
    /// parse. Synthetic calls are filtered on the way through, so the merged
    /// body is exactly what the caller would have got had the tool never been
    /// declared.
    static func aggregate(sseData: Data, model: String, offered: Set<String>) -> Data {
        let filter = StreamFilter(offered: offered)
        var text = ""
        var reasoning = ""
        var calls: [Int: [String: Any]] = [:]
        var callOrder: [Int] = []
        var finishReason = "stop"
        var id = "chatcmpl-jxproxy"
        var created = Int(Date().timeIntervalSince1970)
        var usage: [String: Any]?
        var role = "assistant"

        for line in sseData.split(separator: UInt8(ascii: "\n")) {
            guard var payload = String(data: Data(line), encoding: .utf8) else { continue }
            payload = payload.trimmingCharacters(in: .whitespacesAndNewlines)
            guard payload.hasPrefix("data:") else { continue }
            var json = payload.dropFirst("data:".count)
            if json.hasPrefix(" ") { json = json.dropFirst() }
            if json == "[DONE]" { break }
            guard var chunk = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
            else { continue }

            if filter.isActive { filter.filter(&chunk) }

            if let value = chunk["id"] as? String, !value.isEmpty { id = value }
            if let value = chunk["created"] as? Int { created = value }
            if let value = chunk["usage"] as? [String: Any] { usage = value }
            guard let choices = chunk["choices"] as? [[String: Any]], let first = choices.first
            else { continue }

            if let delta = first["delta"] as? [String: Any] {
                if let value = delta["role"] as? String { role = value }
                if let value = delta["content"] as? String { text += value }
                if let value = delta["reasoning_content"] as? String { reasoning += value }
                for call in (delta["tool_calls"] as? [[String: Any]]) ?? [] {
                    let index = call["index"] as? Int ?? 0
                    if calls[index] == nil {
                        calls[index] = ["id": call["id"] as? String ?? "call_\(index)",
                                        "type": "function",
                                        "function": ["name": "", "arguments": ""]]
                        callOrder.append(index)
                    }
                    guard let function = call["function"] as? [String: Any] else { continue }
                    var merged = calls[index]?["function"] as? [String: Any] ?? [:]
                    if let name = function["name"] as? String, !name.isEmpty { merged["name"] = name }
                    if let arguments = function["arguments"] as? String {
                        merged["arguments"] = ((merged["arguments"] as? String) ?? "") + arguments
                    }
                    calls[index]?["function"] = merged
                }
            }
            if let value = first["finish_reason"] as? String, !value.isEmpty { finishReason = value }
        }

        var message: [String: Any] = ["role": role]
        message["content"] = text.isEmpty && !calls.isEmpty ? NSNull() : text
        if !reasoning.isEmpty { message["reasoning_content"] = reasoning }
        if !calls.isEmpty {
            message["tool_calls"] = callOrder.sorted().compactMap { calls[$0] }
            if finishReason == "stop" { finishReason = "tool_calls" }
        }

        var root: [String: Any] = [
            "id": id,
            "object": "chat.completion",
            "created": created,
            "model": model,
            "choices": [["index": 0, "message": message, "finish_reason": finishReason]],
        ]
        if let usage { root["usage"] = usage }
        return (try? JSONSerialization.data(withJSONObject: root)) ?? Data()
    }
}
