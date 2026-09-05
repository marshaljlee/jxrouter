import Foundation

/// Translates between Anthropic Messages API format and OpenAI Chat Completions
/// format. Determines reasoning capability and handles bidirectional tool calling,
/// multimodal images, schema sanitization, and streaming SSE lifecycle events.
enum MessageTranslator {

    // MARK: - Reasoning Capability

    static func isReasoningCapable(providerId: String, model: String) -> Bool {
        switch providerId {
        case "deepseek":
            return model.contains("reasoner") || model.contains("r1")
        case "opencode-zen", "opencode-go":
            return true
        case "nvidia-nim":
            return model.contains("nemotron") || model.contains("deepseek")
        case "direct":
            return model.contains("claude")
        case "openrouter":
            return model.contains("reasoning") || model.contains("r1")
        case "groq":
            return model.contains("deepseek")
        case "gguf", "llamacpp", "llamaapp":
            return true
        case "openai":
            return isReasoningModel(model: model)
        default:
            return false
        }
    }

    /// Determines if a model is an OpenAI-style reasoning model (such as o1, o3,
    /// or reasoning-focused checkpoints) where temperature is disallowed.
    static func isReasoningModel(model: String) -> Bool {
        let m = model.lowercased()
        return m.contains("o1") || m.contains("o3") || m.contains("o4") || m.contains("r1") || m.contains("reasoner")
    }

    // MARK: - Schema Sanitization & Tool Mapping

    /// Recursively cleans JSON Schemas for OpenAI compatibility by removing
    /// unsupported format fields (like format: 'uri') and draft metadata that
    /// cause OpenAI and OpenRouter to reject tool schemas with HTTP 400.
    static func sanitizeJsonSchema(_ schema: [String: Any]) -> [String: Any] {
        var clean: [String: Any] = [:]
        for (key, value) in schema {
            // Strip format: uri or any format if schema type is string
            if key == "format" {
                continue
            }
            if key == "$schema" || key == "$id" {
                continue
            }
            if key == "properties", let props = value as? [String: [String: Any]] {
                var cleanProps: [String: [String: Any]] = [:]
                for (pKey, pVal) in props {
                    cleanProps[pKey] = sanitizeJsonSchema(pVal)
                }
                clean[key] = cleanProps
            } else if key == "items", let items = value as? [String: Any] {
                clean[key] = sanitizeJsonSchema(items)
            } else if key == "additionalProperties", let addProps = value as? [String: Any] {
                clean[key] = sanitizeJsonSchema(addProps)
            } else if (key == "anyOf" || key == "allOf" || key == "oneOf"), let list = value as? [[String: Any]] {
                clean[key] = list.map { sanitizeJsonSchema($0) }
            } else {
                clean[key] = value
            }
        }
        return clean
    }

    /// Converts Anthropic tool definitions (with name, description, input_schema)
    /// to standard OpenAI Chat Completions tool definitions with type: "function".
    static func convertToolsToOpenAI(anthropicTools: [Any]) -> [[String: Any]] {
        var openAITools: [[String: Any]] = []

        for item in anthropicTools {
            guard let toolDict = item as? [String: Any] else { continue }

            // If already formatted as OpenAI function tool, sanitize parameters and pass through
            if let type = toolDict["type"] as? String, type == "function",
               let fn = toolDict["function"] as? [String: Any] {
                var sanitizedFn = fn
                if let params = fn["parameters"] as? [String: Any] {
                    sanitizedFn["parameters"] = sanitizeJsonSchema(params)
                }
                openAITools.append(["type": "function", "function": sanitizedFn])
                continue
            }

            // Anthropic schema: name, description, input_schema
            guard let name = toolDict["name"] as? String else { continue }
            let description = toolDict["description"] as? String
            let rawSchema = (toolDict["input_schema"] as? [String: Any]) ?? (toolDict["parameters"] as? [String: Any]) ?? [:]
            let sanitizedSchema = sanitizeJsonSchema(rawSchema)

            var fnDict: [String: Any] = [
                "name": name,
                "parameters": sanitizedSchema
            ]
            if let description, !description.isEmpty {
                fnDict["description"] = description
            }
            openAITools.append([
                "type": "function",
                "function": fnDict
            ])
        }

        return openAITools
    }

