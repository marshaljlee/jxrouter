import Foundation

enum RouteAction: String, Codable, Sendable {
    case routeAI
    case passthrough
    case block

    var symbol: String {
        switch self {
        case .routeAI: "square.and.arrow.up.fill"
        case .passthrough: "arrow.right"
        case .block: "nosign"
        }
    }

    var label: String {
        switch self {
        case .routeAI: "AI Route"
        case .passthrough: "Pass Through"
        case .block: "Block"
        }
    }
}

struct RequestClassifier: Sendable {
    let aiHostPatterns: [String] = [
        "api.anthropic.com",
        "api.openai.com",
        "api.openrouter.ai",
        "opencode.ai",
        "integrate.api.nvidia.com",
        "api.groq.com",
        "api.cohere.ai",
        "api.mistral.ai",
        "codestral.mistral.ai",
        "api.deepseek.com",
        "api.perplexity.ai",
        "api.together.xyz",
        "api.fireworks.ai",
        "api.lemonfox.ai",
        "api.replicate.com",
        "inference.ai.azure.com",
        "router.huggingface.co",
        "generativelanguage.googleapis.com",
        "api.x.ai",
        "api.sambanova.ai",
        "api.cerebras.ai",
        "api.claudette.com",
        "api.studio.ai",
        "oai.opencode.ai",
        "zen.opencode.ai",
        "models.inference.ai.azure.com",
        "api.wafer.ch",
        "api.moonshot.cn",
        "api.kimi-coding.com",
        "api.minimax.chat",
        "api.z.ai",
        "gateway.ai.vercel.ai",
        "ollama.com",
    ]

    let aiHostSuffixes: [String] = [
        ".anthropic.com",
        ".openai.com",
        ".openrouter.ai",
        ".opencode.ai",
        ".nvidia.com",
        ".groq.com",
        ".cohere.ai",
        ".mistral.ai",
        ".deepseek.com",
        ".perplexity.ai",
        ".together.xyz",
        ".fireworks.ai",
        ".azure.com",
        ".huggingface.co",
        ".googleapis.com",
        ".x.ai",
        ".cerebras.ai",
        ".sambanova.ai",
        ".replicate.com",
        ".wafer.ch",
        ".moonshot.cn",
        ".kimi-coding.com",
        ".minimax.chat",
        ".z.ai",
        ".vercel.ai",
        ".ollama.com",
    ]

    func classify(host: String) -> RouteAction {
        let lower = host.lowercased()

        if aiHostPatterns.contains(lower) {
            return .routeAI
        }

        for suffix in aiHostSuffixes {
            if lower.hasSuffix(suffix) {
                return .routeAI
            }
        }

        if lower.contains("localhost") || lower.contains("127.0.0.1") {
            return .passthrough
        }

        return .passthrough
    }

    func isKnownAiHost(_ host: String) -> Bool {
        classify(host: host) == .routeAI
    }
}
