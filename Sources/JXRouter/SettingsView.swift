import SwiftUI
import ServiceManagement
import AppKit

// MARK: - Settings View (Tabbed)

struct SettingsView: View {
    @Bindable var manager: ProxyManager
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab: SettingsTab = .general
    @State private var initialSettingsHash: String = ""
    @State private var hasUnsavedChanges: Bool = false
    
    @State private var config = ConfigManager.shared
    // General
    @State private var port: String = "5255"
    @State private var authToken: String = "jxproxy"
    @State private var model: String = "big-pickle"
    @State private var enableThinking: Bool = true
    @State private var provider: String = "opencode-zen"
    @State private var fallbackProviders: String = "deepseek,groq"
    // Model Overrides
    @State private var modelOpus: String = ""
    @State private var modelSonnet: String = ""
    @State private var modelHaiku: String = ""
    // Providers
    @State private var openaiBaseUrl: String = ""
    @State private var localBaseUrl: String = ""
    @State private var localModel: String = ""
    @State private var openaiKey: String = ""
    @State private var openrouterKey: String = ""
    @State private var opencodeKey: String = ""
    @State private var nvidiaKey: String = ""
    @State private var anthropicKey: String = ""
    @State private var deepseekKey: String = ""
    @State private var geminiKey: String = ""
    @State private var mistralKey: String = ""
    @State private var codestralKey: String = ""
    @State private var cohereKey: String = ""
    @State private var groqKey: String = ""
    @State private var fireworksKey: String = ""
    @State private var sambanovaKey: String = ""
    @State private var cerebrasKey: String = ""
    @State private var huggingfaceKey: String = ""
    @State private var xaiKey: String = ""
    
    @AppStorage("autoStartProxy") private var autoStartProxy = false
    
    // System
    @State private var enableSystemProxy: Bool = false
    @State private var networkInterface: String = "Wi-Fi"
    @State private var appRoutes: [AppRouteRule] = []
    @State private var availableInterfaces: [String] = []
    @State private var adminPassword: String = ""
    
    // Local model server
    @State private var lmProvider: String = "llamacpp"
    @State private var lmModelPath: String = ""
    @State private var lmPort: String = "8080"
    @State private var lmBinaryPath: String = ""
    @State private var lmStatus: String = "stopped"
    private var lmStatusText: String {
        switch lmStatus {
        case "stopped": return "Stopped"
        case "starting": return "Starting..."
        case "running": return "Running"
        case "failed": return "Failed"
        default: return lmStatus
        }
    }
    private var lmStatusColor: Color {
        switch lmStatus {
        case "stopped": return Color.dsTextTertiary
        case "starting": return Color.orange
        case "running": return Color.dsGreen
        case "failed": return Color.dsRed
        default: return Color.dsTextTertiary
        }
    }

    // Bot
    @State private var botIntegrationEnabled: Bool = false
    @State private var telegramBotToken: String = ""

    /// Live models fetched from the provider's /v1/models API (e.g., llama.cpp
    /// only exposes its loaded models when the server is actually running).
    @State private var liveModels: [String] = []

    /// Providers the user has actually configured — local-only providers are always
    /// available; remote providers require a non-empty API key.
    private var availableProviders: [ProviderPreset] {
        ProviderPreset.all.filter { preset in
            guard preset.requiresKey else { return true }
            return !apiKeyForProvider(preset.id).isEmpty
        }
    }

    /// Return the reactive @State key value for a provider, falling back to the
    /// Keychain for providers without a dedicated secure field in the UI.
    private func apiKeyForProvider(_ id: String) -> String {
        switch id {
        case "direct":       return anthropicKey
        case "openrouter":   return openrouterKey
        case "opencode-zen", "opencode-go": return opencodeKey
        case "openai":       return openaiKey
        case "nvidia-nim":   return nvidiaKey
        case "deepseek":     return deepseekKey
        case "gemini":       return geminiKey
        case "mistral":      return mistralKey
        case "codestral":    return codestralKey
        case "cohere":       return cohereKey
        case "groq":         return groqKey
        case "fireworks":    return fireworksKey
        case "sambanova":    return sambanovaKey
        case "cerebras":     return cerebrasKey
        case "huggingface":  return huggingfaceKey
        case "xai":          return xaiKey
        default:
            // Providers without a @State binding — check Keychain directly
            return config.apiKey(for: id)
        }
    }

    /// Models for the currently selected provider — used in the Default Model and
    /// Model Override dropdowns so they only show relevant options.
    /// Merges preset models with live models from the provider's API.
    var modelsForProvider: [String] {
        var models = Set<String>()

        // Preset models (always available)
        let matchingPreset = ProviderPreset.all.first(where: {
            $0.id == provider || $0.name.lowercased().contains(provider.lowercased())
        })
        if let preset = matchingPreset {
            for m in preset.models { models.insert(m) }
        }
        // User-configured visible models
        if let p = manager.providers.first(where: { $0.id == provider }) {
            for m in p.visibleModelIds { models.insert(m) }
        }
        // Live models fetched from the provider's API
        for m in liveModels { models.insert(m) }

        return Array(models).sorted()
    }

