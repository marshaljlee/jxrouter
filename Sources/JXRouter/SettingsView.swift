import SwiftUI
import ServiceManagement
import AppKit

// MARK: - Settings View (Tabbed)

struct SettingsView: View {
    @Bindable var manager: ProxyManager
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab: SettingsTab = .general
    /// True once initial state has been loaded, so the hash change from loading
    /// doesn't trigger a redundant save.
    @State private var hasLoaded = false
    /// Debounced auto-save task — settings persist shortly after the last edit,
    /// so there is no Save button to forget.
    @State private var autoSaveTask: Task<Void, Never>?
    /// True while the "Saved ✓" flash is visible in the footer after a persist.
    @State private var showSavedFlash = false
    /// Task that hides the flash after a beat — so a second save re-triggers it.
    @State private var savedFlashTask: Task<Void, Never>?
    /// Field ids that changed in the last auto-save — shown as a brief green
    /// checkmark next to each edited field ("port", "model", "key:deepseek", …).
    @State private var savedFieldFlash: Set<String> = []
    /// Task that clears the per-field checkmarks after ~1.5s.
    @State private var savedFieldFlashTask: Task<Void, Never>?
    /// Snapshot of every editable field's value as of the last persisted save —
    /// diffed against current values to know exactly which fields changed.
    @State private var lastSavedValues: [String: String] = [:]
    /// Provider/model used by the last verification — re-verify only on change.
    @State private var lastVerifiedProvider = ""
    @State private var lastVerifiedModel = ""
    
    @State private var config = ConfigManager.shared
    // General
    @State private var port: String = "5255"
    @State private var authToken: String = "jxproxy"
    @State private var model: String = ""
    @State private var enableThinking: Bool = true
    /// Per-provider reasoning policy selections (provider id → policy). Kept in
    /// sync with ConfigManager so switching providers doesn't discard unsaved choices.
    @State private var reasoningPolicies: [String: ReasoningPolicy] = [:]
    @State private var showLocalOnboarding = false
    @State private var onboardingProvider: LocalModelManager.LocalProvider = .llamacpp
    /// Free API key guide sheet (OpenCode Zen / NVIDIA NIM) for non-technical users.
    @State private var showApiKeyGuide = false
    @State private var provider: String = "opencode-zen"
    @State private var fallbackProviders: String = "nvidia,local"
    /// Per-tier provider overrides (tier key → provider id). The Default pair
    /// always uses the primary provider; Opus/Sonnet/Haiku default to it too.
    @State private var tierProviders: [String: String] = [:]
    /// Per-tier live model lists auto-fetched from each pair's provider.
    @State private var tierLiveModels: [String: [String]] = [:]
    // Model Overrides
    @State private var modelOpus: String = ""
    @State private var modelSonnet: String = ""
    @State private var modelHaiku: String = ""
    // Providers
    @State private var openaiBaseUrl: String = ""
    @State private var localBaseUrl: String = ""
    @State private var localModel: String = ""
    // Custom backend URLs per provider (stored as JSON dict in ConfigManager)
    @State private var providerUrlOverrides: [String: String] = [:]
    // API keys
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
    // Custom (OpenAI-compatible) provider — legacy single entry
    @State private var customUrl: String = ""
    @State private var customKey: String = ""
    // Named custom providers (Settings → Providers → Custom Providers)
    @State private var customProviders: [CustomProviderDef] = []
    /// Reactive per-provider API keys (id → key) for named custom providers.
    @State private var customProviderKeys: [String: String] = [:]
    // Draft fields for the "add custom provider" form
    @State private var newCustomName = ""
    @State private var newCustomUrl = ""
    @State private var newCustomKey = ""

    // Credential / model verification (green ticks)
    @State private var providerChecks: [String: ProviderCheckState] = [:]
    @State private var defaultModelCheck: ProviderCheckState = .unknown
    /// Per-tier model connectivity results from the "Test All Models" button.
    @State private var tierModelChecks: [String: ProviderCheckState] = [:]

    // Auto-detected local runtimes (Ollama, llama.cpp, LM Studio, Jan)
    @State private var localRuntimes: [LocalRuntime] = []
    
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

    /// Providers the user can pick — local-only providers are always available,
    /// remote providers require a non-empty API key. The legacy single "custom"
    /// entry is folded into the named custom-provider list, so it never shows
    /// twice; every named custom provider is always selectable.
    private var availableProviders: [ProviderPreset] {
        var presets = ProviderPreset.all.filter { preset in
            if preset.id == "custom" { return false }
            guard preset.requiresKey else { return true }
            return !apiKeyForProvider(preset.id).isEmpty
        }
        for def in customProviders {
            presets.append(ProviderPreset(
                id: def.id, name: def.name, symbol: "puzzlepiece.extension",
                defaultUrl: def.baseUrl, models: [], requiresKey: true
            ))
        }
        return presets
    }

    /// Resolve display info (name/symbol) for any provider id — built-in presets
    /// plus named custom providers.
    private func providerPreset(_ id: String) -> ProviderPreset? {
        if let preset = ProviderPreset.preset(for: id) { return preset }
        guard let def = customProviders.first(where: { $0.id == id }) else { return nil }
        return ProviderPreset(
            id: def.id, name: def.name, symbol: "puzzlepiece.extension",
            defaultUrl: def.baseUrl, models: [], requiresKey: true
        )
    }

