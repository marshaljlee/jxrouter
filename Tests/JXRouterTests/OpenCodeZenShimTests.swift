import XCTest

/// Tests for `OpenCodeZenShim` — the client fingerprint that makes OpenCode
/// Zen's free tier usable from a harness that is not OpenCode itself.
///
/// Every constant pinned here was bisected against the live gateway on
/// 2026-10-07 (`POST https://opencode.ai/zen/v1/chat/completions`). The whole
/// point of the shim is that four *independent* gates each produce the same
/// opaque `403 FreeTierError`, so a regression in any one of them is invisible
/// in production until a user reports "the free models stopped working". These
/// tests make each gate fail loudly instead.
final class OpenCodeZenShimTests: XCTestCase {

    override func setUp() {
        super.setUp()
        OpenCodeZenShim.resetSessions()
    }

    // MARK: - Gate 2: the session id shape

    /// `ses_` + 12 lowercase hex + 14 base62 is the ONLY accepted shape.
    func testSessionIdMatchesTheOnlyShapeZenAccepts() {
        for _ in 0..<200 {
            let id = OpenCodeZenShim.makeSessionId()
            XCTAssertTrue(OpenCodeZenShim.isValidSessionId(id), "rejected: \(id)")
            XCTAssertEqual(id.count, 30, "ses_ + 12 hex + 14 base62")
        }
    }

    /// The shape this app used to send — `ses_` + 24 hex, i.e. a stripped UUID —
    /// is refused by the gateway. Pinned so nobody "simplifies" the generator
    /// back to it.
    func testSessionIdRejectsTheShapeTheAppUsedToSend() {
        let legacy = "ses_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(24)
        XCTAssertFalse(OpenCodeZenShim.isValidSessionId(String(legacy)),
                       "the legacy UUID-derived id is 24 chars, not 26")

        XCTAssertFalse(OpenCodeZenShim.isValidSessionId("ses_" + String(repeating: "A", count: 12) + String(repeating: "b", count: 14)),
                       "the 12-character prefix must be LOWERCASE hex")
        // The split is only observable through the alphabet: a base62-but-not-hex
        // character (Z) sitting inside the first 12 positions proves the prefix
        // rule is enforced, where an all-'a'/'b' string would be legal either way.
        XCTAssertFalse(OpenCodeZenShim.isValidSessionId("ses_" + String(repeating: "a", count: 11) + "Z" + String(repeating: "b", count: 14)),
                       "position 12 must be lowercase hex, not merely base62")
        XCTAssertFalse(OpenCodeZenShim.isValidSessionId("ses_" + String(repeating: "a", count: 12) + String(repeating: "b", count: 13) + "-"),
                       "the 14-character tail must stay inside base62")
        XCTAssertFalse(OpenCodeZenShim.isValidSessionId("ses_" + String(repeating: "a", count: 25)),
                       "25 characters is one short")
        XCTAssertFalse(OpenCodeZenShim.isValidSessionId("ses" + String(repeating: "a", count: 27)),
                       "missing the underscore")
        XCTAssertFalse(OpenCodeZenShim.isValidSessionId(""))
    }

    /// One id per origin, reused — that is what gives the upstream's sticky
    /// provider routing its prompt-cache affinity.
    func testSessionIdIsStablePerOriginAndDistinctAcrossOrigins() {
        let first = OpenCodeZenShim.sessionId(for: "https://opencode.ai/zen/v1")
        let again = OpenCodeZenShim.sessionId(for: "https://opencode.ai/zen/v1")
        let other = OpenCodeZenShim.sessionId(for: "https://opencode.ai/zen/go/v1")
        XCTAssertEqual(first, again)
        XCTAssertNotEqual(first, other)
        XCTAssertTrue(OpenCodeZenShim.isValidSessionId(first))
        XCTAssertTrue(OpenCodeZenShim.isValidSessionId(other))
    }

    // MARK: - Gate 1: the User-Agent floor

