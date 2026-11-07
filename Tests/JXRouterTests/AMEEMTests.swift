import XCTest
@testable import JXRouter

/// AMEEM v3.0 verification. Every guardrail asserted here was executed against
/// a real input and the observed result checked (I3) — none of these are
/// described-but-untested.
final class AMEEMTests: XCTestCase {

    // MARK: - G-04 sampler band

    func testTemperatureClampRaisesTheGreedyBand() {
        for requested in [0.05, 0.10, 0.20, 0.25] {
            let result = AMEEMSamplerPolicy.clampTemperature(requested)
            XCTAssertEqual(result.value, 0.50, "T=\(requested) must be raised to the 0.50 floor")
            XCTAssertTrue(result.overridden)
            XCTAssertNotNil(result.note)
        }
    }

    func testTemperatureClampLowersTheFormatLossBand() {
        let result = AMEEMSamplerPolicy.clampTemperature(0.95)
        XCTAssertEqual(result.value, 0.75)
        XCTAssertTrue(result.overridden)
    }

    func testTemperatureInsideTheBandIsUntouched() {
        let result = AMEEMSamplerPolicy.clampTemperature(0.60)
        XCTAssertEqual(result.value, 0.60)
        XCTAssertFalse(result.overridden, "the one working configuration must not be overwritten (C-20)")
        XCTAssertNil(result.note)
    }

    func testMissingTemperatureGetsTheDefault() {
        XCTAssertEqual(AMEEMSamplerPolicy.clampTemperature(nil).value, 0.60)
        XCTAssertFalse(AMEEMSamplerPolicy.clampTemperature(nil).overridden)
    }

    func testRequiredSamplersAreAllSet() {
        let samplers = AMEEMSamplerPolicy.requiredSamplers()
        XCTAssertEqual(samplers["top_p"], 0.95)
        XCTAssertEqual(samplers["top_k"], 20)
        XCTAssertEqual(samplers["min_p"], 0.02)
        XCTAssertEqual(samplers["repeat_penalty"], 1.05)
    }

    // MARK: - I1 / G-14 tier is derived, never named

    func testTierIsDerivedFromParameterCount() {
        XCTAssertEqual(AMEEMTiers.tier(nParams: 800_000_000), .micro)
        XCTAssertEqual(AMEEMTiers.tier(nParams: 2_000_000_000), .micro)
        XCTAssertEqual(AMEEMTiers.tier(nParams: 4_000_000_000), .mid)
        XCTAssertEqual(AMEEMTiers.tier(nParams: 9_000_000_000), .mid)
        XCTAssertEqual(AMEEMTiers.tier(nParams: 13_900_000_000), .mid)
        XCTAssertEqual(AMEEMTiers.tier(nParams: 14_000_000_000), .macro)
    }

    /// The exact collision shape from C-07: a 27B dense model whose filename
    /// carries "27B" (which contains "7b") and a modifier token. A name-keyed
    /// classifier places it in MID; the measured count must place it in MACRO.
    func testTwentySevenBillionIsMacroNotMid() {
        XCTAssertEqual(AMEEMTiers.tier(nParams: 27_000_000_000), .macro)
    }

    /// `0.8b` contains `8b`, so a substring classifier hands a sub-1B model a
    /// mid-tier budget. Measured: MICRO.
    func testSubOneBillionIsMicroNotMid() {
        XCTAssertEqual(AMEEMTiers.tier(nParams: 800_000_000), .micro)
    }

    func testUnmeasurableParametersAreNotGuessedIntoATier() {
        XCTAssertNil(AMEEMTiers.tier(nParams: 0), "an unverifiable profile is degraded, not guessed (G-18)")
    }

    func testTierOutputBudgets() {
        XCTAssertEqual(AMEEMTiers.maxTokens(for: .micro), 1024)
        XCTAssertEqual(AMEEMTiers.maxTokens(for: .mid), 2048)
        XCTAssertEqual(AMEEMTiers.maxTokens(for: .macro), 4096)
    }

    // MARK: - G-13 terminal tools

    func testTerminalToolDetection() {
        let offered: Set<String> = ["read_file", "write_file", "finish", "submit"]
        let terminal = AMEEMTools.terminalTools(offered: offered)
        XCTAssertEqual(terminal, ["finish", "submit"])
    }

    func testTerminalToolDetectionIsCaseInsensitive() {
        XCTAssertEqual(AMEEMTools.terminalTools(offered: ["Task_Complete"]), ["Task_Complete"])
    }

    func testNoTerminalToolMeansNoTerminalTool() {
        XCTAssertTrue(AMEEMTools.terminalTools(offered: ["read_file", "grep"]).isEmpty)
    }

    // MARK: - Completion claims (C-16)