    /// Maps Anthropic tool_choice to OpenAI tool_choice.
    static func convertToolChoiceToOpenAI(_ toolChoice: Any) -> Any {
        if let str = toolChoice as? String {
            switch str {
            case "auto": return "auto"
            case "any": return "required"
            case "none": return "none"
            default: return str
            }
        }
        if let dict = toolChoice as? [String: Any], let type = dict["type"] as? String {
            switch type {
            case "auto":
                return "auto"
            case "any":
                return "required"
            case "none":
                return "none"
            case "tool":
                if let name = dict["name"] as? String {
                    return ["type": "function", "function": ["name": name]]
                }
            default:
                break
            }
        }
        return toolChoice
    }

    // MARK: - Anthropic → OpenAI Translation

    /// Convert an Anthropic Messages request to an OpenAI Chat Completions body.
    static func toOpenAIChat(request: MessagesRequest, model: String, enableThinking: Bool, injectToolsIntoPrompt: Bool = false) -> [String: Any] {
        var messages: [[String: Any]] = []

        let rawTools = (request.json["tools"] as? [Any]) ?? []
        let shouldInjectTools = injectToolsIntoPrompt && !rawTools.isEmpty

        // Extract base system string if present
        var baseSystem: String? = nil
        if let system = request.system {
            if let systemStr = system as? String, !systemStr.isEmpty {
                baseSystem = systemStr
            } else if let systemBlocks = system as? [[String: Any]] {
                let text = systemBlocks.compactMap { block -> String? in
                    if let type = block["type"] as? String, type == "text",
                       let text = block["text"] as? String { return text }
                    return nil
                }.joined(separator: "\n")
                if !text.isEmpty {
                    baseSystem = text
                }
            }
        }

        if shouldInjectTools {
            let injectedSystem = LocalChatTemplateEngine.injectToolsIntoSystemPrompt(system: baseSystem, tools: rawTools)
            messages.append(["role": "system", "content": injectedSystem])
        } else if let baseSystem = baseSystem {
            messages.append(["role": "system", "content": baseSystem])
        }

        // Process messages preserving tool_use, tool_result, and multimodal images
        for msg in request.messages {
            let role = msg["role"] as? String ?? "user"
            let content = msg["content"]

            if let str = content as? String {
                messages.append(["role": role, "content": str])
                continue
            }

            guard let blocks = content as? [[String: Any]] else {
                continue
            }

            var textParts: [String] = []
            var imageParts: [[String: Any]] = []
            var toolUseBlocks: [[String: Any]] = []
            var toolResultBlocks: [[String: Any]] = []

            for block in blocks {
                let blockType = block["type"] as? String ?? ""
                switch blockType {
                case "text":
                    if let text = block["text"] as? String, !text.isEmpty {
                        textParts.append(text)
                    }
                case "tool_use":
                    toolUseBlocks.append(block)
                case "tool_result":
                    toolResultBlocks.append(block)
                case "image":
                    // Anthropic base64 image: { type: "image", source: { type: "base64", media_type: "image/png", data: "..." } }
                    if let source = block["source"] as? [String: Any],
                       source["type"] as? String == "base64",
                       let data = source["data"] as? String {
                        let mediaType = source["media_type"] as? String ?? "image/png"
                        imageParts.append([
                            "type": "image_url",
                            "image_url": ["url": "data:\(mediaType);base64,\(data)"]
                        ])
                    }
                case "thinking":
                    // Exclude internal thinking blocks from forwarded user/assistant text
                    break
                default:
                    if let text = block["text"] as? String, !text.isEmpty {
                        textParts.append(text)
                    }
                }
            }

            if role == "assistant" {
                var assistantMsg: [String: Any] = ["role": "assistant"]
                let textContent = textParts.joined(separator: "\n")
                if !textContent.isEmpty {
                    assistantMsg["content"] = textContent
                }
                if !toolUseBlocks.isEmpty {
                    var toolCalls: [[String: Any]] = []
                    for tu in toolUseBlocks {
                        let id = tu["id"] as? String ?? "call_\(UUID().uuidString.prefix(8))"
                        let name = tu["name"] as? String ?? "unknown"
                        let inputObj = tu["input"] ?? [:]
                        let inputData = (try? JSONSerialization.data(withJSONObject: inputObj))
                            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                        toolCalls.append([
                            "id": id,
                            "type": "function",
                            "function": [
                                "name": name,
                                "arguments": inputData
                            ]
                        ])
                    }
                    assistantMsg["tool_calls"] = toolCalls
                }
                if assistantMsg["content"] == nil && assistantMsg["tool_calls"] == nil {
                    assistantMsg["content"] = ""
                }
                messages.append(assistantMsg)
            } else {
                // User role: add user message followed by discrete role: "tool" messages
                if !imageParts.isEmpty {
                    var userParts: [[String: Any]] = []
                    if !textParts.isEmpty {
                        userParts.append(["type": "text", "text": textParts.joined(separator: "\n")])
                    }
                    userParts.append(contentsOf: imageParts)
                    messages.append(["role": "user", "content": userParts])
                } else if !textParts.isEmpty || toolResultBlocks.isEmpty {
                    messages.append(["role": "user", "content": textParts.joined(separator: "\n")])
                }

                // Map Anthropic tool_result blocks to OpenAI role: "tool" messages
                for tr in toolResultBlocks {
                    let toolUseId = tr["tool_use_id"] as? String ?? "unknown"
                    var resultContent = ""
                    if let str = tr["content"] as? String {
                        resultContent = str
                    } else if let blocks = tr["content"] as? [[String: Any]] {
                        resultContent = blocks.compactMap { b -> String? in
                            if let t = b["text"] as? String { return t }
                            return nil
                        }.joined(separator: "\n")
                    } else if let raw = tr["content"],
                              let trData = try? JSONSerialization.data(withJSONObject: raw),
                              let str = String(data: trData, encoding: .utf8) {
                        resultContent = str
                    }
                    messages.append([
                        "role": "tool",
                        "tool_call_id": toolUseId,
                        "content": resultContent
                    ])
                }
            }
        }

        var result: [String: Any] = [
            "model": model,
            "messages": messages,
        ]

        // Map and sanitize tool definitions (unless injected into system prompt)
        if !shouldInjectTools {
            if let tools = request.json["tools"] as? [Any], !tools.isEmpty {
                let converted = convertToolsToOpenAI(anthropicTools: tools)
                if !converted.isEmpty {
                    result["tools"] = converted
                }
            }
            if let toolChoice = request.json["tool_choice"] {
                result["tool_choice"] = convertToolChoiceToOpenAI(toolChoice)
            }
        }

        let isReasoning = isReasoningModel(model: model)

        // Tokens limit mapping
        if let maxTokens = request.maxTokens {
            if isReasoning && model.contains("o1") {
                result["max_completion_tokens"] = maxTokens
            } else {
                result["max_tokens"] = maxTokens
            }
        }

        // Temperature: OpenAI reasoning models forbid temperature (returns HTTP 400)
        if !isReasoning, let temp = request.temperature {
            result["temperature"] = temp
        }

        if request.stream {
            result["stream"] = true
        }

        if enableThinking {
            result["stream_options"] = ["include_usage": true]
        }

        return result
    }

