import Foundation

/// AMEEM v3.0 — capability probe (the source of every calibration decision).
///
/// Every field below is *measured*, never guessed from a name (I1):
///   GET  /v1/models       -> per-model meta (`n_params`, `n_ctx`) and the live
///                            launch argv (`--model`, `--port`, `--mmproj`)
///   GET  /props           -> `chat_template_caps` and effective samplers
///   POST /apply-template  -> the literal prompt, from which the tool-call
///                            dialect and the turn terminator are read
///
/// A profile whose parameters cannot be measured is marked `degraded`, and tool
/// work on a degraded profile is refused rather than guessed (G-18, C-23).
struct AMEEMProfile: Sendable, Equatable {
    var modelID: String
    var nCtx: Int
    var nParams: Int
    var supportsTools: Bool
    var supportsReasoningPreserve: Bool
    var supportsParallelTools: Bool
    var dialect: AMEEMDialect?
    var turnTerminator: String
    var tier: AMEEMTier?
    var degraded: Bool
    var notes: [String]
    var launchArgs: [String]
    var modelPath: String?
    /// When the profile was measured; drives the TTL cache.
    var probedAt: Date = Date()

    /// A profile that could not be probed at all (server unreachable).
    static func unavailable(modelID: String, reason: String) -> AMEEMProfile {
        AMEEMProfile(modelID: modelID, nCtx: 0, nParams: 0,
                     supportsTools: false, supportsReasoningPreserve: false,
                     supportsParallelTools: false, dialect: nil, turnTerminator: "",
                     tier: nil, degraded: true, notes: [reason], launchArgs: [], modelPath: nil,
                     probedAt: Date())
    }
}

/// Caches measured profiles: one probe per model per TTL. A model change needs
/// no scheduling — every request re-derives from the live server once the TTL
/// lapses (this is the "Request" automation layer).
final class AMEEMCapabilityProbe: @unchecked Sendable {

    private var cache: [String: AMEEMProfile] = [:]
    private let lock = NSLock()

    init() {}

    func cached(modelID: String) -> AMEEMProfile? {
        lock.lock(); defer { lock.unlock() }
        guard let hit = cache[modelID],
              Date().timeIntervalSince(hit.probedAt) < AMEEM.probeTTL else { return nil }
        return hit
    }

    private func store(_ profile: AMEEMProfile) {
        lock.lock(); defer { lock.unlock() }
        cache[profile.modelID] = profile
    }

    func invalidateAll() {
        lock.lock(); defer { lock.unlock() }
        cache.removeAll()
    }

    /// Probe the model at `origin` (e.g. `http://127.0.0.1:8080`).
    func profile(for modelID: String, origin: String, apiKey: String = "") async -> AMEEMProfile {
        if let hit = cached(modelID: modelID) { return hit }
        let profile = await probe(modelID: modelID, origin: origin, apiKey: apiKey)
        store(profile)
        return profile
    }

    // MARK: - Probe

