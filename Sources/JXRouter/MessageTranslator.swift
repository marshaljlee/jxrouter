import Foundation

/// Translates between Anthropic Messages API and OpenAI Chat Completions API formats.
enum MessageTranslator {

    // MARK: - Anthropic → OpenAI

    static func toOpenAIChat(request: MessagesRequest, model: String, enableThinking: Bool = true) -> [String: Any] {
        var messages: [[String: Any]] = []

        for msg in request.messages {
            let role = msg["role"] ?? "user"

            if let str = msg["content"] as? String {
                messages.append(["role": role, "content": str])
            } else if let blocks = msg["content"] as? [[String: Any]] {
                var contentArr: [[String: Any]] = []
                var toolCalls: [[String: Any]] = []
                var toolResults: [[String: Any]] = []
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
                        } else if type == "tool_use", let id = block["id"] as? String, let name = block["name"] as? String {
                            var argsString = "{}"
                            if let input = block["input"] {
                                if let str = input as? String {
                                    argsString = str
                                } else if JSONSerialization.isValidJSONObject(input),
                                          let data = try? JSONSerialization.data(withJSONObject: input) {
                                    argsString = String(data: data, encoding: .utf8) ?? "{}"
                                }
                            }
                            toolCalls.append([
                                "id": id,
                                "type": "function",
                                "function": ["name": name, "arguments": argsString]
                            ])
                        } else if type == "tool_result", let toolUseId = block["tool_use_id"] as? String {
                            var resultContent: Any = ""
                            if let content = block["content"] {
                                if let str = content as? String {
                                    resultContent = str
                                } else if let arr = content as? [Any] {
                                    resultContent = arr
                                }
                            }
                            toolResults.append([
                                "role": "tool",
                                "tool_call_id": toolUseId,
                                "content": resultContent
                            ])
                        }
                        // Other block types ("document", "thinking") are dropped, as before.
                    }
                }

                // Each Anthropic tool_result block becomes its own OpenAI "tool" message
                // so tool results actually reach the model. Emitted in place, after the
                // message that carried them, preserving the original ordering.
                for toolResult in toolResults {
                    messages.append(toolResult)
                }

                // Messages with text and/or tool calls keep their original shape, except
                // that an empty content array is never emitted (OpenAI rejects it) —
                // use content: null instead. A message that only carried tool_results
                // produces no content message of its own.
                if !contentArr.isEmpty || !toolCalls.isEmpty || toolResults.isEmpty {
                    var msgDict: [String: Any] = ["role": role]
                    if contentArr.isEmpty {
                        msgDict["content"] = NSNull()
                    } else {
                        msgDict["content"] = contentArr
                    }
                    if !toolCalls.isEmpty {
                        msgDict["tool_calls"] = toolCalls
                    }
                    messages.append(msgDict)
                }
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

        // Reasoning is only requested when pass-through is enabled AND this is not
        // a tool-calling turn. Many OpenAI-compatible providers reject or ignore
        // reasoning mode when the conversation contains tool_use/tool_result
        // (e.g. DeepSeek-R1 cannot combine reasoning with function calling).
        let isToolTurn = request.messages.contains { message in
            if (message["role"] as? String) == "tool" { return true }
            guard let blocks = message["content"] as? [[String: Any]] else { return false }
            return blocks.contains { block in
                let type = block["type"] as? String
                return type == "tool_use" || type == "tool_result"
            }
        }

        if enableThinking, !isToolTurn,
           let thinking = request.json["thinking"] as? [String: Any],
           thinking["type"] as? String == "enabled" {
            body["reasoning_effort"] = "high"
        }