    // MARK: - OpenAI → Anthropic Response Translation

    /// Convert an OpenAI Chat Completions JSON response to Anthropic Messages format.
    static func convertOpenAIResponseToAnthropic(data: Data, model: String, enableThinking: Bool) -> Data {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return data
        }
        let id = "msg_\(UUID().uuidString.prefix(12))"
        var content: [[String: Any]] = []
        var hasToolCalls = false

        if let choices = json["choices"] as? [[String: Any]],
           let message = choices.first?["message"] as? [String: Any] {

            // Reasoning block
            if let reasoning = message["reasoning_content"] as? String, enableThinking, !reasoning.isEmpty {
                content.append(["type": "thinking", "thinking": reasoning])
            }

            // Text block and structured or extracted tool calls
            let rawText = (message["content"] as? String) ?? ""
            var structuredToolCalls = message["tool_calls"] as? [[String: Any]] ?? []

            if structuredToolCalls.isEmpty && !rawText.isEmpty {
                let extracted = LocalChatTemplateEngine.extractToolCalls(from: rawText)
                if !extracted.toolCalls.isEmpty {
                    structuredToolCalls = extracted.toolCalls
                    if !extracted.cleanText.isEmpty {
                        content.append(["type": "text", "text": extracted.cleanText])
                    }
                } else {
                    content.append(["type": "text", "text": rawText])
                }
            } else if !rawText.isEmpty {
                content.append(["type": "text", "text": rawText])
            }

            // Tool calls block
            if !structuredToolCalls.isEmpty {
                hasToolCalls = true
                for tc in structuredToolCalls {
                    let tcId = tc["id"] as? String ?? "call_\(UUID().uuidString.prefix(8))"
                    let fn = tc["function"] as? [String: Any]
                    let name = (tc["name"] as? String) ?? (fn?["name"] as? String) ?? "unknown"
                    let inputDict: [String: Any]
                    if let existingInput = tc["input"] as? [String: Any] {
                        inputDict = existingInput
                    } else {
                        let argsStr = fn?["arguments"] as? String ?? "{}"
                        inputDict = (try? JSONSerialization.jsonObject(with: Data(argsStr.utf8))) as? [String: Any] ?? [:]
                    }
                    content.append([
                        "type": "tool_use",
                        "id": tcId,
                        "name": name,
                        "input": inputDict
                    ])
                }
            }

            if content.isEmpty {
                content.append(["type": "text", "text": ""])
            }
        } else {
            content.append(["type": "text", "text": ""])
        }