    func testCompletionClaimsAreDetected() {
        let claims = [
            "I have created the file.",
            "I've now written the patch.",
            "The task is complete.",
            "Successfully created the directory.",
            "The file has been saved.",
            "All done",
        ]
        for claim in claims {
            XCTAssertTrue(AMEEMClaims.hasCompletionClaim(claim), "missed: \(claim)")
        }
    }

    func testNonClaimsDoNotFire() {
        XCTAssertFalse(AMEEMClaims.hasCompletionClaim("Let me read the file first."))
        XCTAssertFalse(AMEEMClaims.hasCompletionClaim("I will create the file."))
    }

    // MARK: - G-02 dialect detection

    private let taggedNameTemplate = #"To call a tool, use <function name="get_weather"><param name="city">Paris</param></function>"#
    private let taggedEqTemplate = #"<tool_call><function=get_weather><parameter=city>Paris</parameter></function></tool_call>"#
    private let tagJsonTemplate = #"<function=get_weather>{"arguments": {"city": "Paris"}}</function>"#
    private let jsonNativeTemplate = #"{"name": "get_weather", "arguments": {"city": "Paris"}}"#

    func testDialectDetectionSeparatesBothXmlDialects() {
        XCTAssertEqual(AMEEMRecovery.detectDialect(renderedPrompt: taggedNameTemplate), .tagTaggedName)
        XCTAssertEqual(AMEEMRecovery.detectDialect(renderedPrompt: taggedEqTemplate), .tagTaggedEq)
        XCTAssertEqual(AMEEMRecovery.detectDialect(renderedPrompt: tagJsonTemplate), .tagJSON)
        XCTAssertEqual(AMEEMRecovery.detectDialect(renderedPrompt: jsonNativeTemplate), .jsonNative)
    }

    func testDialectIsEmptyForATemplateWithNoTools() {
        XCTAssertNil(AMEEMRecovery.detectDialect(renderedPrompt: "You are a helpful assistant."))
        XCTAssertNil(AMEEMRecovery.detectDialect(renderedPrompt: ""))
    }

    /// The real Bonsai template teaches
    /// `<function=f><parameter=k>v</parameter></function>` **and** embeds the
    /// tool schema as JSON, so a global `"parameters"` substring test classifies
    /// it as JSON — and recovery then runs `json.loads` over
    /// `<parameter=k>v</parameter>`, fails, and drops every call. The dialect
    /// must come from the example the template actually teaches.
    func testDialectIgnoresAJsonSchemaElsewhereInThePrompt() {
        let prompt = """
        <tools>
        {"type":"function","function":{"name":"read_file","parameters":{"type":"object"}}}
        </tools>

        If you choose to call a function ONLY reply in the following format:
        <tool_call>
        <function=example_function_name>
        <parameter=example_parameter_1>
        value_1
        </parameter>
        </function>
        </tool_call>
        """
        XCTAssertEqual(AMEEMRecovery.detectDialect(renderedPrompt: prompt), .tagTaggedEq,
                       "the taught example is XML, not JSON, however the schema is embedded")
        // And recovery must actually work on the dialect it teaches.
        let content = "<function=read_file><parameter=path>/tmp/x</parameter></function>"
        let calls = AMEEMRecovery.recoverToolCalls(
            content: content, dialect: .tagTaggedEq, offeredTools: ["read_file"])
        XCTAssertEqual(calls.count, 1, "the call this template teaches must be recoverable")
    }

    func testDialectIsTagJsonWhenTheTaughtBodyIsJson() {
        let prompt = #"<tool_call><function=read_file>{"path": "/tmp/x"}</function></tool_call>"#
        XCTAssertEqual(AMEEMRecovery.detectDialect(renderedPrompt: prompt), .tagJSON)
        let calls = AMEEMRecovery.recoverToolCalls(
            content: #"<function=read_file>{"path": "/tmp/x"}</function>"#,
            dialect: .tagJSON, offeredTools: ["read_file"])
        XCTAssertEqual(calls.count, 1)
    }

    // MARK: - G-06 / G-08 recovery