    func testUserAgentFloorIsOneEighteenZero() {
        XCTAssertNotNil(OpenCodeZenShim.version(fromUserAgent: "opencode/1.18.31"))
        XCTAssertNotNil(OpenCodeZenShim.version(fromUserAgent: "OpenCode/1.18.31"))
        XCTAssertNil(OpenCodeZenShim.version(fromUserAgent: "opencode"))
        XCTAssertNil(OpenCodeZenShim.version(fromUserAgent: "claude-cli/2.0.0"))
        XCTAssertNil(OpenCodeZenShim.version(fromUserAgent: "opencode/1"))

        XCTAssertTrue(OpenCodeZenShim.meetsFloor((1, 18, 0)))
        XCTAssertTrue(OpenCodeZenShim.meetsFloor((1, 18, 31)))
        XCTAssertTrue(OpenCodeZenShim.meetsFloor((2, 0, 0)))
        XCTAssertFalse(OpenCodeZenShim.meetsFloor((1, 17, 99)),
                       "1.17.x answers 426 UpgradeRequired, not 403 — still refused")
    }

    /// A caller that already presents a conforming, newer agent keeps it; a bare
    /// or foreign one is replaced. Both matter: gate 1 refuses `opencode` with
    /// no version and any third-party agent.
    func testUserAgentIsUpgradedUnlessTheCallerAlreadyConforms() {
        XCTAssertEqual(OpenCodeZenShim.userAgent(existing: nil), OpenCodeZenShim.defaultUserAgent)
        XCTAssertEqual(OpenCodeZenShim.userAgent(existing: "opencode"), OpenCodeZenShim.defaultUserAgent)
        XCTAssertEqual(OpenCodeZenShim.userAgent(existing: "9router/1.0"), OpenCodeZenShim.defaultUserAgent)
        XCTAssertEqual(OpenCodeZenShim.userAgent(existing: "opencode/1.17.0"), OpenCodeZenShim.defaultUserAgent)
        XCTAssertEqual(OpenCodeZenShim.userAgent(existing: "opencode/1.19.0"), "opencode/1.19.0")
    }

    // MARK: - Applicability

    /// A configured key is the paid path, which enforces none of these gates —
    /// rewriting its body would be a bug, not a fix.
    func testShimAppliesOnlyToTheAnonymousZenTier() {
        XCTAssertTrue(OpenCodeZenShim.applies(providerId: "opencode-zen", baseUrl: "https://opencode.ai/zen/v1", apiKey: ""))
        XCTAssertTrue(OpenCodeZenShim.applies(providerId: "opencode-go", baseUrl: "https://opencode.ai/zen/go/v1", apiKey: "public"))
        XCTAssertTrue(OpenCodeZenShim.applies(providerId: "custom-zen", baseUrl: "https://opencode.ai/zen/v1", apiKey: ""))
        XCTAssertFalse(OpenCodeZenShim.applies(providerId: "opencode-zen", baseUrl: "https://opencode.ai/zen/v1", apiKey: "sk-real"),
                       "a real key means the paid path — leave the request alone")
        XCTAssertFalse(OpenCodeZenShim.applies(providerId: "direct", baseUrl: "https://api.anthropic.com/v1", apiKey: ""))
        XCTAssertFalse(OpenCodeZenShim.applies(providerId: "nvidia-nim", baseUrl: "https://integrate.api.nvidia.com/v1", apiKey: ""))
    }

    /// The fingerprint carries the two headers the gateway reads for routing
    /// and logging, plus `Bearer public` only when there is no key.
    func testFingerprintCarriesTheClientIdentity() {
        let headers = OpenCodeZenShim.fingerprint(origin: "https://opencode.ai/zen/v1",
                                                  hasKey: false,
                                                  existingUserAgent: nil)
        XCTAssertEqual(headers["User-Agent"], OpenCodeZenShim.defaultUserAgent)
        XCTAssertEqual(headers["x-opencode-client"], "cli")
        XCTAssertEqual(headers["Authorization"], "Bearer public")
        XCTAssertTrue(OpenCodeZenShim.isValidSessionId(headers["x-opencode-session"] ?? ""))
        XCTAssertEqual(headers["x-opencode-session-id"], headers["x-opencode-session"])
        XCTAssertNotNil(headers["x-opencode-request"])

        let keyed = OpenCodeZenShim.fingerprint(origin: "https://opencode.ai/zen/v1",
                                                hasKey: true,
                                                existingUserAgent: nil)
        XCTAssertNil(keyed["Authorization"], "a configured key must not be overwritten")
    }

    // MARK: - Gates 3 and 4: body conformance