        let stopReason: String
        if hasToolCalls {
            stopReason = "tool_use"
        } else if let choices = json["choices"] as? [[String: Any]],
                  let finishReason = choices.first?["finish_reason"] as? String {
            switch finishReason {
            case "tool_calls": stopReason = "tool_use"
            case "stop": stopReason = "end_turn"
            case "length": stopReason = "max_tokens"
            default: stopReason = "end_turn"
            }
        } else {
            stopReason = "end_turn"
        }

        let result: [String: Any] = [
            "id": id,
            "type": "message",
            "role": "assistant",
            "content": content,
            "model": model,
            "stop_reason": stopReason,
            "usage": json["usage"] ?? ["input_tokens": 0, "output_tokens": 0],
        ]
        return (try? JSONSerialization.data(withJSONObject: result)) ?? data
    }

    // MARK: - OpenAI SSE → Anthropic SSE Translation

    struct ToolCallProgress {
        var id: String
        var name: String
        var blockIndex: Int
        var accumulatedArgs: String
    }

    /// Per-stream state for translating OpenAI SSE chunks to Anthropic events.
    struct OpenAIStreamState {
        var nextBlockIndex: Int = 0
        var activeBlockIndex: Int? = nil
        var activeBlockType: String? = nil // "thinking", "text", "tool_use"
        var toolCallsByIndex: [Int: ToolCallProgress] = [:]
        var hasEncounteredToolCall: Bool = false
        var usage: [String: Any]?
        var messageStartSent: Bool = false
        var insideInlineThink: Bool = false
        var insideInlineToolCall: Bool = false
        var toolCallBuffer: String = ""

        /// Preserves backward compatibility for unclosed block inspections.
        var openedBlocks: [Int] {
            var list: [Int] = []
            if let active = activeBlockIndex {
                list.append(active)
            }
            for p in toolCallsByIndex.values {
                if !list.contains(p.blockIndex) {
                    list.append(p.blockIndex)
                }
            }
            return list
        }
    }

    /// Translate one OpenAI SSE chunk dict to zero or more Anthropic SSE event strings.
    static func openAIToAnthropicSSE(chunk: [String: Any], model: String, state: inout OpenAIStreamState, enableThinking: Bool) -> [String] {
        var events: [String] = []

        guard let choices = chunk["choices"] as? [[String: Any]],
              let choice = choices.first else {
            // Usage chunk
            if let usage = chunk["usage"] as? [String: Any] {
                state.usage = usage
            }
            return events
        }

        let delta = choice["delta"] as? [String: Any] ?? [:]
        let finishReason = choice["finish_reason"] as? String

        // Emit message_start before any content blocks
        if !state.messageStartSent {
            let inputTokens = (state.usage?["prompt_tokens"] as? Int) ?? 0
            let startPayload = "{\"type\":\"message_start\",\"message\":{\"id\":\"msg_\(UUID().uuidString.prefix(12))\",\"type\":\"message\",\"role\":\"assistant\",\"content\":[],\"model\":\(jsonEscape(model)),\"stop_reason\":null,\"stop_sequence\":null,\"usage\":{\"input_tokens\":\(inputTokens),\"output_tokens\":0}}}"
            events.append(SSEFormatter.format(event: "message_start", data: startPayload))
            state.messageStartSent = true
        }

        // 1. Explicit Reasoning Content (reasoning_content field)
        if enableThinking, let reasoning = delta["reasoning_content"] as? String, !reasoning.isEmpty {
            if state.activeBlockType != "thinking" {
                // If another block was open, close it first
                if let active = state.activeBlockIndex {
                    events.append(SSEFormatter.blockStop(index: active))
                }
                let thinkIndex = state.nextBlockIndex
                state.nextBlockIndex += 1
                state.activeBlockIndex = thinkIndex
                state.activeBlockType = "thinking"
                let thinkStart = SSEFormatter.format(event: "content_block_start", data: "{\"type\":\"content_block_start\",\"index\":\(thinkIndex),\"content_block\":{\"type\":\"thinking\",\"thinking\":\"\"}}")
                events.append(thinkStart)
            }
            let thinkIdx = state.activeBlockIndex ?? 0
            let thinkDelta = SSEFormatter.format(event: "content_block_delta", data: "{\"type\":\"content_block_delta\",\"index\":\(thinkIdx),\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\(jsonEscape(reasoning))}}")
            events.append(thinkDelta)
        }

        // 2. Text Content & Inline <think> Tag Extraction
        if let rawContent = delta["content"] as? String, !rawContent.isEmpty {
            var contentToProcess = rawContent

            if enableThinking {
                // Check if we are inside or encountering <think> tags from local models
                if !state.insideInlineThink && contentToProcess.contains("<think>") {
                    let parts = contentToProcess.components(separatedBy: "<think>")
                    let prefixText = parts[0]
                    if !prefixText.isEmpty {
                        events.append(contentsOf: emitTextChunk(prefixText, state: &state))
                    }
                    // Start thinking block
                    if state.activeBlockType == "text", let active = state.activeBlockIndex {
                        events.append(SSEFormatter.blockStop(index: active))
                        state.activeBlockType = nil
                        state.activeBlockIndex = nil
                    }
                    let thinkIndex = state.nextBlockIndex
                    state.nextBlockIndex += 1
                    state.activeBlockIndex = thinkIndex
                    state.activeBlockType = "thinking"
                    state.insideInlineThink = true
                    events.append(SSEFormatter.format(event: "content_block_start", data: "{\"type\":\"content_block_start\",\"index\":\(thinkIndex),\"content_block\":{\"type\":\"thinking\",\"thinking\":\"\"}}"))

                    contentToProcess = parts.dropFirst().joined(separator: "<think>")
                }

                if state.insideInlineThink {
                    if contentToProcess.contains("</think>") {
                        let parts = contentToProcess.components(separatedBy: "</think>")
                        let thinkChunk = parts[0]
                        if !thinkChunk.isEmpty, let idx = state.activeBlockIndex {
                            events.append(SSEFormatter.format(event: "content_block_delta", data: "{\"type\":\"content_block_delta\",\"index\":\(idx),\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\(jsonEscape(thinkChunk))}}"))
                        }
                        // Close thinking block
                        if let active = state.activeBlockIndex {
                            events.append(SSEFormatter.blockStop(index: active))
                        }
                        state.activeBlockType = nil
                        state.activeBlockIndex = nil
                        state.insideInlineThink = false

                        contentToProcess = parts.dropFirst().joined(separator: "</think>")
                    } else {
                        // All content in this chunk is thinking
                        if let idx = state.activeBlockIndex {
                            events.append(SSEFormatter.format(event: "content_block_delta", data: "{\"type\":\"content_block_delta\",\"index\":\(idx),\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\(jsonEscape(contentToProcess))}}"))
                        }
                        contentToProcess = ""
                    }
                }
            }

            // Check for inline <tool_call> tags emitted by local models
            if !state.insideInlineToolCall && contentToProcess.contains("<tool_call>") {
                let parts = contentToProcess.components(separatedBy: "<tool_call>")
                let prefixText = parts[0]
                if !prefixText.isEmpty {
                    events.append(contentsOf: emitTextChunk(prefixText, state: &state))
                }
                if state.activeBlockType == "text", let active = state.activeBlockIndex {
                    events.append(SSEFormatter.blockStop(index: active))
                    state.activeBlockType = nil
                    state.activeBlockIndex = nil
                }
                state.insideInlineToolCall = true
                state.toolCallBuffer = ""
                contentToProcess = parts.dropFirst().joined(separator: "<tool_call>")
            }

            if state.insideInlineToolCall {
                if contentToProcess.contains("</tool_call>") {
                    let parts = contentToProcess.components(separatedBy: "</tool_call>")
                    state.toolCallBuffer += parts[0]
                    contentToProcess = parts.dropFirst().joined(separator: "</tool_call>")
                    state.insideInlineToolCall = false

                    let xml = "<tool_call>\(state.toolCallBuffer)</tool_call>"
                    let extracted = LocalChatTemplateEngine.extractToolCalls(from: xml)
                    for tc in extracted.toolCalls {
                        state.hasEncounteredToolCall = true
                        let blockIdx = state.nextBlockIndex
                        state.nextBlockIndex += 1
                        let tcId = tc["id"] as? String ?? "call_\(UUID().uuidString.prefix(8))"
                        let tcName = tc["name"] as? String ?? "unknown"
                        let inputObj = tc["input"] as? [String: Any] ?? [:]
                        let argsStr = (try? JSONSerialization.data(withJSONObject: inputObj)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

                        events.append(SSEFormatter.format(
                            event: "content_block_start",
                            data: "{\"type\":\"content_block_start\",\"index\":\(blockIdx),\"content_block\":{\"type\":\"tool_use\",\"id\":\(jsonEscape(tcId)),\"name\":\(jsonEscape(tcName)),\"input\":{}}}"
                        ))
                        events.append(SSEFormatter.format(
                            event: "content_block_delta",
                            data: "{\"type\":\"content_block_delta\",\"index\":\(blockIdx),\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\(jsonEscape(argsStr))}}"
                        ))
                        events.append(SSEFormatter.blockStop(index: blockIdx))
                    }
                    state.toolCallBuffer = ""
                } else {
                    state.toolCallBuffer += contentToProcess
                    contentToProcess = ""
                }
            }

            if !contentToProcess.isEmpty {
                events.append(contentsOf: emitTextChunk(contentToProcess, state: &state))
            }
        }

        // 3. Streaming Tool Calls
        if let toolCalls = delta["tool_calls"] as? [[String: Any]], !toolCalls.isEmpty {
            state.hasEncounteredToolCall = true

            // If a text or thinking block was open, close it before tool_use block
            if state.activeBlockType == "text" || state.activeBlockType == "thinking" {
                if let active = state.activeBlockIndex {
                    events.append(SSEFormatter.blockStop(index: active))
                }
                state.activeBlockType = nil
                state.activeBlockIndex = nil
            }

            for tc in toolCalls {
                let callIdx = tc["index"] as? Int ?? 0
                let fn = tc["function"] as? [String: Any]
                let argChunk = fn?["arguments"] as? String ?? ""

                if state.toolCallsByIndex[callIdx] == nil {
                    let blockIdx = state.nextBlockIndex
                    state.nextBlockIndex += 1
                    let id = tc["id"] as? String ?? "call_\(UUID().uuidString.prefix(8))"
                    let name = fn?["name"] as? String ?? "unknown"

                    state.toolCallsByIndex[callIdx] = ToolCallProgress(
                        id: id,
                        name: name,
                        blockIndex: blockIdx,
                        accumulatedArgs: argChunk
                    )

                    let toolStart = SSEFormatter.format(
                        event: "content_block_start",
                        data: "{\"type\":\"content_block_start\",\"index\":\(blockIdx),\"content_block\":{\"type\":\"tool_use\",\"id\":\(jsonEscape(id)),\"name\":\(jsonEscape(name)),\"input\":{}}}"
                    )
                    events.append(toolStart)

                    if !argChunk.isEmpty {
                        let argDelta = SSEFormatter.format(
                            event: "content_block_delta",
                            data: "{\"type\":\"content_block_delta\",\"index\":\(blockIdx),\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\(jsonEscape(argChunk))}}"
                        )
                        events.append(argDelta)
                    }
                } else {
                    let current = state.toolCallsByIndex[callIdx]!
                    if !argChunk.isEmpty {
                        let argDelta = SSEFormatter.format(
                            event: "content_block_delta",
                            data: "{\"type\":\"content_block_delta\",\"index\":\(current.blockIndex),\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\(jsonEscape(argChunk))}}"
                        )
                        events.append(argDelta)
                        state.toolCallsByIndex[callIdx]?.accumulatedArgs += argChunk
                    }
                }
            }
        }

        // 4. Stream Finish / Completion
        if let finishReason {
            // Close active text or thinking block
            if let active = state.activeBlockIndex {
                events.append(SSEFormatter.blockStop(index: active))
                state.activeBlockType = nil
                state.activeBlockIndex = nil
            }

            // Close all tool call blocks
            for progress in state.toolCallsByIndex.values {
                events.append(SSEFormatter.blockStop(index: progress.blockIndex))
            }
            state.toolCallsByIndex.removeAll()

            // If nothing was emitted at all, emit empty text block
            if state.nextBlockIndex == 0 {
                let emptyStart = SSEFormatter.format(event: "content_block_start", data: "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}")
                events.append(emptyStart)
                events.append(SSEFormatter.blockStop(index: 0))
                state.nextBlockIndex = 1
            }

            let anthropicStop: String
            if finishReason == "tool_calls" || state.hasEncounteredToolCall {
                anthropicStop = "tool_use"
            } else {
                switch finishReason {
                case "stop": anthropicStop = "end_turn"
                case "length": anthropicStop = "max_tokens"
                default: anthropicStop = "end_turn"
                }
            }

            let usage = state.usage ?? ["prompt_tokens": 0, "completion_tokens": 0]
            let msgDelta = SSEFormatter.format(event: "message_delta", data: "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"\(anthropicStop)\",\"stop_sequence\":null},\"usage\":\(jsonDictString(usage))}")
            events.append(msgDelta)
        }

        return events
    }

    /// Helper to transition to or continue a text content block.
    private static func emitTextChunk(_ text: String, state: inout OpenAIStreamState) -> [String] {
        var events: [String] = []

        // If thinking block was open, close it before text starts (strict sequential block lifecycle)
        if state.activeBlockType == "thinking" {
            if let active = state.activeBlockIndex {
                events.append(SSEFormatter.blockStop(index: active))
            }
            state.activeBlockType = nil
            state.activeBlockIndex = nil
        }

        if state.activeBlockType != "text" {
            let textIdx = state.nextBlockIndex
            state.nextBlockIndex += 1
            state.activeBlockIndex = textIdx
            state.activeBlockType = "text"
            let textBlockStart = SSEFormatter.format(event: "content_block_start", data: "{\"type\":\"content_block_start\",\"index\":\(textIdx),\"content_block\":{\"type\":\"text\",\"text\":\"\"}}")
            events.append(textBlockStart)
        }

        let idx = state.activeBlockIndex ?? 0
        let textDelta = SSEFormatter.format(event: "content_block_delta", data: "{\"type\":\"content_block_delta\",\"index\":\(idx),\"delta\":{\"type\":\"text_delta\",\"text\":\(jsonEscape(text))}}")
        events.append(textDelta)

        return events
    }

    // MARK: - Helpers

    /// JSON-encode a string for embedding in an SSE data payload.
    private static func jsonEscape(_ s: String) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: s, options: [.fragmentsAllowed]),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }

    private static func jsonDictString(_ dict: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let str = String(data: data, encoding: .utf8) else { return "{}" }
        return str
    }
}