    /// Return the reactive @State key value for a provider, falling back to the
    /// Keychain for providers without a dedicated secure field in the UI.
    private func apiKeyForProvider(_ id: String) -> String {
        // Named custom providers keep their key in a reactive per-id field.
        if customProviders.contains(where: { $0.id == id }) {
            return customProviderKeys[id] ?? ""
        }
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
        case "custom":       return customKey
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
        let matchingPreset = providerPreset(provider)
        if let preset = matchingPreset {
            for m in preset.models { models.insert(ProviderPreset.bareModel(m, for: provider)) }
        }
        // User-configured visible models
        if let p = manager.providers.first(where: { $0.id == provider }) {
            for m in p.visibleModelIds { models.insert(ProviderPreset.bareModel(m, for: provider)) }
        }
        // Live models fetched from the provider's API
        for m in liveModels { models.insert(ProviderPreset.bareModel(m, for: provider)) }

        return Array(models).sorted()
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
        // Clear stale models from the previous provider immediately so the
        // dropdown never shows another provider's list while this fetch is in
        // flight (e.g. switching opencode → nvidia). Only the Default tier's
        // list is cleared — Opus/Sonnet/Haiku pairs have their own providers
        // and manage their own cached lists.
        await MainActor.run {
            liveModels = []
            if providerId != nil {
                tierLiveModels[TierKey.defaultModel.rawValue] = []
            }
        }
        do {
            var req = URLRequest(url: url)
            req.timeoutInterval = 5
            // Use the reactive @State key — a freshly typed key is in the UI
            // before the debounced auto-save flushes it to the Keychain, and
            // config.apiKey() would read an empty Keychain value (401 → no
            // models).
            let key = apiKeyForProvider(pid)
            if !key.isEmpty {
                req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let modelList = json["data"] as? [[String: Any]] else { return }
            let names = modelList.compactMap { $0["id"] as? String }.filter { !$0.isEmpty }
            if !names.isEmpty {
                await MainActor.run {
                    liveModels = names
                    // Persist the fetched list so it survives relaunches — the
                    // user has no manual way to re-fetch after changing keys.
                    if let idx = manager.providers.firstIndex(where: { $0.id == pid }) {
                        manager.providers[idx].visibleModelIds.formUnion(names)
                    }
                }
            }
        } catch {
            print("[SettingsView] Failed to fetch models from \(url): \(error)")
        }
    }

    // MARK: - Provider / Model Verification (green ticks)

    /// Check a provider's API key against its /v1/models endpoint.
    private func verifyProviderKey(_ pid: String) async {
        providerChecks[pid] = .checking
        let key = apiKeyForProvider(pid)
        let result = await ProviderValidator.validateKey(providerId: pid, apiKey: key, baseUrl: config.baseUrl(for: pid))
        providerChecks[pid] = result.ok ? .valid : .invalid(key.isEmpty ? "No key entered" : result.message)
    }

    /// Check that the selected default model answers a tiny chat completion.
    private func verifyDefaultModel() async {
        defaultModelCheck = .checking
        guard !model.isEmpty else {
            defaultModelCheck = .invalid("No model selected")
            return
        }
        let pid = provider
        let result = await ProviderValidator.validateModel(
            providerId: pid, model: ProviderPreset.bareModel(model, for: pid),
            apiKey: apiKeyForProvider(pid), baseUrl: config.baseUrl(for: pid)
        )
        defaultModelCheck = result.ok ? .valid : .invalid(result.message)
    }

    /// Test every Claude tier's model (Default / Opus / Sonnet / Haiku) against
    /// its own provider — one result per tier under the button.
    private func verifyAllTierModels() async {
        for tier in TierKey.allCases {
            tierModelChecks[tier.rawValue] = .checking
            let pid = tierProviderId(for: tier)
            let modelName = tierModelValue(tier)
            guard !modelName.isEmpty else {
                tierModelChecks[tier.rawValue] = .invalid("No model selected")
                continue
            }
            let result = await ProviderValidator.validateModel(
                providerId: pid,
                model: ProviderPreset.bareModel(modelName, for: pid),
                apiKey: apiKeyForProvider(pid),
                baseUrl: config.baseUrl(for: pid)
            )
            tierModelChecks[tier.rawValue] = result.ok ? .valid : .invalid(result.message)
        }
    }

    /// The model id currently bound to a tier.
    private func tierModelValue(_ tier: TierKey) -> String {
        switch tier {
        case .defaultModel: return model
        case .opus: return modelOpus
        case .sonnet: return modelSonnet
        case .haiku: return modelHaiku
        }
    }

    /// Dropdown options restricted to one provider's own models, always keeping
    /// the current value so a selection stays visible before the fetch lands.
    private func scopedOptions(_ models: [String], current: String) -> [String] {
        var set = Set(models)
        if !current.isEmpty { set.insert(current) }
        return set.sorted()
    }

    @ViewBuilder
    private func verificationIndicator(_ state: ProviderCheckState) -> some View {
        switch state {
        case .unknown:
            EmptyView()
        case .checking:
            ProgressView().controlSize(.small)
        case .valid:
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.dsGreen)
                Text("Connected")
                    .font(.system(size: DesignToken.caption2Size))
                    .foregroundStyle(Color.dsGreen)
            }
        case .invalid(let reason):
            HStack(spacing: 4) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.dsRed)
                Text(reason)
                    .font(.system(size: DesignToken.caption2Size))
                    .foregroundStyle(Color.dsRed)
            }
        }
    }

    /// Compact per-tier status row for the "Test All Models" results list.
    @ViewBuilder
    private func compactVerificationIndicator(_ state: ProviderCheckState) -> some View {
        switch state {
        case .unknown:
            Text("Not tested")
                .font(.system(size: DesignToken.caption2Size))
                .foregroundStyle(Color.dsTextTertiary)
        case .checking:
            ProgressView().controlSize(.small)
        case .valid:
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.dsGreen)
                Text("Connected")
                    .font(.system(size: DesignToken.caption2Size))
                    .foregroundStyle(Color.dsGreen)
            }
        case .invalid(let reason):
            HStack(spacing: 4) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.dsRed)
                Text(reason)
                    .font(.system(size: DesignToken.caption2Size))
                    .foregroundStyle(Color.dsRed)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    /// Key field with a Verify button + green/red status indicator.
    private func keyField(_ label: String, providerId: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: DesignToken.spacing4) {
            HStack {
                Text(label)
                    .font(.system(size: DesignToken.captionSize))
                    .foregroundStyle(Color.dsTextSecondary)
                savedFieldCheckmark("key:\(providerId)")
                Spacer()
                verificationIndicator(providerChecks[providerId] ?? .unknown)
            }
            HStack(spacing: DesignToken.spacing6) {
                SecureField("••••••••", text: text)
                    .textFieldStyle(.roundedBorder)
                Button("Verify") {
                    Task { await verifyProviderKey(providerId) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .font(.system(size: DesignToken.caption2Size))
                .help("Check this API key against the provider")
            }
        }
    }

    /// Open the appropriate guidance for a local runtime that isn't running.
    private func guideFor(_ runtime: LocalRuntime) {
        switch runtime.id {
        case "llamacpp", "ollama":
            onboardingProvider = LocalModelManager.LocalProvider(rawValue: runtime.id) ?? .llamacpp
            showLocalOnboarding = true
        default:
            let alert = NSAlert()
            alert.messageText = "\(runtime.name) — How to enable"
            alert.informativeText = runtime.hint
            alert.addButton(withTitle: "OK")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    /// The four independent Provider+Model routing pairs.
    private enum TierKey: String, CaseIterable, Identifiable {
        case defaultModel = "default"
        case opus = "opus"
        case sonnet = "sonnet"
        case haiku = "haiku"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .defaultModel: return "Default Model"
            case .opus: return "Opus"
            case .sonnet: return "Sonnet"
            case .haiku: return "Haiku"
            }
        }
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
        // Tall window so the General and System tabs fit without scrollbars.
        .frame(width: 560, height: 780)
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
            lastVerifiedProvider = provider
            lastVerifiedModel = model
            // Baseline for per-field checkmarks: what's on screen matches what
            // was loaded, so the first save only flashes fields the user edits.
            lastSavedValues = currentFieldValues()
            // Only auto-save from this point on — loading initial state above
            // must not count as an edit.
            hasLoaded = true
            detectNetworkInterfaces()
            Task {
                await fetchLiveModels()
                // Auto-populate model for local providers on first load
                if model.isEmpty, !liveModels.isEmpty {
                    model = liveModels[0]
                }
                // Programmatic auto-population above is not a user edit —
                // refresh the checkmark baseline so first open doesn't flash
                // a spurious "model" checkmark.
                lastSavedValues = currentFieldValues()
                // Autofetch model lists for all four tier pairs so the
                // dropdowns are populated the moment they open.
                for tier in TierKey.allCases {
                    await fetchTierModels(for: tier)
                }
                // Detect local runtimes and show their status.
                localRuntimes = await LocalProviderDetector.detect()
                // Auto-verify stored keys so green ticks appear without clicks.
                if !apiKeyForProvider(provider).isEmpty {
                    await verifyProviderKey(provider)
                }
                if !customKey.isEmpty {
                    await verifyProviderKey("custom")
                }
            }
        }
        .onDisappear {
            // Final flush: persist anything still pending in the debounce.
            autoSaveTask?.cancel()
            savedFlashTask?.cancel()
            savedFieldFlashTask?.cancel()
            saveConfig()
        }
        .onChange(of: settingsHash) { _, _ in
            // Auto-save on every edit (debounced) — no Save button needed, so
            // model/provider changes can never be lost between edit and save.
            guard hasLoaded else { return }
            scheduleAutoSave()
        }
        .onChange(of: provider) { _, newProvider in
            Task {
                await fetchLiveModels(for: newProvider)
                // Auto-populate the default model only when nothing is selected
                // yet — a model the user chose is never overwritten by switching
                // the provider (that would silently revert their pick).
                guard model.isEmpty else { return }
                let preset = providerPreset(newProvider)
                if let preset, !preset.models.isEmpty {
                    model = ProviderPreset.bareModel(preset.models.first ?? "", for: newProvider)
                } else if !liveModels.isEmpty {
                    model = liveModels[0]
                }
            }
        }
        .sheet(isPresented: $showLocalOnboarding) {
            LocalModelOnboardingView(provider: onboardingProvider) {
                showLocalOnboarding = false
                runLocalModel()
            }
        }
        .sheet(isPresented: $showApiKeyGuide) {
            FreeApiKeyGuideView {
                showApiKeyGuide = false
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
                labeledField("Port", caption: "The port the proxy listens on", savedID: "port") {
                    TextField("5255", text: $port)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                }
                labeledField("Auth Token", caption: "Sent as x-api-key header", savedID: "authToken") {
                    TextField("jxproxy", text: $authToken)
                        .textFieldStyle(.roundedBorder)
                }
            }

            sectionGroup("Model") {
                HStack(alignment: .top, spacing: 8) {
                    labeledField("Default Model", savedID: "model") {
                        // Auto-fetch the provider's model list whenever the
                        // dropdown opens — no manual refresh needed.
                        ComboBox(text: $model, options: scopedOptions(modelsForProvider, current: model)) {
                            Task { await fetchLiveModels() }
                        }
                        .frame(height: 22)
                    }
                    Button(action: { Task { await fetchLiveModels() } }) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.dsAccent)
                    .help("Refresh models from \(providerPreset(provider)?.name ?? provider)")
                    .accessibilityLabel("Refresh models")
                }
                HStack(spacing: 8) {
                    Button("Test All Models") {
                        Task { await verifyAllTierModels() }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .font(.system(size: DesignToken.caption2Size))
                    .help("Check Default / Opus / Sonnet / Haiku models against their own providers")
                    Spacer()
                }
                VStack(spacing: 4) {
                    ForEach(TierKey.allCases, id: \.self) { tier in
                        HStack(spacing: 6) {
                            Text(tier.displayName)
                                .font(.system(size: DesignToken.caption2Size))
                                .foregroundStyle(Color.dsTextSecondary)
                                .frame(width: 58, alignment: .leading)
                            Spacer()
                            compactVerificationIndicator(tierModelChecks[tier.rawValue] ?? .unknown)
                        }
                    }
                }
                if !liveModels.isEmpty {
                    Text("\(liveModels.count) model\(liveModels.count == 1 ? "" : "s") auto-fetched from \(providerPreset(provider)?.name ?? provider)")
                        .font(.system(size: DesignToken.caption2Size))
                        .foregroundStyle(Color.dsTextTertiary)
                }
                HStack(spacing: 8) {
                    Toggle(isOn: $enableThinking) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Pass Through Reasoning Content")
                                .font(.system(size: DesignToken.bodySize))
                            Text("Master switch. Preserves thinking tokens from reasoning providers as Anthropic thinking blocks; skipped for tool-calling turns.")
                                .font(.system(size: DesignToken.caption2Size))
                                .foregroundStyle(Color.dsTextTertiary)
                        }
                    }
                    .toggleStyle(.switch)
                    savedFieldCheckmark("enableThinking")
                }

                if enableThinking {
                    HStack(spacing: DesignToken.spacing8) {
                        Text("Reasoning Policy")
                            .font(.system(size: DesignToken.captionSize))
                            .foregroundStyle(Color.dsTextSecondary)
                        Spacer()
                        Picker("", selection: Binding(
                            get: { reasoningPolicies[provider] ?? .auto },
                            set: { reasoningPolicies[provider] = $0 }
                        )) {
                            ForEach(ReasoningPolicy.allCases, id: \.self) { policy in
                                Text(policy.displayName).tag(policy)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 170)
                        savedFieldCheckmark("reasoning:\(provider)")
                    }
                    Text("Auto: reasoning-capable providers (DeepSeek, OpenCode, Kimi…) keep thinking blocks; others never request or surface them. Applies to the active provider.")
                        .font(.system(size: DesignToken.caption2Size))
                        .foregroundStyle(Color.dsTextTertiary)
                }
            }

            sectionGroup("Provider & Model Routing") {
                Text("Each Claude tier (Default / Opus / Sonnet / Haiku) routes through its own provider and model. Lists auto-fetch from your configured providers — no manual refresh needed.")
                    .font(.system(size: DesignToken.caption2Size))
                    .foregroundStyle(Color.dsTextTertiary)

                ForEach(TierKey.allCases, id: \.self) { tier in
                    tierPair(tier)
                }

                if isLocalAutoProvider {
                    localModelQuickControl
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

            Text("Press Verify next to a key to check it against the provider — a green tick means the key works.")
                .font(.system(size: DesignToken.caption2Size))
                .foregroundStyle(Color.dsTextTertiary)

            Button {
                showApiKeyGuide = true
            } label: {
                Label("Get a free API key — step-by-step", systemImage: "sparkles")
                    .font(.system(size: DesignToken.captionSize, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.dsAccent)
            .help("Open the step-by-step guide for free providers (OpenCode Zen, NVIDIA NIM)")

            keyField("Anthropic API Key", providerId: "direct", text: $anthropicKey)
            keyField("OpenAI API Key", providerId: "openai", text: $openaiKey)
            keyField("OpenRouter API Key", providerId: "openrouter", text: $openrouterKey)
            keyField("OpenCode API Key", providerId: "opencode-zen", text: $opencodeKey)
            keyField("NVIDIA NIM API Key", providerId: "nvidia-nim", text: $nvidiaKey)
            keyField("DeepSeek API Key", providerId: "deepseek", text: $deepseekKey)
            keyField("Google Gemini API Key", providerId: "gemini", text: $geminiKey)
            keyField("Mistral API Key", providerId: "mistral", text: $mistralKey)
            keyField("Mistral Codestral API Key", providerId: "codestral", text: $codestralKey)
            keyField("Cohere API Key", providerId: "cohere", text: $cohereKey)
            keyField("Groq API Key", providerId: "groq", text: $groqKey)
            keyField("Fireworks AI API Key", providerId: "fireworks", text: $fireworksKey)
            keyField("SambaNova API Key", providerId: "sambanova", text: $sambanovaKey)
            keyField("Cerebras API Key", providerId: "cerebras", text: $cerebrasKey)
            keyField("HuggingFace API Key", providerId: "huggingface", text: $huggingfaceKey)
            keyField("xAI Grok API Key", providerId: "xai", text: $xaiKey)

            Divider().padding(.vertical, DesignToken.spacing4)

            sectionGroup("Endpoints") {
                labeledField("OpenAI-Compatible Base URL", savedID: "openaiBaseUrl") {
                    TextField("https://integrate.api.nvidia.com/v1", text: $openaiBaseUrl)
                        .textFieldStyle(.roundedBorder)
                }
                labeledField("Local LLM Base URL", savedID: "localBaseUrl") {
                    TextField("http://127.0.0.1:11434/v1", text: $localBaseUrl)
                        .textFieldStyle(.roundedBorder)
                }
                labeledField("Local LLM Model", savedID: "localModel") {
                    TextField("ollama/qwen", text: $localModel)
                        .textFieldStyle(.roundedBorder)
                }
            }

            Divider().padding(.vertical, DesignToken.spacing4)

            sectionGroup("Provider Backend URLs") {
                Text("Override the default API endpoint for any provider.")
                    .font(.system(size: DesignToken.captionSize))
                    .foregroundStyle(Color.dsTextTertiary)
                ForEach(ProviderPreset.all.filter { $0.id != "local" && $0.id != "ollama" && $0.id != "lmstudio" && $0.id != "llamacpp" && $0.id != "custom" }) { preset in
                    labeledField(preset.name) {
                        TextField(
                            preset.defaultUrl,
                            text: Binding(
                                get: { providerUrlOverrides[preset.id] ?? "" },
                                set: { providerUrlOverrides[preset.id] = $0 }
                            )
                        )
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: DesignToken.caption2Size, design: .monospaced))
                    }
                }
            }

            Divider().padding(.vertical, DesignToken.spacing4)

            // Named custom (OpenAI-compatible) providers — add any number.
            sectionGroup("Custom Providers") {
                Text("Point JXProxy at any OpenAI-compatible endpoint — a gateway, a proxy, a vLLM server, InferX, etc. Each saved provider appears in the General → Model dropdowns with its own name, endpoint, and key.")
                    .font(.system(size: DesignToken.captionSize))
                    .foregroundStyle(Color.dsTextTertiary)

                // Add form
                VStack(alignment: .leading, spacing: DesignToken.spacing6) {
                    labeledField("Name", caption: "Shown in the provider dropdowns", savedID: "customNewName") {
                        TextField("e.g. InferX", text: $newCustomName)
                            .textFieldStyle(.roundedBorder)
                    }
                    labeledField("Base URL", caption: "OpenAI-compatible endpoint", savedID: "customNewUrl") {
                        TextField("https://your-endpoint.example.com/v1", text: $newCustomUrl)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: DesignToken.caption2Size, design: .monospaced))
                    }
                    secureField("API Key", text: $newCustomKey)
                    HStack(spacing: 8) {
                        Button {
                            addCustomProvider()
                        } label: {
                            Label("Add Custom Provider", systemImage: "plus.circle.fill")
                                .font(.system(size: DesignToken.captionSize, weight: .semibold))
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(newCustomName.trimmingCharacters(in: .whitespaces).isEmpty
                                  || newCustomUrl.trimmingCharacters(in: .whitespaces).isEmpty
                                  || duplicateCustomName)
                        Text("Models auto-fetch when you open the model dropdowns.")
                            .font(.system(size: DesignToken.caption2Size))
                            .foregroundStyle(Color.dsTextTertiary)
                    }
                }
                .padding(10)
                .background(Color.dsSurface)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.dsBorder, lineWidth: 1)
                )

                // Saved providers
                if customProviders.isEmpty {
                    Text("No custom providers added yet — use the form above to add one (e.g. InferX with its OpenAI-compatible endpoint).")
                        .font(.system(size: DesignToken.caption2Size))
                        .foregroundStyle(Color.dsTextTertiary)
                } else {
                    ForEach(customProviders) { def in
                        savedCustomProviderRow(def)
                    }
                }
            }

            Divider().padding(.vertical, DesignToken.spacing4)

            // Auto-detected local runtimes — item 9
            sectionGroup("Local Providers (Auto-Detected)") {
                Text("JXProxy scans this Mac for local model runtimes. Some must be started manually before their models can be fetched.")
                    .font(.system(size: DesignToken.captionSize))
                    .foregroundStyle(Color.dsTextTertiary)
                ForEach(localRuntimes) { runtime in
                    LocalRuntimeRow(runtime: runtime) {
                        guideFor(runtime)
                    }
                }
                HStack(spacing: 8) {
                    Button("Refresh Detection") {
                        Task { localRuntimes = await LocalProviderDetector.detect() }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Spacer()
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
                    savedFieldCheckmark("appRoutes")

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
                HStack(spacing: 8) {
                    Toggle(isOn: $enableSystemProxy) {
                        Text("Enable System-Wide Proxy")
                            .font(.system(size: DesignToken.bodySize))
                    }
                    .toggleStyle(.switch)
                    savedFieldCheckmark("enableSystemProxy")
                }
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
                        .onChange(of: networkInterface) { _, newValue in
                            // Keep the proxy manager's selected service in sync so
                            // enable/disable act on the interface the user picked.
                            manager.setSystemProxyInterface(newValue)
                        }
                    }
                }

                Text("JXProxy already intercepts all api.anthropic.com traffic automatically (DNS redirection) — this system-wide toggle is only needed for non-Anthropic AI apps that don't honor the proxy. Non-AI requests pass through unmodified.")
                    .font(.system(size: DesignToken.captionSize))
                    .foregroundStyle(Color.dsTextTertiary)
            }

            sectionGroup("Bot Integration") {
                HStack(spacing: 8) {
                    Toggle(isOn: $botIntegrationEnabled) {
                        Text("Enable Telegram Bot Integration")
                            .font(.system(size: DesignToken.bodySize))
                    }
                    .toggleStyle(.switch)
                    savedFieldCheckmark("botIntegration")
                }
                
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
                        Button("Auto-Detect") {
                            autoDetectModel()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Find a .gguf model automatically")
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
                            .disabled(lmStatus == "starting")
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
                Text("DNS redirection needs one-time macOS authorization (a password prompt) when it is first installed or removed. JXProxy does not use a stored password to bypass it — after the first install, Starts and Restarts no longer prompt while redirection is already active.")
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

            if showSavedFlash {
                Label("Saved", systemImage: "checkmark.circle.fill")
                    .font(.system(size: DesignToken.captionSize, weight: .semibold))
                    .foregroundStyle(Color.dsGreen)
                    .symbolEffect(.bounce, value: showSavedFlash)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            } else {
                Label("All changes saved automatically", systemImage: "checkmark.circle.fill")
                    .font(.system(size: DesignToken.captionSize))
                    .foregroundStyle(Color.dsGreen)
            }
        }
        .animation(.easeOut(duration: 0.15), value: showSavedFlash)
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

    private func labeledField<Content: View>(_ label: String, caption: String? = nil, savedID: String? = nil, @ViewBuilder content: () -> Content) -> some View {
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
                if let savedID = savedID {
                    savedFieldCheckmark(savedID)
                }
            }
            content()
        }
    }

    /// A small green ✓ shown next to a field for ~1.5s after its value was
    /// auto-saved. Field ids come from `currentFieldValues()`.
    @ViewBuilder
    private func savedFieldCheckmark(_ id: String) -> some View {
        if savedFieldFlash.contains(id) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 10))
                .foregroundStyle(Color.dsGreen)
                .symbolEffect(.bounce, value: savedFieldFlash)
                .transition(.opacity.combined(with: .scale(scale: 0.5)))
                .animation(.easeOut(duration: 0.15), value: savedFieldFlash)
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

    /// Composite hash of all editable settings – observed to detect unsaved changes.
    private var settingsHash: String {
        let urlOverridesStr = providerUrlOverrides.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        let tierProvidersStr = tierProviders.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        let appRoutesStr = appRoutes.map { "\($0.bundleIdentifier ?? "")|\($0.appName)" }.joined(separator: ",")
        let customProvidersStr = customProviders
            .sorted(by: { $0.id < $1.id })
            .map { "\($0.id)|\($0.name)|\($0.baseUrl)|\(customProviderKeys[$0.id] ?? "")" }
            .joined(separator: ",")
        return [
            port, authToken, model, String(enableThinking), reasoningPolicies.map { "\($0.key)=\($0.value.rawValue)" }.sorted().joined(separator: ","),
            provider, fallbackProviders, tierProvidersStr,
            modelOpus, modelSonnet, modelHaiku,
            openaiBaseUrl, localBaseUrl, localModel,
            urlOverridesStr,
            String(enableSystemProxy), appRoutesStr,
            anthropicKey, openaiKey, openrouterKey, opencodeKey, nvidiaKey,
            deepseekKey, geminiKey, mistralKey, codestralKey, cohereKey,
            groqKey, fireworksKey, sambanovaKey, cerebrasKey, huggingfaceKey, xaiKey,
            customUrl, customKey,
            customProvidersStr,
            String(botIntegrationEnabled), telegramBotToken,
            adminPassword
        ].joined(separator: "\u{1F}")
    }

    private func loadFromConfig() {
        port = "\(config.port)"
        authToken = config.authToken
        // If the stored model is empty, populate from the provider preset
        if !config.model.isEmpty {
            model = config.model
        } else if let preset = providerPreset(config.provider), let firstModel = preset.models.first {
            model = firstModel
        } else {
            model = ""
        }
        enableThinking = config.enableThinking
        reasoningPolicies = config.reasoningPolicies
        provider = config.provider
        fallbackProviders = config.fallbackProviders
        tierProviders["opus"] = config.tierProvider(for: "opus")
        tierProviders["sonnet"] = config.tierProvider(for: "sonnet")
        tierProviders["haiku"] = config.tierProvider(for: "haiku")
        modelOpus = config.modelOpus
        modelSonnet = config.modelSonnet
        modelHaiku = config.modelHaiku
        openaiBaseUrl = config.openaiBaseUrl
        localBaseUrl = config.localLlmBaseUrl
        localModel = config.localLlmModel
        customUrl = config.baseUrl(for: "custom")
        customKey = config.apiKey(for: "custom")
        customProviders = config.customProviders
        customProviderKeys = [:]
        for def in customProviders {
            customProviderKeys[def.id] = config.apiKey(for: def.id)
        }
        // Migrate the legacy single "custom" entry into the named list so it
        // keeps working (and shows up in the provider dropdowns) after the
        // upgrade to named custom providers.
        if customProviders.isEmpty,
           !customUrl.trimmingCharacters(in: .whitespaces).isEmpty {
            let legacy = CustomProviderDef(id: "custom", name: "Custom", baseUrl: customUrl)
            customProviders = [legacy]
            customProviderKeys["custom"] = customKey
        }
        providerUrlOverrides = config.providerBackendUrls
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
        // Store clean model names: strip the provider's own routing prefix so
        // dropdowns, the dashboard, and launchers show "deepseek-chat" instead
        // of "deepseek/deepseek-chat" (routing is unaffected).
        config.model = ProviderPreset.bareModel(model, for: provider)
        config.enableThinking = enableThinking
        config.reasoningPolicies = reasoningPolicies
        config.provider = provider
        config.fallbackProviders = fallbackProviders
        // Persist per-tier provider selections (default tier uses `provider`).
        for tier in TierKey.allCases where tier != .defaultModel {
            if let pid = tierProviders[tier.rawValue], !pid.isEmpty {
                config.setTierProvider(tier.rawValue, pid)
            } else {
                config.setTierProvider(tier.rawValue, "")
            }
        }
        config.modelOpus = ProviderPreset.bareModel(modelOpus, for: provider)
        config.modelSonnet = ProviderPreset.bareModel(modelSonnet, for: provider)
        config.modelHaiku = ProviderPreset.bareModel(modelHaiku, for: provider)
        config.openaiBaseUrl = openaiBaseUrl
        config.localLlmBaseUrl = localBaseUrl
        config.localLlmModel = localModel
        // Custom provider: endpoint + key (persisted, auto-fetchable).
        var overrides = providerUrlOverrides.filter { !$0.value.isEmpty }
        if !customUrl.trimmingCharacters(in: .whitespaces).isEmpty {
            overrides["custom"] = customUrl.trimmingCharacters(in: .whitespaces)
        }
        config.providerBackendUrls = overrides
        config.setApiKey(chainKey: ConfigManager.KeychainKey.custom, value: customKey)
        // Named custom providers: persist definitions + per-provider keys.
        for def in customProviders {
            config.upsertCustomProvider(def, apiKey: customProviderKeys[def.id] ?? "")
        }
        let keptIds = Set(customProviders.map { $0.id })
        for def in config.customProviders where !keptIds.contains(def.id) {
            config.removeCustomProvider(id: def.id)
        }

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

    /// Auto-save: persist all settings shortly after the last edit so nothing
    /// is ever lost between an edit and an explicit Save (there is none).
    /// Re-verifies the active provider + default model only when they changed,
    /// replacing the old Save button's post-save verification.
    private func scheduleAutoSave() {
        autoSaveTask?.cancel()
        autoSaveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            saveConfig()
            // Per-field checkmarks: diff current values against the last saved
            // snapshot, so only the fields that actually changed get a ✓.
            let current = currentFieldValues()
            let changed = Set(current.compactMap { key, value in
                lastSavedValues[key] == value ? nil : key
            })
            lastSavedValues = current
            if !changed.isEmpty {
                savedFieldFlash = changed
                savedFieldFlashTask?.cancel()
                savedFieldFlashTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    guard !Task.isCancelled else { return }
                    savedFieldFlash = []
                }
            }
            // Flash the "Saved ✓" indicator — a fresh flash each persist, even
            // when one is already showing (rapid edits re-trigger it).
            savedFlashTask?.cancel()
            showSavedFlash = true
            savedFlashTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                showSavedFlash = false
            }
            if provider != lastVerifiedProvider || model != lastVerifiedModel {
                lastVerifiedProvider = provider
                lastVerifiedModel = model
                if !apiKeyForProvider(provider).isEmpty {
                    await verifyProviderKey(provider)
                }
                if !model.isEmpty {
                    await verifyDefaultModel()
                }
            }
        }
    }

    /// Snapshot of every editable field's current value, keyed by a stable id
    /// matching the `savedFieldCheckmark` ids used across the tabs. Diffed
    /// against `lastSavedValues` to detect which fields changed in a save.
    private func currentFieldValues() -> [String: String] {
        var values: [String: String] = [:]
        values["port"] = port
        values["authToken"] = authToken
        values["provider"] = provider
        values["model"] = model
        values["enableThinking"] = String(enableThinking)
        values["openaiBaseUrl"] = openaiBaseUrl
        values["localBaseUrl"] = localBaseUrl
        values["localModel"] = localModel
        values["customUrl"] = customUrl
        values["customKey"] = customKey
        values["enableSystemProxy"] = String(enableSystemProxy)
        values["botIntegration"] = String(botIntegrationEnabled)
        values["appRoutes"] = appRoutes.map { "\($0.bundleIdentifier ?? "")\($0.appName)\($0.enabled)" }.joined(separator: ",")
        // API keys — one id per provider.
        for (pid, key) in [
            ("direct", anthropicKey), ("openai", openaiKey), ("openrouter", openrouterKey),
            ("opencode-zen", opencodeKey), ("nvidia-nim", nvidiaKey), ("deepseek", deepseekKey),
            ("gemini", geminiKey), ("mistral", mistralKey), ("codestral", codestralKey),
            ("cohere", cohereKey), ("groq", groqKey), ("fireworks", fireworksKey),
            ("sambanova", sambanovaKey), ("cerebras", cerebrasKey), ("huggingface", huggingfaceKey),
            ("xai", xaiKey), ("custom", customKey),
        ] {
            values["key:\(pid)"] = key
        }
        // Named custom providers + the add-form draft fields.
        for def in customProviders {
            values["customProvider:\(def.id)"] = "\(def.name)|\(def.baseUrl)|\(customProviderKeys[def.id] ?? "")"
        }
        values["customNewName"] = newCustomName
        values["customNewUrl"] = newCustomUrl
        // Tier providers + models.
        for tier in TierKey.allCases {
            values["tierProvider:\(tier.rawValue)"] = tier == .defaultModel ? provider : (tierProviders[tier.rawValue] ?? "")
            values["model:\(tier.rawValue)"] = tierModelValue(tier)
        }
        // Per-provider reasoning policy.
        for (pid, policy) in reasoningPolicies {
            values["reasoning:\(pid)"] = policy.rawValue
        }
        return values
    }

    private func saveAppRoutesToConfig() {
        guard let data = try? JSONEncoder().encode(appRoutes),
              let json = String(data: data, encoding: .utf8) else { return }
        config.appRoutesJSON = json
    }

    private func resetToDefaults() {
        port = "5255"
        authToken = "jxproxy"
        enableThinking = true
        reasoningPolicies = [:]
        provider = "opencode-zen"
        fallbackProviders = "nvidia,local"
        tierProviders = [:]
        tierLiveModels = [:]
        // Model defaults are populated from the provider preset when one is selected
        model = providerPreset(provider)?.models.first ?? ""
        modelOpus = ""
        modelSonnet = ""
        modelHaiku = ""
        openaiBaseUrl = "https://api.openai.com/v1"
        localBaseUrl = "http://127.0.0.1:11434/v1"
        localModel = "ollama/qwen3:latest"
        customUrl = ""
        customKey = ""
        customProviders = []
        customProviderKeys = [:]
        newCustomName = ""
        newCustomUrl = ""
        newCustomKey = ""
        providerUrlOverrides = [:]
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
        // Reset persists immediately via the auto-save on the resulting
        // settingsHash change.
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
                manager.setSystemProxyInterface(networkInterface)
            } else if !manager.systemProxyManager.selectedInterface.isEmpty {
                networkInterface = manager.systemProxyManager.selectedInterface
            }
        } catch {
            availableInterfaces = ["Wi-Fi"]
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
        manager.provider = LocalModelManager.LocalProvider(rawValue: lmProvider) ?? .llamacpp
        manager.modelPath = lmModelPath
        manager.port = Int(lmPort) ?? manager.provider.defaultPort
        manager.customBinaryPath = lmBinaryPath
        onboardingProvider = manager.provider

        // One-click flow: if the server binary or a model file is missing, open
        // the setup tutorial instead of failing with a bare error string.
        switch manager.readiness() {
        case .needsInstall, .needsModel:
            showLocalOnboarding = true
        case .ready:
            if lmModelPath.isEmpty {
                lmModelPath = manager.autoDetectModelFile() ?? ""
                manager.modelPath = lmModelPath
            }
            lmStatus = "starting"
            Task {
                await manager.start()
                updateLMStatus()
                await fetchLiveModels()
            }
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

    /// Quick "Run Local Model" for the General tab's local provider panel:
    /// maps the selected preset to the local server provider, then runs the
    /// one-click flow (auto-detect model → start in background, or onboarding).
    private func runLocalModel() {
        let mgr = LocalModelManager.shared
        let newProvider: LocalModelManager.LocalProvider = provider == "ollama" ? .ollama : .llamacpp
        // Only reset the port when the provider actually changes, so a custom
        // port set in the System tab isn't clobbered by re-tapping Run.
        if mgr.provider != newProvider {
            mgr.provider = newProvider
            mgr.port = newProvider.defaultPort
        }
        onboardingProvider = mgr.provider

        switch mgr.readiness() {
        case .needsInstall, .needsModel:
            showLocalOnboarding = true
        case .ready:
            if mgr.modelPath.isEmpty {
                mgr.modelPath = mgr.autoDetectModelFile() ?? ""
            }
            Task {
                await mgr.start()
                await fetchLiveModels()
            }
        }
    }

    /// Scan for a local .gguf and configure llama.cpp with it.
    private func autoDetectModel() {
        let mgr = LocalModelManager.shared
        if let found = mgr.autoDetectModelFile() {
            lmProvider = "llamacpp"
            mgr.provider = .llamacpp
            lmModelPath = found
            mgr.modelPath = found
        } else {
            onboardingProvider = .llamacpp
            showLocalOnboarding = true
        }
    }

    /// Providers whose local server JXProxy can launch in the background.
    /// (LM Studio runs itself, so it is excluded.)
    private var isLocalAutoProvider: Bool {
        provider == "ollama" || provider == "llamacpp"
    }

    private var localModelQuickControl: some View {
        let mgr = LocalModelManager.shared
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(localModelStatusColor(mgr))
                    .frame(width: 8, height: 8)
                Text(localModelStatusText(mgr))
                    .font(.system(size: DesignToken.captionSize))
                    .foregroundStyle(Color.dsTextSecondary)
                    .lineLimit(1)
                Spacer()
                if mgr.isRunning {
                    Button("Stop") { mgr.stop() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                } else {
                    Button(action: { runLocalModel() }) {
                        Label("Run Local Model", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
            Text("Starts \(mgr.provider.serverName) in the background and auto-fetches its models. Setup steps open automatically if it isn't installed.")
                .font(.system(size: DesignToken.caption2Size))
                .foregroundStyle(Color.dsTextTertiary)
        }
    }

    private func localModelStatusText(_ mgr: LocalModelManager) -> String {
        switch mgr.status {
        case .stopped: return "\(mgr.provider.serverName) not running"
        case .starting: return "Starting \(mgr.provider.serverName)…"
        case .running: return "\(mgr.provider.serverName) running"
        case .failed(let msg): return "Failed: \(msg)"
        }
    }

    private func localModelStatusColor(_ mgr: LocalModelManager) -> Color {
        switch mgr.status {
        case .stopped: return Color.dsTextTertiary
        case .starting: return Color.orange
        case .running: return Color.dsGreen
        case .failed: return Color.dsRed
        }
    }

    // MARK: - Tier Routing (4 independent Provider+Model pairs)

    /// One Provider+Model pair for a Claude tier. Top control: provider
    /// dropdown. Immediately under it: model dropdown dependent on the
    /// selected provider. Both auto-fetch — no manual refresh buttons.
    private func tierPair(_ tier: TierKey) -> some View {
        let pid = tierProviderId(for: tier)
        return VStack(alignment: .leading, spacing: DesignToken.spacing6) {
            // Tier label
            HStack(spacing: 6) {
                Image(systemName: tierSymbol(tier))
                    .font(.system(size: 10))
                    .foregroundStyle(Color.dsAccent)
                Text(tier.displayName)
                    .font(.system(size: DesignToken.captionSize, weight: .semibold))
                    .foregroundStyle(Color.dsTextPrimary)
                Spacer()
                if let preset = providerPreset(pid) {
                    Text(preset.name)
                        .font(.system(size: DesignToken.caption2Size))
                        .foregroundStyle(Color.dsTextTertiary)
                }
                savedFieldCheckmark("tierProvider:\(tier.rawValue)")
            }

            // Provider control. Every tier — including Default — gets its own
            // dropdown; the Default pair is the primary provider selection.
            Menu {
                ForEach(availableProviders) { preset in
                    Button {
                        setTierProvider(tier, preset.id)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: preset.symbol)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 14, height: 14)
                            Text(preset.name)
                            Spacer()
                            if pid == preset.id {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.dsAccent)
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {                    Image(systemName: providerPreset(pid)?.symbol ?? "network")
                        .foregroundStyle(Color.dsAccent)
                        .frame(width: 14)
                    Text(providerPreset(pid)?.name ?? pid)
                        .lineLimit(1)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 9))
                            .foregroundStyle(Color.dsTextSecondary)
                    }
                    .font(.system(size: DesignToken.captionSize))
                    .padding(8)
                    .background(Color.dsSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.dsBorder, lineWidth: 1)
                    )
                }
                .menuStyle(.borderlessButton)

            // Model dropdown (immediately under the provider — dependent on it).
            // Autofetch whenever the dropdown opens.
            HStack(spacing: 6) {
                ComboBox(
                    text: tierModelBinding(tier),
                    options: scopedOptions(tierModelOptions(for: tier), current: tierModelBinding(tier).wrappedValue)
                ) {
                    Task { await fetchTierModels(for: tier) }
                }
                .frame(height: 22)
                savedFieldCheckmark("model:\(tier.rawValue)")
            }
        }
        .padding(10)
        .background(Color.dsSurface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.dsBorder, lineWidth: 1)
        )
    }

    // MARK: - Custom Providers (named OpenAI-compatible endpoints)

    /// Add a named custom provider from the Providers tab form, switch the
    /// Default pair to it, and fetch its models.
    private func addCustomProvider() {
        let name = newCustomName.trimmingCharacters(in: .whitespaces)
        let url = newCustomUrl.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !url.isEmpty else { return }
        // "custom-" prefix keeps ids from ever colliding with built-in preset
        // ids (e.g. a provider named "OpenAI" must not hijack the built-in
        // openai key/baseUrl/routing).
        let id = "custom-" + slugify(name)
        let def = CustomProviderDef(id: id, name: name, baseUrl: url)
        if let idx = customProviders.firstIndex(where: { $0.id == id }) {
            customProviders[idx] = def
        } else {
            customProviders.append(def)
        }
        customProviderKeys[id] = newCustomKey
        newCustomName = ""
        newCustomUrl = ""
        newCustomKey = ""
        // Immediately select it as the Default provider and fetch its models.
        provider = id
        Task { await fetchLiveModels(for: id) }
    }

    /// A saved custom provider row: name, endpoint, key field, verify + delete.
    private func savedCustomProviderRow(_ def: CustomProviderDef) -> some View {
        VStack(alignment: .leading, spacing: DesignToken.spacing6) {
            HStack(spacing: 6) {
                Image(systemName: "puzzlepiece.extension")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.dsAccent)
                Text(def.name)
                    .font(.system(size: DesignToken.captionSize, weight: .semibold))
                    .foregroundStyle(Color.dsTextPrimary)
                Spacer()
                savedFieldCheckmark("customProvider:\(def.id)")
                verificationIndicator(providerChecks[def.id] ?? .unknown)
                Button(role: .destructive) {
                    // Remove the provider; clean up tier references that point
                    // at it; fall back to the first available if it was the
                    // Default provider.
                    customProviders.removeAll { $0.id == def.id }
                    customProviderKeys.removeValue(forKey: def.id)
                    for tier in TierKey.allCases where tier != .defaultModel {
                        if tierProviders[tier.rawValue] == def.id {
                            tierProviders.removeValue(forKey: tier.rawValue)
                        }
                    }
                    if provider == def.id, let first = availableProviders.first {
                        provider = first.id
                    }
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.dsRed)
                .help("Remove this custom provider")
            }
            Text(def.baseUrl)
                .font(.system(size: DesignToken.caption2Size, design: .monospaced))
                .foregroundStyle(Color.dsTextSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            HStack(spacing: DesignToken.spacing6) {
                SecureField("••••••••", text: Binding(
                    get: { customProviderKeys[def.id] ?? "" },
                    set: { customProviderKeys[def.id] = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                Button("Verify") {
                    Task { await verifyProviderKey(def.id) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .font(.system(size: DesignToken.caption2Size))
                Spacer()
                if provider == def.id {
                    Text("Default")
                        .font(.system(size: DesignToken.caption2Size, weight: .semibold))
                        .foregroundStyle(Color.dsGreen)
                }
            }
        }
        .padding(10)
        .background(Color.dsSurface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.dsBorder, lineWidth: 1)
        )
    }

    /// "InferX" → "inferx" / "My Gateway" → "my-gateway" — stable provider id.
    private func slugify(_ name: String) -> String {
        let lowered = name.lowercased()
        let allowed = lowered.filter { $0.isLetter || $0.isNumber || $0 == " " }
        let slug = allowed.split(separator: " ").joined(separator: "-")
        return slug.isEmpty ? "custom-provider" : slug
    }

    /// True when the draft name would overwrite an existing custom provider
    /// (ids are derived from the name). The Add button is disabled then.
    private var duplicateCustomName: Bool {
        let trimmed = newCustomName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        let id = "custom-" + slugify(trimmed)
        return customProviders.contains { $0.id == id }
    }

    private func tierSymbol(_ tier: TierKey) -> String {
        switch tier {
        case .defaultModel: return "circle.fill"
        case .opus: return "star.fill"
        case .sonnet: return "sparkles"
        case .haiku: return "bolt.fill"
        }
    }

    /// Resolved provider id for a tier. Default tier always follows the
    /// primary provider; Opus/Sonnet/Haiku fall back to it when unset.
    private func tierProviderId(for tier: TierKey) -> String {
        switch tier {
        case .defaultModel: return provider
        case .opus: return tierProviders["opus"] ?? provider
        case .sonnet: return tierProviders["sonnet"] ?? provider
        case .haiku: return tierProviders["haiku"] ?? provider
        }
    }

    /// Set a tier's provider, auto-populate its model, and autofetch its
    /// model list immediately. Each pair is independent.
    ///
    /// A user-chosen model is NEVER overwritten: only when the tier has no
    /// model yet is the provider's first preset auto-populated. Previously a
    /// non-empty model that wasn't in the new provider's preset list was
    /// clobbered with the first preset ("big-pickle" for OpenCode Zen), which
    /// looked like the model "reverting" after saving.
    private func setTierProvider(_ tier: TierKey, _ pid: String) {
        if tier == .defaultModel {
            provider = pid
        } else {
            tierProviders[tier.rawValue] = pid
        }
        tierLiveModels[tier.rawValue] = []
        if tierModelValue(tier).isEmpty,
           let preset = providerPreset(pid) {
            setTierModel(tier, ProviderPreset.bareModel(preset.models.first ?? "", for: pid))
        }
        Task { await fetchTierModels(for: tier) }
    }

    private func tierModelBinding(_ tier: TierKey) -> Binding<String> {
        switch tier {
        case .defaultModel: return $model
        case .opus: return $modelOpus
        case .sonnet: return $modelSonnet
        case .haiku: return $modelHaiku
        }
    }

    private func setTierModel(_ tier: TierKey, _ value: String) {
        switch tier {
        case .defaultModel: model = value
        case .opus: modelOpus = value
        case .sonnet: modelSonnet = value
        case .haiku: modelHaiku = value
        }
    }

    /// Model options for a tier: the provider's preset models + user-visible
    /// models + live models fetched from the provider's API (bare names).
    private func tierModelOptions(for tier: TierKey) -> [String] {
        let pid = tierProviderId(for: tier)
        var models = Set<String>()
        if let preset = providerPreset(pid) {
            for m in preset.models { models.insert(ProviderPreset.bareModel(m, for: pid)) }
        }
        if let p = manager.providers.first(where: { $0.id == pid }) {
            for m in p.visibleModelIds { models.insert(ProviderPreset.bareModel(m, for: pid)) }
        }
        for m in tierLiveModels[tier.rawValue] ?? [] {
            models.insert(ProviderPreset.bareModel(m, for: pid))
        }
        return Array(models).sorted()
    }

    /// Fetch available models from a tier's provider and cache them locally.
    private func fetchTierModels(for tier: TierKey) async {
        let pid = tierProviderId(for: tier)
        var baseUrl = config.baseUrl(for: pid).replacingOccurrences(of: "/v1", with: "")
        if pid == "llamacpp" {
            let mgr = LocalModelManager.shared
            if mgr.port != 8080 { baseUrl = "http://\(mgr.host):\(mgr.port)" }
        }
        guard let url = URL(string: "\(baseUrl)/v1/models") else { return }
        do {
            var req = URLRequest(url: url)
            req.timeoutInterval = 5
            // Reactive @State key (same reasoning as fetchLiveModels) so a
            // freshly typed key authenticates the models request immediately.
            let key = apiKeyForProvider(pid)
            if !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let modelList = json["data"] as? [[String: Any]] else { return }
            let names = modelList.compactMap { $0["id"] as? String }.filter { !$0.isEmpty }
            if !names.isEmpty {
                await MainActor.run {
                    tierLiveModels[tier.rawValue] = names
                    if let idx = manager.providers.firstIndex(where: { $0.id == pid }) {
                        manager.providers[idx].visibleModelIds.formUnion(names)
                    }
                }
            }
        } catch {
            print("[SettingsView] Failed to fetch tier models from \(url): \(error)")
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

// MARK: - Local Model Onboarding

/// Step-by-step setup tutorial for running a local LLM (llama.cpp / Ollama).
/// Shown when the user taps "Run Local Model" but the server binary or a model
/// file is missing.
private struct LocalModelOnboardingView: View {
    let provider: LocalModelManager.LocalProvider
    let onRetry: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: provider == .llamacpp ? "server.rack" : "desktopcomputer")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.dsAccent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Set Up \(provider == .llamacpp ? "llama.cpp" : "Ollama")")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.dsTextPrimary)
                    Text("Run your own local LLM in the background")
                        .font(.system(size: DesignToken.captionSize))
                        .foregroundStyle(Color.dsTextTertiary)
                }
                Spacer()
            }

            onboardingStep(
                number: "1",
                title: provider == .llamacpp ? "Install llama.cpp" : "Install Ollama",
                body: provider == .llamacpp
                    ? "llama-server runs local GGUF models. Install via Homebrew, or download from the llama.cpp releases page."
                    : "Ollama serves local models with a single command. Install via Homebrew or download the macOS app.",
                actionTitle: provider == .llamacpp ? "brew install llama.cpp" : "brew install ollama",
                actionURL: provider == .llamacpp ? "https://github.com/ggml-org/llama.cpp/releases" : "https://ollama.com/download"
            )

            onboardingStep(
                number: "2",
                title: provider == .llamacpp ? "Get a model (.gguf)" : "Pull a model",
                body: provider == .llamacpp
                    ? "Download a GGUF model (e.g. Qwen3 4B). In the app, click Auto-Detect or Browse to select the file."
                    : "Pull a model once — Ollama runs it on demand. Try qwen3:8b for a good balance of speed and quality.",
                actionTitle: provider == .llamacpp ? "Browse GGUF models" : "ollama pull qwen3:8b",
                actionURL: provider == .llamacpp ? "https://huggingface.co/models?library=gguf&sort=trending" : nil
            )

            HStack(spacing: 10) {
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("I've installed it — try again") {
                    dismiss()
                    onRetry()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.top, 8)
        }
        .padding(24)
        .frame(width: 500)
        .background(Color.dsBackground)
    }

    private func onboardingStep(number: String, title: String, body: String, actionTitle: String, actionURL: String?) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.dsBackground)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.dsAccent))
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.dsTextPrimary)
                Text(body)
                    .font(.system(size: DesignToken.captionSize))
                    .foregroundStyle(Color.dsTextSecondary)
                HStack(spacing: 8) {
                    Button(actionTitle) { copyCommand(actionTitle) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .font(.system(size: DesignToken.captionSize, design: .monospaced))
                    if let url = actionURL {
                        Button("Open") {
                            if let u = URL(string: url) { NSWorkspace.shared.open(u) }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: DesignToken.captionSize))
                        .foregroundStyle(Color.dsAccent)
                    }
                }
            }
        }
    }

    private func copyCommand(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Free API Key Guide

/// Step-by-step guide for getting a free API key (OpenCode Zen / NVIDIA NIM),
/// written in plain language for non-technical users. Mirrors the local-model
/// onboarding sheet so help appears right where keys are entered.
/// Internal (not private) so the first-launch flow in JXRouterView can present
/// it automatically when no provider key is configured.
struct FreeApiKeyGuideView: View {
    let onDone: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color.dsAccentDim)
                        .frame(width: 48, height: 48)
                    Image(systemName: "sparkles")
                        .font(.system(size: 22))
                        .foregroundStyle(Color.dsAccent)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Get a Free API Key")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.dsTextPrimary)
                    Text("Two free providers — no credit card needed")
                        .font(.system(size: DesignToken.captionSize))
                        .foregroundStyle(Color.dsTextTertiary)
                }
                Spacer()
            }

            Divider().overlay(Color.dsBorder)

            guideStep(
                number: "1",
                title: "OpenCode Zen — no key needed",
                body: "OpenCode Zen is JXProxy's default provider and is already free — no sign-up, no key. In Settings → General, keep the provider as OpenCode Zen and pick a free model (any name ending in -free, or big-pickle).",
                actionTitle: "Open opencode.ai",
                actionURL: "https://opencode.ai"
            )

            guideStep(
                number: "2",
                title: "NVIDIA NIM — free key with 1,000 credits",
                body: "Go to build.nvidia.com, sign in or create a free account (email, Google, or GitHub), then click Get API Key → Generate Key. Copy the key immediately — it's shown only once.",
                actionTitle: "Open build.nvidia.com",
                actionURL: "https://build.nvidia.com"
            )

            guideStep(
                number: "3",
                title: "Paste & verify",
                body: "Back here on the Providers tab, paste the key into the NVIDIA NIM API Key field and click Verify. A green tick means it works — then choose NVIDIA NIM in General and press Start.",
                actionTitle: nil,
                actionURL: nil
            )

            Text("Keys are stored securely in your macOS Keychain — the full written guide ships with JXProxy (docs/tutorials/getting-free-api-keys.md).")
                .font(.system(size: DesignToken.caption2Size))
                .foregroundStyle(Color.dsTextTertiary)

            HStack {
                Spacer()
                Button("Got It") {
                    onDone()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .padding(24)
        .frame(width: 540)
        .background(Color.dsBackground)
    }

    private func guideStep(number: String, title: String, body: String, actionTitle: String?, actionURL: String?) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.dsBackground)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.dsAccent))
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.dsTextPrimary)
                Text(body)
                    .font(.system(size: DesignToken.captionSize))
                    .foregroundStyle(Color.dsTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let actionTitle, let actionURL {
                    Button(actionTitle) {
                        if let url = URL(string: actionURL) {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .font(.system(size: DesignToken.captionSize))
                }
            }
        }
    }
}

// MARK: - Local Runtime Row

/// A row in the auto-detected local providers section showing the runtime's
/// name, running state, and a Guide button.
private struct LocalRuntimeRow: View {
    let runtime: LocalRuntime
    let onGuide: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(runtime.name)
                    .font(.system(size: DesignToken.captionSize, weight: .medium))
                    .foregroundStyle(Color.dsTextPrimary)
                Text(runtime.hint)
                    .font(.system(size: DesignToken.caption2Size))
                    .foregroundStyle(Color.dsTextTertiary)
                    .lineLimit(2)
            }
            Spacer()
            Text(runtime.stateLabel)
                .font(.system(size: DesignToken.caption2Size, weight: .medium))
                .foregroundStyle(statusColor)
            if runtime.state == .missing || runtime.state == .installed {
                Button("Guide") { onGuide() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .font(.system(size: DesignToken.caption2Size))
            }
        }
        .padding(.horizontal, DesignToken.spacing12)
        .padding(.vertical, DesignToken.spacing8)
    }

    private var statusColor: Color {
        switch runtime.state {
        case .running: return Color.dsGreen
        case .installed: return Color.dsOrange
        case .missing: return Color.dsTextTertiary
        }
    }
}

// ComboBox is in SettingsHelpers.swift
