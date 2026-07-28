import Foundation
import Observation

struct ProviderPreset: Identifiable, Hashable {
    let id: String
    let name: String
    let symbol: String
    let defaultUrl: String
    let models: [String]
    let requiresKey: Bool

    static let all: [ProviderPreset] = [
        ProviderPreset(id: "opencode-zen", name: "OpenCode Zen", symbol: "sparkle.magnifyingglass", defaultUrl: "https://zen.opencode.ai/v1", models: ["big-pickle", "big-pickle-turbo", "big-pickle-reasoning", "opus-4.5", "sonnet-4.5", "haiku-3.5"], requiresKey: false),
        ProviderPreset(id: "opencode-go", name: "OpenCode Go", symbol: "sparkle.magnifyingglass", defaultUrl: "https://oai.opencode.ai/v1", models: ["opencode/big-pickle", "opencode/big-pickle-reasoning"], requiresKey: false),
        ProviderPreset(id: "direct", name: "Anthropic Direct", symbol: "person.fill", defaultUrl: "https://api.anthropic.com/v1", models: ["claude-opus-4-5", "claude-sonnet-4-6", "claude-haiku-3-5"], requiresKey: true),
        ProviderPreset(id: "nvidia-nim", name: "NVIDIA NIM", symbol: "cube.fill", defaultUrl: "https://integrate.api.nvidia.com/v1", models: [
            "nvidia/llama-3.1-nemotron-ultra-513b-v1",
            "nvidia/nemotron-3-ultra-550b-a55b",
            "meta/llama-4-maverick",
            "meta/llama-4-scout",
            "meta/llama-3.3-70b-instruct",
            "meta/llama-3.1-405b-instruct",
            "mistralai/mistral-large-24-11",
            "google/gemma-2-27b-it",
            "microsoft/phi-3.5-mini-instruct",
            "deepseek-ai/deepseek-r1",
            "qwen/qwen2.5-72b-instruct",
            "qwen/qwen2.5-coder-32b-instruct",
            "nvidia/llama-3.1-nemotron-70b-instruct",
        ], requiresKey: true),
        ProviderPreset(id: "openrouter", name: "OpenRouter", symbol: "arrow.triangle.branch", defaultUrl: "https://openrouter.ai/api/v1", models: ["openrouter/auto", "anthropic/claude-opus-4.5", "openai/gpt-4o"], requiresKey: true),
        ProviderPreset(id: "openai", name: "OpenAI / Codex", symbol: "brain", defaultUrl: "https://api.openai.com/v1", models: ["gpt-4o", "gpt-4o-mini", "o3"], requiresKey: true),
        ProviderPreset(id: "deepseek", name: "DeepSeek", symbol: "fleuron", defaultUrl: "https://api.deepseek.com/v1", models: ["deepseek/deepseek-chat", "deepseek/deepseek-reasoner"], requiresKey: true),
        ProviderPreset(id: "gemini", name: "Google AI Studio (Gemini)", symbol: "sparkle", defaultUrl: "https://generativelanguage.googleapis.com/v1beta", models: ["gemini/gemini-3.1-flash-lite", "gemini/gemini-3.5-flash", "gemini/gemini-3.5-pro"], requiresKey: true),
        ProviderPreset(id: "mistral", name: "Mistral La Plateforme", symbol: "cloud", defaultUrl: "https://api.mistral.ai/v1", models: ["mistral/mistral-small-latest", "mistral/mistral-medium-latest", "mistral/mistral-large-latest"], requiresKey: true),
        ProviderPreset(id: "codestral", name: "Mistral Codestral", symbol: "cloud.fill", defaultUrl: "https://codestral.mistral.ai/v1", models: ["codestral/codestral-latest"], requiresKey: true),
        ProviderPreset(id: "cohere", name: "Cohere", symbol: "point.3.connected.trianglepath.dotted", defaultUrl: "https://api.cohere.ai/v1", models: ["cohere/command-a-plus-05-2026", "cohere/command-r-plus-08-2024"], requiresKey: true),
        ProviderPreset(id: "groq", name: "Groq", symbol: "bolt", defaultUrl: "https://api.groq.com/openai/v1", models: ["groq/llama-3.3-70b-versatile", "groq/llama-3.1-70b-specdec", "groq/mixtral-8x7b-32768"], requiresKey: true),
        ProviderPreset(id: "fireworks", name: "Fireworks AI", symbol: "flame", defaultUrl: "https://api.fireworks.ai/inference/v1", models: ["fireworks/llama-v3p3-70b-instruct", "fireworks/llama-v3p1-405b-instruct"], requiresKey: true),
        ProviderPreset(id: "sambanova", name: "SambaNova", symbol: "square.stack.3d.up", defaultUrl: "https://api.sambanova.ai/v1", models: ["sambanova/Meta-Llama-3.3-70B-Instruct", "sambanova/DeepSeek-R1"], requiresKey: true),
        ProviderPreset(id: "cerebras", name: "Cerebras Inference", symbol: "cpu", defaultUrl: "https://api.cerebras.ai/v1", models: ["cerebras/gpt-oss-120b", "cerebras/llama-3.3-70b"], requiresKey: true),
        ProviderPreset(id: "huggingface", name: "HuggingFace Inference", symbol: "face.smiling", defaultUrl: "https://router.huggingface.co/v1", models: ["huggingface/Qwen3-Coder-480B-A35B", "huggingface/CodeLlama-70b"], requiresKey: true),
        ProviderPreset(id: "github-models", name: "GitHub Models", symbol: "logo.github", defaultUrl: "https://models.inference.ai.azure.com/v1", models: ["github_models/openai/gpt-4.1", "github_models/meta/llama-3.3-70b"], requiresKey: true),
        ProviderPreset(id: "wafer", name: "Wafer", symbol: "circle.grid.3x3", defaultUrl: "https://api.wafer.ch/v1", models: ["wafer/DeepSeek-V4-Pro"], requiresKey: true),
        ProviderPreset(id: "kimi", name: "Kimi API", symbol: "text.bubble", defaultUrl: "https://api.moonshot.cn/v1", models: ["kimi/kimi-k2.5"], requiresKey: true),
        ProviderPreset(id: "kimi-code", name: "Kimi Code", symbol: "text.bubble.fill", defaultUrl: "https://api.kimi-coding.com/v1", models: ["kimi_code/k3"], requiresKey: true),
        ProviderPreset(id: "minimax", name: "MiniMax", symbol: "square.on.square", defaultUrl: "https://api.minimax.chat/v1", models: ["minimax/MiniMax-M3", "minimax/MiniMax-T1"], requiresKey: true),
        ProviderPreset(id: "xai", name: "xAI Grok", symbol: "x.squareroot", defaultUrl: "https://api.x.ai/v1", models: ["grok-3", "grok-3-mini", "grok-3-reasoner"], requiresKey: true),
        ProviderPreset(id: "zai", name: "Z.ai", symbol: "z.square", defaultUrl: "https://api.z.ai/v1", models: ["zai/glm-5.2"], requiresKey: true),
        ProviderPreset(id: "ollama-cloud", name: "Ollama Cloud", symbol: "cloud", defaultUrl: "https://ollama.com/api/chat", models: ["ollama_cloud/qwen3-coder:480b"], requiresKey: true),
        ProviderPreset(id: "ai-gateway", name: "Vercel AI Gateway", symbol: "arrow.triangle.branch", defaultUrl: "https://gateway.ai.vercel.ai/v1", models: ["vercel/openai/gpt-5.5"], requiresKey: true),
        ProviderPreset(id: "ollama", name: "Ollama (Local)", symbol: "desktopcomputer", defaultUrl: "http://127.0.0.1:11434/v1", models: ["qwen3:latest", "qwen2.5:latest", "llama3.2:latest", "mistral:latest"], requiresKey: false),
        ProviderPreset(id: "lmstudio", name: "LM Studio (Local)", symbol: "desktopcomputer", defaultUrl: "http://127.0.0.1:1234/v1", models: ["lmstudio/<model-id>"], requiresKey: false),
        ProviderPreset(id: "llamacpp", name: "llama.cpp (Local)", symbol: "desktopcomputer", defaultUrl: "http://127.0.0.1:8080/v1", models: [], requiresKey: false),
    ]

    static func preset(for id: String) -> ProviderPreset? {
        all.first { $0.id == id }
    }
}

@MainActor
@Observable
class ProviderSettings: Identifiable {
    let id: String
    var enabled: Bool
    var backendUrl: String
    var visibleModelIds: Set<String>
    var apiKey: String

    init(id: String, enabled: Bool = true, backendUrl: String? = nil, visibleModelIds: Set<String>? = nil, apiKey: String = "") {
        self.id = id
        self.enabled = enabled
        let preset = ProviderPreset.preset(for: id)
        self.backendUrl = backendUrl ?? preset?.defaultUrl ?? ""
        self.visibleModelIds = visibleModelIds ?? Set(preset?.models ?? [])
        self.apiKey = apiKey
    }

    var preset: ProviderPreset? { ProviderPreset.preset(for: id) }

    var visibleModels: [String] {
        guard let p = preset else { return [] }
        return p.models.filter { visibleModelIds.contains($0) }
    }
}
