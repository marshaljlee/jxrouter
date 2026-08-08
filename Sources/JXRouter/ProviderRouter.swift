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
                // Non-primary providers: 4xx client errors (400 model unavailable,
                // 401 auth, 403 forbidden, 404 not found, 429 rate limit) mean this
                // provider can't serve the request — continue the chain. The primary
                // provider's 4xx response semantics stay unchanged (returned as-is).
                if index > 0, [400, 401, 403, 404, 429].contains(response.statusCode) {
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
        
        var model = resolvedModel
        for prefix in ProviderPreset.knownPrefixes {
            if model.hasPrefix(prefix) {
                model = String(model.dropFirst(prefix.count))
                break
            }
        }
        
        switch providerId {
        case "direct":
            return try await routeToAnthropicDirect(request: request, model: model, apiKey: apiKey, baseUrl: baseUrl)
        case "openrouter":
            return try await routeToOpenAICompatible(request: request, model: model, providerId: providerId, apiKey: apiKey, baseUrl: baseUrl, isOpenRouter: true)
        case "opencode-zen", "opencode-go", "openai":
            return try await routeToOpenAICompatible(request: request, model: model, providerId: providerId, apiKey: apiKey, baseUrl: baseUrl, isOpenRouter: false)
        case "nvidia-nim":
            return try await routeToOpenAICompatible(request: request, model: model, providerId: providerId, apiKey: apiKey, baseUrl: baseUrl, isOpenRouter: false)
        case "deepseek", "gemini", "mistral", "codestral", "cohere", "groq", "fireworks", "sambanova", "cerebras", "huggingface", "github-models", "wafer", "kimi", "kimi-code", "minimax", "xai", "zai", "ollama-cloud", "ai-gateway", "custom", "jan":
            return try await routeToOpenAICompatible(request: request, model: model, providerId: providerId, apiKey: apiKey, baseUrl: baseUrl, isOpenRouter: false)
        case let pid where config.customProviders.contains(where: { $0.id == pid }):
            // Named custom providers (Settings → Providers → Custom Providers)
            // route through the same OpenAI-compatible path.
            return try await routeToOpenAICompatible(request: request, model: model, providerId: providerId, apiKey: apiKey, baseUrl: baseUrl, isOpenRouter: false)
        case "local", "ollama":
            return try await routeToOpenAICompatible(request: request, model: config.localLlmModel, providerId: providerId, apiKey: apiKey, baseUrl: config.localLlmBaseUrl, isOpenRouter: false)
        case "lmstudio", "llamacpp":
            return try await routeToOpenAICompatible(request: request, model: model, providerId: providerId, apiKey: "", baseUrl: baseUrl, isOpenRouter: false)
        default:
            return errorResponse(statusCode: 400, type: "invalid_request_error", message: "Unknown provider: \(providerId)")
        }
    }
    
    private func routeToAnthropicDirect(request: MessagesRequest, model: String, apiKey: String, baseUrl: String) async throws -> ProviderResponse {
        guard !apiKey.isEmpty else { return errorResponse(statusCode: 401, type: "authentication_error", message: "ANTHROPIC_API_KEY not configured") }
        // The direct Anthropic path forwards the body untouched, so reasoning is
        // preserved natively and the per-provider reasoning policy does not apply
        // here — client-side thinking (ENABLE_MODEL_THINKING) governs it.
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
    
    private func routeToOpenAICompatible(request: MessagesRequest, model: String, providerId: String, apiKey: String, baseUrl: String, isOpenRouter: Bool) async throws -> ProviderResponse {
        // Resolve the effective reasoning pass-through for this provider + model
        // (global master switch → per-provider auto/on/off → capability heuristic).
        let reasoningEnabled = config.reasoningEnabled(for: providerId, model: model)
        let openaiBody = MessageTranslator.toOpenAIChat(request: request, model: model, enableThinking: reasoningEnabled)
        
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
            return try await handleOpenAIStreaming(response: response, stream: stream, request: request, reasoningEnabled: reasoningEnabled)
        } else {
            let (data, response) = try await CurlClient.request(url: url, method: "POST", headers: headers, body: body, resolveIP: ip)
            let statusCode = response.statusCode
            guard statusCode == 200 else { return ProviderResponse(statusCode: statusCode, headers: ["Content-Type": "application/json"], body: data) }
            return ProviderResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: MessageTranslator.convertOpenAIResponseToAnthropic(data: data, model: request.model, enableThinking: reasoningEnabled))
        }
    }
    
    // MARK: - Streaming
    
    private func handleOpenAIStreaming(response: HTTPURLResponse, stream inputStream: AsyncStream<Data>, request: MessagesRequest, reasoningEnabled: Bool) async throws -> ProviderResponse {
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
                // Per-stream translation state: allocates Anthropic block indices so
                // reasoning can stream as a thinking block ahead of text.
                var streamState = MessageTranslator.OpenAIStreamState()
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

                        let events = MessageTranslator.openAIToAnthropicSSE(chunk: chunkDict, model: request.model, state: &streamState, enableThinking: reasoningEnabled)
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
                    // close every opened block, then message_delta + message_stop so
                    // the client doesn't hang waiting for the stream to end.
                    if hasStarted {
                        for blockIndex in streamState.openedBlocks {
                            continuation.yield(Data(SSEFormatter.blockStop(index: blockIndex).utf8))
                        }
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
    ///
    /// Fixes tier routing for Claude Code's native requests: Claude sends model
    /// names like `claude-opus-4-6-20250805` / `claude-sonnet-4-6` / `claude-haiku-4-5`
    /// (or the short `opus`/`sonnet`/`haiku`), and each tier must be mapped to the
    /// user's per-tier overrides. Previously only the exact single-word tier names
    /// were mapped and every `claude-*` name passed straight through, so tier
    /// routing silently did nothing for native requests.
    ///
    /// Rules:
    /// - `direct` (real Anthropic API): native names pass through untouched.
    /// - Local providers (llamacpp, ollama, lmstudio, jan, local): a non-empty
    ///   Default Model acts as a catch-all; otherwise tier mapping; else passthrough.
    /// - Provider-prefixed names (`opencode/big-pickle`) pass through.
    /// - Native Claude tier names → per-tier override when configured.
    /// - Other well-known names (`gpt-*`, `gemini-*`) pass through.
    private func resolveModel(_ incomingModel: String, for providerId: String? = nil) -> String {
        let lower = incomingModel.lowercased()

        // Direct Anthropic: native model names must reach the real API untouched.
        if providerId == "direct" { return incomingModel }

        let localProviders = ["llamacpp", "lmstudio", "local", "ollama", "jan"]
        if let pid = providerId, localProviders.contains(pid) {
            // A non-empty Default Model is a catch-all for local providers —
            // whatever the agent sends (opus, sonnet, big-pickle, …) is replaced
            // with the local model the user configured.
            if !config.model.isEmpty { return config.model }
            if let tier = tierName(for: lower), let mapped = tierOverride(for: tier) { return mapped }
            // No mapping at all: pass through so the local server can resolve it.
            return incomingModel
        }

        // Provider-prefixed names (e.g. "opencode/big-pickle") pass through.
        if incomingModel.contains("/") { return incomingModel }

        // Native Claude tier names → the user's per-tier override when set.
        // When no override is configured for that tier, the native name passes
        // through so the upstream (OpenAI-compatible) endpoint can try it.
        if let tier = tierName(for: lower) {
            if let mapped = tierOverride(for: tier) { return mapped }
            return incomingModel
        }

        // Other well-known names pass through untouched.
        if lower.hasPrefix("gpt-") || lower.hasPrefix("gemini-") { return incomingModel }

        // Any other model name passes through as-is.
        return incomingModel
    }

    /// Classify a model name into the Claude tier it belongs to, matching both
    /// the short tier names ("opus") and the native Claude model families
    /// ("claude-opus-4-6-…", "claude-3-5-sonnet-…", "claude-3-haiku-…").
    private func tierName(for lower: String) -> String? {
        if lower == "opus" || lower.hasPrefix("claude-opus") || lower.hasPrefix("claude-3-opus") { return "opus" }
        if lower == "sonnet"
            || lower.hasPrefix("claude-sonnet")
            || lower.hasPrefix("claude-3-sonnet")
            || lower.hasPrefix("claude-3-5-sonnet")
            || lower.hasPrefix("claude-3-7-sonnet") { return "sonnet" }
        if lower == "haiku"
            || lower.hasPrefix("claude-haiku")
            || lower.hasPrefix("claude-3-haiku")
            || lower.hasPrefix("claude-3-5-haiku")
            || lower.hasPrefix("claude-3-7-haiku") { return "haiku" }
        return nil
    }

    /// The configured model override for a tier, or nil when unset.
    private func tierOverride(for tier: String) -> String? {
        switch tier {
        case "opus": return config.modelOpus.isEmpty ? nil : config.modelOpus
        case "sonnet": return config.modelSonnet.isEmpty ? nil : config.modelSonnet
        case "haiku": return config.modelHaiku.isEmpty ? nil : config.modelHaiku
        default: return nil
        }
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
        var models: [[String: Any]] = []

        // Sanitize model IDs to remove newlines and excess whitespace.
        let sanitize: (String) -> String = { $0.components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespaces) ?? $0 }

        // Skip entries whose model id is empty or whitespace-only after sanitizing.
        let addModel: (String, String) -> Void = { rawId, ownedBy in
            let id = sanitize(rawId)
            guard !id.isEmpty else { return }
            models.append(["id": id, "object": "model", "created": now, "owned_by": ownedBy])
        }

        addModel(config.modelOpus, "jxproxy")
        addModel(config.modelSonnet, "jxproxy")
        addModel(config.modelHaiku, "jxproxy")
        for preset in ProviderPreset.all {
            for modelId in preset.models {
                addModel(modelId, preset.id)
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
