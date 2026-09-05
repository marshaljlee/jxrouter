import Foundation

/// In-process provider router that translates Anthropic Messages API to OpenAI Chat Completions
/// and handles high-performance streaming.
@MainActor
@Observable
final class ProviderRouter: NSObject, URLSessionDelegate {
    private let upstreamTimeout: TimeInterval = 30.0
    /// How long a single provider attempt may take before the fallback chain
    /// moves on. Upstream requests can hang (rate-limited gateways, dead DNS,
    /// overloaded endpoints) for the full 30s curl timeout — with several
    /// fallbacks that adds up to a minute+ of silence, which Claude Code
    /// abandons as a timeout. 15s bounds one attempt while still leaving
    /// streaming (headers-first) responses plenty of room.
    private let chainAttemptTimeout: TimeInterval = 15.0
    /// Local providers (llama.cpp/Ollama/LM Studio/…) prefill large prompts
    /// on the local machine — a real 60k-token Claude Code request takes 30s+
    /// to prefill before a single token is generated, and the model can be
    /// cold (first request after spawn). A 15s cloud-style cap would abandon
    /// every large local request and burn the whole chain on the cloud
    /// fallbacks. Local attempts get a much longer budget; the chain's total
    /// duration cap and the proxy's per-request timeout are sized to fit.
    private let localAttemptTimeout: TimeInterval = 240.0
    /// The PRIMARY provider (the user's chosen provider, chain index 0) gets a
    /// much longer budget than fallbacks. Real Claude Code requests carry the
    /// whole conversation (300-400KB): the primary must prefill that before a
    /// single byte is streamed back, which takes 30-50s on a loaded remote
    /// gateway (observed: InferX 33-47s). The old code applied the same 15s
    /// fallback cap to the primary, so every real request was abandoned before
    /// the provider even started answering, the whole chain burned through, and
    /// the request failed with an undelivered 503. Fallbacks keep the tighter
    /// 15s cap — they exist to rescue genuinely dead primaries, not to wait.
    private let primaryAttemptTimeout: TimeInterval = 60.0
    /// The FIRST fallback (chain index 1) is the most likely rescue and needs a
    /// real prefill budget too: Claude Code's large requests take 30-60s on any
    /// cloud gateway. The old code gave fallbacks the same 15s as deep
    /// fallbacks, so the first rescue timed out on every real request and the
    /// chain died even when the fallback was healthy. Deeper fallbacks keep the
    /// tight cap so a genuinely dead primary still fails fast overall.
    private let secondaryAttemptTimeout: TimeInterval = 45.0

    /// Whether a provider id is a local (on-machine) runtime.
    private func isLocalProvider(_ pid: String) -> Bool {
        ["local", "ollama", "lmstudio", "llamaapp", "llamacpp", "jan", "unsloth", "gguf"].contains(pid)
    }

    /// The one model a provider is guaranteed to serve, used to rescue a
    /// request when the provider rejects the model it was asked for. Local
    /// providers and `direct` resolve their own model internally, so they
    /// return nil here (no retry needed). Custom providers have no curated
    /// default, so they return nil too.
    private func defaultModelForProvider(_ pid: String) -> String? {
        switch pid {
        case "opencode-zen", "opencode-go": return "big-pickle"
        case "nvidia-nim": return "nvidia/deepseek-v4"
        case "direct", "local", "ollama", "lmstudio", "llamaapp", "llamacpp", "jan", "gguf": return nil
        default:
            return ProviderPreset.preset(for: pid)?.models.first
        }
    }

