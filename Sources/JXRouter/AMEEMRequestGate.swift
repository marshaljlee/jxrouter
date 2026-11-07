import Foundation

/// AMEEM v3.0 — the request-time gate.
///
/// Composes the capability probe with the guardrail register into one decision
/// applied to an OpenAI-format payload on its way to a local inference server.
/// Every refusal is a structured `AMEEMGuardrailViolation` naming the gate (I2);
/// nothing degrades silently.
enum AMEEMRequestGate {

    /// Opt-in escape hatch for the streaming downgrade (G-15).
    static var allowStreaming: Bool {
        ProcessInfo.processInfo.environment["AMEEM_ALLOW_STREAM"] == "1"
    }

    /// The calibration applied to a request.
    struct Calibration {
        var payload: [String: Any]
        var profile: AMEEMProfile
        /// True when the payload was materially changed.
        var changed: Bool
        var notes: [String]
        var terminalTools: Set<String>
        var usedLedger: Bool
        var streamDowngraded: Bool
        var temperatureOverridden: Bool
    }

    /// Calibrate `payload` for the local server at `origin`.
    ///
    /// - Parameters:
    ///   - payload: the OpenAI Chat Completions body about to be sent.
    ///   - origin: the local server origin, e.g. `http://127.0.0.1:8080`.
    ///   - probe: the shared capability probe (TTL-cached).
    /// - Throws: `AMEEMGuardrailViolation` when a precondition cannot be verified.
    static func calibrate(
        payload: [String: Any],
        origin: String,
        apiKey: String = "",
        probe: AMEEMCapabilityProbe,
        streamingRepairAvailable: Bool = false
    ) async throws -> Calibration {
        var body = payload
        var notes: [String] = []
        var changed = false

        let modelID = (body["model"] as? String) ?? ""
        try ameemRequire(!modelID.isEmpty, "G-11", "request has no model field")

        let profile = await probe.profile(for: modelID, origin: origin, apiKey: apiKey)

        let tools = (body["tools"] as? [[String: Any]]) ?? []
        let offered = Set(tools.compactMap { ($0["function"] as? [String: Any])?["name"] as? String })
        let terminal = AMEEMTools.terminalTools(offered: offered)

        // --- Ingress gates (only for tool work; a plain chat is untouched).
        if !offered.isEmpty {
            // G-18: an unverifiable profile must not receive tool work.
            try ameemRequire(!profile.degraded, "G-18",
                "capability profile for '\(modelID)' is unverified "
                + "(\(profile.notes.joined(separator: "; "))). Refusing tool work rather than guessing a tier.")

            // G-01: do not route tool work to a server that cannot parse it.
            try ameemRequire(profile.supportsTools, "G-01",
                "upstream reports no tool-call support for '\(modelID)'; refusing to route a tool "
                + "request that would silently return prose")

            // G-02: a text-channel call would be lost without a matching extractor.
            try ameemRequire(profile.dialect != nil, "G-02",
                "no tool-call dialect could be read from '\(modelID)'; a text-channel call would be "
                + "lost without a matching extractor")

            // G-13: terminal-tool enforcement.
            try ameemRequire(!terminal.isEmpty, "G-13",
                "no terminal tool offered. Without one the loop can only end on prose, which is what "
                + "produces 'it says it finished'. Add one of \(AMEEMTools.terminalNames.sorted()).")
        }

        // --- G-04: sampler band. Clamp, never overwrite (C-20).
        let requestedTemp = doubleValue(body["temperature"])
        let clamp = AMEEMSamplerPolicy.clampTemperature(requestedTemp)
        if doubleValue(body["temperature"]) != clamp.value || body["temperature"] == nil {
            body["temperature"] = clamp.value
            changed = true
        }
        if let note = clamp.note {
            notes.append(note)
            print("[AMEEM] \(note)")
        }
        for (key, value) in AMEEMSamplerPolicy.requiredSamplers() where body[key] == nil {
            body[key] = (key == "top_k") ? Int(value) : value
            changed = true
        }

        // --- G-03: stop tokens derived from the template, never hardcoded.
        //            `</tool_call>` is deliberately absent: stopping there
        //            severs parallel calls.
        var stops: [String] = []
        if let existing = body["stop"] as? [String] { stops = existing }
        else if let single = body["stop"] as? String { stops = [single] }
        if !profile.turnTerminator.isEmpty {
            stops.removeAll { $0 == profile.turnTerminator }
            stops.append(profile.turnTerminator)
            body["stop"] = stops
            changed = true
        } else if !stops.isEmpty {
            notes.append("G-03: no derived terminator; client stop sequences passed through unchanged")
        }

        // --- G-05: parallel calls only when the upstream declares support.
        if boolValue(body["parallel_tool_calls"]) && !profile.supportsParallelTools {
            body["parallel_tool_calls"] = false
            changed = true
            notes.append("G-05: upstream does not support parallel tool calls; disabled for this request")
            print("[AMEEM] G-05: upstream does not support parallel tool calls; disabling for this request.")
        }

        // --- G-12: context budget. Refuse rather than let the runtime truncate
        //            from the FRONT and silently drop the system prompt and tool
        //            definitions.
        let estPromptTokens = (serializedByteCount(body["messages"])) / 4
        let tier = profile.tier ?? .mid
        let maxOut = intValue(body["max_tokens"]) ?? AMEEMTiers.maxTokens(for: tier)
        if profile.nCtx > 0 {
            try ameemRequire(estPromptTokens + maxOut < profile.nCtx, "G-12",
                "prompt ~\(estPromptTokens) + max_tokens \(maxOut) exceeds n_ctx \(profile.nCtx); the "
                + "runtime would drop the head of the context")
        }
        if intValue(body["max_tokens"]) == nil {
            body["max_tokens"] = maxOut
            changed = true
        }

        // --- G-14: condensation, with tool-definition survival verification
        //            (G-07).
        var usedLedger = false
        if tier == .micro, let messages = body["messages"] as? [[String: Any]], !messages.isEmpty {
            let condensed = AMEEMLedger.condenseToLedger(messages: messages)
            var accept = true
            if !offered.isEmpty {
                let rendered = await probe.render(
                    origin: origin, model: modelID, apiKey: apiKey,
                    messages: condensed, tools: tools, addGenerationPrompt: true) ?? ""
                if !AMEEMLedger.allToolNamesPresent(Array(offered), inRenderedPrompt: rendered) {
                    accept = false
                    notes.append("G-07: condensation removed tool definitions from the prompt; skipped")
                    print("[AMEEM] G-07: condensation removed tool definitions from the prompt. "
                        + "Skipping condensation for this request.")
                }
            }
            if accept {
                body["messages"] = condensed
                usedLedger = true
                changed = true
            }
        }

        // --- G-15: streaming parity. A recovery pass needs the whole body, and a
        //            turn whose text has already been streamed cannot be
        //            repaired — so the firewall can never fire on it. Downgrade
        //            unless the caller can repair mid-stream or the operator has
        //            explicitly accepted the risk.
        var streamDowngraded = false
        if boolValue(body["stream"]) && !allowStreaming && !streamingRepairAvailable {
            body["stream"] = false
            changed = true
            streamDowngraded = true
            notes.append("G-15: stream downgraded to false so text-channel recovery can run "
                + "(set AMEEM_ALLOW_STREAM=1 to accept the risk)")
            print("[AMEEM] G-15: stream=true downgraded to false so text-channel recovery can run. "
                + "Set AMEEM_ALLOW_STREAM=1 to accept the risk.")
        }

        return Calibration(
            payload: body, profile: profile, changed: changed, notes: notes,
            terminalTools: terminal, usedLedger: usedLedger,
            streamDowngraded: streamDowngraded, temperatureOverridden: clamp.overridden)
    }

    /// The first user turn, for the firewall's session key.
    static func firstUserTurn(in payload: [String: Any]) -> String {
        guard let messages = payload["messages"] as? [[String: Any]] else { return "" }
        for msg in messages where (msg["role"] as? String) == "user" {
            if let text = msg["content"] as? String { return text }
            if let blocks = msg["content"] as? [[String: Any]] {
                return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
            }
        }
        return ""
    }

    // MARK: - Small helpers

    private static func doubleValue(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let n = any as? NSNumber { return n.doubleValue }
        return nil
    }

    private static func intValue(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let n = any as? NSNumber { return n.intValue }
        return nil
    }

    private static func boolValue(_ any: Any?) -> Bool {
        if let b = any as? Bool { return b }
        if let n = any as? NSNumber { return n.boolValue }
        return false
    }

    private static func serializedByteCount(_ any: Any?) -> Int {
        guard let any, let data = try? JSONSerialization.data(withJSONObject: any) else { return 0 }
        return data.count
    }
}
