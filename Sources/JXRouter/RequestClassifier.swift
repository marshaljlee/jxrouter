import Foundation

struct RequestClassifier {
    private let routeOpenAI: Bool
    private let aiHosts: Set<String> = [
        "api.anthropic.com", "api.openai.com", "generativelanguage.googleapis.com",
        "api.deepseek.com", "api.openrouter.ai", "integrate.api.nvidia.com",
        "api.mistral.ai", "codestral.mistral.ai", "api.groq.com",
        "api.fireworks.ai", "api.sambanova.ai", "api.cerebras.ai",
        "router.huggingface.co", "api.x.ai", "api.cohere.ai",
        "opencode.ai", "api.moonshot.cn", "api.minimax.chat",
        "api.antigravity.dev",
    ]

    init(routeOpenAI: Bool = true) {
        self.routeOpenAI = routeOpenAI
    }

    func isKnownAiHost(_ host: String) -> Bool {
        let h = host.lowercased()
        return aiHosts.contains(h) || h.contains("anthropic") || h.contains("openai") || h.contains("gemini")
    }

    static func isOpenAIHost(_ host: String) -> Bool {
        host.lowercased() == "api.openai.com"
    }

    func classify(host: String) -> RouteAction {
        let h = host.lowercased()
        if h == "api.openai.com" {
            return routeOpenAI ? .routeAI : .passThroughOpenAI
        }
        if isKnownAiHost(h) { return .routeAI }
        return .passthrough
    }
}
