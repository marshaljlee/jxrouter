import Foundation

enum ProviderChainError: Error, LocalizedError {
    case allProvidersFailed([String])
    case noProviderConfigured
    case invalidModel(String)

    var errorDescription: String? {
        switch self {
        case .allProvidersFailed(let ids): return "All providers failed: \(ids.joined(separator: ", "))"
        case .noProviderConfigured: return "No provider configured"
        case .invalidModel(let m): return "Invalid model: \(m)"
        }
    }

    /// Human-readable message summarising why every provider in the chain
    /// failed — used by the router to return a 503 with actionable detail.
    static func chainFailureMessage(_ failures: [(providerId: String, statusCode: Int)], lastError: Error?) -> String {
        if failures.isEmpty, let err = lastError {
            return "All providers failed: \(err.localizedDescription)"
        }
        let details = failures.map { entry in
            let name = ProviderPreset.preset(for: entry.providerId)?.name ?? entry.providerId
            return entry.statusCode == 0 ? "\(name) (network error)" : "\(name) (\(entry.statusCode))"
        }
        return "All providers failed: \(details.joined(separator: ", "))"
    }
}

/// Thrown when a single provider attempt exceeds its budget in the chain.
struct ProviderChainAttemptTimedOut: Error, LocalizedError {
    var errorDescription: String? { "Provider attempt timed out" }
}
