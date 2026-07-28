import Foundation

/// Translates between Anthropic Messages API and OpenAI Chat Completions API formats.
enum MessageTranslator {

    // MARK: - Anthropic → OpenAI

    static func toOpenAIChat(request: MessagesRequest, model: String) -> [String: Any] {
        var messages: [[String: Any]] = []

        for msg in request.messages {
            let role = msg["role"] ?? "user"

            if let str = msg["content"] as? String {
                messages.append(["role": role, "content": str])
            } else if let blocks = msg["content"] as? [[String: Any]] {
                var contentArr: [[String: Any]] = []
                for block in blocks {
                    if let type = block["type"] as? String {
                        if type == "text", let text = block["text"] as? String {
                            contentArr.append(["type": "text", "text": text])
                        } else if type == "image", let source = block["source"] as? [String: Any] {
                            if let mediaType = source["media_type"] as? String, let data = source["data"] as? String {
                                contentArr.append([
                                    "type": "image_url",
                                    "image_url": ["url": "data:\(mediaType);base64,\(data)"]
                                ])
                            }
                        }
                    }
                }
                messages.append(["role": role, "content": contentArr])
            }
        }

        if let system = request.json["system"] {
            var sysContent = ""
            if let str = system as? String { sysContent = str }
            else if let blocks = system as? [[String: Any]] {
                sysContent = blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
            }
            if !sysContent.isEmpty {
                messages.insert(["role": "system", "content": sysContent], at: 0)
            }
        }

        var body: [String: Any] = [
            "model": model,
            "messages": messages,
            "max_tokens": request.json["max_tokens"] as? Int ?? 4096,
            "stream": request.stream,
            "temperature": request.json["temperature"] as? Double ?? 0.7,
        ]

        if let stop = request.json["stop_sequences"] as? [String] { body["stop"] = stop }

        if let tools = request.json["tools"] as? [[String: Any]], !tools.isEmpty {
            body["tools"] = tools.map { ["type": "function", "function": ["name": $0["name"] ?? "", "description": $0["description"] ?? "", "parameters": $0["input_schema"] ?? [:]]] }
            if let toolChoice = request.json["tool_choice"] as? [String: Any] {
                switch toolChoice["type"] as? String {
                case "any": body["tool_choice"] = "required"
                case "tool": body["tool_choice"] = ["type": "function", "function": ["name": toolChoice["name"]]]
                default: body["tool_choice"] = "auto"
                }
            }
        }

        if let thinking = request.json["thinking"] as? [String: Any], thinking["type"] as? String == "enabled" {
            body["reasoning_effort"] = "high"
        }

        return body
    }

    // MARK: - OpenAI → Anthropic SSE

    static func openAIToAnthropicSSE(chunk: [String: Any], model: String, alreadyStarted: Bool = false) -> [String] {
        var events: [String] = []
        guard let choices = chunk["choices"] as? [[String: Any]] else { return events }

        for choice in choices {
            let delta = choice["delta"] as? [String: Any] ?? [:]
            let index = choice["index"] as? Int ?? 0

            if delta["role"] as? String == "assistant", !alreadyStarted {
                events.append(contentsOf: SSEFormatter.assistantMessageStart(model: model))
            }

            // Handle standard text content
            if let content = delta["content"] as? String, !content.isEmpty {
                events.append(SSEFormatter.textDelta(text: content))
            }

            // Handle reasoning_content (used by DeepSeek, OpenCode, etc.)
            // Treat as regular text content so the response is not silently lost.
            if let reasoning = delta["reasoning_content"] as? String, !reasoning.isEmpty {
                events.append(SSEFormatter.textDelta(text: reasoning))
            }

            if let toolCalls = delta["tool_calls"] as? [[String: Any]] {
                for tc in toolCalls {
                    let tcIdx = tc["index"] as? Int ?? 0
                    if let fn = tc["function"] as? [String: Any] {
                        if let name = fn["name"] as? String {
                            events.append(SSEFormatter.toolUseStart(index: tcIdx, id: "\(name)_\(tcIdx)", name: name))
                        }
                        if let args = fn["arguments"] as? String {
                            events.append(SSEFormatter.toolUseDelta(index: tcIdx, args: args))
                        }
                    }
                }
            }

            if let finishReason = choice["finish_reason"] as? String {
                let stopReason: String
                switch finishReason {
                case "tool_calls": stopReason = "tool_use"
                case "length": stopReason = "max_tokens"
                default: stopReason = "end_turn"
                }

                let usage = chunk["usage"] as? [String: Int] ?? [:]
                let outputTokens = usage["completion_tokens"] ?? 0
                events.append(contentsOf: SSEFormatter.messageStop(index: index, stopReason: stopReason, outputTokens: outputTokens))
            }
        }

        return events
    }

    // MARK: - OpenAI → Anthropic (non-streaming)

    static func convertOpenAIResponseToAnthropic(data: Data, model: String) -> Data {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return data }

        let choices = json["choices"] as? [[String: Any]] ?? []
        let choice = choices.first?["message"] as? [String: Any]
        var content = choice?["content"] as? String ?? ""
        // Some providers (OpenCode, DeepSeek) put the response in reasoning_content
        // with content being empty. Fall back to reasoning_content if content is empty.
        if content.isEmpty, let reasoning = choice?["reasoning_content"] as? String {
            content = reasoning
        }
        let finishReason = choice?["finish_reason"] as? String
        let usage = json["usage"] as? [String: Int] ?? [:]

        let stopReason: String
        switch finishReason {
        case "tool_calls": stopReason = "tool_use"
        case "length": stopReason = "max_tokens"
        default: stopReason = "end_turn"
        }

        var contentBlocks: [[String: Any]] = []
        if !content.isEmpty {
            contentBlocks.append(["type": "text", "text": content])
        }

        if let toolCalls = choice?["tool_calls"] as? [[String: Any]] {
            for tc in toolCalls {
                if let fn = tc["function"] as? [String: Any],
                   let name = fn["name"] as? String,
                   let argsStr = fn["arguments"] as? String {
                    let args = (try? JSONSerialization.jsonObject(with: Data(argsStr.utf8))) as? [String: Any] ?? ["raw_arguments": argsStr]
                    contentBlocks.append([
                        "type": "tool_use",
                        "id": "\(name)_\(UUID().uuidString.prefix(8))",
                        "name": name,
                        "input": args
                    ])
                }
            }
        }

        let anthropicResponse: [String: Any] = [
            "id": "msg_\(Int(Date().timeIntervalSince1970))",
            "type": "message",
            "role": "assistant",
            "content": contentBlocks,
            "model": model,
            "stop_reason": stopReason,
            "stop_sequence": nil as Any? as Any,
            "usage": [
                "input_tokens": usage["prompt_tokens"] ?? 0,
                "output_tokens": usage["completion_tokens"] ?? 0,
            ],
        ]

        return (try? JSONSerialization.data(withJSONObject: anthropicResponse)) ?? data
    }
}
