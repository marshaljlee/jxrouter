import Foundation

/// Anthropic Messages API request body. Parsed from the incoming JSON and
/// forwarded to providers after translation to OpenAI format.
struct MessagesRequest {
    var model: String = ""
    var messages: [[String: Any]] = []
    var system: Any?
    var maxTokens: Int?
    var temperature: Double?
    var stream: Bool = false
    /// The raw JSON dictionary as it arrived from the client — passed through
    /// to `direct` (Anthropic) which expects an untouched body.
    var json: [String: Any]

    /// Initialise from the raw request JSON.
    init(json: [String: Any]) {
        self.json = json
        self.model = json["model"] as? String ?? ""
        self.messages = json["messages"] as? [[String: Any]] ?? []
        self.system = json["system"]
        self.maxTokens = json["max_tokens"] as? Int
        self.temperature = json["temperature"] as? Double
        self.stream = json["stream"] as? Bool ?? false
    }
}
