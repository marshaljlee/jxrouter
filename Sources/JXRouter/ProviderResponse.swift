import Foundation

struct ProviderResponse {
    var id: String = ""
    var object: String = ""
    var model: String = ""
    var choices: [Choice] = []
    var usage: Usage?
    var statusCode: Int = 200
    var headers: [String: String] = [:]
    var stream: AsyncStream<Data>?
    var body: Data = Data()
    /// Which provider served this request (set by the chain logic for logging).
    var servingProvider: String?
    /// True when the request was served by a fallback (index > 0 in the chain).
    var usedFallback: Bool = false

    // Custom memberwise initializer matching the call sites in ProviderRouter:
    // ProviderResponse(statusCode:headers:body:stream:) — stream must precede body.
    init(statusCode: Int, headers: [String: String], body: Data = Data()) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    init(statusCode: Int, headers: [String: String], body: Data = Data(), stream: AsyncStream<Data>?) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
        self.stream = stream
    }

    struct Choice: Codable {
        var index: Int = 0
        var message: Message?
        var delta: Delta?
        var finishReason: String?
        enum CodingKeys: String, CodingKey { case index, message, delta, finishReason = "finish_reason" }
    }

    struct Message: Codable {
        var role: String = ""
        var content: String?
        var reasoningContent: String?
        enum CodingKeys: String, CodingKey { case role, content, reasoningContent = "reasoning_content" }
    }

    struct Delta: Codable {
        var role: String?
        var content: String?
        var reasoningContent: String?
        var finishReason: String?
        enum CodingKeys: String, CodingKey { case role, content, reasoningContent = "reasoning_content", finishReason = "finish_reason" }
    }

    struct Usage: Codable {
        var promptTokens: Int = 0
        var completionTokens: Int = 0
        var totalTokens: Int = 0
        enum CodingKeys: String, CodingKey { case promptTokens = "prompt_tokens", completionTokens = "completion_tokens", totalTokens = "total_tokens" }
    }
}