        return body
    }

    // MARK: - Reasoning Capability Heuristic

    /// Providers known to emit `reasoning_content` / accept `reasoning_effort`
    /// regardless of the specific model. opencode-zen/opencode-go are excluded
    /// on purpose: their capability is purely model-driven (big-pickle vs
    /// big-pickle-reasoning), so the model-name signal decides for them.
    /// Other providers still get reasoning pass-through when the model name
    /// signals it, or when the user sets the policy to `.on` explicitly.
    private static let reasoningCapableProviderIDs: Set<String> = [
        "deepseek", "openrouter",
        "openai", "kimi", "kimi-code", "xai", "zai",
    ]

    /// Heuristic used by the `.auto` reasoning policy: a provider/model is
    /// reasoning-capable when the resolved model name signals reasoning, or the
    /// provider is known to emit reasoning content.
    static func isReasoningCapable(providerId: String, model: String) -> Bool {
        let lower = model.lowercased()
        // Explicit reasoning signals in the model name win.
        if lower.contains("reason") || lower.contains("thinking") { return true }
        if lower.contains("deepseek-reasoner") { return true }
        let tokens = lower.split { !$0.isLetter && !$0.isNumber }
        if tokens.contains("r1") || tokens.contains("k1") || tokens.contains("k2") { return true }
        // Qwen3-style local models emit reasoning_content through many servers.
        if lower.contains("qwen") { return true }
        // Known non-reasoning models of capable providers (checked before the
        // provider-list fallback so deepseek-chat/v3 don't request reasoning).
        if lower.contains("deepseek-chat") || lower.contains("deepseek-v3") { return false }
        return reasoningCapableProviderIDs.contains(providerId)
    }

    // MARK: - OpenAI → Anthropic SSE

    /// Mutable per-stream state used while translating one OpenAI SSE stream
    /// into Anthropic events. Block indices are allocated sequentially so a
    /// `thinking` block (index 0) can precede the `text` block (index 1) exactly
    /// like a real Anthropic extended-thinking stream.
    struct OpenAIStreamState {
        var messageStarted = false
        var thinkingIndex: Int?
        var textIndex: Int?
        /// Upstream OpenAI tool-call index → Anthropic block index.
        var toolBlockMap: [Int: Int] = [:]
        /// Anthropic tool block indices whose `content_block_start` has been emitted.
        var toolBlocksStarted: Set<Int> = []
        /// Anthropic block indices opened so far, in open order.
        var openedBlocks: [Int] = []
        var finished = false
        private var nextBlockIndex = 0

        mutating func allocateBlock() -> Int {
            defer { nextBlockIndex += 1 }
            return nextBlockIndex
        }
    }

    static func openAIToAnthropicSSE(chunk: [String: Any], model: String, state: inout OpenAIStreamState, enableThinking: Bool = true) -> [String] {
        var events: [String] = []
        guard let choices = chunk["choices"] as? [[String: Any]] else { return events }

        for choice in choices {
            let delta = choice["delta"] as? [String: Any] ?? [:]

            if delta["role"] as? String == "assistant", !state.messageStarted {
                events.append(SSEFormatter.messageStart(model: model))
                state.messageStarted = true
            }

            // Reasoning content (DeepSeek's reasoning_content, OpenRouter's
            // reasoning, etc.) is mapped to an Anthropic `thinking` block so the
            // client preserves it as thinking tokens. When pass-through is off
            // the reasoning is deliberately dropped — never flattened into text.
            let reasoning = (delta["reasoning_content"] as? String) ?? (delta["reasoning"] as? String) ?? ""
            if !reasoning.isEmpty, enableThinking {
                if state.thinkingIndex == nil {
                    let idx = state.allocateBlock()
                    state.thinkingIndex = idx
                    state.openedBlocks.append(idx)
                    events.append(SSEFormatter.thinkingStart(index: idx))
                }
                if let idx = state.thinkingIndex {
                    events.append(SSEFormatter.thinkingDelta(text: reasoning, index: idx))
                }
            }

            // Standard text content
            if let content = delta["content"] as? String, !content.isEmpty {
                if state.textIndex == nil {
                    let idx = state.allocateBlock()
                    state.textIndex = idx
                    state.openedBlocks.append(idx)
                    events.append(SSEFormatter.textBlockStart(index: idx))
                }
                if let idx = state.textIndex {
                    events.append(SSEFormatter.textDelta(text: content, index: idx))
                }
            }

            if let toolCalls = delta["tool_calls"] as? [[String: Any]] {
                for tc in toolCalls {
                    let upstreamIdx = tc["index"] as? Int ?? 0
                    let blockIdx: Int
                    if let existing = state.toolBlockMap[upstreamIdx] {
                        blockIdx = existing
                    } else {
                        blockIdx = state.allocateBlock()
                        state.toolBlockMap[upstreamIdx] = blockIdx
                    }
                    // The block's index is reserved on first sight so delta chunks can
                    // reference it, but the Anthropic content_block_start is only
                    // emitted once a tool name is known — a name arriving in a later
                    // chunk still opens the block. Only started blocks are closed.
                    if let fn = tc["function"] as? [String: Any],
                       let name = fn["name"] as? String,
                       !state.toolBlocksStarted.contains(blockIdx) {
                        state.toolBlocksStarted.insert(blockIdx)
                        state.openedBlocks.append(blockIdx)
                        events.append(SSEFormatter.toolUseStart(index: blockIdx, id: tc["id"] as? String ?? "\(name)_\(upstreamIdx)", name: name))
                    }
                    if let fn = tc["function"] as? [String: Any], let args = fn["arguments"] as? String, !args.isEmpty {
                        events.append(SSEFormatter.toolUseDelta(index: blockIdx, args: args))
                    }
                }
            }

            if let finishReason = choice["finish_reason"] as? String, !state.finished {
                state.finished = true
                let stopReason: String
                switch finishReason {
                case "tool_calls": stopReason = "tool_use"
                case "length": stopReason = "max_tokens"
                default: stopReason = "end_turn"
                }

                let usage = chunk["usage"] as? [String: Int] ?? [:]
                let outputTokens = usage["completion_tokens"] ?? 0
                // Close every opened content block in order, then the message.
                for blockIndex in state.openedBlocks {
                    events.append(SSEFormatter.blockStop(index: blockIndex))
                }
                events.append(SSEFormatter.messageDelta(stopReason: stopReason, outputTokens: outputTokens))
            }
        }

        return events
    }

    // MARK: - OpenAI → Anthropic (non-streaming)

    static func convertOpenAIResponseToAnthropic(data: Data, model: String, enableThinking: Bool = true) -> Data {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return data }

        let choices = json["choices"] as? [[String: Any]] ?? []
        let choice = choices.first?["message"] as? [String: Any]
        let content = choice?["content"] as? String ?? ""
        // Some providers (OpenCode, DeepSeek) put the response in reasoning_content
        // with content being empty. Pass it through as an Anthropic thinking block
        // when enabled so thinking tokens are preserved.
        let reasoning = choice?["reasoning_content"] as? String ?? ""
        let finishReason = choice?["finish_reason"] as? String
        let usage = json["usage"] as? [String: Int] ?? [:]

        let stopReason: String
        switch finishReason {
        case "tool_calls": stopReason = "tool_use"
        case "length": stopReason = "max_tokens"
        default: stopReason = "end_turn"
        }

        var contentBlocks: [[String: Any]] = []
        if enableThinking, !reasoning.isEmpty {
            contentBlocks.append(["type": "thinking", "thinking": reasoning])
        }
        if !content.isEmpty {
            contentBlocks.append(["type": "text", "text": content])
        }
        // Safety net: with pass-through off, keep an otherwise-empty response
        // readable by surfacing reasoning as text — an assistant turn with no
        // content blocks at all is rejected by some clients.
        if contentBlocks.isEmpty, !reasoning.isEmpty {
            contentBlocks.append(["type": "text", "text": reasoning])
        }

        if let toolCalls = choice?["tool_calls"] as? [[String: Any]] {
            for tc in toolCalls {
                if let fn = tc["function"] as? [String: Any],
                   let name = fn["name"] as? String,
                   let argsStr = fn["arguments"] as? String {
                    let args = (try? JSONSerialization.jsonObject(with: Data(argsStr.utf8))) as? [String: Any] ?? ["raw_arguments": argsStr]
                    contentBlocks.append([
                        "type": "tool_use",
                        "id": tc["id"] as? String ?? "\(name)_\(UUID().uuidString.prefix(8))",
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
                "input_tokens": usage["input_tokens"] ?? usage["prompt_tokens"] ?? 0,
                "output_tokens": usage["output_tokens"] ?? usage["completion_tokens"] ?? 0,
            ],
        ]

        return (try? JSONSerialization.data(withJSONObject: anthropicResponse)) ?? data
    }
}
