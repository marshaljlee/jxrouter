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
    ///
    /// A targeted, actionable hint always beats the generic list: "All
    /// providers failed: 401, 400" leaves the user guessing, while
    /// "Authentication failed — check the API key" tells them what to do.
    static func chainFailureMessage(_ failures: [(providerId: String, statusCode: Int)], lastError: Error?) -> String {
        // With no per-provider detail there is nothing to summarise, so the
        // underlying error speaks for itself — unwrapped, since the caller
        // already knows the chain failed.
        if failures.isEmpty {
            return lastError?.localizedDescription ?? "No provider configured"
        }

        // One entry per provider, keeping the FIRST failure. The same provider
        // appearing as primary and again as fallback is one problem, not two.
        var seen = Set<String>()
        let unique = failures.filter { seen.insert($0.providerId).inserted }

        for entry in unique {
            let name = ProviderPreset.preset(for: entry.providerId)?.name ?? entry.providerId
            switch entry.statusCode {
            case 401, 403:
                return "Authentication failed — check the API key configured for \(name)."
            case 404 where entry.providerId == "nvidia-nim":
                // NVIDIA 404s are almost always the account-level "Public API
                // Endpoints" permission, not a bad model name.
                return "NVIDIA NIM is returning 404 for this model. Enable \"Public API Endpoints\" for your NVIDIA account, or choose a model your key can access."
            default:
                continue
            }
        }

        if unique.allSatisfy({ $0.statusCode == 0 }) {
            return "Could not reach any provider — check your network connection and that the provider endpoints are reachable."
        }

        // Diagnostic list. Provider IDs rather than display names: this goes to
        // the client as a 503 body, and the ID is what the user actually sees
        // and configures in Settings, so it is unambiguous.
        let details = unique.map { entry in
            entry.statusCode == 0 ? "\(entry.providerId) (network error)" : "\(entry.providerId) (HTTP \(entry.statusCode))"
        }
        return "All providers failed: \(details.joined(separator: ", "))"
    }
}

/// Thrown when a single provider attempt exceeds its budget in the chain.
struct ProviderChainAttemptTimedOut: Error, LocalizedError {
    var errorDescription: String? { "Provider attempt timed out" }
}