    /// Models available across the entire provider chain (primary + fallbacks).
    /// This ensures the default model you pick is a model that exists on every
    /// provider in the chain, not just the primary.
    /// Live models fetched from the provider's API are also included so that
    /// local providers (llamacpp, ollama, lmstudio) show their running models.
    var modelsForProviderChain: [String] {
        let chainIds = providerChainIds
        guard chainIds.count > 1 else { return modelsForProvider }

        // Gather model sets for each provider in the chain
        let chainSets: [Set<String>] = chainIds.compactMap { pid in
            let preset = ProviderPreset.all.first(where: {
                $0.id == pid || $0.name.lowercased().contains(pid.lowercased())
            })
            // Return the set of bare model names (strip any provider/ prefix)
            guard let p = preset else { return nil }
            let names = p.models.map { $0.contains("/") ? String($0.split(separator: "/").last!) : $0 }
            return Set(names)
        }
        guard chainSets.count == chainIds.count else { return modelsForProvider }

        // Intersect all sets — only models available on EVERY provider in the chain
        var intersection = chainSets[0]
        for s in chainSets.dropFirst() {
            intersection = intersection.intersection(s)
        }
        // Also include live models so dynamically-discovered models (e.g. from
        // a running local server) appear in the dropdown alongside chain models.
        let live = Set(liveModels.map { $0.contains("/") ? String($0.split(separator: "/").last!) : $0 })
        intersection.formUnion(live)
        if !intersection.isEmpty {
            return intersection.sorted()
        }

        // Fall back: show models from all providers in the chain merged
        var merged = Set<String>()
        for pid in chainIds {
            if let preset = ProviderPreset.all.first(where: {
                $0.id == pid || $0.name.lowercased().contains(pid.lowercased())
            }) {
                for m in preset.models { merged.insert(m) }
            }
        }
        merged.formUnion(live)
        return merged.sorted()
    }

    /// Resolved provider IDs for the full chain (primary + fallbacks).
    private var providerChainIds: [String] {
        let primary = provider
        let fallbacks = fallbackProviders
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
            .map { ConfigManager.resolveProviderName($0) }
        return [primary] + fallbacks
    }

