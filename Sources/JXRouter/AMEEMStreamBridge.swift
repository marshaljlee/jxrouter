import Foundation

/// AMEEM v3.0 — SSE bridge for the streaming downgrade (G-15).
///
/// G-15 exists because a recovery pass needs the whole body: a turn whose text
/// has already been streamed to the client cannot be repaired, so the firewall
/// can never fire on it. AMEEM therefore downgrades `stream` to `false` by
/// default so recovery and the firewall can run — but a client that asked for
/// SSE must still *receive* SSE, or the fix breaks the transport it was meant
/// to protect. This bridge re-frames a complete response back into the SSE
/// dialect the caller expects.
enum AMEEMStreamBridge {

    /// Re-frame a complete Anthropic message into an Anthropic SSE stream.
    static func anthropicStream(fromMessageJSON json: [String: Any], model: String) -> AsyncStream<Data> {
        AsyncStream { continuation in
            let id = (json["id"] as? String) ?? "msg_\(UUID().uuidString.prefix(12))"
            let content = (json["content"] as? [[String: Any]]) ?? []
            let stopReason = (json["stop_reason"] as? String) ?? "end_turn"
            let usage = (json["usage"] as? [String: Any]) ?? [:]

            let startPayload: [String: Any] = [
                "type": "message_start",
                "message": ["id": id, "type": "message", "role": "assistant",
                            "content": [], "model": model,
                            "stop_reason": NSNull(), "stop_sequence": NSNull(),
                            "usage": usage],
            ]
            continuation.yield(Data(SSEFormatter.format(event: "message_start", data: string(startPayload)).utf8))

            for (index, block) in content.enumerated() {
                switch block["type"] as? String {
                case "text":
                    let rawText = (block["text"] as? String) ?? " "
                    let text = ResponseHygiene.stripControlTokens(rawText)
                    continuation.yield(Data(SSEFormatter.format(event: "content_block_start", data: string([
                        "type": "content_block_start", "index": index,
                        "content_block": ["type": "text", "text": ""],
                    ])).utf8))
                    if !text.isEmpty {
                        continuation.yield(Data(SSEFormatter.format(event: "content_block_delta", data: string([
                            "type": "content_block_delta", "index": index,
                            "delta": ["type": "text_delta", "text": text],
                        ])).utf8))
                    }
                case "thinking":
                    let thinking = (block["thinking"] as? String) ?? ""
                    continuation.yield(Data(SSEFormatter.format(event: "content_block_start", data: string([
                        "type": "content_block_start", "index": index,
                        "content_block": ["type": "thinking", "thinking": ""],
                    ])).utf8))
                    if !thinking.isEmpty {
                        continuation.yield(Data(SSEFormatter.format(event: "content_block_delta", data: string([
                            "type": "content_block_delta", "index": index,
                            "delta": ["type": "thinking_delta", "thinking": thinking],
                        ])).utf8))
                    }
                case "tool_use":
                    let name = (block["name"] as? String) ?? "unknown"
                    let toolID = (block["id"] as? String) ?? "call_\(UUID().uuidString.prefix(8))"
                    let input = block["input"] ?? [:]
                    continuation.yield(Data(SSEFormatter.format(event: "content_block_start", data: string([
                        "type": "content_block_start", "index": index,
                        "content_block": ["type": "tool_use", "id": toolID, "name": name, "input": [:]],
                    ])).utf8))
                    let partial = (try? JSONSerialization.data(withJSONObject: input))
                        .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                    continuation.yield(Data(SSEFormatter.format(event: "content_block_delta", data: string([
                        "type": "content_block_delta", "index": index,
                        "delta": ["type": "input_json_delta", "partial_json": partial],
                    ])).utf8))
                default:
                    break
                }
                continuation.yield(Data(SSEFormatter.blockStop(index: index).utf8))
            }

            continuation.yield(Data(SSEFormatter.format(event: "message_delta", data: string([
                "type": "message_delta",
                "delta": ["stop_reason": stopReason, "stop_sequence": NSNull()],
                "usage": usage,
            ])).utf8))
            continuation.yield(Data(SSEFormatter.format(event: "message_stop", data: "{\"type\":\"message_stop\"}").utf8))
            continuation.finish()
        }
    }

    /// Re-frame a complete OpenAI Chat Completions response into an OpenAI SSE
    /// stream, so an OpenAI client that asked for `stream: true` still parses it.
    static func openAIStream(fromResponseJSON json: [String: Any], model: String) -> AsyncStream<Data> {
        AsyncStream { continuation in
            let id = (json["id"] as? String) ?? "chatcmpl-\(UUID().uuidString.prefix(12))"
            let created = (json["created"] as? Int) ?? Int(Date().timeIntervalSince1970)
            let choice = (json["choices"] as? [[String: Any]])?.first ?? [:]
            let message = (choice["message"] as? [String: Any]) ?? [:]

            func chunk(_ delta: [String: Any], finish: String?) {
                var choice: [String: Any] = ["index": 0, "delta": delta]
                choice["finish_reason"] = finish.map { $0 as Any } ?? NSNull()
                let payload: [String: Any] = [
                    "id": id, "object": "chat.completion.chunk", "created": created, "model": model,
                    "choices": [choice],
                ]
                continuation.yield(Data(SSEFormatter.format(data: string(payload)).utf8))
            }

            chunk(["role": "assistant"], finish: nil)
            if let reasoning = message["reasoning_content"] as? String, !reasoning.isEmpty {
                chunk(["reasoning_content": reasoning], finish: nil)
            }
            if let content = message["content"] as? String, !content.isEmpty {
                chunk(["content": content], finish: nil)
            }
            if let toolCalls = message["tool_calls"] as? [[String: Any]] {
                for (index, call) in toolCalls.enumerated() {
                    let fn = (call["function"] as? [String: Any]) ?? [:]
                    chunk(["tool_calls": [[
                        "index": index,
                        "id": (call["id"] as? String) ?? "call_\(index)",
                        "type": "function",
                        "function": ["name": (fn["name"] as? String) ?? "unknown",
                                     "arguments": (fn["arguments"] as? String) ?? "{}"],
                    ]]], finish: nil)
                }
            }
            let finish = toolCallsPresent(message) ? "tool_calls"
                : ((choice["finish_reason"] as? String) ?? "stop")
            chunk([:], finish: finish)
            if let usage = json["usage"] {
                continuation.yield(Data(SSEFormatter.format(data: string([
                    "id": id, "object": "chat.completion.chunk", "created": created, "model": model,
                    "choices": [], "usage": usage,
                ])).utf8))
            }
            continuation.yield(Data("data: [DONE]\n\n".utf8))
            continuation.finish()
        }
    }

    private static func toolCallsPresent(_ message: [String: Any]) -> Bool {
        !((message["tool_calls"] as? [[String: Any]]) ?? []).isEmpty
    }

    private static func string(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}
