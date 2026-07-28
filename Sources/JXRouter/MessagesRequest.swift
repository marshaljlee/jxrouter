import Foundation

/// Parsed Anthropic Messages API request.
struct MessagesRequest {
    let json: [String: Any]
    let model: String
    let messages: [[String: Any]]
    let stream: Bool

    init(json: [String: Any]) {
        self.json = json
        self.model = json["model"] as? String ?? "claude-sonnet-4-20250514"
        self.messages = json["messages"] as? [[String: Any]] ?? []
        self.stream = json["stream"] as? Bool ?? false
    }
}