    /// Claude Code sends `Bash`/`Read`. The gate is case-sensitive, so those do
    /// NOT count and the lowercase declarations must be added alongside them —
    /// the caller's own tools survive verbatim.
    func testConformAddsLowercaseDeclarationsWithoutTouchingTheCallersTools() {
        var body: [String: Any] = [
            "model": "big-pickle",
            "tools": [["type": "function", "function": ["name": "Bash"]],
                      ["type": "function", "function": ["name": "Read"]]],
        ]
        OpenCodeZenShim.conform(body: &body)

        let names = OpenCodeZenShim.toolNames(inOpenAITools: body["tools"])
        XCTAssertTrue(names.contains("Bash"), "the caller's tool must survive")
        XCTAssertTrue(names.contains("Read"))
        XCTAssertTrue(names.contains("bash"), "lowercase bash is what the gate matches")
        XCTAssertTrue(names.contains("read"))
    }

    func testConformForcesStreamingAndReportsIt() {
        var nonStreaming: [String: Any] = ["model": "big-pickle", "stream": false]
        XCTAssertTrue(OpenCodeZenShim.conform(body: &nonStreaming),
                      "a forced stream must be reported so the caller can re-aggregate")
        XCTAssertEqual(nonStreaming["stream"] as? Bool, true)

        var streaming: [String: Any] = ["model": "big-pickle", "stream": true]
        XCTAssertFalse(OpenCodeZenShim.conform(body: &streaming))
        XCTAssertEqual(streaming["stream"] as? Bool, true)
    }

    func testConformDoesNotDuplicateDeclarationsItAlreadyAdded() {
        var body: [String: Any] = ["model": "big-pickle",
                                   "tools": [OpenCodeZenShim.syntheticDeclaration(name: "bash"),
                                             OpenCodeZenShim.syntheticDeclaration(name: "read")]]
        OpenCodeZenShim.conform(body: &body)
        OpenCodeZenShim.conform(body: &body)
        let tools = (body["tools"] as? [[String: Any]]) ?? []
        XCTAssertEqual(tools.count, 2, "conform is idempotent")
    }

    /// A body with no `tools` key at all still has to satisfy the gate.
    func testConformWorksWithoutAPreExistingToolsArray() {
        var body: [String: Any] = ["model": "big-pickle", "messages": [[String: Any]]()]
        OpenCodeZenShim.conform(body: &body)
        let names = OpenCodeZenShim.toolNames(inOpenAITools: body["tools"])
        XCTAssertEqual(names, OpenCodeZenShim.syntheticToolNames)
    }

    // MARK: - Undoing the conformance

    /// A caller's real tool call must survive; the shim's own must not.
    func testStripSyntheticToolCallsKeepsCallerCallsAndDropsItsOwn() {
        let response: [String: Any] = [
            "choices": [[
                "index": 0,
                "message": ["role": "assistant",
                            "tool_calls": [
                                ["id": "call_1", "type": "function",
                                 "function": ["name": "bash", "arguments": "{}"]],
                                ["id": "call_2", "type": "function",
                                 "function": ["name": "Bash", "arguments": "{\"command\":\"ls\"}"]]],
                            "content": NSNull()],
                "finish_reason": "tool_calls",
            ]],
        ]
        let data = try! JSONSerialization.data(withJSONObject: response)
        let stripped = OpenCodeZenShim.stripSyntheticToolCalls(fromBody: data, offered: ["Bash"])
        let root = try! JSONSerialization.jsonObject(with: stripped) as! [String: Any]
        let choice = (root["choices"] as! [[String: Any]])[0]
        let message = choice["message"] as! [String: Any]
        let calls = message["tool_calls"] as! [[String: Any]]

        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual((calls[0]["function"] as! [String: Any])["name"] as? String, "Bash")
        XCTAssertEqual(choice["finish_reason"] as? String, "tool_calls",
                       "a real call is still a tool turn")
    }

    /// When nothing but synthetic calls remains, the turn is not a tool turn and
    /// must be reported as `stop` — otherwise an agent harness waits forever for
    /// a tool it never declared.
    func testStripSyntheticToolCallsRewritesFinishReasonWhenNothingRemains() {
        let response: [String: Any] = [
            "choices": [[
                "index": 0,
                "message": ["role": "assistant", "content": "",
                            "tool_calls": [["id": "call_1", "type": "function",
                                            "function": ["name": "bash", "arguments": "{}"]]]],
                "finish_reason": "tool_calls",
            ]],
        ]
        let data = try! JSONSerialization.data(withJSONObject: response)
        let stripped = OpenCodeZenShim.stripSyntheticToolCalls(fromBody: data, offered: [])
        let root = try! JSONSerialization.jsonObject(with: stripped) as! [String: Any]
        let choice = (root["choices"] as! [[String: Any]])[0]
        XCTAssertNil((choice["message"] as! [String: Any])["tool_calls"])
        XCTAssertEqual(choice["finish_reason"] as? String, "stop")
    }