    /// Fetch available models from a provider's /v1/models API.
    /// For local providers (llamacpp, ollama, lmstudio) this discovers models
    /// loaded by the running server. For remote providers (e.g. NVIDIA) the
    /// API key is included in the request when available. Non-fatal on failure.
    private func fetchLiveModels(for providerId: String? = nil) async {
        let pid = providerId ?? provider
        var baseUrl = config.baseUrl(for: pid).replacingOccurrences(of: "/v1", with: "")
        // For llamacpp, honour the port configured in LocalModelManager so that
        // a server started with a custom port is still discovered.
        if pid == "llamacpp" {
            let mgr = LocalModelManager.shared
            if mgr.port != 8080 {
                baseUrl = "http://\(mgr.host):\(mgr.port)"
            }
        }
        guard let url = URL(string: "\(baseUrl)/v1/models") else { return }
        do {
            var req = URLRequest(url: url)
            req.timeoutInterval = 5
            // Include API key for providers that require auth on the models endpoint
            let key = config.apiKey(for: pid)
            if !key.isEmpty {
                req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let modelList = json["data"] as? [[String: Any]] else { return }
            let names = modelList.compactMap { $0["id"] as? String }
            if !names.isEmpty {
                await MainActor.run { liveModels = names }
            }
        } catch {
            print("[SettingsView] Failed to fetch models from \(url): \(error)")
        }
    }

    /// All known models across all providers (used for the broader "knownModels"
    /// variable that was previously hardcoded).
    var allModels: [String] {
        let presets = ProviderPreset.all
        var models = Set<String>()
        for preset in presets {
            for m in preset.models {
                models.insert(m.hasPrefix("\(preset.id)/") ? m : "\(preset.id)/\(m)")
            }
        }
        for p in manager.providers {
            for m in p.visibleModelIds {
                models.insert(m.hasPrefix("\(p.id)/") ? m : "\(p.id)/\(m)")
            }
        }
        return Array(models).sorted()
    }

    enum SettingsTab: String, CaseIterable {
        case general = "General"
        case providers = "Providers"
        case routing = "Routing"
        case system = "System"
        case logs = "Logs"

        var icon: String {
            switch self {
            case .general: return "network"
            case .providers: return "key"
            case .routing: return "arrow.triangle.branch"
            case .system: return "gearshape.2"
            case .logs: return "list.bullet.rectangle.portrait"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Custom tab bar
            tabBar

            Divider().overlay(Color.dsSeparator)

            // Tab content
            Group {
                switch selectedTab {
                case .general:
                    ScrollView { generalTab.padding(DesignToken.spacing20) }
                case .providers:
                    ScrollView { providersTab.padding(DesignToken.spacing20) }
                case .routing:
                    ScrollView { routingTab.padding(DesignToken.spacing20) }
                case .system:
                    ScrollView { systemTab.padding(DesignToken.spacing20) }
                case .logs:
                    logsTab.padding(DesignToken.spacing20)
                }
            }

            Divider().overlay(Color.dsSeparator)

            // Footer actions
            settingsFooter
                .padding(.horizontal, DesignToken.spacing20)
                .padding(.vertical, DesignToken.spacing12)
        }
        .frame(width: 540, height: 600)
        .background(Color.dsBackground)
        .onAppear {
            loadFromConfig()
            // Ensure the saved provider is still configured; fall back to the
            // first available one if its key was cleared outside this session.
            if !availableProviders.contains(where: { $0.id == provider }) {
                if let first = availableProviders.first {
                    provider = first.id
                }
            }
            detectNetworkInterfaces()
            Task { await fetchLiveModels() }
        }
        .onDisappear {
            saveConfig()
        }
        .onChange(of: provider) { _, newProvider in
            Task { await fetchLiveModels(for: newProvider) }
        }
        .onChange(of: settingsHash) { _, newHash in 
            if !initialSettingsHash.isEmpty && newHash != initialSettingsHash {
                hasUnsavedChanges = true
            }
            saveConfig()
            // If the current provider's key was cleared, fall back to the first
            // available provider so the selection doesn't go stale.
            if !availableProviders.contains(where: { $0.id == provider }) {
                if let first = availableProviders.first {
                    provider = first.id
                }
            }
        }
    }

    // MARK: - Tab Bar

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(SettingsTab.allCases, id: \.self) { tab in
                Button(action: { selectedTab = tab }) {
                    VStack(spacing: 8) {
                        HStack(spacing: 6) {
                            Image(systemName: tab.icon)
                                .font(.system(size: 13))
                            Text(tab.rawValue)
                                .font(.system(size: 13, weight: selectedTab == tab ? .medium : .regular))
                        }
                        
                        Rectangle()
                            .fill(selectedTab == tab ? Color.dsAccent : Color.clear)
                            .frame(height: 2)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 12)
                    .foregroundStyle(selectedTab == tab ? Color.dsTextPrimary : Color.dsTextSecondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable()
                .accessibilityHint("Switch to \(tab.rawValue) settings tab")
            }
        }
    }

    // MARK: - General Tab

    private var generalTab: some View {
        VStack(alignment: .leading, spacing: DesignToken.spacing20) {
            sectionGroup("Proxy Configuration") {
                labeledField("Port", caption: "The port the proxy listens on") {
                    TextField("5255", text: $port)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                }
                labeledField("Auth Token", caption: "Sent as x-api-key header") {
                    TextField("jxproxy", text: $authToken)
                        .textFieldStyle(.roundedBorder)
                }
            }

            sectionGroup("Model") {
                labeledField("Default Model") {
                    ComboBox(text: $model, options: modelsForProviderChain.isEmpty ? allModels : modelsForProviderChain)
                        .frame(height: 22)
                }
                Toggle(isOn: $enableThinking) {
                    Text("Enable Extended Thinking")
                        .font(.system(size: DesignToken.bodySize))
                }
                .toggleStyle(.switch)
            }

            sectionGroup("Provider") {
                HStack(spacing: 6) {
                    // Selected provider icon — fills the full 22pt space, no boxing/cropping
                    if let p = ProviderPreset.preset(for: provider) {
                        Image(systemName: p.symbol)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 22, height: 22)
                            .foregroundStyle(Color.dsAccent)
                    }
                    Menu {
                        ForEach(availableProviders) { preset in
                            Button {
                                provider = preset.id
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: preset.symbol)
                                        .resizable()
                                        .aspectRatio(contentMode: .fit)
                                        .frame(width: 16, height: 16)
                                    Text(preset.name)
                                }
                            }
                        }
                    } label: {
                        Text(ProviderPreset.preset(for: provider)?.name ?? provider)
                            .font(.system(size: DesignToken.captionSize))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 240)
                    .accessibilityLabel("Primary provider")
                }
                .onChange(of: provider) { _, newProvider in
                    if let preset = ProviderPreset.all.first(where: { $0.id == newProvider || $0.name.lowercased().contains(newProvider.lowercased()) }) {
                        model = preset.models.first ?? model
                    }
                }

                labeledField("Fallback Providers", caption: "Comma-separated") {
                    TextField("nvidia,local", text: $fallbackProviders)
                        .textFieldStyle(.roundedBorder)
                }
            }

            sectionGroup("Model Overrides") {
                HStack(spacing: DesignToken.spacing12) {
                    labeledField("model_opus") {
                        ComboBox(text: $modelOpus, options: modelsForProviderChain.isEmpty ? allModels : modelsForProviderChain)
                            .frame(height: 22)
                    }
                    labeledField("model_sonnet") {
                        ComboBox(text: $modelSonnet, options: modelsForProviderChain.isEmpty ? allModels : modelsForProviderChain)
                            .frame(height: 22)
                    }
                }
                labeledField("model_haiku") {
                    ComboBox(text: $modelHaiku, options: modelsForProviderChain.isEmpty ? allModels : modelsForProviderChain)
                        .frame(height: 22)
                }
            }
        }
    }

    // MARK: - Providers Tab

    private var providersTab: some View {
        VStack(alignment: .leading, spacing: DesignToken.spacing20) {
            VStack(alignment: .leading, spacing: DesignToken.spacing4) {
                Text("Provider Credentials")
                    .font(.system(size: DesignToken.subheadSize, weight: .semibold))
                    .foregroundStyle(Color.dsTextPrimary)
                Text("API keys are stored securely in macOS Keychain")
                    .font(.system(size: DesignToken.captionSize))
                    .foregroundStyle(Color.dsTextTertiary)
            }
            .accessibilityAddTraits(.isHeader)

            secureField("Anthropic API Key", text: $anthropicKey)
            secureField("OpenAI API Key", text: $openaiKey)
            secureField("OpenRouter API Key", text: $openrouterKey)
            secureField("OpenCode API Key", text: $opencodeKey)
            secureField("NVIDIA NIM API Key", text: $nvidiaKey)
            secureField("DeepSeek API Key", text: $deepseekKey)
            secureField("Google Gemini API Key", text: $geminiKey)
            secureField("Mistral API Key", text: $mistralKey)
            secureField("Mistral Codestral API Key", text: $codestralKey)
            secureField("Cohere API Key", text: $cohereKey)
            secureField("Groq API Key", text: $groqKey)
            secureField("Fireworks AI API Key", text: $fireworksKey)
            secureField("SambaNova API Key", text: $sambanovaKey)
            secureField("Cerebras API Key", text: $cerebrasKey)
            secureField("HuggingFace API Key", text: $huggingfaceKey)
            secureField("xAI Grok API Key", text: $xaiKey)

            Divider().padding(.vertical, DesignToken.spacing4)

            sectionGroup("Endpoints") {
                labeledField("OpenAI-Compatible Base URL") {
                    TextField("https://integrate.api.nvidia.com/v1", text: $openaiBaseUrl)
                        .textFieldStyle(.roundedBorder)
                }
                labeledField("Local LLM Base URL") {
                    TextField("http://127.0.0.1:11434/v1", text: $localBaseUrl)
                        .textFieldStyle(.roundedBorder)
                }
                labeledField("Local LLM Model") {
                    TextField("ollama/qwen", text: $localModel)
                        .textFieldStyle(.roundedBorder)
                }
            }
        }
    }

    // MARK: - Routing Tab

    private var routingTab: some View {
        VStack(alignment: .leading, spacing: DesignToken.spacing20) {
            sectionGroup("App Routing Rules") {
                Text("Choose which apps route through JXProxy. Drag .app files from Finder to add rules.")
                    .font(.system(size: DesignToken.captionSize))
                    .foregroundStyle(Color.dsTextTertiary)

                if appRoutes.isEmpty {
                    ContentUnavailableView(
                        "No App Rules",
                        systemImage: "square.stack.3d",
                        description: Text("Drag applications here or click Add to create rules.")
                    )
                    .padding(.vertical, DesignToken.spacing16)
                } else {
                    VStack(spacing: 0) {
                        ForEach($appRoutes) { $rule in
                            AppRuleRow(rule: $rule, onDelete: {
                                appRoutes.removeAll { $0.id == rule.id }
                            })
                            if rule.id != appRoutes.last?.id {
                                Divider().overlay(Color.dsSeparator.opacity(0.5))
                            }
                        }
                    }
                    .background(Color.dsSurface)
                    .clipShape(RoundedRectangle(cornerRadius: DesignToken.radiusCard))
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignToken.radiusCard)
                            .stroke(Color.dsBorder, lineWidth: 1)
                    )
                }

                HStack(spacing: DesignToken.spacing8) {
                    Button {
                        addNewAppRule()
                    } label: {
                        Label("Add App Rule", systemImage: "plus.circle")
                            .font(.system(size: DesignToken.captionSize))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.dsAccent)

                    Spacer()

                    if !appRoutes.isEmpty {
                        Button("Clear All") {
                            appRoutes.removeAll()
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: DesignToken.captionSize))
                        .foregroundStyle(Color.dsRed)
                    }
                }
            }
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                _ = handleDrop(providers: providers)
                return true
            }
        }
    }

    // MARK: - System Tab

    private var systemTab: some View {
        VStack(alignment: .leading, spacing: DesignToken.spacing20) {
            sectionGroup("System Proxy") {
                Toggle(isOn: $enableSystemProxy) {
                    Text("Enable System-Wide Proxy")
                        .font(.system(size: DesignToken.bodySize))
                }
                .toggleStyle(.switch)
                .onChange(of: enableSystemProxy) { _, newValue in
                    Task {
                        if newValue {
                            manager.enableSystemProxy(port: Int(port) ?? 5255)
                        } else {
                            manager.disableSystemProxy()
                        }
                    }
                }

                if !availableInterfaces.isEmpty {
                    labeledField("Network Interface") {
                        Picker("", selection: $networkInterface) {
                            ForEach(availableInterfaces, id: \.self) { iface in
                                Text(iface).tag(iface)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 200)
                        .disabled(!enableSystemProxy)
                    }
                }

                Text("Routes HTTP/HTTPS through JXProxy. Non-AI requests pass through unmodified.")
                    .font(.system(size: DesignToken.captionSize))
                    .foregroundStyle(Color.dsTextTertiary)
            }

            sectionGroup("Bot Integration") {
                Toggle(isOn: $botIntegrationEnabled) {
                    Text("Enable Telegram Bot Integration")
                        .font(.system(size: DesignToken.bodySize))
                }
                .toggleStyle(.switch)
                
                if botIntegrationEnabled {
                    secureField("Telegram Bot Token", text: $telegramBotToken)
                }
            }

            sectionGroup("Local Model Server") {
                VStack(alignment: .leading, spacing: 8) {
                    // Provider picker
                    HStack {
                        Text("Provider")
                            .font(.system(size: DesignToken.captionSize, weight: .medium))
                        Spacer()
                        Picker("", selection: $lmProvider) {
                            Text("llama.cpp").tag("llamacpp")
                            Text("Ollama").tag("ollama")
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 180)
                    }

                    // Model file path
                    HStack {
                        Text("Model File")
                            .font(.system(size: DesignToken.captionSize, weight: .medium))
                        Spacer()
                        Text(lmModelPath.isEmpty ? "None selected" : (lmModelPath as NSString).lastPathComponent)
                            .font(.system(size: DesignToken.captionSize, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(lmModelPath.isEmpty ? Color.dsTextTertiary : Color.dsTextPrimary)
                        Button("Browse") {
                            browseForModel()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    // Port (for llama.cpp)
                    if lmProvider == "llamacpp" {
                        HStack {
                            Text("Port")
                                .font(.system(size: DesignToken.captionSize, weight: .medium))
                            Spacer()
                            TextField("8080", text: $lmPort)
                                .frame(width: 80)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: DesignToken.captionSize, design: .monospaced))
                        }
                    }

                    // Binary path override
                    HStack {
                        Text("Binary Path")
                            .font(.system(size: DesignToken.captionSize, weight: .medium))
                        Spacer()
                        TextField("(auto-detect)", text: $lmBinaryPath)
                            .frame(width: 200)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: DesignToken.captionSize, design: .monospaced))
                            .help("Leave empty to auto-detect in PATH and common install locations")
                    }

                    // Status + Run/Stop
                    HStack {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(lmStatusColor)
                                .frame(width: 8, height: 8)
                            Text(lmStatusText)
                                .font(.system(size: DesignToken.captionSize, weight: .medium))
                                .foregroundStyle(lmStatusColor)
                        }

                        Spacer()

                        if lmStatus == "running" {
                            Button("Stop", role: .destructive) {
                                stopLocalModel()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        } else if lmStatus == "stopped" || lmStatus == "failed" {
                            Button("Run") {
                                startLocalModel()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(lmModelPath.isEmpty || lmStatus == "starting")
                        } else if lmStatus == "starting" {
                            ProgressView()
                                .scaleEffect(0.6)
                        }
                    }
                }
                .padding(.horizontal, DesignToken.spacing12)
                .padding(.vertical, DesignToken.spacing8)
            }

            sectionGroup("Privilege Elevation") {
                secureField("Mac Admin Password", text: $adminPassword)
                Text("Saved securely in Keychain. Used to bypass password prompts when configuring DNS redirection.")
                    .font(.system(size: DesignToken.captionSize))
                    .foregroundStyle(Color.dsTextTertiary)
            }

            sectionGroup("Auto-Launch") {
                Toggle(isOn: $manager.autoLaunchEnabled) {
                    Text("Launch at Login")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.dsTextPrimary)
                }
                .tint(Color.dsAccent)
                
                Toggle(isOn: $autoStartProxy) {
                    Text("Auto-start proxy on launch")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.dsTextPrimary)
                }
                .tint(Color.dsAccent)
            }

            sectionGroup("Information") {
                InfoRow(label: "Version", value: "1.0.0")
                InfoRow(label: "Proxy Port", value: port)
                InfoRow(label: "Active Provider", value: provider)
                InfoRow(label: "Model", value: model)
                if manager.builtInProxyRunning {
                    InfoRow(label: "Uptime", value: formattedUptime(manager.proxyServer.stats.uptime))
                }
            }
        }
    }

    // MARK: - Logs Tab

    private var logsTab: some View {
        VStack(alignment: .leading, spacing: DesignToken.spacing12) {
            HStack {
                Text("Live Traffic Logs")
                    .font(.system(size: DesignToken.subheadSize, weight: .semibold))
                    .foregroundStyle(Color.dsTextPrimary)
                Spacer()
                Button("Clear") {
                    manager.trafficLog.clear()
                }
                .buttonStyle(.plain)
                .font(.system(size: DesignToken.captionSize))
                .foregroundStyle(Color.dsRed)
            }

            if manager.trafficLog.entries.isEmpty {
                ContentUnavailableView(
                    "No Traffic",
                    systemImage: "network.slash",
                    description: Text("No requests have been intercepted yet.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.vertical, DesignToken.spacing24)
            } else {
                ScrollView {
                    LazyVStack(spacing: DesignToken.spacing8) {
                        ForEach(manager.trafficLog.entries) { entry in
                            LogEntryRow(entry: entry)
                            Divider().overlay(Color.dsSeparator.opacity(0.3))
                        }
                    }
                    .padding(.vertical, DesignToken.spacing8)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.dsSurface)
                .clipShape(RoundedRectangle(cornerRadius: DesignToken.radiusCard))
                .overlay(
                    RoundedRectangle(cornerRadius: DesignToken.radiusCard)
                        .stroke(Color.dsBorder, lineWidth: 1)
                )
            }
        }
    }

    // MARK: - Settings Footer

    private var settingsFooter: some View {
        HStack {
            Button("Reset to Defaults", role: .destructive) {
                resetToDefaults()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .focusable()
            .accessibilityHint("Reset all settings to factory defaults")

            Spacer()

            if hasUnsavedChanges {
                Text("Restart proxy to apply network changes.")
                    .font(.system(size: DesignToken.captionSize))
                    .foregroundStyle(Color.dsTextTertiary)
            }
        }
    }

    // MARK: - Reusable Components

    private func sectionGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: DesignToken.spacing10) {
            Text(title)
                .font(.system(size: DesignToken.captionSize, weight: .semibold))
                .foregroundStyle(Color.dsTextSecondary)
                .textCase(.uppercase)
            content()
        }
    }

    private func labeledField<Content: View>(_ label: String, caption: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: DesignToken.spacing4) {
            HStack(spacing: DesignToken.spacing4) {
                Text(label)
                    .font(.system(size: DesignToken.captionSize))
                    .foregroundStyle(Color.dsTextSecondary)
                if let caption = caption {
                    Text(caption)
                        .font(.system(size: DesignToken.caption2Size))
                        .foregroundStyle(Color.dsTextTertiary)
                }
            }
            content()
        }
    }

    private func secureField(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: DesignToken.spacing4) {
            Text(label)
                .font(.system(size: DesignToken.captionSize))
                .foregroundStyle(Color.dsTextSecondary)
            HStack(spacing: DesignToken.spacing6) {
                SecureField("••••••••", text: text)
                    .textFieldStyle(.roundedBorder)
                Button("Paste") {
                    if let str = NSPasteboard.general.string(forType: .string) {
                        text.wrappedValue = str
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: DesignToken.caption2Size))
                .foregroundStyle(Color.dsAccent)
                .accessibilityLabel("Paste from clipboard")
            }
        }
    }

    // MARK: - Helpers

    /// Composite hash of all editable settings – observed by a single `.onChange` to auto-save.
    private var settingsHash: String {
        [
            port, authToken, model, String(enableThinking),
            provider, fallbackProviders,
            modelOpus, modelSonnet, modelHaiku,
            openaiBaseUrl, localBaseUrl, localModel,
            anthropicKey, openaiKey, openrouterKey, opencodeKey, nvidiaKey,
            deepseekKey, geminiKey, mistralKey, codestralKey, cohereKey,
            groqKey, fireworksKey, sambanovaKey, cerebrasKey, huggingfaceKey, xaiKey,
            String(botIntegrationEnabled), telegramBotToken,
            adminPassword
        ].joined(separator: "\u{1F}")
    }

    private func loadFromConfig() {
        port = "\(config.port)"
        authToken = config.authToken
        model = config.model
        enableThinking = config.enableThinking
        provider = config.provider
        fallbackProviders = config.fallbackProviders
        modelOpus = config.modelOpus
        modelSonnet = config.modelSonnet
        modelHaiku = config.modelHaiku
        openaiBaseUrl = config.openaiBaseUrl
        localBaseUrl = config.localLlmBaseUrl
        localModel = config.localLlmModel
        anthropicKey = config.apiKey(for: "direct")
        openaiKey = config.apiKey(for: "openai")
        openrouterKey = config.apiKey(for: "openrouter")
        opencodeKey = config.apiKey(for: "opencode-zen")
        nvidiaKey = config.apiKey(for: "nvidia-nim")
        deepseekKey = config.apiKey(for: "deepseek")
        geminiKey = config.apiKey(for: "gemini")
        mistralKey = config.apiKey(for: "mistral")
        codestralKey = config.apiKey(for: "codestral")
        cohereKey = config.apiKey(for: "cohere")
        groqKey = config.apiKey(for: "groq")
        fireworksKey = config.apiKey(for: "fireworks")
        sambanovaKey = config.apiKey(for: "sambanova")
        cerebrasKey = config.apiKey(for: "cerebras")
        huggingfaceKey = config.apiKey(for: "huggingface")
        xaiKey = config.apiKey(for: "xai")
        enableSystemProxy = manager.systemProxyEnabled
        botIntegrationEnabled = config.botIntegrationEnabled
        telegramBotToken = config.getApiKey(chainKey: ConfigManager.KeychainKey.telegramBotToken)
        adminPassword = config.getApiKey(chainKey: ConfigManager.KeychainKey.adminPassword)
        loadAppRoutesFromConfig()
        initialSettingsHash = settingsHash
    }

    private func loadAppRoutesFromConfig() {
        let json = config.appRoutesJSON
        guard !json.isEmpty, let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([AppRouteRule].self, from: data) else {
            appRoutes = []
            return
        }
        appRoutes = decoded
    }

    private func saveConfig() {
        if let portVal = Int(port) { config.port = portVal }
        config.authToken = authToken
        config.model = model
        config.enableThinking = enableThinking
        config.provider = provider
        config.fallbackProviders = fallbackProviders
        config.modelOpus = modelOpus
        config.modelSonnet = modelSonnet
        config.modelHaiku = modelHaiku
        config.openaiBaseUrl = openaiBaseUrl
        config.localLlmBaseUrl = localBaseUrl
        config.localLlmModel = localModel

        config.setApiKey(chainKey: ConfigManager.KeychainKey.anthropic, value: anthropicKey)
        config.setApiKey(chainKey: ConfigManager.KeychainKey.openai, value: openaiKey)
        config.setApiKey(chainKey: ConfigManager.KeychainKey.openrouter, value: openrouterKey)
        config.setApiKey(chainKey: ConfigManager.KeychainKey.opencode, value: opencodeKey)
        config.setApiKey(chainKey: ConfigManager.KeychainKey.nvidia, value: nvidiaKey)
        config.setApiKey(chainKey: ConfigManager.KeychainKey.deepseek, value: deepseekKey)
        config.setApiKey(chainKey: ConfigManager.KeychainKey.gemini, value: geminiKey)
        config.setApiKey(chainKey: ConfigManager.KeychainKey.mistral, value: mistralKey)
        config.setApiKey(chainKey: ConfigManager.KeychainKey.codestral, value: codestralKey)
        config.setApiKey(chainKey: ConfigManager.KeychainKey.cohere, value: cohereKey)
        config.setApiKey(chainKey: ConfigManager.KeychainKey.groq, value: groqKey)
        config.setApiKey(chainKey: ConfigManager.KeychainKey.fireworks, value: fireworksKey)
        config.setApiKey(chainKey: ConfigManager.KeychainKey.sambanova, value: sambanovaKey)
        config.setApiKey(chainKey: ConfigManager.KeychainKey.cerebras, value: cerebrasKey)
        config.setApiKey(chainKey: ConfigManager.KeychainKey.huggingface, value: huggingfaceKey)
        config.setApiKey(chainKey: ConfigManager.KeychainKey.xai, value: xaiKey)
        config.botIntegrationEnabled = botIntegrationEnabled
        config.setApiKey(chainKey: ConfigManager.KeychainKey.telegramBotToken, value: telegramBotToken)
        config.setApiKey(chainKey: ConfigManager.KeychainKey.adminPassword, value: adminPassword)

        saveAppRoutesToConfig()
        manager.loadAllFromConfig()
    }

    private func saveAppRoutesToConfig() {
        guard let data = try? JSONEncoder().encode(appRoutes),
              let json = String(data: data, encoding: .utf8) else { return }
        config.appRoutesJSON = json
    }

    private func resetToDefaults() {
        port = "5255"
        authToken = "jxproxy"
        model = "big-pickle"
        enableThinking = true
        provider = "opencode-zen"
        fallbackProviders = "deepseek,groq"
        modelOpus = "opencode/big-pickle"
        modelSonnet = "deepseek/deepseek-chat"
        modelHaiku = "groq/llama-3.3-70b-versatile"
        openaiBaseUrl = "https://integrate.api.nvidia.com/v1"
        localBaseUrl = "http://127.0.0.1:11434/v1"
        localModel = "ollama/qwen"
        anthropicKey = ""
        openaiKey = ""
        openrouterKey = ""
        opencodeKey = ""
        nvidiaKey = ""
        deepseekKey = ""
        geminiKey = ""
        mistralKey = ""
        codestralKey = ""
        cohereKey = ""
        groqKey = ""
        fireworksKey = ""
        sambanovaKey = ""
        cerebrasKey = ""
        huggingfaceKey = ""
        xaiKey = ""
        enableSystemProxy = false
        appRoutes = []
        botIntegrationEnabled = false
        telegramBotToken = ""
        adminPassword = ""
        
        initialSettingsHash = settingsHash
    }

    private func addNewAppRule() {
        let panel = NSOpenPanel()
        panel.title = "Select Application"
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            addAppRuleFrom(url: url)
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                DispatchQueue.main.async {
                    self.addAppRuleFrom(url: url)
                }
            }
            handled = true
        }
        return handled
    }

    private func addAppRuleFrom(url: URL) {
        guard url.pathExtension == "app" || (try? url.resourceValues(forKeys: [.isApplicationKey]).isApplication) == true else { return }
        let bundle = Bundle(url: url)
        let appName = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? url.deletingPathExtension().lastPathComponent
        let bundleId = bundle?.bundleIdentifier

        // Avoid duplicates
        guard !appRoutes.contains(where: { $0.bundleIdentifier == bundleId }) else { return }

        appRoutes.append(AppRouteRule(
            appName: appName,
            bundleIdentifier: bundleId,
            enabled: true,
            action: .routeAI
        ))
    }

    private func detectNetworkInterfaces() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        task.arguments = ["-listallnetworkservices"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()

        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            let lines = output.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("An asterisk") }
            availableInterfaces = lines
            if !lines.isEmpty {
                networkInterface = lines[0]
            }
        } catch {
            availableInterfaces = ["Wi-Fi"]
        }
    }

    private func formattedUptime(_ interval: TimeInterval) -> String {
        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60
        let seconds = Int(interval) % 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        } else {
            return "\(seconds)s"
        }
    }

    // MARK: - Local Model Server

    private func browseForModel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.data]
        panel.message = "Select a GGUF model file"
        panel.directoryURL = URL(fileURLWithPath: NSString(string: LocalModelManager.shared.modelDirectory).expandingTildeInPath)

        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = url.path
        lmModelPath = path
        LocalModelManager.shared.setModelPathFromFile(path)
        LocalModelManager.shared.port = Int(lmPort) ?? 8080
    }

    private func startLocalModel() {
        let manager = LocalModelManager.shared
        manager.modelPath = lmModelPath
        manager.port = Int(lmPort) ?? 8080
        manager.customBinaryPath = lmBinaryPath
        manager.provider = LocalModelManager.LocalProvider(rawValue: lmProvider) ?? .llamacpp

        lmStatus = "starting"
        Task {
            await manager.start()
            updateLMStatus()
        }
    }

    private func stopLocalModel() {
        LocalModelManager.shared.stop()
        lmStatus = "stopped"
    }

    private func refreshLocalModelStatus() {
        updateLMStatus()
    }

    private func syncBinaryPathToManager() {
        LocalModelManager.shared.customBinaryPath = lmBinaryPath
    }

    private func updateLMStatus() {
        let mgr = LocalModelManager.shared
        switch mgr.status {
        case .stopped: lmStatus = "stopped"
        case .starting: lmStatus = "starting"
        case .running: lmStatus = "running"
        case .failed(let msg): lmStatus = "failed: \(msg)"
        }
    }
}

