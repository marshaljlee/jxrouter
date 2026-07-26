import Foundation

/// In-process provider router that translates Anthropic Messages API to OpenAI Chat Completions
/// and handles high-performance streaming.
@MainActor
@Observable
final class ProviderRouter: NSObject, URLSessionDelegate {
    private let upstreamTimeout: TimeInterval = 30.0
    private let config: ConfigManager
    private var session: URLSession!
    
    var lastLatencyMs: Double = 0.0
    
    init(config: ConfigManager = .shared) {
        self.config = config
        super.init()
        let configObj = URLSessionConfiguration.default
        configObj.timeoutIntervalForRequest = upstreamTimeout
        configObj.timeoutIntervalForResource = upstreamTimeout * 2
        self.session = URLSession(configuration: configObj, delegate: self, delegateQueue: nil)
    }
    
    // MARK: - URLSessionDelegate (Bypass hostname mismatch for IP connections)
    nonisolated func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
    
    // MARK: - Public API
    
    func route(method: String, path: String, headers: [String: String], body: Data) async throws -> ProviderResponse {
        switch path {
        case "/v1/messages", "/v1/v1/messages", "/messages":
            return try await handleMessages(method: method, body: body)
        case "/v1/messages/count_tokens":
            return handleTokenCount(body: body)
        case "/v1/models":
            return handleModelList()
        case "/health", "/", "/api/hello", "/v1/api/hello":
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
        
        let knownPrefixes = ["opencode/", "openrouter/", "openai/", "ollama/", "deepseek/", "xai/", "gemini/", "mistral/", "codestral/", "cohere/", "groq/", "fireworks/", "sambanova/", "cerebras/", "huggingface/", "github_models/", "wafer/", "kimi/", "kimi_code/", "minimax/", "zai/", "ollama_cloud/", "vercel/", "nvidia_nim/", "lmstudio/", "llamacpp/"]
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
            return try await routeToOpenAICompatible(request: request, model: model, apiKey: apiKey, baseUrl: baseUrl, isOpenRouter: true)
        case "opencode-zen", "opencode-go", "openai":
            return try await routeToOpenAICompatible(request: request, model: model, apiKey: apiKey, baseUrl: baseUrl, isOpenRouter: false)
        case "nvidia-nim":
            return try await routeToOpenAICompatible(request: request, model: model, apiKey: apiKey, baseUrl: config.openaiBaseUrl, isOpenRouter: false)
        case "deepseek", "gemini", "mistral", "codestral", "cohere", "groq", "fireworks", "sambanova", "cerebras", "huggingface", "github-models", "wafer", "kimi", "kimi-code", "minimax", "xai", "zai", "ollama-cloud", "ai-gateway":
            return try await routeToOpenAICompatible(request: request, model: model, apiKey: apiKey, baseUrl: baseUrl, isOpenRouter: false)
        case "local", "ollama":
            return try await routeToOpenAICompatible(request: request, model: config.localLlmModel, apiKey: apiKey, baseUrl: config.localLlmBaseUrl, isOpenRouter: false)
        case "lmstudio", "llamacpp":
            return try await routeToOpenAICompatible(request: request, model: model, apiKey: "", baseUrl: baseUrl, isOpenRouter: false)
        default:
            return errorResponse(statusCode: 400, type: "invalid_request_error", message: "Unknown provider: \(providerId)")
        }
    }
    
