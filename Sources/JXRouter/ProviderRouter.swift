import Foundation

/// In-process provider router that translates Anthropic Messages API to OpenAI Chat Completions
/// and handles high-performance streaming.
@MainActor
@Observable
final class ProviderRouter {
    private let upstreamTimeout: TimeInterval = 30.0
    private let config: ConfigManager
    private let session: URLSession
    
    var lastLatencyMs: Double = 0.0
    
    init(config: ConfigManager = .shared) {
        self.config = config
        let configObj = URLSessionConfiguration.default
        configObj.timeoutIntervalForRequest = upstreamTimeout
        configObj.timeoutIntervalForResource = upstreamTimeout * 2
        self.session = URLSession(configuration: configObj)
    }
    
    // MARK: - Public API
    
    func route(method: String, path: String, headers: [String: String], body: Data) async throws -> ProviderResponse {
        switch path {
        case "/v1/messages":
            return try await handleMessages(method: method, body: body)
        case "/v1/messages/count_tokens":
            return handleTokenCount(body: body)
        case "/v1/models":
            return handleModelList()
        case "/health", "/":
            return handleHealth()
        case "/stop":
            return ProviderResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: Data(#"{"status":"stopped"}"#.utf8))
        default:
            return ProviderResponse(statusCode: 204, headers: [:], body: Data())
        }
    }
    
    // MARK: - Messages Handler
    
    private func handleMessages(method: String, body: Data) async throws -> ProviderResponse {
        if method == "HEAD" || method == "OPTIONS" {
            return ProviderResponse(statusCode: 204, headers: ["Allow": "POST, HEAD, OPTIONS"], body: Data())
        }
        
        guard let requestJSON = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return errorResponse(statusCode: 400, type: "invalid_request_error", message: "Invalid JSON body")
        }
        
        let messagesRequest = MessagesRequest(json: requestJSON)
        
        let primaryProvider = ConfigManager.resolveProviderName(config.provider)
        let fallbackNames = config.fallbackProviders
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { ConfigManager.resolveProviderName($0) }
        
        let providerChain = [primaryProvider] + fallbackNames
        var lastError: Error?
        
        for providerId in providerChain {
            do {
                let startTime = CFAbsoluteTimeGetCurrent()
                let response = try await routeToProvider(providerId: providerId, request: messagesRequest)
                let elapsedMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
                
                self.lastLatencyMs = elapsedMs
                config.lastLatencyMs = elapsedMs
                
                if response.statusCode >= 500 {
                    lastError = ProviderError.providerUnavailable(providerId: providerId, statusCode: response.statusCode)
                    continue
                }
                return response
            } catch {
                lastError = error
                continue
            }
        }
        
        let errorMsg = lastError?.localizedDescription ?? "No providers available"
        return errorResponse(statusCode: 503, type: "api_error", message: errorMsg)
    }
    
    // MARK: - Routing
    
    private func routeToProvider(providerId: String, request: MessagesRequest) async throws -> ProviderResponse {
        let resolvedModel = resolveModel(request.model)
        let apiKey = config.apiKey(for: providerId)
        let baseUrl = config.baseUrl(for: providerId)
        
        let knownPrefixes = ["opencode/", "openrouter/", "openai/", "ollama/", "deepseek/", "xai/"]
        var model = resolvedModel
        for prefix in knownPrefixes {
            if model.hasPrefix(prefix) {
                model = String(model.dropFirst(prefix.count))
                break
            }
        }
        
        switch providerId {
        case "direct":
            return try await routeToAnthropicDirect(request: request, model: model, apiKey: apiKey, baseUrl: baseUrl)
        case "openrouter":
            return try await routeToOpenAICompatible(request: request, model: model, apiKey: apiKey, baseUrl: "https://openrouter.ai/api/v1", isOpenRouter: true)
        case "opencode-zen", "opencode-go", "openai":
            return try await routeToOpenAICompatible(request: request, model: model, apiKey: apiKey, baseUrl: baseUrl, isOpenRouter: false)
        case "local":
            return try await routeToOpenAICompatible(request: request, model: config.localLlmModel, apiKey: apiKey, baseUrl: config.localLlmBaseUrl, isOpenRouter: false)
        default:
            return errorResponse(statusCode: 400, type: "invalid_request_error", message: "Unknown provider: \(providerId)")
        }
    }
    
