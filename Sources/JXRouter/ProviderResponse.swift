import Foundation

/// Response from a provider route — either a buffered body or an async SSE stream.
struct ProviderResponse: Sendable {
    let statusCode: Int
    let headers: [String: String]
    let body: Data
    var stream: AsyncStream<Data>?
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