    private func routeToAnthropicDirect(request: MessagesRequest, model: String, apiKey: String, baseUrl: String) async throws -> ProviderResponse {
        guard !apiKey.isEmpty else { return errorResponse(statusCode: 401, type: "authentication_error", message: "ANTHROPIC_API_KEY not configured") }
        var bodyDict = request.json
        bodyDict["model"] = model
        
        let url = URL(string: "\(baseUrl)/v1/messages")!
        let host = url.host ?? "api.anthropic.com"
        guard let ip = await DirectDNSResolver.shared.resolve(host) else {
            return errorResponse(statusCode: 502, type: "dns_error", message: "Failed to resolve IP for \(host)")
        }
        
        let body = (try? JSONSerialization.data(withJSONObject: bodyDict)) ?? Data()
        var headers: [String: String] = [
            "Content-Type": "application/json",
            "x-api-key": apiKey,
            "anthropic-version": "2023-06-01",
            "Host": host
        ]
        
        if request.stream {
            let (response, stream) = try await CurlClient.stream(url: url, method: "POST", headers: headers, body: body, resolveIP: ip)
            return ProviderResponse(statusCode: response.statusCode, headers: ["Content-Type": "text/event-stream", "Cache-Control": "no-cache", "Connection": "keep-alive"], body: Data(), stream: stream)
        } else {
            let (data, response) = try await CurlClient.request(url: url, method: "POST", headers: headers, body: body, resolveIP: ip)
            return ProviderResponse(statusCode: response.statusCode, headers: ["Content-Type": response.mimeType ?? "application/json"], body: data)
        }
    }
    
