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
        ProviderPreset(id: "nvidia-nim", name: "NVIDIA NIM", symbol: "cube.fill", defaultUrl: "https://integrate.api.nvidia.com/v1", models: ["nvidia/llama-3.1-nemotron-ultra-513b-v1", "nvidia/nemotron-3-ultra-550b-a55b", "meta/llama-4-maverick", "meta/llama-4-scout"], requiresKey: true),
        ProviderPreset(id: "openrouter", name: "OpenRouter", symbol: "arrow.triangle.branch", defaultUrl: "https://openrouter.ai/api/v1", models: ["openrouter/auto", "anthropic/claude-opus-4.5", "openai/gpt-4o"], requiresKey: true),
        ProviderPreset(id: "openai", name: "OpenAI / Codex", symbol: "brain", defaultUrl: "https://api.openai.com/v1", models: ["gpt-4o", "gpt-4o-mini", "o3"], requiresKey: true),
        ProviderPreset(id: "ollama", name: "Ollama (Local)", symbol: "desktopcomputer", defaultUrl: "http://127.0.0.1:11434/v1", models: ["qwen3:latest", "qwen2.5:latest", "llama3.2:latest", "mistral:latest"], requiresKey: false),
        ProviderPreset(id: "deepseek", name: "DeepSeek", symbol: "fleuron", defaultUrl: "https://api.deepseek.com/v1", models: ["deepseek/deepseek-chat", "deepseek/deepseek-reasoner"], requiresKey: true),
        ProviderPreset(id: "xai", name: "xAI Grok", symbol: "x.squareroot", defaultUrl: "https://api.x.ai/v1", models: ["grok-3", "grok-3-mini", "grok-3-reasoner"], requiresKey: true),
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
