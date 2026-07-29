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
            return ProviderResponse(statusCode: 200, headers: ["Content-Length": "0", "Connection": "close"], body: Data())
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
        let chainStart = CFAbsoluteTimeGetCurrent()
        let maxChainDuration: TimeInterval = 120.0 // Total fallback chain cap
        
        for (index, providerId) in providerChain.enumerated() {
            let elapsed = CFAbsoluteTimeGetCurrent() - chainStart
            guard elapsed < maxChainDuration else {
                lastError = ProviderError.providerUnavailable(providerId: providerId, statusCode: 504)
                break
            }
            
            if index > 0 {
                try await Task.sleep(nanoseconds: 1_000_000_000)
                guard CFAbsoluteTimeGetCurrent() - chainStart < maxChainDuration else {
                    lastError = ProviderError.providerUnavailable(providerId: providerId, statusCode: 504)
                    break
                }
            }
            
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
        let resolvedModel = resolveModel(request.model, for: providerId)
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
            return try await routeToOpenAICompatible(request: request, model: model, apiKey: apiKey, baseUrl: baseUrl, isOpenRouter: false)
        case "deepseek", "gemini", "mistral", "codestral", "cohere", "groq", "fireworks", "sambanova", "cerebras", "huggingface", "github-models", "wafer", "kimi", "kimi-code", "minimax", "xai", "zai", "ollama-cloud", "ai-gateway":
            return try await routeToOpenAICompatible(request: request, model: model, apiKey: apiKey, baseUrl: baseUrl, isOpenRouter: false)
        case "local", "ollama":
            return try await routeToOpenAICompatible(request: request, model: config.localLlmModel, apiKey: apiKey, baseUrl: config.localLlmBaseUrl, isOpenRouter: false, chatTemplate: config.chatTemplate)
        case "lmstudio", "llamacpp":
            return try await routeToOpenAICompatible(request: request, model: model, apiKey: "", baseUrl: baseUrl, isOpenRouter: false, chatTemplate: config.chatTemplate)
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
        let ip = await DirectDNSResolver.shared.resolve(host) ?? host
        
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
    
    private func routeToOpenAICompatible(request: MessagesRequest, model: String, apiKey: String, baseUrl: String, isOpenRouter: Bool, chatTemplate: String = "") async throws -> ProviderResponse {
        var openaiBody = MessageTranslator.toOpenAIChat(request: request, model: model)
        
        // Inject chat_template override for local GGUF models with broken
        // baked-in templates (e.g. raise_exception blocks).
        if !chatTemplate.isEmpty {
            openaiBody["chat_template"] = chatTemplate
            print("[ProviderRouter] Using chat_template override for local model")
        }
        
        let url = URL(string: "\(baseUrl)/chat/completions")!
        let host = url.host ?? "api.openai.com"
        let ip = await DirectDNSResolver.shared.resolve(host) ?? host
        
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
            return ProviderResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: MessageTranslator.convertOpenAIResponseToAnthropic(data: data, model: request.model))
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
                // FIX #3: Label the outer for-await loop so we can break out of it on [DONE].
                streamLoop: for await chunk in inputStream {
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
                            // Break the outer for-await loop — the stream is done.
                            // Previously this only broke the inner while loop, causing
                            // the output stream to stay open for another 30s (--max-time).
                            break streamLoop
                        }

                        guard let chunkData = dataString.data(using: .utf8),
                              let chunkDict = try? JSONSerialization.jsonObject(with: chunkData) as? [String: Any] else {
                            continue
                        }

                        let events = MessageTranslator.openAIToAnthropicSSE(chunk: chunkDict, model: request.model, alreadyStarted: hasStarted)
                        for event in events {
                            if event.contains("content_block_start") { hasStarted = true }
                            if event.contains("message_delta") {
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
                        // If message_delta already set hasFinished, the stream is done
                        // even if upstream doesn't send [DONE]. Break to avoid waiting
                        // for curl --max-time (30s) unnecessarily.
                        if hasFinished { break streamLoop }
                    }
                }

                if !hasFinished {
                    // If content blocks were started but we never got a finish_reason,
                    // emit content_block_stop + message_delta + message_stop so the
                    // client doesn't hang waiting for the stream to end.
                    if hasStarted {
                        let cbStop = SSEFormatter.format(event: "content_block_stop", data: "{\"type\":\"content_block_stop\",\"index\":0}")
                        continuation.yield(Data(cbStop.utf8))
                        let msgDelta = SSEFormatter.format(event: "message_delta", data: "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\",\"stop_sequence\":null},\"usage\":{\"output_tokens\":0}}")
                        continuation.yield(Data(msgDelta.utf8))
                    }
                    let stopEvent = SSEFormatter.format(event: "message_stop", data: "{\"type\":\"message_stop\"}")
                    continuation.yield(Data(stopEvent.utf8))
                    hasFinished = true
                }
                continuation.finish()
            } catch {
                // FIX #4: Catch any error in the streaming Task.
                // Previously the Task had no catch clause — if anything threw,
                // the task silently died and continuation.finish() was never called,
                // causing the output stream to hang open forever.
                print("[ProviderRouter] Streaming error: \(error)")
                if !hasFinished {
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
    
    // MARK: - Helpers
    
    /// Resolve the incoming model name to the actual model to send to the provider.
    /// For local providers (llamacpp, ollama, lmstudio, local) the tier mapping
    /// (opus → modelOpus, sonnet → modelSonnet) is skipped — the default model
    /// is used directly since the user is expected to configure it in Settings.
    /// For well-known model names (starting with "claude-", "gpt-", "gemini-", etc.),
    /// passes through directly instead of applying tier mapping.
    /// Tier mapping only applies when the incoming model is exactly "opus", "sonnet",
    /// or "haiku" — NOT when it's part of a longer model name.
    private func resolveModel(_ incomingModel: String, for providerId: String? = nil) -> String {
        let localProviders = ["llamacpp", "lmstudio", "local", "ollama"]
        if let pid = providerId, localProviders.contains(pid) {
            return config.model
        }
        if incomingModel.contains("/") { return incomingModel }
        
        // Pass through well-known Anthropic model names directly
        let lower = incomingModel.lowercased()
        if lower.hasPrefix("claude-") || lower.hasPrefix("gpt-") || lower.hasPrefix("gemini-") {
            return incomingModel
        }
        
        // Tier mapping: ONLY for exact single-word tier names
        if lower == "opus", !config.modelOpus.isEmpty { return config.modelOpus }
        if lower == "sonnet", !config.modelSonnet.isEmpty { return config.modelSonnet }
        if lower == "haiku", !config.modelHaiku.isEmpty { return config.modelHaiku }
        
        // For any other model name, pass through as-is (no tier substring matching)
        return incomingModel
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
        let result: [String: Any] = ["input_tokens": Int(ceil(Double(totalChars) / 4.0)), "estimated": true]
        return ProviderResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: (try? JSONSerialization.data(withJSONObject: result)) ?? Data())
    }
    
    private func handleModelList() -> ProviderResponse {
        let now = Int(Date().timeIntervalSince1970)
        var models: [[String: Any]] = [
            ["id": config.modelOpus, "object": "model", "created": now, "owned_by": "jxproxy"],
            ["id": config.modelSonnet, "object": "model", "created": now, "owned_by": "jxproxy"],
            ["id": config.modelHaiku, "object": "model", "created": now, "owned_by": "jxproxy"],
        ]
        
        for preset in ProviderPreset.all {
            for modelId in preset.models {
                models.append(["id": modelId, "object": "model", "created": now, "owned_by": preset.id])
            }
        }
        
        let result: [String: Any] = ["data": models]
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