    private func routeToAnthropicDirect(request: MessagesRequest, model: String, apiKey: String, baseUrl: String) async throws -> ProviderResponse {
        guard !apiKey.isEmpty else { return errorResponse(statusCode: 401, type: "authentication_error", message: "ANTHROPIC_API_KEY not configured") }
        var bodyDict = request.json
        bodyDict["model"] = model
        
        var urlRequest = URLRequest(url: URL(string: "\(baseUrl)/v1/messages")!)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: bodyDict)
        
        let (data, response) = try await session.data(for: urlRequest)
        let httpResponse = response as? HTTPURLResponse
        return ProviderResponse(statusCode: httpResponse?.statusCode ?? 502, headers: ["Content-Type": httpResponse?.mimeType ?? "application/json"], body: data)
    }
    
    private func routeToOpenAICompatible(request: MessagesRequest, model: String, apiKey: String, baseUrl: String, isOpenRouter: Bool) async throws -> ProviderResponse {
        let openaiBody = toOpenAIChat(request: request, model: model)
        var urlRequest = URLRequest(url: URL(string: "\(baseUrl)/chat/completions")!)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        if isOpenRouter {
            urlRequest.setValue("https://github.com/marshaljlee/jxproxy", forHTTPHeaderField: "HTTP-Referer")
            urlRequest.setValue("JXRouter", forHTTPHeaderField: "X-Title")
        }
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: openaiBody)
        
        if request.stream {
            return try await handleOpenAIStreaming(request: urlRequest)
        } else {
            let (data, response) = try await session.data(for: urlRequest)
            let httpResponse = response as? HTTPURLResponse
            let statusCode = httpResponse?.statusCode ?? 502
            guard statusCode == 200 else { return ProviderResponse(statusCode: statusCode, headers: ["Content-Type": "application/json"], body: data) }
            return ProviderResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: convertOpenAIResponseToAnthropic(data: data, model: request.model))
        }
    }
    
    // MARK: - Streaming
    
    private func handleOpenAIStreaming(request: URLRequest) async throws -> ProviderResponse {
        let (bytes, response) = try await session.bytes(for: request)
        let httpResponse = response as? HTTPURLResponse
        let statusCode = httpResponse?.statusCode ?? 502
        
        if statusCode != 200 {
            let data = try await bytes.reduce(into: Data()) { $0.append($1) }
            return ProviderResponse(statusCode: statusCode, headers: ["Content-Type": "application/json"], body: data)
        }
        
        var hasStarted = false
        // Using an AsyncStream to efficiently yield bytes as they are translated
        let (stream, continuation) = AsyncStream.makeStream(of: Data.self)
        
        Task {
            do {
                for try await line in bytes.lines {
                    guard line.hasPrefix("data: ") else { continue }
                    let dataString = String(line.dropFirst(6))
                    
                    if dataString == "[DONE]" {
                        let stopEvent = SSEFormatter.format(event: "message_stop", data: "{\"type\":\"message_stop\"}")
                        continuation.yield(Data(stopEvent.utf8))
                        break
                    }
                    
                    guard let chunkData = dataString.data(using: .utf8),
                          let chunk = try? JSONSerialization.jsonObject(with: chunkData) as? [String: Any] else {
                        continue
                    }
                    
                    let events = openAIToAnthropicSSE(chunk: chunk)
                    for event in events {
                        if event.contains("content_block_start") { hasStarted = true }
                        continuation.yield(Data(event.utf8))
                    }
                }
                
                if !hasStarted {
                    let stopEvent = SSEFormatter.format(event: "message_stop", data: "{\"type\":\"message_stop\"}")
                    continuation.yield(Data(stopEvent.utf8))
                }
                continuation.finish()
            } catch {
                continuation.finish()
            }
        }
        
        var fullData = Data()
        for await chunk in stream {
            fullData.append(chunk)
        }
        
        return ProviderResponse(
            statusCode: 200,
            headers: ["Content-Type": "text/event-stream", "Cache-Control": "no-cache", "Connection": "keep-alive"],
            body: fullData
        )
    }
    
    // MARK: - Translation
    
    private func toOpenAIChat(request: MessagesRequest, model: String) -> [String: Any] {
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
                            // Translate Anthropic image to OpenAI image_url
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
    
    // MARK: - Server-Sent Events (SSE) Formatting Helpers
    
    /// Helper struct to encapsulate SSE formatting logic and document spec mismatches.
    /// Note on Spec Mismatches:
    /// - OpenAI streams `choices[0].delta.content` continuously as simple strings.
    /// - Anthropic requires a strict lifecycle: `message_start` -> `content_block_start` -> `content_block_delta` -> `content_block_stop` -> `message_delta` -> `message_stop`.
    /// - OpenAI tools arrive as `tool_calls` array with incremental string chunks for JSON arguments.
    /// - Anthropic expects `content_block_start` for `tool_use`, then `input_json_delta` for the JSON arguments.
    private struct SSEFormatter {
        static func format(event: String, data: String) -> String {
            return "event: \(event)\ndata: \(data)\n\n"
        }
        
        static func textDelta(text: String) -> String {
            let str = String(data: (try? JSONEncoder().encode(text)) ?? Data(), encoding: .utf8) ?? "\"\""
            return format(event: "content_block_delta", data: "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\(str)}}")
        }
        
        static func assistantMessageStart() -> [String] {
            return [
                format(event: "content_block_start", data: "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}"),
                format(event: "message_start", data: "{\"type\":\"message_start\",\"message\":{\"role\":\"assistant\",\"content\":[]}}")
            ]
        }
        
        static func toolUseStart(index: Int, id: String, name: String) -> String {
            let nameStr = String(data: (try? JSONEncoder().encode(name)) ?? Data(), encoding: .utf8) ?? "\"\""
            return format(event: "content_block_start", data: "{\"type\":\"content_block_start\",\"index\":\(index),\"content_block\":{\"type\":\"tool_use\",\"id\":\"\(id)\",\"name\":\(nameStr),\"input\":{}}}")
        }
        
        static func toolUseDelta(index: Int, args: String) -> String {
            let argStr = String(data: (try? JSONEncoder().encode(args)) ?? Data(), encoding: .utf8) ?? "\"\""
            return format(event: "content_block_delta", data: "{\"type\":\"content_block_delta\",\"index\":\(index),\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\(argStr)}}")
        }
        
        static func messageStop(index: Int, stopReason: String, outputTokens: Int) -> [String] {
            return [
                format(event: "content_block_stop", data: "{\"type\":\"content_block_stop\",\"index\":\(index)}"),
                format(event: "message_delta", data: "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"\(stopReason)\",\"stop_sequence\":null},\"usage\":{\"output_tokens\":\(outputTokens)}}"),
                format(event: "message_stop", data: "{\"type\":\"message_stop\"}")
            ]
        }
    }
    
    private func openAIToAnthropicSSE(chunk: [String: Any]) -> [String] {
        var events: [String] = []
        guard let choices = chunk["choices"] as? [[String: Any]] else { return events }
        
        for choice in choices {
            let delta = choice["delta"] as? [String: Any] ?? [:]
            let index = choice["index"] as? Int ?? 0
            
            if let content = delta["content"] as? String, !content.isEmpty {
                events.append(SSEFormatter.textDelta(text: content))
            }
            
            if delta["role"] as? String == "assistant" {
                events.append(contentsOf: SSEFormatter.assistantMessageStart())
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
    
    private func convertOpenAIResponseToAnthropic(data: Data, model: String) -> Data {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return data }
        
        let choices = json["choices"] as? [[String: Any]] ?? []
        let choice = choices.first?["message"] as? [String: Any]
        let content = choice?["content"] as? String ?? ""
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
    
    // MARK: - Helpers
    
    private func resolveModel(_ incomingModel: String) -> String {
        let lower = incomingModel.lowercased()
        if incomingModel.contains("/") { return incomingModel }
        if lower.contains("opus"), !config.modelOpus.isEmpty { return config.modelOpus }
        if lower.contains("sonnet"), !config.modelSonnet.isEmpty { return config.modelSonnet }
        if lower.contains("haiku"), !config.modelHaiku.isEmpty { return config.modelHaiku }
        return config.model
    }
    
    private func handleTokenCount(body: Data) -> ProviderResponse {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return errorResponse(statusCode: 400, type: "invalid_request_error", message: "Invalid JSON")
        }
        var totalChars = 0
        if let messages = json["messages"] as? [[String: Any]] {
            for msg in messages {
                if let content = msg["content"] as? String { totalChars += content.count }
                else if let blocks = msg["content"] as? [[String: Any]] {
                    for block in blocks { if let text = block["text"] as? String { totalChars += text.count } }
                }
            }
        }
        let result = ["input_tokens": Int(ceil(Double(totalChars) / 4.0)), "estimated": true] as [String: Any]
        return ProviderResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: (try? JSONSerialization.data(withJSONObject: result)) ?? Data())
    }
    
    private func handleModelList() -> ProviderResponse {
        let now = Int(Date().timeIntervalSince1970)
        let result = ["data": [
            ["id": "claude-opus-4-8-20250701", "object": "model", "created": now, "owned_by": "jxrouter"],
            ["id": "claude-sonnet-5-20251001", "object": "model", "created": now, "owned_by": "jxrouter"],
            ["id": "claude-haiku-4-5-20251001", "object": "model", "created": now, "owned_by": "jxrouter"],
            ["id": config.modelOpus, "object": "model", "created": now, "owned_by": "jxrouter"],
            ["id": config.modelSonnet, "object": "model", "created": now, "owned_by": "jxrouter"],
            ["id": config.modelHaiku, "object": "model", "created": now, "owned_by": "jxrouter"],
        ]]
        return ProviderResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: (try? JSONSerialization.data(withJSONObject: result)) ?? Data())
    }
    
    private func handleHealth() -> ProviderResponse {
        let result: [String: Any] = ["status": "ok", "provider": config.provider, "fallbackProviders": config.fallbackProviders, "version": "1.0.0"]
        return ProviderResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: (try? JSONSerialization.data(withJSONObject: result)) ?? Data())
    }
    
    private func errorResponse(statusCode: Int, type: String, message: String) -> ProviderResponse {
        let body: [String: Any] = ["type": "error", "error": ["type": type, "message": message]]
        return ProviderResponse(statusCode: statusCode, headers: ["Content-Type": "application/json"], body: (try? JSONSerialization.data(withJSONObject: body)) ?? Data())
    }
}

// MARK: - Supporting Types

struct ProviderResponse {
    let statusCode: Int
    let headers: [String: String]
    let body: Data
}

struct MessagesRequest {
    let json: [String: Any]
    var model: String { json["model"] as? String ?? "" }
    var stream: Bool { json["stream"] as? Bool ?? true }
    var messages: [[String: Any]] { json["messages"] as? [[String: Any]] ?? [] }
}

enum ProviderError: LocalizedError {
    case providerUnavailable(providerId: String, statusCode: Int)
    case noProvidersAvailable
    case invalidResponse
    
    var errorDescription: String? {
        switch self {
        case .providerUnavailable(let id, let code): return "Provider '\(id)' returned \(code)"
        case .noProvidersAvailable: return "No providers available"
        case .invalidResponse: return "Invalid response from provider"
        }
    }
}
