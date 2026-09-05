import Foundation

/// Translates between the OpenAI Responses API format and the Chat Completions
/// format so requests can flow through the shared Chat Completions chain.
enum ResponsesTranslator {

    /// Convert an OpenAI Responses request body to a Chat Completions body.
    static func toChatCompletions(_ requestJSON: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]

        if let model = requestJSON["model"] as? String {
            result["model"] = model
        }
        if let instructions = requestJSON["instructions"] as? String {
            result["messages"] = [["role": "system", "content": instructions]]
        }
        if let input = requestJSON["input"] as? String {
            var messages = result["messages"] as? [[String: Any]] ?? []
            messages.append(["role": "user", "content": input])
            result["messages"] = messages
        } else if let inputArray = requestJSON["input"] as? [[String: Any]] {
            var messages = result["messages"] as? [[String: Any]] ?? []
            messages.append(contentsOf: inputArray)
            result["messages"] = messages
        }
        if let stream = requestJSON["stream"] as? Bool { result["stream"] = stream }
        if let maxOutput = requestJSON["max_output_tokens"] as? Int { result["max_tokens"] = maxOutput }

        return result
    }

    /// Convert a Chat Completions SSE stream into a Responses SSE stream.
    static func translateChatSSEToResponses(_ stream: AsyncStream<Data>, model: String) -> AsyncStream<Data> {
        AsyncStream { continuation in
            Task {
                let responseId = "resp_\(UUID().uuidString.prefix(12))"
                // Send the response.created event
                let created = SSEFormatter.format(event: "response.created", data: "{\"type\":\"response.created\",\"response\":{\"id\":\"\(responseId)\",\"object\":\"response\",\"status\":\"in_progress\",\"model\":\"\(model)\"}}")
                continuation.yield(Data(created.utf8))

                for await chunk in stream {
                    // Forward each chunk as-is (Chat Completions SSE passes through)
                    continuation.yield(chunk)
                }

                // Send response.completed
                let completed = SSEFormatter.format(event: "response.completed", data: "{\"type\":\"response.completed\",\"response\":{\"id\":\"\(responseId)\",\"object\":\"response\",\"status\":\"completed\"}}")
                continuation.yield(Data(completed.utf8))
                continuation.finish()
            }
        }
    }

    /// Convert a Chat Completions JSON response to a Responses JSON body.
    static func toResponses(_ chatJSON: [String: Any], model: String) -> [String: Any] {
        let responseId = "resp_\(UUID().uuidString.prefix(12))"
        var output: [[String: Any]] = []

        if let choices = chatJSON["choices"] as? [[String: Any]] {
            for choice in choices {
                if let message = choice["message"] as? [String: Any],
                   let content = message["content"] as? String {
                    output.append([
                        "type": "message",
                        "content": [["type": "output_text", "text": content]]
                    ])
                }
            }
        }

        return [
            "id": responseId,
            "object": "response",
            "status": "completed",
            "model": model,
            "output": output,
        ]
    }
}
