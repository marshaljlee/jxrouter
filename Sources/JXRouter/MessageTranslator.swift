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

    /// Text of the most recent user turn, for content-based routing decisions
    /// (STE100 path selection). Returns "" when the last turn is multimodal-only
    /// or there is no user turn at all.
    private static func lastUserText(_ request: MessagesRequest) -> String {
        for msg in request.messages.reversed() {
            guard let role = msg["role"] as? String, role == "user" else { continue }
            if let text = msg["content"] as? String, !text.isEmpty { return text }
            if let blocks = msg["content"] as? [[String: Any]] {
                let text = blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
                if !text.isEmpty { return text }
            }
            return ""
        }
        return ""
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

        // Source-of-truth gateway: prepend the watched project tree so the
        // model answers from real file contents instead of guessing. No-op
        // when the gateway is off or has not scanned yet.
        var effectiveSystem = baseSystem
        if let gatewayBlock = SourceOfTruthGateway.shared.contextBlock() {
            effectiveSystem = (effectiveSystem.map { $0 + "\n\n" + gatewayBlock }) ?? gatewayBlock
        }

        // ASD-STE100 output rules, opt-in. Routed by path rather than applied
        // blindly: a turn carrying a tool schema, or whose last user message is
        // machine-readable (patch, diff, JSON, fenced code), passes through
        // untouched so normalization can never corrupt a payload.
        if ConfigManager.shared.ste100Enforce {
            let steConfig = STE100.Config.default
            let stePath = STE100.path(toolsPresent: !rawTools.isEmpty,
                                      messageText: lastUserText(request),
                                      exemptToolsAndCode: steConfig.exemptToolsAndCode)
            let steDirective = STE100.systemDirective(for: stePath, config: steConfig)
            if !steDirective.isEmpty {
                effectiveSystem = (effectiveSystem.map { $0 + "\n\n" + steDirective }) ?? steDirective
            }
        }

        if shouldInjectTools {
            let injectedSystem = LocalChatTemplateEngine.injectToolsIntoSystemPrompt(system: effectiveSystem, tools: rawTools)
            messages.append(["role": "system", "content": injectedSystem])
        } else if let effectiveSystem = effectiveSystem {
            messages.append(["role": "system", "content": effectiveSystem])
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
            var thinkingParts: [String] = []

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
                    // Preserve thinking blocks on ingress: replay them to
                    // reasoning-capable upstreams via `reasoning_content` so
                    // multi-turn thinking context survives the OpenAI hop
                    // (Anthropic's replay contract requires thinking history).
                    // Non-reasoning upstreams simply ignore the field.
                    if let text = block["thinking"] as? String, !text.isEmpty {
                        thinkingParts.append(text)
                    }
                case "redacted_thinking":
                    // Opaque encrypted payload — cannot be re-serialized into
                    // the OpenAI dialect; drop it (logged class of loss).
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
                // Replay prior thinking as reasoning_content so reasoning-capable
                // upstreams (DeepSeek R1, Qwen3-thinking, …) keep the reasoning
                // chain instead of restarting cold every turn. Gated on the
                // provider's reasoning capability: strict upstreams reject
                // unknown message fields, so a reasoning-disabled provider must
                // never see it (dropped-and-logged class of loss).
                if !thinkingParts.isEmpty && enableThinking {
                    assistantMsg["reasoning_content"] = thinkingParts.joined(separator: "\n")
                }
                if !toolUseBlocks.isEmpty {
                    var toolCalls: [[String: Any]] = []
                    for tu in toolUseBlocks {
                        // Round-trip ids verbatim: Claude Code replays tool_use
                        // ids in tool_result blocks; a fresh UUID here breaks
                        // id pairing on strict upstreams. Synthesize ONLY when
                        // the block arrived without an id.
                        let id = tu["id"] as? String
                            ?? "call_\(UUID().uuidString.prefix(8))"
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
                // User role: OpenAI requires every `role:"tool"` message to
                // IMMEDIATELY follow the assistant tool_calls message — no user
                // text may sit between them. Emit tool results first, then the
                // user text as its own message.
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
                    if tr["is_error"] as? Bool == true, !resultContent.hasPrefix("ERROR") {
                        resultContent = "ERROR: " + resultContent
                    }
                    messages.append([
                        "role": "tool",
                        "tool_call_id": toolUseId,
                        "content": resultContent
                    ])
                }

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
            }
        }

        var result: [String: Any] = [
            "model": model,
            "messages": messages,
        ]

        if request.stream {
            result["stream"] = true
        }

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

        // Tokens limit mapping: reasoning models (o-series, R1, reasoner)
        // reject `max_tokens` — send `max_completion_tokens` for all of them.
        if let maxTokens = request.maxTokens {
            if isReasoning {
                result["max_completion_tokens"] = maxTokens
            } else {
                result["max_tokens"] = maxTokens
            }
        }

        // stop_sequences → stop (OpenAI caps `stop` at 4 entries; truncate+log).
        if let stopSeqs = request.json["stop_sequences"] as? [String], !stopSeqs.isEmpty {
            let clamped = Array(stopSeqs.prefix(4))
            if clamped.count < stopSeqs.count {
                print("[MessageTranslator] Clamped stop_sequences \(stopSeqs.count) → 4 for OpenAI upstream")
            }
            result["stop"] = clamped
        }

        // Temperature: OpenAI reasoning models forbid temperature (returns HTTP 400)
        if !isReasoning, let temp = request.temperature {
            result["temperature"] = temp
        }

        if request.stream {
            // Always request usage in the final chunk — Claude Code's context
            // math reads it. Providers that ignore stream_options just omit it.
            result["stream_options"] = ["include_usage": true]
        }

        return result
    }

    // MARK: - OpenAI → Anthropic Response Translation

    /// Convert an OpenAI error response (or generic HTTP failure) to Anthropic error format
    /// so Claude Code and Anthropic SDK clients parse the failure cleanly.
    static func convertOpenAIErrorToAnthropic(data: Data, statusCode: Int) -> Data {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // Already in Anthropic error format?
            if json["type"] as? String == "error" && json["error"] is [String: Any] {
                return data
            }
            // OpenAI error format: {"error": {"message": "...", "type": "...", "code": ...}}
            if let errObj = json["error"] as? [String: Any] {
                let msg = (errObj["message"] as? String) ?? "Upstream error (HTTP \(statusCode))"
                let errType = (errObj["type"] as? String) ?? (statusCode == 400 ? "invalid_request_error" : "api_error")
                let anthropic: [String: Any] = [
                    "type": "error",
                    "error": [
                        "type": errType,
                        "message": msg
                    ]
                ]
                if let converted = try? JSONSerialization.data(withJSONObject: anthropic) {
                    return converted
                }
            }
        }
        let rawStr = String(data: data, encoding: .utf8) ?? "HTTP \(statusCode) error"
        let fallback: [String: Any] = [
            "type": "error",
            "error": [
                "type": statusCode == 400 ? "invalid_request_error" : "api_error",
                "message": rawStr
            ]
        ]
        return (try? JSONSerialization.data(withJSONObject: fallback)) ?? data
    }

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
            var rawText = (message["content"] as? String) ?? ""

            // Handle inline <think> tags in non-streaming text
            if rawText.contains("<think>") {
                let thinkRegex = try? NSRegularExpression(pattern: #"<think>\s*([\s\S]*?)\s*</think>"#, options: [])
                if let match = thinkRegex?.firstMatch(in: rawText, options: [], range: NSRange(location: 0, length: rawText.utf16.count)),
                   let thinkRange = Range(match.range(at: 1), in: rawText),
                   let fullRange = Range(match.range(at: 0), in: rawText) {
                    let inlineThink = String(rawText[thinkRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if enableThinking && !inlineThink.isEmpty && !content.contains(where: { $0["type"] as? String == "thinking" }) {
                        content.insert(["type": "thinking", "thinking": inlineThink], at: 0)
                    }
                    rawText.removeSubrange(fullRange)
                    rawText = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }

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
                // Anthropic rejects empty text blocks on replay ("text content
                // blocks must be non-empty") — a single space keeps the block
                // valid without polluting the transcript.
                content.append(["type": "text", "text": " "])
            }
        } else {
            content.append(["type": "text", "text": " "])
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
            case "content_filter": stopReason = "refusal"
            default: stopReason = "end_turn"
            }
        } else {
            stopReason = "end_turn"
        }

        // Usage MUST be reshaped to Anthropic semantics — Claude Code's context
        // math reads input_tokens/output_tokens; raw prompt_tokens keys make
        // every token estimate silently wrong.
        let result: [String: Any] = [
            "id": id,
            "type": "message",
            "role": "assistant",
            "content": content,
            "model": model,
            "stop_reason": stopReason,
            "usage": Self.anthropicUsage(fromOpenAI: json["usage"]),
        ]
        return (try? JSONSerialization.data(withJSONObject: result)) ?? data
    }

    /// Map an OpenAI usage object (prompt_tokens/completion_tokens/…) into the
    /// Anthropic usage shape (input_tokens/output_tokens/cache fields).
    static func anthropicUsage(fromOpenAI raw: Any?) -> [String: Any] {
        guard let usage = raw as? [String: Any] else {
            return ["input_tokens": 0, "output_tokens": 0]
        }
        var mapped: [String: Any] = [
            "input_tokens": (usage["prompt_tokens"] as? Int) ?? 0,
            "output_tokens": (usage["completion_tokens"] as? Int) ?? 0,
        ]
        if let details = usage["prompt_tokens_details"] as? [String: Any],
           let cached = details["cached_tokens"] as? Int, cached > 0 {
            mapped["cache_read_input_tokens"] = cached
        }
        if let details = usage["completion_tokens_details"] as? [String: Any],
           let reasoning = details["reasoning_tokens"] as? Int, reasoning > 0 {
            mapped["output_tokens_details"] = ["thinking_tokens": reasoning]
        }
        return mapped
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
        /// Trailing partial marker bytes held back from emission. Tags split
        /// across delta chunks (one token per chunk) would otherwise be
        /// consumed as ordinary content and could never reassemble — an
        /// opening tag would leak as visible text, and a closing `</think>`
        /// would strand the stream inside the thinking block forever. This
        /// buffer holds the partial bytes and prepends them to the next chunk.
        var pendingMarkerSuffix: String = ""
        /// Total characters streamed as visible text/thinking/tool-arg deltas —
        /// the floor estimate for output_tokens when the upstream never sends
        /// a usage chunk (llama-server stream builds omit it).
        var streamedCharCount: Int = 0
        /// Visible assistant text accumulated across the stream. Consulted
        /// only at end-of-stream, and only when no structured tool call
        /// arrived, to recover a call the model wrote into the TEXT channel —
        /// the "announces a tool, never calls it" failure.
        var textBuffer: String = ""
        /// Names of the tools the client actually offered. Recovered
        /// text-channel calls are filtered against this set so prose that
        /// merely *documents* tool syntax is never executed as a real call.
        var knownToolNames: Set<String> = []

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
            state.streamedCharCount += reasoning.count
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

        // 2. Text Content & Inline Think Tag Extraction
        if let rawContent = delta["content"] as? String, !rawContent.isEmpty {
            state.streamedCharCount += rawContent.count
            // Prepend any partial opening-marker bytes held back from the
            // previous chunk so tags split across chunks still assemble.
            var contentToProcess = rawContent
            if !state.pendingMarkerSuffix.isEmpty {
                contentToProcess = state.pendingMarkerSuffix + contentToProcess
                state.pendingMarkerSuffix = ""
            }

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
                        // All content in this chunk is thinking — except a
                        // trailing partial `</think>`, which must be held back.
                        // Emitting it here consumes the fragment as thinking
                        // text, so the closing tag can never reassemble: the
                        // block then stays open for the rest of the stream and
                        // swallows every later block — including a tool call
                        // the model wrote as text — leaving the client with no
                        // tool_use, no visible text, and stop_reason end_turn.
                        let hold = Self.splitHoldLength(contentToProcess, marker: "</think>")
                        let emitPart = hold > 0 ? String(contentToProcess.dropLast(hold)) : contentToProcess
                        if hold > 0 { state.pendingMarkerSuffix = String(contentToProcess.suffix(hold)) }
                        if !emitPart.isEmpty, let idx = state.activeBlockIndex {
                            events.append(SSEFormatter.format(event: "content_block_delta", data: "{\"type\":\"content_block_delta\",\"index\":\(idx),\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\(jsonEscape(emitPart))}}"))
                        }
                        contentToProcess = ""
                    }
                }
            } else {
                // When thinking is disabled, strip <think>...</think> blocks from output (jxrouter reference parity)
                if !state.insideInlineThink && contentToProcess.contains("<think>") {
                    let parts = contentToProcess.components(separatedBy: "<think>")
                    let prefixText = parts[0]
                    state.insideInlineThink = true
                    let remainder = parts.dropFirst().joined(separator: "<think>")
                    if remainder.contains("</think>") {
                        let subParts = remainder.components(separatedBy: "</think>")
                        state.insideInlineThink = false
                        contentToProcess = prefixText + subParts.dropFirst().joined(separator: "</think>")
                    } else {
                        contentToProcess = prefixText
                    }
                } else if state.insideInlineThink {
                    if contentToProcess.contains("</think>") {
                        let parts = contentToProcess.components(separatedBy: "</think>")
                        state.insideInlineThink = false
                        contentToProcess = parts.dropFirst().joined(separator: "</think>")
                    } else {
                        // The thinking text is being stripped, but a trailing
                        // partial `</think>` still has to be carried into the
                        // next chunk. Dropping it means the closing tag can
                        // never reassemble, `insideInlineThink` stays true for
                        // the rest of the stream, and everything after it is
                        // silently discarded — tool calls included.
                        let hold = Self.splitHoldLength(contentToProcess, marker: "</think>")
                        if hold > 0 { state.pendingMarkerSuffix = String(contentToProcess.suffix(hold)) }
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
                // The closing tag may be SPLIT across chunks, with its opening
                // fragment already swallowed into toolCallBuffer — testing
                // contentToProcess alone misses it and the tag bytes end up
                // embedded in the args. Test the COMBINED buffer+chunk.
                let combinedToolBuffer = state.toolCallBuffer + contentToProcess
                if combinedToolBuffer.contains("</tool_call>") {
                    let parts = combinedToolBuffer.components(separatedBy: "</tool_call>")
                    state.toolCallBuffer = parts[0]
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
                // Split-marker guard: if this chunk ENDS with a partial prefix
                // of an opening marker (e.g. "<tool_ca"), hold those bytes back
                // instead of emitting them as visible text — the rest of the
                // tag arrives in the next chunk(s) and the prepend above
                // reassembles it. Without this, per-token streaming leaks tag
                // fragments into the transcript.
                var holdLength = 0
                if !state.insideInlineToolCall && !state.insideInlineThink {
                    for marker in ["<tool_call>", "<think>"] {
                        holdLength = max(holdLength, Self.splitHoldLength(contentToProcess, marker: marker))
                    }
                }
                if holdLength > 0 {
                    let emitPart = String(contentToProcess.dropLast(holdLength))
                    state.pendingMarkerSuffix = String(contentToProcess.suffix(holdLength))
                    if !emitPart.isEmpty {
                        events.append(contentsOf: emitTextChunk(emitPart, state: &state))
                    }
                } else {
                    events.append(contentsOf: emitTextChunk(contentToProcess, state: &state))
                }
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
                    state.streamedCharCount += argChunk.count

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
                        state.streamedCharCount += argChunk.count
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
            // Flush any held-back partial marker at end-of-stream — it never
            // completed into a real tag, so it is ordinary content and must not
            // be silently dropped. If a thinking block is still open, that
            // content belongs to the thinking channel rather than to a new
            // text block.
            if !state.pendingMarkerSuffix.isEmpty, !state.insideInlineToolCall {
                if state.activeBlockType == "thinking", let idx = state.activeBlockIndex {
                    events.append(SSEFormatter.format(event: "content_block_delta", data: "{\"type\":\"content_block_delta\",\"index\":\(idx),\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\(jsonEscape(state.pendingMarkerSuffix))}}"))
                } else {
                    events.append(contentsOf: emitTextChunk(state.pendingMarkerSuffix, state: &state))
                }
                state.pendingMarkerSuffix = ""
            }

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

            // Text-channel tool-call recovery. A model that cannot drive the
            // native `tool_calls` field writes the call into its text instead
            // ("I will now run …", or a <tool_call> / <function=…> / <invoke>
            // block). The client sees prose, no tool_use block arrives, and the
            // turn ends having done nothing. Recover it here — gated on NO
            // structured call having been seen, so every already-working path
            // is byte-identical — and filtered to names the client offered, so
            // prose that merely documents tool syntax is never executed.
            if state.toolCallsByIndex.isEmpty && !state.hasEncounteredToolCall && !state.textBuffer.isEmpty {
                let recovered = LocalChatTemplateEngine.extractToolCalls(from: state.textBuffer)
                for tc in recovered.toolCalls {
                    let name = (tc["name"] as? String)
                        ?? ((tc["function"] as? [String: Any])?["name"] as? String)
                        ?? ""
                    guard !name.isEmpty else { continue }
                    if !state.knownToolNames.isEmpty && !state.knownToolNames.contains(name) { continue }

                    let blockIdx = state.nextBlockIndex
                    state.nextBlockIndex += 1
                    let tcId = (tc["id"] as? String) ?? "call_\(UUID().uuidString.prefix(8))"
                    let inputObj = (tc["input"] as? [String: Any]) ?? [:]
                    let argsStr = (try? JSONSerialization.data(withJSONObject: inputObj)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

                    events.append(SSEFormatter.format(
                        event: "content_block_start",
                        data: "{\"type\":\"content_block_start\",\"index\":\(blockIdx),\"content_block\":{\"type\":\"tool_use\",\"id\":\(jsonEscape(tcId)),\"name\":\(jsonEscape(name)),\"input\":{}}}"
                    ))
                    events.append(SSEFormatter.format(
                        event: "content_block_delta",
                        data: "{\"type\":\"content_block_delta\",\"index\":\(blockIdx),\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\(jsonEscape(argsStr))}}"
                    ))
                    events.append(SSEFormatter.blockStop(index: blockIdx))
                    state.hasEncounteredToolCall = true
                }
            }

            // If nothing was emitted at all, emit a non-empty text block — an
            // EMPTY text block poisons Claude Code transcripts on replay
            // ("text content blocks must be non-empty", claude-code#88536).
            if state.nextBlockIndex == 0 {
                let emptyStart = SSEFormatter.format(event: "content_block_start", data: "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\" \"}}")
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
                case "content_filter": anthropicStop = "refusal"
                default: anthropicStop = "end_turn"
                }
            }

            // message_delta usage is Anthropic-shaped and CUMULATIVE — Claude
            // Code's context math reads output_tokens; the raw OpenAI dict
            // (prompt_tokens/completion_tokens) broke every token estimate.
            // When the upstream never sent a usage chunk (llama-server builds
            // omit it even with include_usage), estimate output tokens from
            // the streamed deltas (chars/4 floor) instead of reporting a
            // dishonest zero.
            var usage = Self.anthropicUsage(fromOpenAI: state.usage)
            if (usage["output_tokens"] as? Int) == 0 {
                usage["output_tokens"] = max(1, state.streamedCharCount / 4)
            }
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
        // Accumulate for end-of-stream text-channel tool-call recovery.
        state.textBuffer += text

        return events
    }

    // MARK: - Helpers

    /// Length of the longest trailing suffix of `text` that is a proper prefix
    /// of `marker` — the bytes that must be held back because the marker is only
    /// partially delivered and will complete in a later chunk.
    ///
    /// Every marker needs this, not just the opening ones: a tag split across
    /// delta chunks is otherwise consumed as ordinary content, can never
    /// reassemble, and the block it should have opened or closed is stranded.
    private static func splitHoldLength(_ text: String, marker: String) -> Int {
        let maxOverlap = min(marker.count - 1, text.count)
        guard maxOverlap > 0 else { return 0 }
        for len in stride(from: maxOverlap, through: 1, by: -1) {
            if marker.hasPrefix(String(text.suffix(len))) { return len }
        }
        return 0
    }

    /// Names of the tools a request offered, in either dialect (Anthropic's
    /// top-level `name` or OpenAI's `function.name`). Used to filter
    /// text-channel tool calls so prose that merely documents tool syntax is
    /// never executed as a real call.
    static func toolNames(in request: MessagesRequest) -> Set<String> {
        var names: Set<String> = []
        for item in (request.json["tools"] as? [Any]) ?? [] {
            guard let dict = item as? [String: Any] else { continue }
            if let name = dict["name"] as? String { names.insert(name) }
            if let fn = dict["function"] as? [String: Any], let name = fn["name"] as? String {
                names.insert(name)
            }
        }
        return names
    }

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