    /// A caller that genuinely offered `bash` keeps its own calls — the shim
    /// only removes what it invented.
    func testStripIsANoOpWhenTheCallerOfferedTheNamesItself() {
        let response: [String: Any] = [
            "choices": [[
                "index": 0,
                "message": ["role": "assistant",
                            "tool_calls": [["id": "call_1", "type": "function",
                                            "function": ["name": "bash", "arguments": "{}"]]],
                            "content": NSNull()],
                "finish_reason": "tool_calls",
            ]],
        ]
        let data = try! JSONSerialization.data(withJSONObject: response)
        let stripped = OpenCodeZenShim.stripSyntheticToolCalls(fromBody: data, offered: ["bash", "read"])
        XCTAssertEqual(stripped, data, "offered names must not be filtered")
    }

    // MARK: - Streaming filter

    /// A tool call streams in pieces: the name in one delta, the arguments in
    /// the next. Both must go, and a caller's own call must stay.
    func testStreamFilterDropsTheNameAndEveryFollowingArgumentDelta() {
        let filter = OpenCodeZenShim.StreamFilter(offered: ["Bash"])

        var opening: [String: Any] = ["choices": [[
            "index": 0,
            "delta": ["tool_calls": [
                ["index": 0, "id": "call_1", "type": "function", "function": ["name": "bash"]],
                ["index": 1, "id": "call_2", "type": "function", "function": ["name": "Bash"]],
            ]],
            "finish_reason": NSNull(),
        ]]]
        filter.filter(&opening)
        let openingCalls = (((opening["choices"] as! [[String: Any]])[0]["delta"] as! [String: Any])["tool_calls"] as! [[String: Any]])
        XCTAssertEqual(openingCalls.count, 1, "the synthetic opening delta is dropped")
        XCTAssertEqual((openingCalls[0]["function"] as! [String: Any])["name"] as? String, "Bash")

        var arguments: [String: Any] = ["choices": [[
            "index": 0,
            "delta": ["tool_calls": [["index": 0, "function": ["arguments": "{\"command\":\"rm -rf /\"}"]]]],
            "finish_reason": NSNull(),
        ]]]
        filter.filter(&arguments)
        let delta = (arguments["choices"] as! [[String: Any]])[0]["delta"] as! [String: Any]
        XCTAssertNil(delta["tool_calls"],
                     "index 0 was condemned by name — its arguments must not leak either")

        var terminal: [String: Any] = ["choices": [[
            "index": 0, "delta": [String: Any](), "finish_reason": "tool_calls",
        ]]]
        filter.filter(&terminal)
        XCTAssertEqual((terminal["choices"] as! [[String: Any]])[0]["finish_reason"] as? String, "tool_calls",
                       "index 1 is the caller's own call, so this is still a tool turn")
    }

    /// The mirror case: when every call in the stream was the shim's own, the
    /// turn is not a tool turn and must not be reported as one — otherwise an
    /// agent harness waits for a tool it never declared.
    func testStreamFilterReportsStopWhenEveryCallWasSynthetic() {
        let filter = OpenCodeZenShim.StreamFilter(offered: [])

        var opening: [String: Any] = ["choices": [[
            "index": 0,
            "delta": ["tool_calls": [["index": 0, "id": "call_1", "type": "function",
                                      "function": ["name": "bash"]]]],
            "finish_reason": NSNull(),
        ]]]
        filter.filter(&opening)
        let delta = (opening["choices"] as! [[String: Any]])[0]["delta"] as! [String: Any]
        XCTAssertNil(delta["tool_calls"])

        var terminal: [String: Any] = ["choices": [[
            "index": 0, "delta": [String: Any](), "finish_reason": "tool_calls",
        ]]]
        filter.filter(&terminal)
        XCTAssertEqual((terminal["choices"] as! [[String: Any]])[0]["finish_reason"] as? String, "stop")
    }

    // MARK: - SSE aggregation (gate 4, for a non-streaming caller)

    private func sseChunk(_ json: [String: Any]) -> Data {
        Data(("data: " + String(data: try! JSONSerialization.data(withJSONObject: json), encoding: .utf8)! + "\n\n").utf8)
    }

