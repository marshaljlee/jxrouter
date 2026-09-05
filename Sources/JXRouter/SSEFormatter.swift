import Foundation

/// Formats Server-Sent Events for Anthropic-compatible streaming.
enum SSEFormatter {
    /// Format a single SSE event with event name and JSON data payload.
    static func format(event: String, data: String) -> String {
        "event: \(event)\ndata: \(data)\n\n"
    }

    /// Format a raw SSE data line (no event name).
    static func format(data: String) -> String {
        "data: \(data)\n\n"
    }

    /// Content block stop event for a given block index.
    static func blockStop(index: Int) -> String {
        format(event: "content_block_stop", data: "{\"type\":\"content_block_stop\",\"index\":\(index)}")
    }
}
