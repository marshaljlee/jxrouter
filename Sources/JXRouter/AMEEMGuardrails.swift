import Foundation

/// AMEEM v3.0 — Adaptive Model Engine & Execution Middleware (core).
///
/// Port of the reference implementation `ameem_proxy.py` (companion to
/// "Adaptive Model Engine & Execution Middleware (AMEEM).md", v3.0) into
/// JXRouter's in-process request path.
///
/// Two non-negotiable invariants govern every decision in this file:
///
///   I1 — NOTHING IS KEYED ON A MODEL'S NAME. Every calibration decision is
///        derived from measured state: `n_params`/`n_ctx` (from `/v1/models`),
///        `chat_template_caps` (from `/props`), and the literal rendered prompt
///        (from `/apply-template`). A name-substring classifier is a bug
///        generator — `"27b"` contains `"7b"`, `"0.8b"` contains `"8b"` — and
///        is forbidden.
///
///   I2 — FAIL CLOSED. If a precondition cannot be verified, refuse the request
///        with a structured error naming the gate. Silent degradation is the
///        mechanism behind "the task came back unfinished".
///
/// This file is pure (no I/O, no live server) so every guardrail below is
/// exercisable by unit test. The probe and the request gate live in
/// `AMEEMCapabilityProbe.swift` and `AMEEMRequestGate.swift`.
enum AMEEM {
    /// Specification version this port implements.
    static let version = "3.0"

    /// 16 MB payload ceiling (preserved from the reference implementation).
    static let maxPayloadBytes = 16 * 1024 * 1024

    /// TTL for a cached capability profile, in seconds.
    static let probeTTL: TimeInterval = 300

    /// Tool observations larger than this are offloaded to disk (Pillar B).
    static let observationInlineLimit = 2000

    /// Hard bound on firewall recovery cycles (G-09). The reference documented
    /// three cycles but implemented none; here the bound is real state.
    static let recoveryCycleLimit = 3

    /// Directory for offloaded tool observations.
    static var scratchDirectory: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ProcessInfo.processInfo.environment["AMEEM_SCRATCH_DIR"] ?? "\(home)/.ameem/scratch"
    }
}

// MARK: - Guardrails

/// Enforcement mode. `enforce` is the specification's fail-closed default; the
/// other two exist because an operator whose local build reports no
/// `chat_template_caps` would otherwise have every tool request refused. The
/// mode is read once from the environment.
enum AMEEMMode: String {
    /// Refuse the request with a structured 409 naming the gate (I2, default).
    case enforce
    /// Log the violation and continue with whatever calibration is possible.
    case warn
    /// Do not run the request-time gate at all.
    case off

    static var current: AMEEMMode {
        switch (ProcessInfo.processInfo.environment["AMEEM_MODE"] ?? "enforce").lowercased() {
        case "warn": return .warn
        case "off", "0", "false": return .off
        default: return .enforce
        }
    }
}

/// Raised when a precondition cannot be verified. Always fails closed.
struct AMEEMGuardrailViolation: Error, LocalizedError, Equatable {
    let gate: String
    let detail: String

    var errorDescription: String? { "[\(gate)] \(detail)" }
    /// The message an HTTP 409 body carries — gate first, then the reason.
    var clientMessage: String { "[\(gate)] \(detail)" }
}

/// Assert a guardrail. No-op when satisfied, throws otherwise (I2).
@inline(__always)
func ameemRequire(_ condition: Bool, _ gate: String, _ detail: @autoclosure () -> String) throws {
    if !condition { throw AMEEMGuardrailViolation(gate: gate, detail: detail()) }
}

// MARK: - Tier (derived from measured parameters, never from a name)

/// The capability tier. Derived from `n_params` only — see I1 / contradiction
/// C-07, where a name-substring classifier put a 27B dense model in the 9B
/// tier because `"27b"` contains `"7b"`.
enum AMEEMTier: String, CaseIterable, Sendable {
    case micro = "MICRO"
    case mid = "MID"
    case macro = "MACRO"
}

enum AMEEMTiers {
    /// Per-step output budget. MICRO was raised from the reference's 384: a
    /// reasoning block plus a tool call routinely exceeds it (C-19).
    static let maxTokens: [AMEEMTier: Int] = [
        .micro: 1024, .mid: 2048, .macro: 4096,
    ]

    /// Minimum context window a tier expects. Used by the context-budget gate
    /// and the load-time reconciler.
    static let contextFloor: [AMEEMTier: Int] = [
        .micro: 8192, .mid: 16384, .macro: 32768,
    ]

    /// Classify from a measured parameter count. Returns nil when unmeasurable —
    /// an unverifiable profile is *degraded*, not guessed (G-18, C-23).
    static func tier(nParams: Int) -> AMEEMTier? {
        guard nParams > 0 else { return nil }
        if nParams < 4_000_000_000 { return .micro }
        if nParams < 14_000_000_000 { return .mid }
        return .macro
    }