    /// Per-attempt deadline for one provider in the chain. The PRIMARY (index 0)
    /// is the user's chosen provider and gets the generous primary budget so a
    /// slow-but-working gateway can actually serve a large request; fallbacks
    /// keep the tight chain cap so a dead primary is abandoned quickly. Local
    /// runtimes always get the long prefill budget.
    private func attemptTimeout(for providerId: String, index: Int) -> TimeInterval {
        if isLocalProvider(providerId) { return localAttemptTimeout }
        switch index {
        case 0: return primaryAttemptTimeout
        case 1: return secondaryAttemptTimeout
        default: return chainAttemptTimeout
        }
    }
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
        case "/v1/chat/completions", "/v1/v1/chat/completions", "/chat/completions":
            return try await handleChatCompletions(method: method, body: body)
        case "/v1/responses", "/v1/v1/responses", "/responses":
            return try await handleResponses(method: method, body: body)
        case "/v1/messages/count_tokens":
            return handleTokenCount(body: body)
        case "/v1/models":
            return handleModelList()
        case "/health", "/", "/api/hello", "/v1/api/hello":
            return handleHealth()
        case "/stop":
            return ProviderResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: Data(#"{"status":"stopped"}"#.utf8))
        default:
            // Honest error instead of a silent empty 200 — unknown paths on an
            // AI host are passed through by DirectTLSHandler before reaching
            // the router, so this is only a safety net.
            return errorResponse(statusCode: 404, type: "invalid_request_error", message: "Not found: \(path)")
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

        // Route the request through the tier's own provider when Claude sent a
        // model for a tier that has one configured (Opus / Sonnet / Haiku),
        // otherwise the global primary — both followed by the fallback chain.
        let tier = tierName(for: messagesRequest.model.lowercased())
        let providerChain = providerChain(for: tier)
        var lastError: Error?
        var failures: [(providerId: String, statusCode: Int)] = []
        let chainStart = CFAbsoluteTimeGetCurrent()
        // Total fallback chain cap — sized so a slow local prefill (up to the
        // 240s local attempt budget) can complete instead of being cut off.
        let maxChainDuration: TimeInterval = 300.0
        
        for (index, providerId) in providerChain.enumerated() {
            let elapsed = CFAbsoluteTimeGetCurrent() - chainStart
            guard elapsed < maxChainDuration else {
                failures.append((providerId, 504))
                break
            }
            
            if index > 0 {
                try await Task.sleep(nanoseconds: 1_000_000_000)
                guard CFAbsoluteTimeGetCurrent() - chainStart < maxChainDuration else {
                    failures.append((providerId, 504))
                    break
                }
            }
            
            do {
                let startTime = CFAbsoluteTimeGetCurrent()
                // Tier model overrides (e.g. Sonnet → minimaxai/minimax-m3) apply
                // ONLY to the tier's own primary provider. A fallback must receive
                // the model the client actually asked for — otherwise opencode-zen
                // gets handed "minimaxai/minimax-m3" and, not recognizing it,
                // silently serves its default model (big-pickle), so every model
                // choice appeared to route to big-pickle.
                // The curl --max-time must match the attempt budget, or curl
                // would kill itself at 30s before the 60s primary budget elapses
                // (a slow-but-working primary then looks dead and the chain
                // burns through to a 503).
                let budget = attemptTimeout(for: providerId, index: index)
                var response = try await Self.withAttemptTimeout(seconds: budget) {
                    try await self.routeToProvider(providerId: providerId, request: messagesRequest, applyTierMapping: index == 0, maxTime: Int(budget))
                }
                // Model-rejection rescue: a provider that refuses the REQUESTED
                // model (400 model unavailable, 401 "model not supported", 404
                // unknown model) gets ONE retry with its OWN default model. This
                // is what makes fallbacks actually rescue a dead primary: Claude
                // Code sends native names ("claude-sonnet-4-…") which no
                // OpenAI-compatible fallback can serve — without the retry the
                // whole chain 401s and the user has to switch models manually.
                // The client's model is always tried first, so the previous
                // "fallback must not silently substitute a model" behavior is
                // preserved when the fallback CAN serve the requested model.
                if [400, 401, 404].contains(response.statusCode), defaultModelForProvider(providerId) != nil {
                    print("[ProviderRouter] \(providerId) rejected model — retrying with its default model")
                    response = try await Self.withAttemptTimeout(seconds: budget) {
                        try await self.routeToProvider(providerId: providerId, request: messagesRequest, applyTierMapping: index == 0, forceDefaultModel: true, maxTime: Int(budget))
                    }
                }
                let elapsedMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
                
                self.lastLatencyMs = elapsedMs
                config.lastLatencyMs = elapsedMs

                if response.statusCode >= 500 {
                    failures.append((providerId, response.statusCode))
                    continue
                }
                // 4xx client errors (400 model unavailable, 401 auth, 403 forbidden,
                // 404 not found, 429 rate limit) mean this provider can't serve the
                // request — continue the chain so a configured fallback is tried.
                // Previously this only applied to non-primary providers, so the
                // chain stopped dead on the primary's 4xx and the user had to
                // switch models manually.
                if [400, 401, 403, 404, 429].contains(response.statusCode) {
                    failures.append((providerId, response.statusCode))
                    continue
                }
                // Attach which provider served the request (and whether a
                // fallback had to be used) so the Logs tab can show it.
                response.servingProvider = providerId
                response.usedFallback = index > 0
                return response
            } catch {
                failures.append((providerId, 0))
                lastError = error
                continue
            }
        }
        
        let errorMsg = ProviderChainError.chainFailureMessage(failures, lastError: lastError)
        return errorResponse(statusCode: 503, type: "api_error", message: errorMsg)
    }
    
    // MARK: - OpenAI Chat Completions (system-wide OpenAI routing)

    /// Route an OpenAI-format Chat Completions request — from ANY app talking
    /// to api.openai.com through the system-wide proxy (Codex, the OpenAI SDK,
    /// curl, …) — through the configured provider chain. The request is already
    /// OpenAI format, so it is forwarded to OpenAI-compatible providers as-is:
    /// no Anthropic translation, and the OpenAI-format SSE stream passes
    /// through untouched. The `direct` provider is skipped because Anthropic's
    /// API is not OpenAI-compatible.
    /// Route an OpenAI Responses API request (`POST /v1/responses` — what the
    /// Codex CLI and recent OpenAI SDKs actually call) through the provider
    /// chain. The request is translated into Chat Completions shape, routed by
    /// the shared chain, then the result is translated back into Responses
    /// format (JSON or SSE) so the client sees native Responses data.
    private func handleResponses(method: String, body: Data) async throws -> ProviderResponse {
        if method == "HEAD" || method == "OPTIONS" {
            return ProviderResponse(statusCode: 204, headers: ["Allow": "POST, HEAD, OPTIONS"], body: Data())
        }

        guard let requestJSON = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return errorResponse(statusCode: 400, type: "invalid_request_error", message: "Invalid JSON body")
        }