// MARK: - Log Entry Row

private struct LogEntryRow: View {
    let entry: TrafficEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(entry.method)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.dsBackground)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(methodColor(entry.method))
                    .clipShape(Capsule())
                
                Text(entry.host)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.dsTextPrimary)
                
                Spacer()
                
                Text(entry.timestamp, style: .time)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.dsTextTertiary)
            }
            
            HStack {
                Text(entry.url)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color.dsTextSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                
                Spacer()
                
                if let appName = entry.appProcessName {
                    Text(appName)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.dsAccent)
                }
                
                Text(actionString(entry.action))
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(actionColor(entry.action))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.method) request to \(entry.host). \(entry.appProcessName != nil ? "From \(entry.appProcessName!)." : "") Status: \(actionString(entry.action))")
    }
    
    private func methodColor(_ method: String) -> Color {
        switch method {
        case "GET": return .dsGreen
        case "POST": return .dsOrange
        case "CONNECT": return .dsAccent
        default: return .dsTextSecondary
        }
    }
    
    private func actionColor(_ action: RouteAction) -> Color {
        switch action {
        case .routeAI: return .dsGreen
        case .passthrough: return .dsTextSecondary
        case .block: return .dsRed
        }
    }
    
    private func actionString(_ action: RouteAction) -> String {
        switch action {
        case .routeAI: return "ROUTED"
        case .passthrough: return "PASSTHROUGH"
        case .block: return "BLOCKED"
        }
    }
}

// ComboBox is in SettingsHelpers.swift
