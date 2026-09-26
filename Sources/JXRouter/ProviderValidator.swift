import Foundation

/// Per-provider credential / model validation states used by the Settings UI.
enum ProviderCheckState: Equatable {
    case unknown
    case checking
    case valid
    case invalid(String)
}

/// Outcome of a provider or model check with a human-readable failure reason
/// (HTTP status + the server's own error text when available).
struct ProviderCheckResult: Equatable {
    let ok: Bool
    let message: String
}

/// Validates provider credentials and model reachability with lightweight
/// requests, so the UI can show green ticks when things work and clear
/// messages when they don't (e.g. a free-tier model that no longer exists,
/// or a custom endpoint that rejects the key/model).
struct ProviderValidator {

    /// True when the provider answers a `/v1/models` request with a 2xx.
    /// 401/403 → invalid credentials; network failure → unreachable.
    /// Providers that don't require a key (opencode-zen, local runtimes)
    /// are considered valid without a key — nothing to verify.
    static func validateKey(providerId: String, apiKey: String, baseUrl: String) async -> ProviderCheckResult {
        // Keyless providers have nothing to validate.
        if apiKey.isEmpty {
            let preset = ProviderPreset.preset(for: providerId)
            if let preset, !preset.requiresKey { return ProviderCheckResult(ok: true, message: "Connected") }
            if (preset?.requiresKey ?? true), !isLocalEndpoint(baseUrl) {
                return ProviderCheckResult(ok: false, message: "No API key entered — add it in Settings → Providers")
            }
        }
        
        let urlStr: String
        if providerId == "direct" || baseUrl.contains("api.anthropic.com") {
            urlStr = baseUrl.hasSuffix("/v1") ? baseUrl + "/models" : baseUrl + "/v1/models"
        } else if providerId == "gemini" && !baseUrl.contains("/openai") {
            urlStr = baseUrl.hasSuffix("/") ? baseUrl + "models" : baseUrl + "/models"
        } else {
            urlStr = baseUrl.hasSuffix("/v1") ? baseUrl + "/models" : baseUrl + "/v1/models"
        }

        guard let url = URL(string: urlStr) else {
            return ProviderCheckResult(ok: false, message: "Invalid base URL")
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        if !apiKey.isEmpty {
            if providerId == "direct" || baseUrl.contains("api.anthropic.com") {
                req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            } else if providerId == "gemini" && !baseUrl.contains("/openai") {
                req.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
            } else {
                req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }
        }
        if providerId == "openrouter" || baseUrl.contains("openrouter.ai") {
            req.setValue("https://github.com/marshaljlee/jxproxy", forHTTPHeaderField: "HTTP-Referer")
            req.setValue("JXProxy", forHTTPHeaderField: "X-Title")
        }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse {
                if (200...299).contains(http.statusCode) {
                    return ProviderCheckResult(ok: true, message: "Connected")
                }
                let detail = serverMessage(data)
                return ProviderCheckResult(ok: false, message: detail.isEmpty ? "HTTP \(http.statusCode)" : "HTTP \(http.statusCode): \(detail)")
            }
            return ProviderCheckResult(ok: false, message: "No response")
        } catch {
            return ProviderCheckResult(ok: false, message: error.localizedDescription)
        }
    }