    func testAggregateFoldsSSEIntoASingleCompletion() {
        var sse = Data()
        sse.append(sseChunk(["id": "chatcmpl-1", "created": 42, "model": "big-pickle",
                             "choices": [["index": 0, "delta": ["role": "assistant", "content": ""], "finish_reason": NSNull()]]]))
        sse.append(sseChunk(["id": "chatcmpl-1",
                             "choices": [["index": 0, "delta": ["content": "ok"], "finish_reason": NSNull()]]]))
        sse.append(sseChunk(["id": "chatcmpl-1",
                             "choices": [["index": 0, "delta": [String: Any](), "finish_reason": "stop"]],
                             "usage": ["prompt_tokens": 3, "completion_tokens": 1, "total_tokens": 4]]))
        sse.append(Data("data: [DONE]\n\n".utf8))

        let body = OpenCodeZenShim.aggregate(sseData: sse, model: "big-pickle", offered: [])
        let root = try! JSONSerialization.jsonObject(with: body) as! [String: Any]
        XCTAssertEqual(root["object"] as? String, "chat.completion")
        XCTAssertEqual(root["id"] as? String, "chatcmpl-1")
        XCTAssertEqual(root["created"] as? Int, 42)
        let choice = (root["choices"] as! [[String: Any]])[0]
        XCTAssertEqual((choice["message"] as! [String: Any])["content"] as? String, "ok")
        XCTAssertEqual(choice["finish_reason"] as? String, "stop")
        XCTAssertEqual((root["usage"] as! [String: Any])["total_tokens"] as? Int, 4)
    }

    /// The forced stream must not smuggle a synthetic call back to the caller.
    func testAggregateDropsASyntheticToolCallTheClientNeverOffered() {
        var sse = Data()
        sse.append(sseChunk(["id": "chatcmpl-2",
                             "choices": [["index": 0,
                                          "delta": ["tool_calls": [["index": 0, "id": "call_1", "type": "function",
                                                                    "function": ["name": "bash"]]]],
                                          "finish_reason": NSNull()]]]))
        sse.append(sseChunk(["id": "chatcmpl-2",
                             "choices": [["index": 0,
                                          "delta": ["tool_calls": [["index": 0, "function": ["arguments": "{\"command\":\"ls\"}"]]]],
                                          "finish_reason": NSNull()]]]))
        sse.append(sseChunk(["id": "chatcmpl-2",
                             "choices": [["index": 0, "delta": [String: Any](), "finish_reason": "tool_calls"]]]))
        sse.append(Data("data: [DONE]\n\n".utf8))

        let body = OpenCodeZenShim.aggregate(sseData: sse, model: "big-pickle", offered: [])
        let root = try! JSONSerialization.jsonObject(with: body) as! [String: Any]
        let choice = (root["choices"] as! [[String: Any]])[0]
        XCTAssertNil((choice["message"] as! [String: Any])["tool_calls"])
        XCTAssertEqual(choice["finish_reason"] as? String, "stop")
    }

    /// A caller that really did offer `bash` gets its call back, assembled from
    /// the deltas.
    func testAggregateRebuildsACallTheCallerDidOffer() {
        var sse = Data()
        sse.append(sseChunk(["id": "chatcmpl-3",
                             "choices": [["index": 0,
                                          "delta": ["tool_calls": [["index": 0, "id": "call_9", "type": "function",
                                                                    "function": ["name": "bash", "arguments": ""]]]],
                                          "finish_reason": NSNull()]]]))
        sse.append(sseChunk(["id": "chatcmpl-3",
                             "choices": [["index": 0,
                                          "delta": ["tool_calls": [["index": 0, "function": ["arguments": "{\"command\":\"pwd\"}"]]]],
                                          "finish_reason": NSNull()]]]))
        sse.append(sseChunk(["id": "chatcmpl-3",
                             "choices": [["index": 0, "delta": [String: Any](), "finish_reason": "tool_calls"]]]))

        let body = OpenCodeZenShim.aggregate(sseData: sse, model: "big-pickle", offered: ["bash"])
        let root = try! JSONSerialization.jsonObject(with: body) as! [String: Any]
        let choice = (root["choices"] as! [[String: Any]])[0]
        let calls = (choice["message"] as! [String: Any])["tool_calls"] as! [[String: Any]]
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0]["id"] as? String, "call_9")
        XCTAssertEqual((calls[0]["function"] as! [String: Any])["arguments"] as? String, "{\"command\":\"pwd\"}")
        XCTAssertEqual(choice["finish_reason"] as? String, "tool_calls")
    }
}