    static func maxTokens(for tier: AMEEMTier) -> Int { maxTokens[tier] ?? 2048 }
    static func contextFloor(for tier: AMEEMTier) -> Int { contextFloor[tier] ?? 8192 }
}

// MARK: - Sampler policy (G-04)

/// The narrow sampler band. The most common cause of "never finishes" is a
/// temperature at or near zero on a reasoning-capable model: decoding becomes
/// greedy, the argmax continuation is the sentence it just wrote, and a
/// self-verification step can never be satisfied, so the model re-reads itself
/// until the token limit with zero content tokens. Measured incident: T=0.10.
///
/// The opposite failure is equally real: a high temperature loses format
/// adherence, so tool arguments degrade. The band is narrow on purpose.
///
/// C-20: the reference *overwrote* temperature unconditionally, which would
/// have converted the one working configuration (T=0.6) into a failing one.
/// This port clamps into the band and logs every override.
enum AMEEMSamplerPolicy {
    static let tempMin = 0.50
    static let tempMax = 0.75
    static let tempDefault = 0.60
    static let topP = 0.95
    static let topK = 20
    static let minP = 0.02
    static let repeatPenalty = 1.05

    struct ClampResult: Equatable {
        let value: Double
        /// True when the requested value fell outside the band and was moved.
        let overridden: Bool
        let note: String?
    }

    /// Force a requested temperature into the safe band.
    static func clampTemperature(_ requested: Double?) -> ClampResult {
        guard let requested else {
            return ClampResult(value: tempDefault, overridden: false, note: nil)
        }
        if requested < tempMin {
            return ClampResult(
                value: tempMin,
                overridden: true,
                note: "G-04: temperature \(fmt(requested)) is below the \(fmt(tempMin)) floor "
                    + "and risks a greedy reasoning loop; raised to \(fmt(tempMin))."
            )
        }
        if requested > tempMax {
            return ClampResult(
                value: tempMax,
                overridden: true,
                note: "G-04: temperature \(fmt(requested)) exceeds the \(fmt(tempMax)) ceiling "
                    + "and risks malformed tool arguments; lowered to \(fmt(tempMax))."
            )
        }
        return ClampResult(value: requested, overridden: false, note: nil)
    }

    /// The samplers AMEEM requires to be set explicitly. A missing setting is
    /// not a neutral setting — an absent `top_k` silently becomes the runtime
    /// default of 40 (C-17).
    static func requiredSamplers() -> [String: Double] {
        ["top_p": topP, "top_k": Double(topK), "min_p": minP, "repeat_penalty": repeatPenalty]
    }

    private static func fmt(_ value: Double) -> String { String(format: "%.2f", value) }
}

// MARK: - Terminal tools (G-13 / Pillar D)

/// A loop that terminates on prose can terminate early; a loop that terminates
/// on a *tool call* cannot. The offered suite must contain one of these.
enum AMEEMTools {
    static let terminalNames: Set<String> = [
        "task_complete", "finish", "done", "complete_task", "final_answer", "submit",
    ]

    /// Names in `offered` that count as a terminal tool (case-insensitive).
    static func terminalTools(offered: Set<String>) -> Set<String> {
        Set(offered.filter { terminalNames.contains($0.lowercased()) })
    }
}

// MARK: - Completion claims (G-09, C-16)

/// Prose that asserts work was performed. Used only by the firewall, and only
/// after recovery has already failed to find a call. Deliberately broad, and
/// honestly incomplete: it is English-only by construction (see the ledger).
enum AMEEMClaims {
    static let pattern = #"(?i)(?:\bi(?:'ve| have)\s+(?:now\s+)?(?:created|executed|run|completed|written|deleted|modified|generated|installed|saved|updated|added|removed|fixed|finished)"#
        + #"|\b(?:task|work|job|operation)\s+(?:is\s+|has\s+been\s+)?(?:complete|completed|done|finished|successful|successfully)"#
        + #"|\bsuccessfully\s+(?:created|executed|ran|run|completed|written|deleted|modified|generated|installed|saved|updated|added|removed|fixed)"#
        + #"|\b(?:the\s+)?(?:file|files|changes?|patch)\s+(?:has\s+been|have\s+been|is|are)\s+(?:created|written|saved|applied|modified|deleted)"#
        + #"|\b(?:all\s+)?(?:done|complete|completed|finished)\b[.!]?\s*$)"#

    private static let regex = try? NSRegularExpression(pattern: pattern)

    /// True when the text asserts completion of the work.
    static func hasCompletionClaim(_ text: String) -> Bool {
        guard !text.isEmpty, let regex else { return false }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.firstMatch(in: text, options: [], range: range) != nil
    }
}
