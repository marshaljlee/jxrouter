import Foundation

/// Server-Sent Events formatting for Anthropic Messages API.
///
/// Documents the spec mismatch between OpenAI and Anthropic SSE formats:
/// - OpenAI streams `choices[0].delta.content` continuously.
/// - Anthropic requires a strict lifecycle: `message_start` → `content_block_start` →
///   `content_block_delta` → `content_block_stop` → `message_delta` → `message_stop`.
/// - OpenAI tools arrive as `tool_calls` with incremental JSON string chunks.
/// - Anthropic expects `content_block_start` for `tool_use`, then `input_json_delta`.
enum SSEFormatter {

    static func format(event: String, data: String) -> String {
        "event: \(event)\ndata: \(data)\n\n"
    }

    static func textDelta(text: String, index: Int = 0) -> String {
        let str = String(data: (try? JSONEncoder().encode(text)) ?? Data(), encoding: .utf8) ?? "\"\""
        return format(event: "content_block_delta", data: "{\"type\":\"content_block_delta\",\"index\":\(index),\"delta\":{\"type\":\"text_delta\",\"text\":\(str)}}")
    }

    static func textBlockStart(index: Int) -> String {
        format(event: "content_block_start", data: "{\"type\":\"content_block_start\",\"index\":\(index),\"content_block\":{\"type\":\"text\",\"text\":\"\"}}")
    }

    /// `message_start` without any content block — blocks are opened lazily when
    /// the first delta of that kind arrives, so reasoning (thinking block) can
    /// claim index 0 ahead of text.
    static func messageStart(model: String) -> String {
        let msgId = "msg_\(UUID().uuidString.prefix(8))"
        return format(event: "message_start", data: "{\"type\":\"message_start\",\"message\":{\"id\":\"\(msgId)\",\"type\":\"message\",\"role\":\"assistant\",\"model\":\"\(model)\",\"content\":[],\"usage\":{\"input_tokens\":0,\"output_tokens\":0}}}")
    }

    /// Start an Anthropic `thinking` content block so reasoning tokens from
    /// OpenAI-compatible providers (DeepSeek, OpenCode, etc.) are preserved as
    /// thinking tokens instead of being flattened into visible text.
    static func thinkingStart(index: Int) -> String {
        format(event: "content_block_start", data: "{\"type\":\"content_block_start\",\"index\":\(index),\"content_block\":{\"type\":\"thinking\",\"thinking\":\"\"}}")
    }

    static func thinkingDelta(text: String, index: Int = 0) -> String {
        let str = String(data: (try? JSONEncoder().encode(text)) ?? Data(), encoding: .utf8) ?? "\"\""
        return format(event: "content_block_delta", data: "{\"type\":\"content_block_delta\",\"index\":\(index),\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\(str)}}")
    }

    static func toolUseStart(index: Int, id: String, name: String) -> String {
        let nameStr = String(data: (try? JSONEncoder().encode(name)) ?? Data(), encoding: .utf8) ?? "\"\""
        return format(event: "content_block_start", data: "{\"type\":\"content_block_start\",\"index\":\(index),\"content_block\":{\"type\":\"tool_use\",\"id\":\"\(id)\",\"name\":\(nameStr),\"input\":{}}}")
    }

    static func toolUseDelta(index: Int, args: String) -> String {
        let argStr = String(data: (try? JSONEncoder().encode(args)) ?? Data(), encoding: .utf8) ?? "\"\""
        return format(event: "content_block_delta", data: "{\"type\":\"content_block_delta\",\"index\":\(index),\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\(argStr)}}")
    }

    static func blockStop(index: Int) -> String {
        format(event: "content_block_stop", data: "{\"type\":\"content_block_stop\",\"index\":\(index)}")
    }

    static func messageDelta(stopReason: String, outputTokens: Int) -> String {
        format(event: "message_delta", data: "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"\(stopReason)\",\"stop_sequence\":null},\"usage\":{\"output_tokens\":\(outputTokens)}}")
    }
}
