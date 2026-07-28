import Foundation

/// Shared HTTP helpers — eliminates duplication across ProxyServer, DirectTLSHandler,
/// and ProviderRouter (CurlClient).
enum HTTPUtils {

    /// Map an HTTP status code to its reason phrase.
    static func statusText(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 201: return "Created"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 408: return "Request Timeout"
        case 429: return "Too Many Requests"
        case 500: return "Internal Server Error"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        default: return "Unknown"
        }
    }

    /// Parse raw HTTP headers from a request or response string.
    /// Skips the request/status line and stops at the first empty line.
    static func parseHeaders(from raw: String) -> [String: String] {
        var headers: [String: String] = [:]
        let lines = raw.components(separatedBy: "\r\n")
        for line in lines.dropFirst() {
            guard !line.isEmpty else { break }
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2 {
                let key = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
                let value = parts[1].trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }
        }
        return headers
    }

    /// Extract the body from a raw HTTP request/response string.
    /// Returns everything after the first `\r\n\r\n`.
    static func extractBody(from raw: String) -> Data {
        guard let range = raw.range(of: "\r\n\r\n") else { return Data() }
        return Data(raw[range.upperBound...].utf8)
    }
}