    func testRecoveryConvertsTagTaggedNameCall() {
        let content = #"Sure. <function name="get_weather"><param name="city">Paris</param></function>"#
        let calls = AMEEMRecovery.recoverToolCalls(
            content: content, dialect: .tagTaggedName, offeredTools: ["get_weather"])
        XCTAssertEqual(calls.count, 1)
        let fn = calls[0]["function"] as? [String: Any]
        XCTAssertEqual(fn?["name"] as? String, "get_weather")
        XCTAssertEqual(fn?["arguments"] as? String, #"{"city":"Paris"}"#)
    }

    func testRecoveryConvertsTagTaggedEqCallWithCDATA() throws {
        let content = #"<tool_call><function=read_file><parameter=path><![CDATA[/tmp/a b.txt]]></parameter></function></tool_call>"#
        let calls = AMEEMRecovery.recoverToolCalls(
            content: content, dialect: .tagTaggedEq, offeredTools: ["read_file"])
        XCTAssertEqual(calls.count, 1)
        let fn = calls[0]["function"] as? [String: Any]
        let args = try XCTUnwrap(fn?["arguments"] as? String)
        let parsed = try JSONSerialization.jsonObject(with: Data(args.utf8)) as? [String: Any]
        XCTAssertEqual(parsed?["path"] as? String, "/tmp/a b.txt", "CDATA must be unwrapped, not escaped")
    }

    func testRecoveryConvertsNativeJsonCall() {
        let content = #"{"name": "get_weather", "arguments": {"city": "Paris"}}"#
        let calls = AMEEMRecovery.recoverToolCalls(
            content: content, dialect: .jsonNative, offeredTools: ["get_weather"])
        XCTAssertEqual(calls.count, 1)
    }

    /// G-06: prose that merely *documents* tool syntax must stay inert.
    func testRecoveryRefusesAnUnOfferedTool() {
        let content = #"<function name="delete_everything"><param name="path">/</param></function>"#
        let calls = AMEEMRecovery.recoverToolCalls(
            content: content, dialect: .tagTaggedName, offeredTools: ["read_file"])
        XCTAssertTrue(calls.isEmpty)
    }

    func testRecoveryOfEmptyContentIsEmpty() {
        XCTAssertTrue(AMEEMRecovery.recoverToolCalls(
            content: "", dialect: .tagTaggedName, offeredTools: ["x"]).isEmpty)
    }

    // MARK: - G-17 / G-19 companions

    func testCompanionKeyPairsAllThreeLayouts() {
        let model = "/m/Qwen3VL 8B Q4_K_M.gguf"
        let key = AMEEMCompanions.companionKey(model)
        XCTAssertEqual(AMEEMCompanions.companionKey("/m/mmproj Qwen3VL 8B BF16.gguf"), key)
        XCTAssertEqual(AMEEMCompanions.companionKey("/m/mmproj-Qwen3VL-8B-F16.gguf"), key)
        XCTAssertEqual(AMEEMCompanions.companionKey("/m/Qwen3VL-8B.mmproj.gguf"), key)
    }

    func testCompanionKeyIgnoresQuantisationDifference() {
        XCTAssertEqual(
            AMEEMCompanions.companionKey("/m/Model Q8_0.gguf"),
            AMEEMCompanions.companionKey("/m/mmproj Model BF16.gguf"))
    }

    func testCompanionKeyDoesNotPairUnrelatedModels() {
        let key = AMEEMCompanions.companionKey("/m/Ornith-1.5 9B Q8_0.gguf")
        XCTAssertNotEqual(AMEEMCompanions.companionKey("/m/MiniCPM5-2B.gguf"), key)
    }

    func testFindCompanionPicksTheMatchingProjector() {
        let candidates = ["/m/mmproj Qwen3VL 8B BF16.gguf", "/m/mmproj Ornith-1.5 9B F16.gguf"]
        XCTAssertEqual(
            AMEEMCompanions.findCompanion(modelPath: "/m/Qwen3VL-8B-Q4_K_M.gguf", candidates: candidates),
            "/m/mmproj Qwen3VL 8B BF16.gguf")
    }

    // MARK: - GGUF header markers (synthetic files)

    func testProjectorDetectedFromArchitectureMarker() throws {
        let path = try writeGGUF(kv: [("general.architecture", "clip")])
        defer { try? FileManager.default.removeItem(atPath: path) }
        XCTAssertTrue(AMEEMCompanions.isProjector(path: path))
    }

    func testProjectorDetectedFromTypeMarkerAlone() throws {
        // A tower published under another architecture is caught only by the
        // second marker.
        let path = try writeGGUF(kv: [("general.architecture", "qwen3vl"), ("general.type", "mmproj")])
        defer { try? FileManager.default.removeItem(atPath: path) }
        XCTAssertTrue(AMEEMCompanions.isProjector(path: path))
    }

    func testTextModelIsNotAProjector() throws {
        let path = try writeGGUF(kv: [
            ("general.architecture", "llama"),
            ("general.type", "model"),
            ("tokenizer.chat_template", "{{ messages }}"),
        ])
        defer { try? FileManager.default.removeItem(atPath: path) }
        XCTAssertFalse(AMEEMCompanions.isProjector(path: path))
        let markers = AMEEMCompanions.readMarkers(path: path)
        XCTAssertEqual(markers["general.architecture"], "llama")
        XCTAssertEqual(markers["general.type"], "model")
    }

    func testReconcilerReadsTemplateAndContextFromHeader() throws {
        let path = try writeGGUF(kv: [
            ("general.architecture", "qwen3"),
            ("general.name", "Test Model"),
            ("qwen3.context_length", UInt32(131072)),
            ("tokenizer.chat_template", "{% if tools %}enable_thinking{% endif %}"),
        ])
        defer { try? FileManager.default.removeItem(atPath: path) }
        let facts = AMEEMPresetReconciler.readGGUF(path: path)
        XCTAssertEqual(facts.error, "")
        XCTAssertEqual(facts.architecture, "qwen3")
        XCTAssertEqual(facts.name, "Test Model")
        XCTAssertEqual(facts.nCtxTrain, 131072)
        XCTAssertTrue(facts.supportsReasoningControls)
        XCTAssertFalse(facts.isProjector)
    }

    func testReconcilerSkipsAFileWithNoChatTemplate() throws {
        // The general filter that keeps image/video diffusion GGUFs out of the
        // language-model set, without maintaining an architecture list.
        let path = try writeGGUF(kv: [("general.architecture", "flux")])
        defer { try? FileManager.default.removeItem(atPath: path) }
        let facts = AMEEMPresetReconciler.readGGUF(path: path)
        XCTAssertTrue(facts.template.isEmpty)
        XCTAssertFalse(facts.isProjector)
    }

    func testReconcilerReportsANonGguf() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("not-a-model-\(UUID()).gguf")
        try Data("hello".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(AMEEMPresetReconciler.readGGUF(path: url.path).error, "not a GGUF")
    }

    // MARK: - Preset generation and diff

    func testDerivedPresetCarriesTheSamplerBandAndCeiling() {
        let facts = AMEEMPresetReconciler.Facts(
            path: "/m/Model.gguf", size: 0, architecture: "qwen3",
            generalType: "model", name: "Model", nCtxTrain: 262144, eosID: nil,
            template: "{{ messages }}", error: "")
        let preset = AMEEMPresetReconciler.derivePreset(facts, projector: "/m/mmproj Model.gguf", ctxCeiling: 65536)
        XCTAssertEqual(preset["ctx-size"], "65536", "the ceiling caps a 262k-native window")
        XCTAssertEqual(preset["temp"], "0.6")
        XCTAssertEqual(preset["top-k"], "20")
        XCTAssertEqual(preset["min-p"], "0.02")
        XCTAssertEqual(preset["jinja"], "1")
        XCTAssertEqual(preset["mmproj"], "/m/mmproj Model.gguf")
    }

    func testDerivedPresetAddsReasoningOnlyWhenTheTemplateExposesIt() {
        var facts = AMEEMPresetReconciler.Facts(
            path: "/m/Model.gguf", size: 0, architecture: "qwen3", generalType: "model",
            name: "M", nCtxTrain: 32768, eosID: nil, template: "plain", error: "")
        XCTAssertNil(AMEEMPresetReconciler.derivePreset(facts, projector: nil, ctxCeiling: 65536)["reasoning"])
        facts.template = "{% if preserve_thinking %}x{% endif %}"
        XCTAssertEqual(AMEEMPresetReconciler.derivePreset(facts, projector: nil, ctxCeiling: 65536)["reasoning"], "on")
    }

    func testPresetDiffReportsAddChangeAndRemove() {
        let existing = ["Model": ["ctx-size": "32768", "temp": "0.2", "legacy": "keep"]]
        let proposed: [(name: String, fields: [String: String])] = [
            ("Model", ["ctx-size": "65536", "temp": "0.6"]),
            ("New", ["ctx-size": "8192"]),
        ]
        let findings = AMEEMPresetReconciler.diffSections(proposed: proposed, existing: existing)
        XCTAssertTrue(findings.contains { $0.hasPrefix("CHANGE [Model] ctx-size") })
        XCTAssertTrue(findings.contains { $0.hasPrefix("CHANGE [Model] temp") })
        XCTAssertTrue(findings.contains { $0.hasPrefix("DROP   [Model] legacy") })
        XCTAssertTrue(findings.contains { $0.hasPrefix("ADD    [New]") })
    }

    func testPresetDiffReportsARemovedSection() {
        let findings = AMEEMPresetReconciler.diffSections(
            proposed: [], existing: ["Gone": ["model": "/m/gone.gguf"]])
        XCTAssertTrue(findings.contains { $0.hasPrefix("REMOVE [Gone]") })
    }

    func testOwnerCommentsSurviveAParseRenderRoundTrip() {
        let text = """
        # launcher-decision: {"ctx": 32768}
        [Model]
        model = /m/Model.gguf
        ctx-size = 32768

        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("presets-\(UUID()).ini")
        try? text.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let (sections, comments) = AMEEMPresetReconciler.parsePresets(url.path)
        XCTAssertEqual(sections["Model"]?["ctx-size"], "32768")
        XCTAssertEqual(comments["Model"], ["# launcher-decision: {\"ctx\": 32768}"])
        let rendered = AMEEMPresetReconciler.renderPresetFile(
            sections: [("Model", ["ctx-size": "65536"])], ownerComments: comments)
        XCTAssertTrue(rendered.contains("# launcher-decision: {\"ctx\": 32768}"),
                      "I4: the launcher's metadata must be preserved verbatim")
    }

    func testDigestBasenameIsSkipped() {
        XCTAssertTrue(AMEEMPresetReconciler.isDigestName("/m/sha256-\(String(repeating: "a", count: 64)).gguf"))
        XCTAssertFalse(AMEEMPresetReconciler.isDigestName("/m/Model.gguf"))
    }

    // MARK: - G-09 firewall

    private func firewallInputs() -> (offered: Set<String>, terminal: Set<String>) {
        (["read_file", "write_file", "finish"], ["finish"])
    }

    func testFirewallDoesNotFireOnANativeCall() {
        let firewall = AMEEMFirewall()
        let message: [String: Any] = [
            "role": "assistant",
            "content": "I have created the file.",
            "tool_calls": [["id": "call_1", "type": "function",
                            "function": ["name": "write_file", "arguments": "{}"]]],
        ]
        let outcome = firewall.evaluate(
            model: "m", firstUserTurn: "do it", message: message,
            dialect: .tagTaggedName, offeredTools: ["write_file", "finish"], terminalTools: ["finish"])
        XCTAssertFalse(outcome.fired)
        XCTAssertFalse(outcome.changed, "a native call is a good turn and must pass through untouched")
        XCTAssertEqual(outcome.message["content"] as? String, "I have created the file.")
    }

    func testFirewallRecoversBeforeEvaluating() {
        let firewall = AMEEMFirewall()
        let message: [String: Any] = [
            "role": "assistant",
            "content": #"I have written it. <function name="write_file"><param name="path">/a</param></function>"#,
        ]
        let outcome = firewall.evaluate(
            model: "m", firstUserTurn: "do it", message: message,
            dialect: .tagTaggedName, offeredTools: ["write_file", "finish"], terminalTools: ["finish"])
        XCTAssertFalse(outcome.fired, "recovery short-circuits evaluation (C-04)")
        XCTAssertTrue(outcome.changed, "a recovered call still changes the message")
        XCTAssertNotNil(outcome.message["tool_calls"], "the recovered call must be emitted as real tool_calls")
    }

    func testFirewallFiresOnABareCompletionClaim() {
        let firewall = AMEEMFirewall()
        let message: [String: Any] = ["role": "assistant", "content": "I have created the file."]
        let outcome = firewall.evaluate(
            model: "m", firstUserTurn: "do it", message: message,
            dialect: .tagTaggedName, offeredTools: ["write_file", "finish"], terminalTools: ["finish"])
        XCTAssertTrue(outcome.fired)
        XCTAssertTrue(outcome.changed)
        XCTAssertTrue((outcome.message["content"] as? String)?.contains("VALIDATION ERROR") == true)
    }

    func testFirewallDoesNotFireWithoutATerminalTool() {
        let firewall = AMEEMFirewall()
        let message: [String: Any] = ["role": "assistant", "content": "The task is complete."]
        let outcome = firewall.evaluate(
            model: "m", firstUserTurn: "do it", message: message,
            dialect: .tagTaggedName, offeredTools: ["write_file"], terminalTools: [])
        XCTAssertFalse(outcome.fired, "without a terminal tool the loop cannot be trusted to end on a call")
        XCTAssertFalse(outcome.changed)
    }

    func testFirewallIsBoundedAndThenSurfacesTheFailure() {
        let firewall = AMEEMFirewall()
        let message: [String: Any] = ["role": "assistant", "content": "Done."]
        var firings = 0
        for _ in 0..<(AMEEM.recoveryCycleLimit + 2) {
            let outcome = firewall.evaluate(
                model: "m", firstUserTurn: "do it", message: message,
                dialect: .tagTaggedName, offeredTools: ["finish"], terminalTools: ["finish"])
            if outcome.fired { firings += 1 }
            if let content = outcome.message["content"] as? String, content.contains("budget is exhausted") {
                XCTAssertEqual(firings, AMEEM.recoveryCycleLimit + 1)
                return
            }
        }
        XCTFail("the firewall never surfaced the exhausted-budget failure")
    }

    func testFirewallKeyIsStableAndPerSession() {
        let firewall = AMEEMFirewall()
        XCTAssertEqual(firewall.key(model: "m", firstUserTurn: "a"),
                       firewall.key(model: "m", firstUserTurn: "a"))
        XCTAssertNotEqual(firewall.key(model: "m", firstUserTurn: "a"),
                          firewall.key(model: "m", firstUserTurn: "b"))
        XCTAssertNotEqual(firewall.key(model: "m1", firstUserTurn: "a"),
                          firewall.key(model: "m2", firstUserTurn: "a"))
    }

    /// Regression for the defect verification gate V8 caught in the reference
    /// proxy: `_apply_firewall` discarded a successful recovery because it keyed
    /// on `fired`, which is False for a recovered turn. The recovered call must
    /// reach the client as real `tool_calls` — never as a 200 whose `content`
    /// still holds it.
    func testApplyWritesBackARecoveredCallAndEndsOnToolCalls() throws {
        let firewall = AMEEMFirewall()
        let body: [String: Any] = [
            "id": "chatcmpl-1", "model": "m",
            "choices": [[
                "index": 0, "finish_reason": "stop",
                "message": ["role": "assistant",
                            "content": #"I will read it. <function name="read_file"><param name="path">/tmp/x</param></function>"#],
            ]],
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        let (repaired, changed) = firewall.apply(
            toBody: data, model: "m", firstUserTurn: "read /tmp/x",
            dialect: .tagTaggedName, offeredTools: ["read_file", "finish"], terminalTools: ["finish"])
        XCTAssertTrue(changed)
        let root = try JSONSerialization.jsonObject(with: repaired) as? [String: Any]
        let choice = (root?["choices"] as? [[String: Any]])?.first
        let message = choice?["message"] as? [String: Any]
        let calls = (message?["tool_calls"] as? [[String: Any]]) ?? []
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual((calls.first?["function"] as? [String: Any])?["name"] as? String, "read_file")
        XCTAssertEqual(choice?["finish_reason"] as? String, "tool_calls")
        XCTAssertTrue(message?["content"] is NSNull, "the recovered call must not also sit in content")
    }

    func testApplyLeavesAGoodTurnByteIdentical() throws {
        let firewall = AMEEMFirewall()
        let body: [String: Any] = [
            "id": "chatcmpl-2",
            "choices": [["index": 0, "finish_reason": "stop",
                         "message": ["role": "assistant", "content": "Here is the answer: 42."]]],
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        let (repaired, changed) = firewall.apply(
            toBody: data, model: "m", firstUserTurn: "what is 6x7",
            dialect: .tagTaggedName, offeredTools: ["finish"], terminalTools: ["finish"])
        XCTAssertFalse(changed)
        XCTAssertEqual(repaired, data, "a turn with no claim and no call must be untouched")
    }

    // MARK: - Pillar A / G-05 ledger

    func testLedgerRetainsEveryObservation() {
        let messages: [[String: Any]] = [
            ["role": "system", "content": "sys"],
            ["role": "user", "content": "goal"],
            ["role": "tool", "name": "step1", "content": "result one"],
            ["role": "tool", "name": "step2", "content": "result two"],
            ["role": "tool", "name": "step3", "content": "result three"],
        ]
        let condensed = AMEEMLedger.condenseToLedger(messages: messages)
        XCTAssertEqual(condensed.count, 1)
        let text = (condensed[0]["content"] as? String) ?? ""
        XCTAssertTrue(text.contains("Observations retained: 3"), "C-06: all observations must survive")
        XCTAssertTrue(text.contains("result one"))
        XCTAssertTrue(text.contains("result two"))
        XCTAssertTrue(text.contains("result three"))
    }

    func testLedgerOffloadsALargeObservationToDisk() throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("ameem-\(UUID())")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let large = String(repeating: "x", count: AMEEM.observationInlineLimit + 500)
        let (preview, handle) = AMEEMLedger.offload(large, tag: "tool_output_1", scratchDir: scratch.path)
        XCTAssertNotNil(handle)
        XCTAssertTrue(preview.contains("offloaded"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: handle!), "the handle must be retrievable")
    }

    func testLedgerKeepsASmallObservationInline() {
        let (preview, handle) = AMEEMLedger.offload("small", tag: "t", scratchDir: "/nonexistent")
        XCTAssertNil(handle)
        XCTAssertEqual(preview, "small")
    }

    // MARK: - Request gate (no live server)

    func testGateRefusesToolWorkOnAnUnverifiableProfile() async {
        let probe = AMEEMCapabilityProbe()
        let payload: [String: Any] = [
            "model": "some-model",
            "messages": [["role": "user", "content": "hi"]],
            "tools": [["type": "function",
                       "function": ["name": "finish", "parameters": ["type": "object"]]]],
        ]
        do {
            _ = try await AMEEMRequestGate.calibrate(
                payload: payload, origin: "http://127.0.0.1:1", probe: probe)
            XCTFail("an unverifiable profile must refuse tool work (G-18)")
        } catch let violation as AMEEMGuardrailViolation {
            XCTAssertEqual(violation.gate, "G-18")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testGateAppliesTheBandAndDowngradesTheStreamWithoutTools() async throws {
        let probe = AMEEMCapabilityProbe()
        let payload: [String: Any] = [
            "model": "some-model",
            "messages": [["role": "user", "content": "hi"]],
            "temperature": 0.05,
            "stream": true,
        ]
        let calibration = try await AMEEMRequestGate.calibrate(
            payload: payload, origin: "http://127.0.0.1:1", probe: probe)
        XCTAssertEqual(calibration.payload["temperature"] as? Double, 0.50)
        XCTAssertEqual(calibration.payload["top_k"] as? Int, 20)
        XCTAssertEqual(calibration.payload["min_p"] as? Double, 0.02)
        XCTAssertTrue(calibration.streamDowngraded, "G-15: a stream must be downgraded so recovery can run")
        XCTAssertEqual(calibration.payload["stream"] as? Bool, false)
    }

    func testGateHonoursTheStreamingEscapeHatch() async throws {
        let probe = AMEEMCapabilityProbe()
        let payload: [String: Any] = [
            "model": "some-model",
            "messages": [["role": "user", "content": "hi"]],
            "stream": true,
        ]
        let calibration = try await AMEEMRequestGate.calibrate(
            payload: payload, origin: "http://127.0.0.1:1", probe: probe,
            streamingRepairAvailable: true)
        XCTAssertFalse(calibration.streamDowngraded)
        XCTAssertEqual(calibration.payload["stream"] as? Bool, true)
    }

    // MARK: - SSE bridge (G-15 must not break the transport)

    func testAnthropicBridgeEmitsACompleteStream() async {
        let json: [String: Any] = [
            "id": "msg_1", "type": "message", "role": "assistant",
            "content": [["type": "text", "text": "hello"],
                        ["type": "tool_use", "id": "call_1", "name": "finish", "input": ["ok": true]]],
            "stop_reason": "tool_use",
            "usage": ["input_tokens": 1, "output_tokens": 2],
        ]
        var events: [String] = []
        for await chunk in AMEEMStreamBridge.anthropicStream(fromMessageJSON: json, model: "m") {
            events.append(String(decoding: chunk, as: UTF8.self))
        }
        let all = events.joined()
        XCTAssertTrue(all.contains("event: message_start"))
        XCTAssertTrue(all.contains("content_block_start"))
        XCTAssertTrue(all.contains("input_json_delta"))
        XCTAssertTrue(all.contains("message_delta"))
        XCTAssertTrue(all.contains("message_stop"))
    }

    func testOpenAIBridgeTerminatesWithDone() async {
        let json: [String: Any] = [
            "id": "chatcmpl-1", "created": 1, "model": "m",
            "choices": [["index": 0,
                         "message": ["role": "assistant", "content": "hi"],
                         "finish_reason": "stop"]],
        ]
        var events: [String] = []
        for await chunk in AMEEMStreamBridge.openAIStream(fromResponseJSON: json, model: "m") {
            events.append(String(decoding: chunk, as: UTF8.self))
        }
        let all = events.joined()
        XCTAssertTrue(all.contains("chat.completion.chunk"))
        XCTAssertTrue(all.contains("data: [DONE]"))
    }

    // MARK: - Load-time reconciler over the real model library

    private var realModelsDir: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Models").path
    }

    private func realGgufCount() -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: realModelsDir))?
            .filter { $0.lowercased().hasSuffix(".gguf") }.count ?? 0
    }

    /// Runs the Swift reconciler over the operator's actual model library. This
    /// is the Swift port's counterpart to verification gate V2.
    func testReconcilerOverTheRealModelLibrary() throws {
        try XCTSkipIf(realGgufCount() == 0, "no GGUFs in ~/Models")
        let report = AMEEMPresetReconciler.reconcile(
            modelsDirs: [realModelsDir],
            presetsPath: FileManager.default.temporaryDirectory
                .appendingPathComponent("ameem-absent-\(UUID()).ini").path)

        XCTAssertGreaterThan(report.scanned, 0)
        XCTAssertGreaterThan(report.models.count, 0, "the library must yield at least one language model")
        XCTAssertTrue(report.unreadable.isEmpty,
                      "unreadable: \(report.unreadable.map { $0.path + " -> " + $0.error })")

        // A companion is never a model.
        for projector in report.projectors {
            XCTAssertFalse(report.models.contains { $0.path == projector.path })
        }
        // Every proposed section must come from a file that carries a chat template.
        for model in report.models {
            XCTAssertFalse(model.template.isEmpty, "\(model.path) has no template")
        }
        // Section names must be unique (V7).
        let names = report.proposed.map(\.name)
        XCTAssertEqual(names.count, Set(names).count, "section names collide: \(names)")

        // Every skip carries a reason (I5).
        for (path, why) in report.skipped {
            XCTAssertFalse(why.isEmpty, "\(path) was skipped without a reason")
        }
        // A known diffusion GGUF must be filtered as "no chat template" (V3).
        if let flux = report.skipped.first(where: {
            ($0.path as NSString).lastPathComponent.lowercased().contains("flux")
        }) {
            XCTAssertTrue(flux.why.contains("no chat template"), "flux reason was: \(flux.why)")
        }
        // At least one model ↔ projector pairing (V5), and the attached path exists.
        for (model, projector) in report.pairs {
            XCTAssertTrue(FileManager.default.fileExists(atPath: projector),
                          "\(projector) does not exist for \(model)")
        }
        print("[AMEEM] real-library report: scanned=\(report.scanned) models=\(report.models.count) "
            + "companions=\(report.projectors.count) duplicates=\(report.duplicates.count) "
            + "skipped=\(report.skipped.count) pairs=\(report.pairs.count)")
    }

    // MARK: - Session preflight (load-time trigger A)

    func testSessionPreflightRefusesAProjectorServedAsAModel() throws {
        let mmproj = try writeGGUF(kv: [("general.architecture", "clip")])
        defer { try? FileManager.default.removeItem(atPath: mmproj) }
        let presets = FileManager.default.temporaryDirectory
            .appendingPathComponent("presets-\(UUID()).ini")
        try "[VisionTower]\nmodel = \(mmproj)\nctx-size = 4096\n"
            .write(to: presets, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: presets) }

        let result = AMEEMPresetReconciler.check(modelsDirs: [], presetsPath: presets.path)
        XCTAssertFalse(result.isClean, "a projector served as a model must be fatal at preflight")
        XCTAssertTrue(result.fatal.contains { $0.contains("G-17") })
    }

    func testSessionPreflightRefusesAMissingModel() throws {
        let presets = FileManager.default.temporaryDirectory
            .appendingPathComponent("presets-\(UUID()).ini")
        try "[Gone]\nmodel = /nonexistent/model-\(UUID()).gguf\n"
            .write(to: presets, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: presets) }

        let result = AMEEMPresetReconciler.check(modelsDirs: [], presetsPath: presets.path)
        XCTAssertFalse(result.isClean)
        XCTAssertTrue(result.fatal.contains { $0.contains("G-19") })
    }

    func testSessionPreflightRefusesAMissingAttachedProjector() throws {
        let model = try writeGGUF(kv: [
            ("general.architecture", "llama"),
            ("general.type", "model"),
            ("tokenizer.chat_template", "{{ messages }}"),
        ])
        defer { try? FileManager.default.removeItem(atPath: model) }
        let presets = FileManager.default.temporaryDirectory
            .appendingPathComponent("presets-\(UUID()).ini")
        try "[M]\nmodel = \(model)\nmmproj = /nonexistent/mmproj-\(UUID()).gguf\n"
            .write(to: presets, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: presets) }

        let result = AMEEMPresetReconciler.check(modelsDirs: [], presetsPath: presets.path)
        XCTAssertFalse(result.isClean)
        XCTAssertTrue(result.fatal.contains { $0.contains("G-19") && $0.contains("mmproj") })
    }

    func testSessionPreflightIsCleanForAConsistentPreset() throws {
        let model = try writeGGUF(kv: [
            ("general.architecture", "llama"),
            ("general.type", "model"),
            ("tokenizer.chat_template", "{{ messages }}"),
        ])
        defer { try? FileManager.default.removeItem(atPath: model) }
        let presets = FileManager.default.temporaryDirectory
            .appendingPathComponent("presets-\(UUID()).ini")
        try "[M]\nmodel = \(model)\nctx-size = 32768\n"
            .write(to: presets, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: presets) }

        let result = AMEEMPresetReconciler.check(modelsDirs: [], presetsPath: presets.path)
        XCTAssertTrue(result.isClean, "fatal: \(result.fatal)")
    }

    // MARK: - Synthetic GGUF builder

    /// Build a minimal but structurally valid GGUF whose KV section holds the
    /// supplied scalar/string keys. Used to exercise the header reader without a
    /// multi-gigabyte model on disk.
    private func writeGGUF(kv: [(String, Any)]) throws -> String {
        var data = Data()
        data.append(contentsOf: Array("GGUF".utf8))
        data.append(littleEndian(UInt32(3)))          // version
        data.append(littleEndian(UInt64(0)))          // tensor count
        data.append(littleEndian(UInt64(kv.count)))   // kv count
        for (key, value) in kv {
            let keyBytes = Array(key.utf8)
            data.append(littleEndian(UInt64(keyBytes.count)))
            data.append(contentsOf: keyBytes)
            switch value {
            case let string as String:
                data.append(littleEndian(UInt32(8)))
                let bytes = Array(string.utf8)
                data.append(littleEndian(UInt64(bytes.count)))
                data.append(contentsOf: bytes)
            case let int as Int:
                data.append(littleEndian(UInt32(10)))   // uint64
                data.append(littleEndian(UInt64(int)))
            case let uint as UInt32:
                data.append(littleEndian(UInt32(4)))    // uint32
                data.append(littleEndian(uint))
            default:
                data.append(littleEndian(UInt32(7)))    // bool
                data.append(0)
            }
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ameem-test-\(UUID()).gguf")
        try data.write(to: url)
        return url.path
    }

    private func littleEndian(_ value: UInt32) -> Data {
        Data(withUnsafeBytes(of: value.littleEndian) { Data($0) })
    }
    private func littleEndian(_ value: UInt64) -> Data {
        Data(withUnsafeBytes(of: value.littleEndian) { Data($0) })
    }
}
