import Foundation
import CryptoKit

/// AMEEM v3.0 — the hallucination firewall, corrected and bounded
/// (Pillar C, G-09, C-04, C-05, C-14).
///
/// Order of operations, which is the whole fix:
///   1. **Recover first.** Extract text-channel calls into real `tool_calls`,
///      filtered against the offered tool list. If anything is recovered, the
///      turn is good — stop.
///   2. **Then evaluate.** Fire only if: no native call, no recovered call, a
///      completion claim is present, a terminal tool was offered, and the cycle
///      budget is not exhausted.
///   3. **Bound explicitly.** State keyed by `sha256(model + first user turn)`,
///      max three cycles. The reference documented this bound but implemented
///      none, so a task that succeeded and then legitimately summarised could
///      never terminate.
///   4. **Then surface.** On exhaustion, return a structured failure to the
///      client. Never loop.
final class AMEEMFirewall: @unchecked Sendable {

    struct State {
        var cycles: Int = 0
        var lastSeen: Date = Date()
    }

    private var state: [String: State] = [:]
    private let lock = NSLock()

    /// The stable session key: model plus the first user turn.
    func key(model: String, firstUserTurn: String) -> String {
        let digest = SHA256.hash(data: Data("\(model)\u{0}\(firstUserTurn)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    func cycleCount(for key: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return state[key]?.cycles ?? 0
    }

    /// Reset all session state (used by tests and on a proxy restart).
    func reset() {
        lock.lock(); defer { lock.unlock() }
        state.removeAll()
    }

    /// The result of one evaluation.
    ///
    /// `changed` is deliberately separate from `fired`: a successful recovery
    /// returns a repaired message with `fired == false` (recovery
    /// short-circuits evaluation). A caller that keyed on `fired` alone would
    /// discard the recovered `tool_calls` and hand the client the call buried in
    /// `content` — the exact failure V8 exists to catch.
    struct Outcome {
        var message: [String: Any]
        var fired: Bool
        var changed: Bool
    }

    /// Returns the possibly-repaired assistant message.
    func evaluate(
        model: String,
        firstUserTurn: String,
        message: [String: Any],
        dialect: AMEEMDialect?,
        offeredTools: Set<String>,
        terminalTools: Set<String>
    ) -> Outcome {
        let content = (message["content"] as? String) ?? ""
        let nativeCalls = (message["tool_calls"] as? [[String: Any]]) ?? []
        if !nativeCalls.isEmpty { return Outcome(message: message, fired: false, changed: false) }

        // 1. Recover first — a recovered call makes the turn good.
        let recovered = AMEEMRecovery.recoverToolCalls(
            content: content, dialect: dialect, offeredTools: offeredTools)
        if !recovered.isEmpty {
            var repaired = message
            repaired["tool_calls"] = recovered
            repaired["content"] = NSNull()
            print("[AMEEM] G-08: recovered \(recovered.count) text-channel call(s): "
                + "\(recovered.compactMap { ($0["function"] as? [String: Any])?["name"] as? String })")
            return Outcome(message: repaired, fired: false, changed: true)
        }

        // 2. Evaluate — only a genuine completion claim on a terminal-capable
        //    suite, with budget remaining, may fire.
        if terminalTools.isEmpty { return Outcome(message: message, fired: false, changed: false) }
        if !AMEEMClaims.hasCompletionClaim(content) { return Outcome(message: message, fired: false, changed: false) }

        let key = key(model: model, firstUserTurn: firstUserTurn)
        lock.lock()
        var current = state[key] ?? State()
        if current.cycles >= AMEEM.recoveryCycleLimit {
            lock.unlock()
            print("[AMEEM] G-09: recovery budget exhausted (\(current.cycles)). Surfacing failure "
                + "to the client instead of looping.")
            var repaired = message
            repaired["content"] = "AMEEM: the model claimed completion without dispatching a tool "
                + "call, and the \(AMEEM.recoveryCycleLimit)-cycle recovery budget is exhausted. "
                + "This task cannot be completed with the current model configuration. "
                + "Reported rather than retried."
            return Outcome(message: repaired, fired: true, changed: true)
        }
        current.cycles += 1
        current.lastSeen = Date()
        state[key] = current
        lock.unlock()

        var repaired = message
        repaired["content"] = "AMEEM VALIDATION ERROR: you stated the work was performed but no "
            + "tool call was dispatched, so nothing changed on disk. Emit the tool call now, or "
            + "call the terminal tool (\(terminalTools.sorted().joined(separator: ", "))) if the "
            + "goal is met."
        return Outcome(message: repaired, fired: true, changed: true)
    }

    /// Apply the firewall to a whole non-streaming response body. Returns the
    /// possibly-rewritten body and whether anything changed.
    func apply(
        toBody body: Data,
        model: String,
        firstUserTurn: String,
        dialect: AMEEMDialect?,
        offeredTools: Set<String>,
        terminalTools: Set<String>
    ) -> (body: Data, changed: Bool) {
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              var choices = root["choices"] as? [[String: Any]],
              var first = choices.first,
              let message = first["message"] as? [String: Any] else {
            return (body, false)
        }
        let outcome = evaluate(
            model: model, firstUserTurn: firstUserTurn, message: message,
            dialect: dialect, offeredTools: offeredTools, terminalTools: terminalTools)
        guard outcome.changed else { return (body, false) }
        first["message"] = outcome.message
        // OpenAI semantics: a turn carrying tool calls ends on `tool_calls`.
        first["finish_reason"] = ((outcome.message["tool_calls"] as? [[String: Any]]) ?? []).isEmpty
            ? "stop" : "tool_calls"
        choices[0] = first
        var out = root
        out["choices"] = choices
        return ((try? JSONSerialization.data(withJSONObject: out)) ?? body, true)
    }
}