    private func probe(modelID: String, origin: String, apiKey: String) async -> AMEEMProfile {
        var notes: [String] = []
        let origin = origin.hasSuffix("/") ? String(origin.dropLast()) : origin

        // --- 1. Residency (G-11).
        guard let models = await getJSON("\(origin)/v1/models", apiKey: apiKey),
              let entries = models["data"] as? [[String: Any]] else {
            return .unavailable(modelID: modelID, reason: "upstream \(origin) is not reachable or served no /v1/models")
        }
        guard let entry = entries.first(where: { ($0["id"] as? String) == modelID }) else {
            return .unavailable(modelID: modelID, reason: "G-11: model '\(modelID)' is not served upstream")
        }
        let status = entry["status"] as? [String: Any]
        let args = (status?["args"] as? [String]) ?? []
        let meta = (entry["meta"] as? [String: Any]) ?? [:]
        let loadState = status?["value"] as? String
        if let loadState, loadState != "loaded" {
            notes.append("model was '\(loadState)' at probe time; first request pays the load")
        }

        // --- 1b. Companion gate (G-17).
        var modelPath: String?
        if let idx = args.firstIndex(of: "--model"), args.count > idx + 1 {
            modelPath = args[idx + 1]
        }
        if let path = modelPath {
            if AMEEMCompanions.isProjector(path: path) {
                return .unavailable(modelID: modelID, reason: "G-17: '\(modelID)' resolves to a vision "
                    + "projector (\((path as NSString).lastPathComponent)), not a language model. It has no "
                    + "output head and cannot generate tokens. Attach it to its text model with "
                    + "`mmproj = <path>` rather than serving it as a model.")
            }
        } else {
            notes.append("preset exposes no --model path; companion status unverified")
        }

        // --- 2. Instance port, so /props reports the loaded model's caps rather
        //        than the router's.
        var propsOrigin = origin
        if let idx = args.firstIndex(of: "--port"), args.count > idx + 1,
           let port = args[idx + 1] as String?, !port.isEmpty, port != "0" {
            propsOrigin = "http://127.0.0.1:\(port)"
        }
        let props = await getJSON("\(propsOrigin)/props", apiKey: apiKey) ?? [:]
        let caps = (props["chat_template_caps"] as? [String: Any]) ?? [:]
        let gen = ((props["default_generation_settings"] as? [String: Any])?["params"] as? [String: Any]) ?? [:]

        let nCtx = intValue(meta["n_ctx"]) ?? intValue(gen["n_ctx"]) ?? 0
        let nParams = intValue(meta["n_params"]) ?? 0

        // --- 3. Capability, not name (G-14).
        let supportsTools = boolValue(caps["supports_tools"]) && boolValue(caps["supports_tool_calls"])
        let supportsReasoning = boolValue(caps["supports_preserve_reasoning"])
            || boolValue(caps["supports_reasoning_effort"])
        let supportsParallel = boolValue(caps["supports_parallel_tool_calls"])

        // --- 3b. Unverifiable capability is not the same as "small" (G-18).
        var degraded = !(nParams > 0 && nCtx > 0)
        if nParams == 0 { notes.append("n_params unavailable upstream; capability unverified") }
        if nCtx == 0 { notes.append("n_ctx unavailable upstream; context budget unverifiable") }
        if modelPath == nil { degraded = true }

        let tier = AMEEMTiers.tier(nParams: nParams)

        // --- 4. Dialect + turn terminator, read from the rendered prompt.
        let probeTools: [[String: Any]] = [[
            "type": "function",
            "function": ["name": "__ameem_probe__", "description": "probe",
                         "parameters": ["type": "object", "properties": [:], "required": []]],
        ]]
        let rendered = await render(
            origin: origin, model: modelID, apiKey: apiKey,
            messages: [["role": "system", "content": "probe"], ["role": "user", "content": "probe"]],
            tools: probeTools, addGenerationPrompt: true) ?? ""
        let dialect = AMEEMRecovery.detectDialect(renderedPrompt: rendered)
        let terminator = await turnTerminator(origin: origin, model: modelID, apiKey: apiKey)

        if !supportsTools { notes.append("upstream reports no tool-call support for this template") }
        if dialect == nil { notes.append("no tool-call dialect could be read from the rendered prompt") }
        if terminator.isEmpty { notes.append("no turn terminator could be derived by differential rendering") }

        let profile = AMEEMProfile(
            modelID: modelID, nCtx: nCtx, nParams: nParams,
            supportsTools: supportsTools, supportsReasoningPreserve: supportsReasoning,
            supportsParallelTools: supportsParallel, dialect: dialect,
            turnTerminator: terminator, tier: tier, degraded: degraded,
            notes: notes, launchArgs: args, modelPath: modelPath)

        print("[AMEEM] Probed \(modelID) -> tier=\(tier?.rawValue ?? "?") params=\(nParams) "
            + "ctx=\(nCtx) tools=\(supportsTools) dialect=\(dialect?.rawValue ?? "<none>") "
            + "terminator=\(terminator.isEmpty ? "<none>" : terminator)"
            + (notes.isEmpty ? "" : " | " + notes.joined(separator: "; ")))
        return profile
    }

    // MARK: - Template rendering

    /// `POST /apply-template` — the literal prompt the template produced.
    func render(
        origin: String, model: String, apiKey: String,
        messages: [[String: Any]], tools: [[String: Any]]?,
        addGenerationPrompt: Bool? = nil
    ) async -> String? {
        var payload: [String: Any] = ["model": model, "messages": messages]
        if let tools { payload["tools"] = tools }
        if let addGenerationPrompt { payload["add_generation_prompt"] = addGenerationPrompt }
        guard let out = await postJSON("\(origin)/apply-template", payload: payload, apiKey: apiKey) else {
            print("[AMEEM] G-01: /apply-template failed")
            return nil
        }
        return out["prompt"] as? String
    }

    /// Read the turn terminator by differential rendering (G-03).
    ///
    /// A chat model ends its turn on a token that is usually not its base EOS; if
    /// the engine watches the wrong one, generation runs past the turn and the
    /// model answers itself. Never hardcoded, never `</tool_call>` — stopping
    /// there severs parallel calls.
    private func turnTerminator(origin: String, model: String, apiKey: String) async -> String {
        func renderAssistant(_ text: String) async -> String {
            await render(origin: origin, model: model, apiKey: apiKey,
                         messages: [["role": "user", "content": "probe"],
                                    ["role": "assistant", "content": text]],
                         tools: nil, addGenerationPrompt: false) ?? ""
        }
        let a = await renderAssistant("AA")
        let b = await renderAssistant("BBBBBB")
        guard !a.isEmpty, !b.isEmpty else { return "" }
        var n = 0
        let limit = min(a.count, b.count)
        let aChars = Array(a), bChars = Array(b)
        while n < limit, aChars[aChars.count - 1 - n] == bChars[bChars.count - 1 - n] { n += 1 }
        guard n > 0 else { return "" }
        return String(aChars.suffix(n)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - HTTP helpers

    private func getJSON(_ urlString: String, apiKey: String) async -> [String: Any]? {
        guard let url = URL(string: urlString) else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        if !apiKey.isEmpty { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        guard let (data, _) = try? await URLSession.shared.data(for: req) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func postJSON(_ urlString: String, payload: [String: Any], apiKey: String) async -> [String: Any]? {
        guard let url = URL(string: urlString) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 600
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        guard let (data, _) = try? await URLSession.shared.data(for: req) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func intValue(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let n = any as? NSNumber { return n.intValue }
        if let d = any as? Double { return Int(d) }
        return nil
    }

    private func boolValue(_ any: Any?) -> Bool {
        if let b = any as? Bool { return b }
        if let n = any as? NSNumber { return n.boolValue }
        return false
    }
}