    /// True when a tiny chat completion to the given model succeeds (2xx) or
    /// is rate-limited (429 — the model and key were accepted, just throttled).
    /// A 400/404 naming the model means the model id is dead (broken free tier
    /// or a model that doesn't exist on a custom endpoint).
    static func validateModel(providerId: String, model: String, apiKey: String, baseUrl: String) async -> ProviderCheckResult {
        guard !model.isEmpty else { return ProviderCheckResult(ok: false, message: "No model selected") }
        if apiKey.isEmpty {
            let preset = ProviderPreset.preset(for: providerId)
            if (preset?.requiresKey ?? true), !isLocalEndpoint(baseUrl) {
                let name = preset?.name ?? providerId
                return ProviderCheckResult(ok: false, message: "No API key entered for \(name) — add it in Settings → Providers")
            }
        }

        let isAnthropic = providerId == "direct" || baseUrl.contains("api.anthropic.com")
        let urlStr: String
        if isAnthropic {
            urlStr = baseUrl.hasSuffix("/v1") ? baseUrl + "/messages" : baseUrl + "/v1/messages"
        } else if providerId == "gemini" && !baseUrl.contains("/openai") {
            urlStr = baseUrl.hasSuffix("/v1") ? baseUrl + "/chat/completions" : baseUrl + "/v1/chat/completions"
        } else {
            urlStr = baseUrl.hasSuffix("/v1") ? baseUrl + "/chat/completions" : baseUrl + "/v1/chat/completions"
        }

        guard let url = URL(string: urlStr) else {
            return ProviderCheckResult(ok: false, message: "Invalid base URL")
        }

        let body: [String: Any]
        if isAnthropic {
            body = [
                "model": model,
                "max_tokens": 1,
                "messages": [["role": "user", "content": "ping"]]
            ]
        } else {
            body = [
                "model": model,
                "messages": [["role": "user", "content": "ping"]],
                "max_tokens": 1,
            ]
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 12
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if !apiKey.isEmpty {
            if isAnthropic {
                req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            } else if providerId == "gemini" && !baseUrl.contains("/openai") {
                req.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
                req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            } else {
                req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }
        }

        if providerId == "openrouter" || baseUrl.contains("openrouter.ai") {
            req.setValue("https://github.com/marshaljlee/jxproxy", forHTTPHeaderField: "HTTP-Referer")
            req.setValue("JXProxy", forHTTPHeaderField: "X-Title")
        }

        if providerId.hasPrefix("opencode") || baseUrl.contains("opencode.ai") {
            let sessionId = "ses_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(24)
            let requestId = "req_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(24)
            req.setValue(sessionId, forHTTPHeaderField: "x-opencode-session")
            req.setValue(requestId, forHTTPHeaderField: "x-opencode-request")
            req.setValue("cli", forHTTPHeaderField: "x-opencode-client")
            req.setValue("opencode/1.18.21", forHTTPHeaderField: "User-Agent")
        }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                return ProviderCheckResult(ok: false, message: "No response")
            }
            if (200...299).contains(http.statusCode) || http.statusCode == 429 {
                return ProviderCheckResult(ok: true, message: http.statusCode == 429 ? "Rate limited (key + model accepted)" : "Connected")
            }
            let detail = serverMessage(data)
            return ProviderCheckResult(ok: false, message: detail.isEmpty ? "HTTP \(http.statusCode)" : "HTTP \(http.statusCode): \(detail)")
        } catch {
            return ProviderCheckResult(ok: false, message: error.localizedDescription)
        }
    }

    /// True when the base URL points at this Mac (127.0.0.1 / localhost / ::1).
    /// Local servers (llama.app, Ollama, LM Studio) accept requests with no
    /// API key, so the "No API key entered" guard must not fire for them.
    private static func isLocalEndpoint(_ baseUrl: String) -> Bool {
        let host = baseUrl.replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .split(separator: "/").first.map(String.init) ?? ""
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
            || host.hasPrefix("127.0.0.1:") || host.hasPrefix("localhost:")
    }

    /// Extract the human-readable error text from a JSON error body
    /// (`{"error": {"message": …}}`, `{"message": …}`, `{"detail": …}`) or fall
    /// back to the raw body text (many gateways reply with plain text like
    /// "service failure: endpoint not found").
    private static func serverMessage(_ data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let err = json["error"] as? [String: Any], let m = err["message"] as? String, !m.isEmpty {
                return m
            }
            if let m = json["message"] as? String, !m.isEmpty { return m }
            if let d = json["detail"] as? String, !d.isEmpty { return d }
        }
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return "" }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Show the full server guidance (e.g. InferX's "set a default tenant or
        // use a tenant-routing header") — truncating at 140 chars cut off the
        // actionable part of the message.
        return String(trimmed.prefix(400))
    }
}