        let requestedModel = requestJSON["model"] as? String ?? ""
        let chatBody = ResponsesTranslator.toChatCompletions(requestJSON)
        let response = try await runChatChain(requestJSON: chatBody)

        if let stream = response.stream {
            // Translate the chat-completions SSE stream into the Responses SSE
            // event sequence the client is waiting for.
            let converted = ResponsesTranslator.translateChatSSEToResponses(stream, model: requestedModel)
            return ProviderResponse(
                statusCode: response.statusCode,
                headers: ["Content-Type": "text/event-stream", "Cache-Control": "no-cache", "Connection": "keep-alive"],
                body: Data(),
                stream: converted
            )
        }

        guard response.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any] else {
            return response
        }
        let model = json["model"] as? String ?? requestedModel
        let responsesJSON = ResponsesTranslator.toResponses(json, model: model)
        return ProviderResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: (try? JSONSerialization.data(withJSONObject: responsesJSON)) ?? response.body)
    }

    private func handleChatCompletions(method: String, body: Data) async throws -> ProviderResponse {
        if method == "HEAD" || method == "OPTIONS" {
            return ProviderResponse(statusCode: 204, headers: ["Allow": "POST, HEAD, OPTIONS"], body: Data())
        }

        guard let requestJSON = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return errorResponse(statusCode: 400, type: "invalid_request_error", message: "Invalid JSON body")
        }

        return try await runChatChain(requestJSON: requestJSON)
    }

    /// Walk an OpenAI Chat Completions request through the provider chain.
    /// Shared by the raw `/v1/chat/completions` path (response passes through
    /// untouched) and the `/v1/responses` path (response is converted back to
    /// Responses format by the caller).
    private func runChatChain(requestJSON: [String: Any]) async throws -> ProviderResponse {
        let requestedModel = requestJSON["model"] as? String ?? ""
        let wantsStream = requestJSON["stream"] as? Bool ?? false
        // OpenAI clients usually send gpt-* names, but when they send a Claude
        // tier model the tier's own provider should be used, matching the
        // Anthropic path.
        let tier = tierName(for: requestedModel.lowercased())
        let chain = providerChain(for: tier).filter { $0 != "direct" }
        guard !chain.isEmpty else {
            return errorResponse(statusCode: 503, type: "api_error", message: "No OpenAI-compatible provider configured")
        }

        var lastError: Error?
        var failures: [(providerId: String, statusCode: Int)] = []
        let chainStart = CFAbsoluteTimeGetCurrent()
        let maxChainDuration: TimeInterval = 300.0
        for (index, providerId) in chain.enumerated() {
            let elapsed = CFAbsoluteTimeGetCurrent() - chainStart
            guard elapsed < maxChainDuration else {
                failures.append((providerId, 504))
                break
            }

            if index > 0 {
                try await Task.sleep(nanoseconds: 1_000_000_000)
                guard CFAbsoluteTimeGetCurrent() - chainStart < maxChainDuration else {
                    failures.append((providerId, 504))
                    break
                }
            }

            do {
                let startTime = CFAbsoluteTimeGetCurrent()
                // Same rule as Anthropic messages: tier model overrides apply only
                // to the tier's primary; fallbacks get the client's original model.
                let budget = attemptTimeout(for: providerId, index: index)
                var response = try await Self.withAttemptTimeout(seconds: budget) {
                    try await self.routeChatCompletionsToProvider(providerId: providerId, request: requestJSON, model: requestedModel, stream: wantsStream, applyTierMapping: index == 0, maxTime: Int(budget))
                }
                // Same model-rejection rescue as the Anthropic path: retry once
                // with the provider's own default model so a dead primary is
                // rescued by a fallback instead of failing the whole request.
                if [400, 401, 404].contains(response.statusCode), defaultModelForProvider(providerId) != nil {
                    print("[ProviderRouter] \(providerId) rejected model — retrying with its default model")
                    response = try await Self.withAttemptTimeout(seconds: budget) {
                        try await self.routeChatCompletionsToProvider(providerId: providerId, request: requestJSON, model: requestedModel, stream: wantsStream, applyTierMapping: index == 0, forceDefaultModel: true, maxTime: Int(budget))
                    }
                }
                let elapsedMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
                self.lastLatencyMs = elapsedMs
                config.lastLatencyMs = elapsedMs

                if response.statusCode >= 500 {
                    failures.append((providerId, response.statusCode))
                    continue
                }
                // Same failover rule as Anthropic messages: a 4xx means this
                // provider can't serve the request — try the next fallback.
                if [400, 401, 403, 404, 429].contains(response.statusCode) {
                    failures.append((providerId, response.statusCode))
                    continue
                }
                response.servingProvider = providerId
                response.usedFallback = index > 0
                return response
            } catch {
                failures.append((providerId, 0))
                lastError = error
                continue
            }
        }

        let errorMsg = ProviderChainError.chainFailureMessage(failures, lastError: lastError)
        return errorResponse(statusCode: 503, type: "api_error", message: errorMsg)
    }

    /// Forward one OpenAI-format Chat Completions request to a provider's
    /// OpenAI-compatible endpoint. The model is resolved through the same tier
    /// logic as Anthropic requests; the response (including SSE) is returned
    /// untouched so the OpenAI client sees native OpenAI data.
    private func routeChatCompletionsToProvider(providerId: String, request: [String: Any], model: String, stream: Bool, applyTierMapping: Bool = true, forceDefaultModel: Bool = false, maxTime: Int = 30) async throws -> ProviderResponse {
        var body = request
        let resolvedModel = resolveModel(model, for: providerId, applyTierOverride: applyTierMapping, forceDefaultModel: forceDefaultModel)
        var effectiveModel = resolvedModel
        for prefix in ProviderPreset.knownPrefixes {
            if effectiveModel.hasPrefix(prefix) {
                effectiveModel = String(effectiveModel.dropFirst(prefix.count))
                break
            }
        }
        body["model"] = effectiveModel

        let apiKey = config.apiKey(for: providerId)
        var baseUrl = config.baseUrl(for: providerId)
        // Same live-port resolution as the Anthropic path — llama.app's server
        // can move ports across relaunches, and a stale hardcoded 8080 would
        // silently fail every OpenAI-format request to it.
        if providerId == "llamaapp" || providerId == "llamacpp" {
            baseUrl = "http://127.0.0.1:\(LocalServerDiscovery.liveLlamaPort())/v1"
        }
        let effectiveMaxTime = isLocalProvider(providerId) ? 300 : maxTime
        guard let url = URL(string: "\(baseUrl)/chat/completions") else {
            return errorResponse(statusCode: 500, type: "api_error", message: "Invalid provider URL: \(baseUrl)")
        }
        let host = url.host ?? "api.openai.com"
        let ip = await DirectDNSResolver.shared.resolve(host) ?? host

        var headers: [String: String] = ["Content-Type": "application/json", "Host": host]
        if !apiKey.isEmpty { headers["Authorization"] = "Bearer \(apiKey)" }

        let bodyData: Data
        do {
            bodyData = try JSONSerialization.data(withJSONObject: body)
        } catch {
            print("[ProviderRouter] JSON serialization failed: \(error)")
            return errorResponse(statusCode: 500, type: "api_error", message: "Failed to serialize request body: \(error.localizedDescription)")
        }
        if stream {
            let (response, inputStream) = try await CurlClient.stream(url: url, method: "POST", headers: headers, body: bodyData, resolveIP: ip, maxTime: effectiveMaxTime)
            if response.statusCode != 200 {
                var full = Data()
                for await chunk in inputStream { full.append(chunk) }
                return ProviderResponse(statusCode: response.statusCode, headers: ["Content-Type": "application/json"], body: full)
            }
            return ProviderResponse(
                statusCode: 200,
                headers: ["Content-Type": "text/event-stream", "Cache-Control": "no-cache", "Connection": "keep-alive"],
                body: Data(),
                stream: inputStream
            )
        } else {
            let (data, response) = try await CurlClient.request(url: url, method: "POST", headers: headers, body: bodyData, resolveIP: ip, maxTime: effectiveMaxTime)
            return ProviderResponse(statusCode: response.statusCode, headers: ["Content-Type": response.mimeType ?? "application/json"], body: data)
        }
    }

    /// First model id a local OpenAI-compatible endpoint (llama.cpp, LM
    /// Studio, Ollama, …) serves, fetched on demand and cached briefly. Used
    /// to turn a "local"/empty model placeholder into a real model name.
    private static var localModelCache: [String: (model: String, at: Date)] = [:]
    private func firstLocalModel(baseUrl: String) async -> String? {
        let key = baseUrl
        if let cached = Self.localModelCache[key], Date().timeIntervalSince(cached.at) < 60 {
            return cached.model
        }
        let endpoint = baseUrl.hasSuffix("/v1") ? "\(baseUrl)/models" : "\(baseUrl)/v1/models"
        guard let url = URL(string: endpoint) else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 2
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["data"] as? [[String: Any]],
              let first = list.compactMap({ $0["id"] as? String }).first,
              !first.isEmpty else { return nil }
        Self.localModelCache[key] = (first, Date())
        return first
    }

    /// Whether a provider id is one the router can send requests to — a
    /// built-in preset (or the legacy "local" alias) or a named custom provider.
    private func providerIsValid(_ pid: String) -> Bool {
        if config.customProviders.contains(where: { $0.id == pid }) { return true }
        if pid == "local" { return true }
        return ProviderPreset.preset(for: pid) != nil
    }

    /// The provider chain for a request. When the request targets a Claude tier
    /// (Opus / Sonnet / Haiku) that has its own provider configured, that
    /// provider becomes the primary of the chain; otherwise the global primary
    /// is used. Both are followed by the configured fallbacks. Fallbacks that
    /// can't possibly serve (built-in key-requiring providers with no API key)
    /// are skipped so the chain reaches a working provider instead of burning
    /// time on guaranteed 401s. Custom providers are always tried — many are
    /// keyless local gateways.
    private func providerChain(for tier: String? = nil) -> [String] {
        var primary = ConfigManager.resolveProviderName(config.provider)
        if let tier,
           let pid = config.tierProvider(for: tier),
           !pid.isEmpty {
            let resolved = ConfigManager.resolveProviderName(pid)
            if providerIsValid(resolved) {
                primary = resolved
            } else {
                print("[ProviderRouter] Tier \(tier) provider \(pid) is no longer valid — using \(primary)")
            }
        }
        var chain = [primary]
        let fallbacks = config.fallbackProviders
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { ConfigManager.resolveProviderName($0) }
        for pid in fallbacks {
            if pid == primary { continue }
            // Dedupe: "nvidia,opencode-zen,nvidia-nim" resolves to nvidia-nim
            // twice — a duplicate attempt wastes up to 15s of the chain.
            if chain.contains(pid) { continue }
            if config.customProviders.contains(where: { $0.id == pid }) {
                chain.append(pid)
                continue
            }
            if let preset = ProviderPreset.preset(for: pid),
               preset.requiresKey,
               config.apiKey(for: pid).isEmpty {
                print("[ProviderRouter] Skipping fallback \(pid) — requires an API key that isn't configured")
                continue
            }
            chain.append(pid)
        }
        return chain
    }

    // MARK: - Routing
    
    private func routeToProvider(providerId: String, request: MessagesRequest, applyTierMapping: Bool = true, forceDefaultModel: Bool = false, maxTime: Int = 30) async throws -> ProviderResponse {
        let resolvedModel = resolveModel(request.model, for: providerId, applyTierOverride: applyTierMapping, forceDefaultModel: forceDefaultModel)
        let apiKey = config.apiKey(for: providerId)
        var baseUrl = config.baseUrl(for: providerId)
        // llama.app's built-in server picks its own port (historically 8080,
        // but it can move to a different free port after a relaunch) — resolve
        // the LIVE port so both local-model discovery and requests reach the
        // actual server instead of silently failing on a stale 8080.
        if providerId == "llamaapp" || providerId == "llamacpp" {
            baseUrl = "http://127.0.0.1:\(LocalServerDiscovery.liveLlamaPort())/v1"
        }
        
        var model = resolvedModel
        for prefix in ProviderPreset.knownPrefixes {
            if model.hasPrefix(prefix) {
                model = String(model.dropFirst(prefix.count))
                break
            }
        }

        // A tier model saved as "local" (or empty) means "use the local
        // model", not a model literally named "local" — resolve it to the
        // user's configured local default, or the first model the running
        // local server actually serves. Without this, a local provider gets
        // sent "local" and answers 400, so the local fallback can never save
        // a request when the cloud providers are down.
        let localProviders = ["local", "ollama", "lmstudio", "llamaapp", "jan", "unsloth", "gguf"]
        if localProviders.contains(providerId) {
            // The direct GGUF provider serves exactly ONE model: the alias we
            // registered when llama-server launched. It must never be replaced
            // by the generic localLlmModel (which defaults to an ollama name) —
            // substitute the configured GGUF alias, or the first model the
            // server actually reports.
            if providerId == "gguf" {
                let ggufAlias = config.ggufModelAlias
                let lower = model.lowercased()
                let isLocalModelName = lower.hasPrefix("gguf/") || lower == ggufAlias.lowercased()
                if lower.isEmpty || lower == "local" || !isLocalModelName {
                    if !ggufAlias.isEmpty {
                        model = ggufAlias
                    } else if let first = await firstLocalModel(baseUrl: baseUrl) {
                        model = first
                    }
                } else if lower.hasPrefix("gguf/") {
                    // Strip the gguf/ prefix so the server receives its alias.
                    model = String(model.dropFirst("gguf/".count))
                }
            } else {
                let lower = model.lowercased()
                // A local provider can only serve local models. Any other name — a
                // tier "local" placeholder, an empty local default, or a cloud
                // model like "big-pickle" that leaked in as the global default —
                // must be substituted with the configured local default, or the
                // first model the running local server actually serves. Sending a
                // cloud name to llama.cpp/Ollama yields a 400 model-not-found that
                // used to burn the whole fallback chain.
                let isLocalModelName = lower.hasPrefix("local/") || lower.hasPrefix("ollama/")
                    || lower.hasPrefix("lmstudio/") || lower.hasPrefix("llamaapp/")
                if lower.isEmpty || lower == "local" || !isLocalModelName {
                    if !config.localLlmModel.isEmpty {
                        model = config.localLlmModel
                    } else if let first = await firstLocalModel(baseUrl: baseUrl) {
                        model = first
                    }
                }
            }
        }
        
        // Local runtimes prefill large prompts on the local machine (30s+ for
        // a 60k-token request, longer when the model is cold) — their curl
        // calls get a much longer --max-time so the chain doesn't abandon them.
        // Cloud maxTime comes from the caller (primary vs fallback budget).
        let effectiveMaxTime = isLocalProvider(providerId) ? 300 : maxTime

        switch providerId {
        case "direct":
            return try await routeToAnthropicDirect(request: request, model: model, apiKey: apiKey, baseUrl: baseUrl)
        case "openrouter":
            return try await routeToOpenAICompatible(request: request, model: model, providerId: providerId, apiKey: apiKey, baseUrl: baseUrl, isOpenRouter: true, maxTime: effectiveMaxTime)
        case "opencode-zen", "opencode-go", "openai":
            return try await routeToOpenAICompatible(request: request, model: model, providerId: providerId, apiKey: apiKey, baseUrl: baseUrl, isOpenRouter: false, maxTime: effectiveMaxTime)
        case "nvidia-nim":
            return try await routeToOpenAICompatible(request: request, model: model, providerId: providerId, apiKey: apiKey, baseUrl: baseUrl, isOpenRouter: false, maxTime: effectiveMaxTime)
        case "deepseek", "gemini", "gemini-oauth", "mistral", "codestral", "cohere", "groq", "fireworks", "sambanova", "cerebras", "huggingface", "github-models", "wafer", "kimi", "kimi-code", "minimax", "xai", "zai", "ollama-cloud", "ai-gateway", "antigravity", "custom", "jan":
            return try await routeToOpenAICompatible(request: request, model: model, providerId: providerId, apiKey: apiKey, baseUrl: baseUrl, isOpenRouter: false, maxTime: effectiveMaxTime)
        case let pid where config.customProviders.contains(where: { $0.id == pid }):
            // Named custom providers (Settings → Providers → Custom Providers)
            // route through the same OpenAI-compatible path.
            return try await routeToOpenAICompatible(request: request, model: model, providerId: providerId, apiKey: apiKey, baseUrl: baseUrl, isOpenRouter: false, maxTime: effectiveMaxTime)
        case "local", "ollama":
            return try await routeToOpenAICompatible(request: request, model: model, providerId: providerId, apiKey: apiKey, baseUrl: config.localLlmBaseUrl, isOpenRouter: false, maxTime: effectiveMaxTime)
        case "lmstudio", "llamaapp", "llamacpp", "unsloth", "gguf":
            return try await routeToOpenAICompatible(request: request, model: model, providerId: providerId, apiKey: "", baseUrl: baseUrl, isOpenRouter: false, maxTime: effectiveMaxTime)
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
        
        guard let url = URL(string: "\(baseUrl)/v1/messages") else {
            return errorResponse(statusCode: 500, type: "api_error", message: "Invalid provider URL: \(baseUrl)")
        }
        let host = url.host ?? "api.anthropic.com"
        let ip = await DirectDNSResolver.shared.resolve(host) ?? host

        // The direct provider's curl budget: 60s — the primary-attempt budget.
        // curl was previously hardcoded to 30s, so a healthy-but-slow primary
        // timed out before its own attempt budget elapsed and the chain
        // burned a fallback. Direct is never a local runtime, so the 300s
        // local budget does not apply here.
        let effectiveMaxTime = 60

        let body = (try? JSONSerialization.data(withJSONObject: bodyDict)) ?? Data()
        let headers: [String: String] = [
            "Content-Type": "application/json",
            "x-api-key": apiKey,
            "anthropic-version": "2023-06-01",
            "Host": host
        ]
        
        if request.stream {
            let (response, stream) = try await CurlClient.stream(url: url, method: "POST", headers: headers, body: body, resolveIP: ip, maxTime: effectiveMaxTime)
            return ProviderResponse(statusCode: response.statusCode, headers: ["Content-Type": "text/event-stream", "Cache-Control": "no-cache", "Connection": "keep-alive"], body: Data(), stream: stream)
        } else {
            let (data, response) = try await CurlClient.request(url: url, method: "POST", headers: headers, body: body, resolveIP: ip, maxTime: effectiveMaxTime)
            return ProviderResponse(statusCode: response.statusCode, headers: ["Content-Type": response.mimeType ?? "application/json"], body: data)
        }
    }
    
    private func routeToOpenAICompatible(request: MessagesRequest, model: String, providerId: String, apiKey: String, baseUrl: String, isOpenRouter: Bool, maxTime: Int = 30) async throws -> ProviderResponse {
        // Resolve the effective reasoning pass-through for this provider + model
        // (global master switch → per-provider auto/on/off → capability heuristic).
        let reasoningEnabled = config.reasoningEnabled(for: providerId, model: model)
        let openaiBody = MessageTranslator.toOpenAIChat(request: request, model: model, enableThinking: reasoningEnabled)

        guard let url = URL(string: "\(baseUrl)/chat/completions") else {
            return errorResponse(statusCode: 500, type: "api_error", message: "Invalid provider URL: \(baseUrl)")
        }
        let host = url.host ?? "api.openai.com"
        let ip = await DirectDNSResolver.shared.resolve(host) ?? host
        
        let body: Data
        do {
            body = try JSONSerialization.data(withJSONObject: openaiBody)
        } catch {
            print("[ProviderRouter] JSON serialization failed: \(error)")
            return errorResponse(statusCode: 500, type: "api_error", message: "Failed to serialize request body: \(error.localizedDescription)")
        }
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
        
        let isLocal = isLocalProvider(providerId) || baseUrl.contains("127.0.0.1") || baseUrl.contains("localhost")
        let hasNativeTools = openaiBody["tools"] != nil

        if request.stream {
            var (response, stream) = try await CurlClient.stream(url: url, method: "POST", headers: headers, body: body, resolveIP: ip, maxTime: maxTime)

            // Auto-heal for local models if the inference engine rejects tools format (e.g. 400 Bad Request, missing Jinja tool template)
            if response.statusCode != 200 && isLocal && hasNativeTools {
                print("[ProviderRouter] Local provider \(providerId) returned HTTP \(response.statusCode) with native tools. Auto-healing with system prompt tool injection...")
                let fallbackBody = MessageTranslator.toOpenAIChat(request: request, model: model, enableThinking: reasoningEnabled, injectToolsIntoPrompt: true)
                if let fallbackData = try? JSONSerialization.data(withJSONObject: fallbackBody) {
                    let (retryResponse, retryStream) = try await CurlClient.stream(url: url, method: "POST", headers: headers, body: fallbackData, resolveIP: ip, maxTime: maxTime)
                    if retryResponse.statusCode == 200 {
                        response = retryResponse
                        stream = retryStream
                    }
                }
            }

            return try await handleOpenAIStreaming(response: response, stream: stream, request: request, reasoningEnabled: reasoningEnabled)
        } else {
            var (data, response) = try await CurlClient.request(url: url, method: "POST", headers: headers, body: body, resolveIP: ip, maxTime: maxTime)

            // Auto-heal for local models if native tools reject with 400 or 500
            if response.statusCode != 200 && isLocal && hasNativeTools {
                print("[ProviderRouter] Local provider \(providerId) returned HTTP \(response.statusCode) with native tools. Auto-healing with system prompt tool injection...")
                let fallbackBody = MessageTranslator.toOpenAIChat(request: request, model: model, enableThinking: reasoningEnabled, injectToolsIntoPrompt: true)
                if let fallbackData = try? JSONSerialization.data(withJSONObject: fallbackBody) {
                    let (retryData, retryResponse) = try await CurlClient.request(url: url, method: "POST", headers: headers, body: fallbackData, resolveIP: ip, maxTime: maxTime)
                    if retryResponse.statusCode == 200 {
                        data = retryData
                        response = retryResponse
                    }
                }
            }

            let statusCode = response.statusCode
            guard statusCode == 200 else { return ProviderResponse(statusCode: statusCode, headers: ["Content-Type": "application/json"], body: data) }
            return ProviderResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: MessageTranslator.convertOpenAIResponseToAnthropic(data: data, model: request.model, enableThinking: reasoningEnabled))
        }
    }
    
    /// Race a provider attempt against a deadline. Streaming responses return
    /// after headers, so a full generation is never cut off; a provider that
    /// hangs before answering (the common failure) is abandoned at the deadline
    /// and the chain moves to the next fallback.
    static func withAttemptTimeout<T>(seconds: TimeInterval, _ op: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await op() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw ProviderChainAttemptTimedOut()
            }
            let first = try await group.next()
            group.cancelAll()
            guard let result = first else { throw ProviderChainAttemptTimedOut() }
            return result
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
            // No throwing call exists in this body (AsyncStream<Data> iteration
            // doesn't throw), so a do/catch here was dead code the compiler
            // rejected as unreachable — the task always completes normally.
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
                } else {
                    // Nothing was ever emitted — deliver a complete minimal
                    // Anthropic stream (message_start → empty text block →
                    // message_delta → message_stop) so the client gets a valid
                    // (empty) message instead of a truncated/protocol-violating
                    // stream that just stops.
                    let inputTokens = (streamState.usage?["prompt_tokens"] as? Int) ?? 0
                    let startPayload = "{\"type\":\"message_start\",\"message\":{\"id\":\"msg_\(UUID().uuidString.prefix(12))\",\"type\":\"message\",\"role\":\"assistant\",\"content\":[],\"model\":\"\(request.model)\",\"stop_reason\":null,\"stop_sequence\":null,\"usage\":{\"input_tokens\":\(inputTokens),\"output_tokens\":0}}}"
                    continuation.yield(Data(SSEFormatter.format(event: "message_start", data: startPayload).utf8))
                    let blockStart = SSEFormatter.format(event: "content_block_start", data: "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}")
                    continuation.yield(Data(blockStart.utf8))
                    continuation.yield(Data(SSEFormatter.blockStop(index: 0).utf8))
                    let msgDelta = SSEFormatter.format(event: "message_delta", data: "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\",\"stop_sequence\":null},\"usage\":{\"output_tokens\":0}}")
                    continuation.yield(Data(msgDelta.utf8))
                }
                let stopEvent = SSEFormatter.format(event: "message_stop", data: "{\"type\":\"message_stop\"}")
                continuation.yield(Data(stopEvent.utf8))
                hasFinished = true
            }
            continuation.finish()
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
    /// - Local providers (llamaapp, ollama, lmstudio, jan, local): a non-empty
    ///   Default Model acts as a catch-all; otherwise tier mapping; else passthrough.
    /// - Provider-prefixed names (`opencode/big-pickle`) pass through.
    /// - Native Claude tier names → per-tier override when configured.
    /// - Other well-known names (`gpt-*`, `gemini-*`) pass through.
    private func resolveModel(_ incomingModel: String, for providerId: String? = nil, applyTierOverride: Bool = true, forceDefaultModel: Bool = false) -> String {
        let lower = incomingModel.lowercased()

        // Map all models to Gemini models for Google-based providers
        if let pid = providerId, pid == "gemini" {
            if let tier = tierName(for: lower), applyTierOverride, let mapped = tierOverride(for: tier) {
                return mapped
            }
            
            // Claude models → Gemini equivalents
            if lower.contains("opus") {
                return "gemini/gemini-2.5-pro"
            } else if lower.contains("sonnet") {
                return "gemini/gemini-2.5-flash"
            } else if lower.contains("haiku") {
                return "gemini/gemini-2.5-flash"
            }
            
            // OpenAI models → Gemini equivalents
            if lower.hasPrefix("gpt-4o-mini") || lower.contains("gpt-3.5") || lower.hasPrefix("gpt-4.1-mini") || lower.hasPrefix("gpt-4.1-nano") {
                return "gemini/gemini-2.5-flash"
            } else if lower.hasPrefix("gpt-4") || lower.hasPrefix("gpt-5") || lower.contains("o3") || lower.contains("o4") || lower.contains("o1") {
                return "gemini/gemini-2.5-pro"
            }
            
            // Already Gemini-prefixed
            if lower.hasPrefix("gemini-") {
                return "gemini/" + incomingModel
            }
            if lower.hasPrefix("gemini/") {
                return incomingModel
            }
            // Any unrecognized model defaults to flash
            return "gemini/gemini-2.5-flash"
        }

        // Direct Anthropic: native model names must reach the real API untouched.
        if providerId == "direct" { return incomingModel }

        // Model-rejection rescue: the provider refused the requested model, so
        // retry with the provider's own default — the one model it is known to
        // serve (preset flagship) rather than a native Claude name or another
        // provider's model that it can never serve.
        if forceDefaultModel, let pid = providerId, pid != "direct",
           let def = defaultModelForProvider(pid) {
            return def
        }

        let localProviders = ["llamaapp", "lmstudio", "local", "ollama", "jan", "unsloth", "gguf"]
        if let pid = providerId, localProviders.contains(pid) {
            // A non-empty Default Model is a catch-all for local providers —
            // whatever the agent sends (opus, sonnet, big-pickle, …) is replaced
            // with the local model the user configured.
            if !config.model.isEmpty { return config.model }
            if applyTierOverride, let tier = tierName(for: lower), let mapped = tierOverride(for: tier) { return mapped }
            // No mapping at all: pass through so the local server can resolve it.
            return incomingModel
        }

        // Provider-prefixed names (e.g. "opencode/big-pickle") pass through.
        if incomingModel.contains("/") { return incomingModel }

        // Native Claude tier names → the user's per-tier override when set.
        // When no override is configured for that tier, the native name passes
        // through so the upstream (OpenAI-compatible) endpoint can try it.
        if let tier = tierName(for: lower) {
            if applyTierOverride, let mapped = tierOverride(for: tier) {
                // A tier model saved as "local" means "use the local model" —
                // it is only meaningful for local providers (where it is
                // resolved to a real local model before the request is sent).
                // Leaking the literal string "local" to cloud fallbacks asks
                // them for a model that doesn't exist (404/401/400), which
                // used to burn the whole fallback chain even when the local
                // tier provider was healthy.
                if mapped.lowercased() == "local", let pid = providerId, !localProviders.contains(pid) {
                    return incomingModel
                }
                return mapped
            }
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
        if lower == "opus" || lower.hasPrefix("opus[") || lower.hasPrefix("claude-opus") || lower.hasPrefix("claude-3-opus") { return "opus" }
        if lower == "sonnet"
            || lower.hasPrefix("sonnet[")
            || lower.hasPrefix("claude-sonnet")
            || lower.hasPrefix("claude-3-sonnet")
            || lower.hasPrefix("claude-3-5-sonnet")
            || lower.hasPrefix("claude-3-7-sonnet") { return "sonnet" }
        if lower == "haiku"
            || lower.hasPrefix("haiku[")
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
        // Only models the user can actually reach — see ConfigManager.accessibleModels().
        let accessible = config.accessibleModels()
        let models: [[String: Any]] = accessible.map { entry in
            ["id": entry.id, "object": "model", "created": now, "owned_by": entry.ownedBy]
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
