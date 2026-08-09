import Foundation

/// Response from a provider route — either a buffered body or an async SSE stream.
struct ProviderResponse: Sendable {
    let statusCode: Int
    let headers: [String: String]
    let body: Data
    var stream: AsyncStream<Data>?
    /// The upstream provider id that served this response (nil when the request
    /// was not routed to a provider). Set by the router on the success path.
    var servingProvider: String?
    /// True when a fallback provider served the request because the primary failed.
    var usedFallback: Bool = false
}

enum ProviderError: Error, LocalizedError {
    case providerUnavailable(providerId: String, statusCode: Int)

    var errorDescription: String? {
        switch self {
        case .providerUnavailable(let id, let code):
            return "Provider \(id) unavailable (HTTP \(code))"
        }
    }
}