    private func routeToOpenAICompatible(request: MessagesRequest, model: String, apiKey: String, baseUrl: String, isOpenRouter: Bool) async throws -> ProviderResponse {
        let openaiBody = toOpenAIChat(request: request, model: model)
        
        let url = URL(string: "\(baseUrl)/chat/completions")!
        let host = url.host ?? "api.openai.com"
        guard let ip = await DirectDNSResolver.shared.resolve(host) else {
            return errorResponse(statusCode: 502, type: "dns_error", message: "Failed to resolve IP for \(host)")
        }
        
        let body = (try? JSONSerialization.data(withJSONObject: openaiBody)) ?? Data()
        var headers: [String: String] = [
            "Content-Type": "application/json",
            "Host": host
        ]
        if !apiKey.isEmpty {
            headers["Authorization"] = "Bearer \(apiKey)"
        }
        if isOpenRouter {
            headers["HTTP-Referer"] = "https://github.com/marshaljlee/jxproxy"
            headers["X-Title"] = "JXProxy"
        }
        
        if request.stream {
            let (response, stream) = try await CurlClient.stream(url: url, method: "POST", headers: headers, body: body, resolveIP: ip)
            return try await handleOpenAIStreaming(response: response, stream: stream, request: request)
        } else {
            let (data, response) = try await CurlClient.request(url: url, method: "POST", headers: headers, body: body, resolveIP: ip)
            let statusCode = response.statusCode
            guard statusCode == 200 else { return ProviderResponse(statusCode: statusCode, headers: ["Content-Type": "application/json"], body: data) }
            return ProviderResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: convertOpenAIResponseToAnthropic(data: data, model: request.model))
        }
    }
    
    // MARK: - Streaming
    
    private func handleOpenAIStreaming(response: HTTPURLResponse, stream inputStream: AsyncStream<Data>, request: MessagesRequest) async throws -> ProviderResponse {
        let statusCode = response.statusCode
        
        if statusCode != 200 {
            var fullData = Data()
            for await chunk in inputStream {
                fullData.append(chunk)
            }
            return ProviderResponse(statusCode: statusCode, headers: ["Content-Type": "application/json"], body: fullData)
        }
        
        var hasStarted = false
        var hasFinished = false
        let (stream, continuation) = AsyncStream.makeStream(of: Data.self)
        
        Task {
            do {
                var buffer = Data()
                for await chunk in inputStream {
                    buffer.append(chunk)
                    
                    while let newlineRange = buffer.range(of: Data("\n".utf8)) {
                        let lineData = buffer.subdata(in: buffer.startIndex..<newlineRange.lowerBound)
                        buffer.removeSubrange(buffer.startIndex..<newlineRange.upperBound)
                        
                        guard let line = String(data: lineData, encoding: .utf8), line.hasPrefix("data: ") else { continue }
                        let dataString = String(line.dropFirst(6))
                        
                        if dataString == "[DONE]" {
                            if !hasFinished {
                                let stopEvent = SSEFormatter.format(event: "message_stop", data: "{\"type\":\"message_stop\"}")
                                continuation.yield(Data(stopEvent.utf8))
                                hasFinished = true
                            }
                            break
                        }
                        
                        guard let chunkData = dataString.data(using: .utf8),
                              let chunkDict = try? JSONSerialization.jsonObject(with: chunkData) as? [String: Any] else {
                            continue
                        }
                        
                        let events = openAIToAnthropicSSE(chunk: chunkDict, model: request.model, alreadyStarted: hasStarted)
                        for event in events {
                            if event.contains("content_block_start") { hasStarted = true }
                            if event.contains("message_delta") {
                                // When message_delta is emitted, the next logical event is message_stop
                                continuation.yield(Data(event.utf8))
                                if !hasFinished {
                                    let stopEvent = SSEFormatter.format(event: "message_stop", data: "{\"type\":\"message_stop\"}")
                                    continuation.yield(Data(stopEvent.utf8))
                                    hasFinished = true
                                }
                                continue
                            }
                            continuation.yield(Data(event.utf8))
                        }
                    }
                }
                
                if !hasStarted && !hasFinished {
                    let stopEvent = SSEFormatter.format(event: "message_stop", data: "{\"type\":\"message_stop\"}")
                    continuation.yield(Data(stopEvent.utf8))
                    hasFinished = true
                }
                continuation.finish()
            }
        }
        
        return ProviderResponse(
            statusCode: 200,
            headers: ["Content-Type": "text/event-stream", "Cache-Control": "no-cache", "Connection": "keep-alive"],
            body: Data(),
            stream: stream
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
        
        static func assistantMessageStart(model: String) -> [String] {
            let msgId = "msg_\(UUID().uuidString.prefix(8))"
            return [
                format(event: "message_start", data: "{\"type\":\"message_start\",\"message\":{\"id\":\"\(msgId)\",\"type\":\"message\",\"role\":\"assistant\",\"model\":\"\(model)\",\"content\":[],\"usage\":{\"input_tokens\":0,\"output_tokens\":0}}}"),
                format(event: "content_block_start", data: "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}")
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
                format(event: "message_delta", data: "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"\(stopReason)\",\"stop_sequence\":null},\"usage\":{\"output_tokens\":\(outputTokens)}}")
            ]
        }
    }
    
    private func openAIToAnthropicSSE(chunk: [String: Any], model: String, alreadyStarted: Bool = false) -> [String] {
        var events: [String] = []
        guard let choices = chunk["choices"] as? [[String: Any]] else { return events }
        
        for choice in choices {
            let delta = choice["delta"] as? [String: Any] ?? [:]
            let index = choice["index"] as? Int ?? 0
            
            if delta["role"] as? String == "assistant", !alreadyStarted {
                events.append(contentsOf: SSEFormatter.assistantMessageStart(model: model))
            }
            
            if let content = delta["content"] as? String, !content.isEmpty {
                events.append(SSEFormatter.textDelta(text: content))
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
        var models: [[String: Any]] = [
            ["id": config.modelOpus, "object": "model", "created": now, "owned_by": "jxproxy"],
            ["id": config.modelSonnet, "object": "model", "created": now, "owned_by": "jxproxy"],
            ["id": config.modelHaiku, "object": "model", "created": now, "owned_by": "jxproxy"],
        ]
        
        // Add models from all configured providers
        // (models already include their provider prefix, e.g. "deepseek/deepseek-chat")
        for preset in ProviderPreset.all {
            for modelId in preset.models {
                models.append(["id": modelId, "object": "model", "created": now, "owned_by": preset.id])
            }
        }
        
        let result = ["data": models]
        return ProviderResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: (try? JSONSerialization.data(withJSONObject: result)) ?? Data())
    }
    
    private func handleHealth() -> ProviderResponse {
        let result: [String: Any] = ["status": "ok", "provider": config.provider, "fallbackProviders": config.fallbackProviders, "version": "1.0.0", "proxy": "jxproxy"]
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
    var stream: AsyncStream<Data>? = nil
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
import Foundation

final class DirectDNSResolver {
    static let shared = DirectDNSResolver()
    
    private var cache: [String: String] = [
        "api.anthropic.com": "160.79.104.10",
        "api.openai.com": "104.18.2.161",
        "api.openrouter.ai": "104.21.36.195"
    ]
    
    func resolve(_ hostname: String) async -> String? {
        if let cached = cache[hostname] { return cached }
        
        let url = URL(string: "https://cloudflare-dns.com/dns-query?name=\(hostname)&type=A")!
        var request = URLRequest(url: url)
        request.setValue("application/dns-json", forHTTPHeaderField: "Accept")
        
        do {
            let sessionConfig = URLSessionConfiguration.default
            sessionConfig.timeoutIntervalForRequest = 5.0
            let session = URLSession(configuration: sessionConfig)
            
            let (data, _) = try await session.data(for: request)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let answer = json["Answer"] as? [[String: Any]] else {
                return nil
            }
            
            for record in answer {
                if let type = record["type"] as? Int, type == 1, let data = record["data"] as? String {
                    cache[hostname] = data
                    return data
                }
            }
        } catch {
            print("[DirectDNSResolver] Failed to resolve \(hostname): \(error)")
        }
        return nil
    }
}
import Foundation

enum CurlError: Error {
    case invalidResponse
    case processFailed(Int32)
}

final class CurlClient {
    static func request(url: URL, method: String, headers: [String: String], body: Data?, resolveIP: String? = nil) async throws -> (Data, HTTPURLResponse) {
        let (response, stream) = try await self.stream(url: url, method: method, headers: headers, body: body, resolveIP: resolveIP)
        
        var fullData = Data()
        for await chunk in stream {
            fullData.append(chunk)
        }
        
        return (fullData, response)
    }
    
    static func stream(url: URL, method: String, headers: [String: String], body: Data?, resolveIP: String? = nil) async throws -> (HTTPURLResponse, AsyncStream<Data>) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        
        var args = ["-i", "-s", "-N", "-X", method]
        
        if let ip = resolveIP, let host = url.host {
            let port = url.port ?? (url.scheme == "https" ? 443 : 80)
            args.append("--resolve")
            args.append("\(host):\(port):\(ip)")
        }
        
        for (key, value) in headers {
            args.append("-H")
            args.append("\(key): \(value)")
        }
        
        let tempFileURL: URL?
        if let bodyData = body {
            let tempDir = FileManager.default.temporaryDirectory
            let tempFile = tempDir.appendingPathComponent(UUID().uuidString + ".json")
            try bodyData.write(to: tempFile)
            args.append("--data-binary")
            args.append("@\(tempFile.path)")
            tempFileURL = tempFile
        } else {
            tempFileURL = nil
        }
        
        args.append(url.absoluteString)
        process.arguments = args
        
        let pipe = Pipe()
        process.standardOutput = pipe
        
        try process.run()
        
        // Read headers
        let fileHandle = pipe.fileHandleForReading
        var headerData = Data()
        var statusCode = 200
        var responseHeaders: [String: String] = [:]
        
        // Continue reading until we hit \r\n\r\n
        while let byteData = try fileHandle.read(upToCount: 1), !byteData.isEmpty {
            headerData.append(byteData)
            if headerData.count >= 4 && headerData.suffix(4) == Data("\r\n\r\n".utf8) {
                break
            }
        }
        
        let headerString = String(data: headerData, encoding: .utf8) ?? ""
        let lines = headerString.components(separatedBy: "\r\n")
        
        // Handle HTTP/2 or HTTP/1.1 response status line (can be multiple if 100 Continue)
        var actualHeaders = lines
        if let first = lines.first, first.starts(with: "HTTP/") {
            let parts = first.split(separator: " ")
            if parts.count >= 2, let code = Int(parts[1]) {
                statusCode = code
            }
        }
        
        for line in actualHeaders.dropFirst() {
            if line.isEmpty { continue }
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2 {
                responseHeaders[String(parts[0]).trimmingCharacters(in: .whitespaces)] = String(parts[1]).trimmingCharacters(in: .whitespaces)
            }
        }
        
        let response = HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: responseHeaders)!
        
        let stream = AsyncStream<Data> { continuation in
            fileHandle.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    fileHandle.readabilityHandler = nil
                    process.waitUntilExit()
                    if let tempFile = tempFileURL {
                        try? FileManager.default.removeItem(at: tempFile)
                    }
                    continuation.finish()
                } else {
                    continuation.yield(data)
                }
            }
        }
        
        return (response, stream)
    }
}
