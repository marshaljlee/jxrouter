import SwiftUI
import ServiceManagement
import AppKit

/// Lifecycle of a tier's model-list auto-fetch, surfaced under the model
/// dropdown so a slow or failed fetch is never silent.
private enum TierFetchState: Equatable {
    case idle
    case fetching
    case loaded
    case failed(String)
}

/// Result of a single model health check.
struct ModelHealthResult: Identifiable {
    let id = UUID()
    let providerId: String
    let providerName: String
    let model: String
    let status: ModelHealthStatus
    let latencyMs: Double?
    let errorMessage: String?
}

enum ModelHealthStatus: Equatable {
    case checking
    case healthy
    case unhealthy(String)
    case rateLimited
}

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
    /// Monotonically increasing counter bumped on every user edit. The auto-save
    /// snapshot carries the generation at which it was taken; if the counter has
    /// advanced by the time the debounce fires, the snapshot is stale and the
    /// save is skipped (a fresher save will follow).
    @State private var saveGeneration = 0

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
    @State private var onboardingProvider: LocalModelManager.LocalProvider = .llamaapp
    /// Free API key guide sheet (OpenCode Zen / NVIDIA NIM) for non-technical users.
    @State private var showApiKeyGuide = false
    /// Transient feedback after a ~/.zshrc key detection (button or live watcher).
    @State private var shellImportFlash: String?
    @State private var shellImportFlashTask: Task<Void, Never>?
    @State private var provider: String = "opencode-zen"
    @State private var fallbackProviders: String = "nvidia,local"
    /// Per-tier provider overrides (tier key → provider id). The Default pair
    /// always uses the primary provider; Opus/Sonnet/Haiku default to it too.
    @State private var tierProviders: [String: String] = [:]
    /// Per-tier live model lists auto-fetched from each pair's provider.
    @State private var tierLiveModels: [String: [String]] = [:]
    /// App-wide live model lists per provider id (non-local providers) —
    /// fetched once when Settings opens so every provider's dropdown carries
    /// the provider's FULL live model list (free tier included), not just the
    /// curated preset subset.
    @State private var providerLiveModels: [String: [String]] = [:]
    /// Whether the app-wide provider model fetch is still running.
    @State private var isFetchingAllProviderModels = false
    // Model Overrides
    @State private var modelOpus: String = ""
    @State private var modelSonnet: String = ""
    @State private var modelHaiku: String = ""
    // Providers
    @State private var openaiBaseUrl: String = ""
    @State private var localBaseUrl: String = ""
    @State private var localModel: String = ""
    // Local Endpoint Live State
    @State private var localEndpointModels: [String] = []
    @State private var localEndpointStatus: String = ""
    @State private var isFetchingLocalEndpointModels = false
    // GGUF Direct
    @State private var ggufModelPath: String = ""
    @State private var ggufModelAlias: String = "local-model"
    @State private var ggufGpuLayers: Int = 0
    @State private var ggufContextSize: Int = 0
    @State private var ggufPort: String = "8081"
    @State private var ggufModels: [GGUFModelFile] = []
    @State private var ggufScanState: String = ""
    @State private var ggufScanTask: Task<Void, Never>?
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
    @State private var antigravityKey: String = ""
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

    // Model Health Check state
    @State private var modelHealthResults: [ModelHealthResult] = []
    @State private var isRunningHealthCheck = false
    @State private var healthCheckProgress: String = ""
    // Gemini OAuth
    @State private var geminiOAuth = GeminiOAuthManager.shared
    /// User-supplied OAuth client ID for Gemini Web — Google blocks the
    /// bundled community client ID ("This app is blocked"); the user's own
    /// Google Cloud client is never blocked.
    @State private var geminiOAuthClientId: String = ""

    // Credential / model verification (green ticks)
    @State private var providerChecks: [String: ProviderCheckState] = [:]
    /// Per-tier model connectivity results from the "Test All Models" button.
    @State private var tierModelChecks: [String: ProviderCheckState] = [:]
    /// Per-tier model-list fetch lifecycle — a spinner while the dropdown
    /// auto-fetches, and a clear error + Retry when the provider can't be
    /// reached, so the user always knows what the fetch is doing.
    @State private var tierFetchStates: [String: TierFetchState] = [:]

    // Auto-detected local runtimes (Ollama, llama.app, LM Studio, Jan)
    @State private var localRuntimes: [LocalRuntime] = []
    
    @AppStorage("autoStartProxy") private var autoStartProxy = false
    
    // System
    @State private var enableSystemProxy: Bool = false
    /// Whether OpenAI connections (api.openai.com) are routed through JXProxy.
    /// Independent of Anthropic: off → OpenAI traffic passes through unmodified.
    @State private var routeOpenAI: Bool = true
    @State private var networkInterface: String = "Wi-Fi"
    @State private var appRoutes: [AppRouteRule] = []
    @State private var availableInterfaces: [String] = []

    // Remote Web Control (mobile web-wrapper apps)
    @State private var webControlEnabled: Bool = false
    @State private var webControlPort: String = "5355"
    
    // Bot
    @State private var botIntegrationEnabled: Bool = false
    @State private var telegramBotToken: String = ""

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
        // Named custom providers keep their key in a reactive per-id field; an
        // empty field falls back to the persisted key (Keychain, plus the
        // endpoint-matched built-in inheritance in ConfigManager), so a custom
        // provider at a built-in endpoint resolves the user's verified key
        // even before the debounced save flushes it.
        if customProviders.contains(where: { $0.id == id }) {
            let key = customProviderKeys[id] ?? ""
            return key.isEmpty ? config.apiKey(for: id) : key
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
        case "antigravity":  return antigravityKey
        case "custom":       return customKey
        default:
            // Providers without a @State binding — check Keychain directly
            return config.apiKey(for: id)
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

    /// Test every Claude tier's model (Default / Opus / Sonnet / Haiku) against
    /// its own provider — one result per tier under the button. All four tiers
    /// run concurrently (each child hops to the main actor only to record its
    /// own result), so the check finishes in ~one round-trip instead of four
    /// sequential ones.
    private func verifyAllTierModels() async {
        async let defaultCheck: Void = verifyTierModel(.defaultModel)
        async let opusCheck: Void = verifyTierModel(.opus)
        async let sonnetCheck: Void = verifyTierModel(.sonnet)
        async let haikuCheck: Void = verifyTierModel(.haiku)
        _ = await (defaultCheck, opusCheck, sonnetCheck, haikuCheck)
    }

    /// Run one tier's model check against its own provider and record the
    /// result. Model-list fetches and network round-trips run off the main
    /// actor; only the result is written back to the UI state.
    private func verifyTierModel(_ tier: TierKey) async {
        tierModelChecks[tier.rawValue] = .checking
        // Local/custom providers (e.g. llama.app) expose their models only
        // via the live fetch — if a tier has no model yet, fetch the list
        // first so "Test All Models" can pick up the available model.
        if tierModelValue(tier).isEmpty {
            await fetchTierModels(for: tier)
        }
        let pid = tierProviderId(for: tier)
        let modelName = tierModelValue(tier)
        guard !modelName.isEmpty else {
            tierModelChecks[tier.rawValue] = .invalid("No model selected")
            return
        }
        let result = await ProviderValidator.validateModel(
            providerId: pid,
            model: ProviderPreset.bareModel(modelName, for: pid),
            apiKey: apiKeyForProvider(pid),
            baseUrl: config.baseUrl(for: pid)
        )
        tierModelChecks[tier.rawValue] = result.ok ? .valid : .invalid(result.message)
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
                    // Hover shows the FULL server message — the row itself is
                    // truncated, but the guidance ("set a default tenant…")
                    // must be reachable.
                    .help(reason)
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
                    .onSubmit {
                        saveConfigImmediately()
                    }
                    .onChange(of: text.wrappedValue) {
                        // A key edit invalidates the old verification result —
                        // never show a stale red X (or a green tick) for a key
                        // the user just changed.
                        providerChecks[providerId] = .unknown
                    }
                Button("Verify") {
                    saveConfigImmediately()
                    Task { await verifyProviderKey(providerId) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .font(.system(size: DesignToken.caption2Size))
                .help("Check this API key against the provider")

                // Dedicated remove button — deletes the key from the Keychain
                // and uninstalls every model that was installed with it.
                Button("Remove") {
                    confirmRemoveApiKey(providerId: providerId, label: label)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .font(.system(size: DesignToken.caption2Size))
                .foregroundStyle(Color.dsRed)
                .disabled(text.wrappedValue.isEmpty)
                .help("Remove this API key and uninstall all models installed with it")
            }
        }
    }

    /// Open the appropriate guidance for a local runtime that isn't running.
    private func guideFor(_ runtime: LocalRuntime) {
        switch runtime.id {
        case "llamaapp", "ollama":
            onboardingProvider = LocalModelManager.LocalProvider(rawValue: runtime.id) ?? .llamaapp
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
        // Match window width and expand to fill window height dynamically.
        .frame(width: 560)
        .frame(maxHeight: .infinity)
        .background(Color.dsBackground)
        .onAppear {
            // Re-scan the shell configs first so a key added to ~/.zshrc since
            // launch (or since this panel last opened) shows up immediately.
            config.importKeysFromShellConfigs()
            loadFromConfig()
            // Ensure the saved provider is still configured; fall back to the
            // first available one if its key was cleared outside this session.
            if !availableProviders.contains(where: { $0.id == provider }) {
                if let first = availableProviders.first {
                    provider = first.id
                }
            }
            // Repair provider/model desync saved by older builds: if a tier's
            // stored model belongs to a *different* provider (e.g. an NVIDIA
            // model left selected after switching the Default pair to DeepSeek),
            // reselect the provider's own first model so routing and "Test All
            // Models" are never tested against a mismatched pair.
            for tier in TierKey.allCases {
                sanitizeTierModel(for: tier)
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
                // Autofetch model lists for all four tier pairs so the
                // dropdowns are populated the moment they open.
                for tier in TierKey.allCases {
                    await fetchTierModels(for: tier)
                }
                // Programmatic auto-population above is not a user edit —
                // refresh the checkmark baseline so first open doesn't flash
                // a spurious "model" checkmark.
                lastSavedValues = currentFieldValues()
                // Detect local runtimes and show their status.
                localRuntimes = await LocalProviderDetector.detect()
                // Sync the General tab's local-model quick control with the
                // live server (llama.app may be running on its own port).
                await LocalModelManager.shared.refreshStatus()
                // Auto-scan for GGUF models from the background.
                await scanGGUFModels()
                // Auto-fetch every configured provider's full live model list
                // (free tier included) so dropdowns populate app-wide.
                await fetchAllProviderModels()
                // Auto-verify stored keys so green ticks appear without clicks.
                if !apiKeyForProvider(provider).isEmpty {
                    await verifyProviderKey(provider)
                }
                if !customKey.isEmpty {
                    await verifyProviderKey("custom")
                }
                // Check Gemini OAuth status on appear
                if geminiOAuth.hasStoredToken {
                    geminiOAuth.isAuthorized = true
                    await verifyProviderKey("gemini-oauth")
                }
                // Inspect live local endpoint models
                await fetchLocalEndpointModels()
            }
        }
        .onDisappear {
            // Final flush: persist anything still pending.
            saveConfigImmediately()
        }
        .onReceive(NotificationCenter.default.publisher(for: .jxproxyFlushSettingsSave)) { _ in
            saveConfigImmediately()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            saveConfigImmediately()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            saveConfigImmediately()
        }
        .onChange(of: selectedTab) { _, _ in
            saveConfigImmediately()
        }
        .onChange(of: settingsHash) { _, _ in
            // Auto-save on every edit (debounced) — no Save button needed, so
            // model/provider changes can never be lost between edit and save.
            guard hasLoaded else { return }
            saveGeneration += 1
            scheduleAutoSave()
        }
        .onReceive(NotificationCenter.default.publisher(for: .jxproxyShellKeysImported)) { note in
            // The live watcher re-imported keys from ~/.zshrc while the panel
            // was open — refresh the fields so the new keys appear immediately.
            reloadApiKeysFromConfig()
            let imported = (note.userInfo?["imported"] as? [String]) ?? []
            flashShellImport("Auto-detected in ~/.zshrc: \(imported.joined(separator: ", "))")
        }
        .onChange(of: provider) { _, newProvider in
            // The Default tier follows the primary provider: clear the previous
            // provider's cached models, reselect the model if it no longer
            // belongs to the new provider, and auto-fetch the new list — so the
            // model dropdown always reflects the selected provider immediately.
            syncTierToProvider(.defaultModel, newProvider)
        }
        .onChange(of: model) {
            // A changed model invalidates the previous test result: clear the
            // row so a stale red error from the old model never lingers.
            tierModelChecks[TierKey.defaultModel.rawValue] = .unknown
        }
        .onChange(of: modelOpus) {
            tierModelChecks[TierKey.opus.rawValue] = .unknown
        }
        .onChange(of: modelSonnet) {
            tierModelChecks[TierKey.sonnet.rawValue] = .unknown
        }
        .onChange(of: modelHaiku) {
            tierModelChecks[TierKey.haiku.rawValue] = .unknown
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
                Button(action: {
                    saveConfigImmediately()
                    selectedTab = tab
                }) {
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
                            Text(providerPreset(tierProviderId(for: tier))?.name ?? tierProviderId(for: tier))
                                .font(.system(size: DesignToken.caption2Size))
                                .foregroundStyle(Color.dsTextTertiary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer()
                            compactVerificationIndicator(tierModelChecks[tier.rawValue] ?? .unknown)
                        }
                    }
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

                fallbackControl

                if isLocalAutoProvider {
                    localModelQuickControl
                }
            }

            // Direct GGUF hosting — select a local .gguf model, load it into
            // llama-server, and route Claude through it. Model metadata (chat
            // template, context length, architecture) is read from the GGUF
            // header so the server applies the correct chat settings.
            sectionGroup("Local GGUF Model (Direct)") {
                Text("Pick a GGUF model on disk — JXRouter launches llama-server with it and routes requests to it, like Unsloth's model picker. The model's embedded chat template and context length are applied automatically.")
                    .font(.system(size: DesignToken.caption2Size))
                    .foregroundStyle(Color.dsTextTertiary)

                // Model selection
                HStack(spacing: 8) {
                    Menu {
                        if ggufModels.isEmpty {
                            Button("No models found — scan first") {}.disabled(true)
                        }
                        ForEach(ggufModels) { model in
                            Button {
                                selectGGUFModel(model)
                            } label: {
                                HStack(spacing: 8) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(model.name)
                                            .font(.system(size: DesignToken.captionSize))
                                            .lineLimit(1)
                                        Text("\(model.fileSizeFormatted) · \(model.quantization) · \(model.contextLength) ctx")
                                            .font(.system(size: DesignToken.caption2Size))
                                            .foregroundStyle(Color.dsTextTertiary)
                                    }
                                    Spacer()
                                    if ggufModelPath == model.path {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(Color.dsAccent)
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "cpu")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.dsAccent)
                            Text(selectedGGUFDisplayName)
                                .font(.system(size: DesignToken.captionSize))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 9))
                                .foregroundStyle(Color.dsTextSecondary)
                        }
                        .padding(8)
                        .background(Color.dsSurface)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.dsBorder, lineWidth: 1)
                        )
                    }
                    .menuStyle(.borderlessButton)
                    .frame(maxWidth: .infinity)

                    Button {
                        Task { await scanGGUFModels() }
                    } label: {
                        if ggufScanState == "Scanning…" {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Rescan for GGUF models")
                }

                if !ggufScanState.isEmpty {
                    Text(ggufScanState)
                        .font(.system(size: DesignToken.caption2Size))
                        .foregroundStyle(Color.dsTextTertiary)
                }

                // Selected model details
                if let selected = ggufModels.first(where: { $0.path == ggufModelPath }) {
                    HStack(spacing: 12) {
                        Label {
                            Text(selected.quantization.isEmpty ? "GGUF" : selected.quantization)
                        } icon: {
                            Image(systemName: "shippingbox")
                        }
                        Label {
                            Text("\(selected.contextLength) ctx")
                        } icon: {
                            Image(systemName: "text.alignleft")
                        }
                        Label {
                            Text(selected.architecture)
                        } icon: {
                            Image(systemName: "cpu")
                        }
                        if selected.isLargeModel {
                            Label {
                                Text("Large model")
                            } icon: {
                                Image(systemName: "exclamationmark.triangle")
                            }
                            .foregroundStyle(Color.orange)
                        }
                        Spacer()
                    }
                    .font(.system(size: DesignToken.caption2Size))
                    .foregroundStyle(Color.dsTextSecondary)
                }

                // Run/Stop control
                HStack(spacing: 8) {
                    Circle()
                        .fill(localModelStatusColor(LocalModelManager.shared))
                        .frame(width: 8, height: 8)
                    Text(ggufStatusText)
                        .font(.system(size: DesignToken.captionSize))
                        .foregroundStyle(Color.dsTextSecondary)
                        .lineLimit(1)
                    Spacer()
                    if LocalModelManager.shared.isRunning && LocalModelManager.shared.provider == .gguf {
                        Button("Stop") { stopGGUFModel() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    } else {
                        Button(action: { runGGUFModel() }) {
                            Label("Load Model", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(ggufModelPath.isEmpty)
                    }
                }

                // Advanced settings
                Divider().padding(.vertical, 2)
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Port")
                            .font(.system(size: DesignToken.caption2Size))
                            .foregroundStyle(Color.dsTextSecondary)
                        TextField("8081", text: $ggufPort)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 70)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("GPU Layers")
                            .font(.system(size: DesignToken.caption2Size))
                            .foregroundStyle(Color.dsTextSecondary)
                        Picker("", selection: $ggufGpuLayers) {
                            Text("CPU").tag(0)
                            Text("GPU (All)").tag(-1)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 160)
                    }
                    Spacer()
                }
                Text("GPU (All) offloads every layer to the Metal GPU — fastest on Apple Silicon. CPU runs purely on the processor and uses far less memory.")
                    .font(.system(size: DesignToken.caption2Size))
                    .foregroundStyle(Color.dsTextTertiary)
            }
        }
    }

    // MARK: - GGUF Helpers

    /// The currently selected GGUF model's display name.
    private var selectedGGUFDisplayName: String {
        guard let model = ggufModels.first(where: { $0.path == ggufModelPath }) else {
            return ggufModelPath.isEmpty ? "Select a GGUF model…" : (ggufModelPath as NSString).lastPathComponent
        }
        return model.name
    }

    /// Status text for the GGUF llama-server.
    private var ggufStatusText: String {
        let mgr = LocalModelManager.shared
        switch mgr.status {
        case .stopped: return "llama-server not running"
        case .starting: return "Loading model…"
        case .running(let pid):
            if mgr.provider == .gguf {
                return "llama-server running\(pid > 0 ? " (PID \(pid))" : "")"
            }
            return "llama-server not running"
        case .failed(let msg): return "Failed: \(msg)"
        }
    }

    /// Select a GGUF model and sync it to the manager + config.
    private func selectGGUFModel(_ model: GGUFModelFile) {
        ggufModelPath = model.path
        ggufModelAlias = model.suggestedAlias
        let mgr = LocalModelManager.shared
        mgr.selectedGGUFPath = model.path
        mgr.ggufModelAlias = model.suggestedAlias
        // Auto-apply a sensible GPU default for large models: offload all
        // layers when the model is small enough, CPU for very large ones.
        mgr.ggufGpuLayers = model.isLargeModel ? 0 : -1
        ggufGpuLayers = mgr.ggufGpuLayers
        // The server port is shared with the provider routing.
        mgr.provider = .gguf
        mgr.port = Int(ggufPort) ?? 8081
        // Persist immediately so the router always resolves the right alias,
        // even before the debounced autosave fires.
        config.ggufModelPath = model.path
        config.ggufModelAlias = model.suggestedAlias
        print("[Settings] Selected GGUF model: \(model.name) (\(model.path))")
    }

    /// Scan the default locations for GGUF models.
    private func scanGGUFModels() async {
        ggufScanTask?.cancel()
        ggufScanState = "Scanning…"
        ggufModels = await Task.detached(priority: .userInitiated) {
            GGUFModelScanner.scan()
        }.value
        ggufScanState = ggufModels.isEmpty ? "No GGUF models found in ~/Models, ~/Downloads, or /Volumes." : "Found \(ggufModels.count) model\(ggufModels.count == 1 ? "" : "s")."
    }

    /// Run the selected GGUF model through llama-server, then make it the
    /// active routed provider so Claude Code routes through it immediately —
    /// select a model, load it, ready to use (like Unsloth's model picker).
    private func runGGUFModel() {
        let mgr = LocalModelManager.shared
        mgr.provider = .gguf
        mgr.selectedGGUFPath = ggufModelPath
        mgr.ggufModelAlias = ggufModelAlias
        mgr.ggufGpuLayers = ggufGpuLayers
        mgr.ggufContextSize = ggufContextSize
        if let p = Int(ggufPort) { mgr.port = p }
        // Set the routed provider/model so this model becomes active.
        if provider != "gguf" {
            provider = "gguf"
        }
        // Set the default model to the alias the server will report.
        model = mgr.ggufModelAlias
        Task {
            await mgr.start()
            await fetchTierModels(for: .defaultModel)
            // After the server is up, make sure the model id matches what the
            // server actually reports (the alias we registered).
            if let first = tierLiveModels[TierKey.defaultModel.rawValue]?.first, !first.isEmpty {
                setTierModel(.defaultModel, first)
            }
        }
    }

    /// Stop the GGUF llama-server.
    private func stopGGUFModel() {
        let mgr = LocalModelManager.shared
        if mgr.provider == .gguf {
            mgr.stop()
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

            HStack(spacing: DesignToken.spacing12) {
                Button {
                    showApiKeyGuide = true
                } label: {
                    Label("Get a free API key — step-by-step", systemImage: "sparkles")
                        .font(.system(size: DesignToken.captionSize, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.dsAccent)
                .help("Open the step-by-step guide for free providers (OpenCode Zen, NVIDIA NIM)")

                Button {
                    detectKeysFromShellConfigs()
                } label: {
                    Label("Detect keys from ~/.zshrc", systemImage: "arrow.triangle.2.circlepath")
                        .font(.system(size: DesignToken.captionSize, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.dsAccent)
                .help("Scan ~/.zshrc for exported API keys and import any that aren't saved yet")
            }

            if let flash = shellImportFlash {
                Text(flash)
                    .font(.system(size: DesignToken.caption2Size))
                    .foregroundStyle(Color.dsTextTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

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
            keyField("Antigravity API Key", providerId: "antigravity", text: $antigravityKey)

            Divider().padding(.vertical, DesignToken.spacing4)

            // Gemini Web OAuth — no API key needed; authenticates via browser OAuth.
            sectionGroup("Gemini Web (OAuth)") {
                Text("Gemini Web OAuth uses Google's web-based PKCE flow — no API key needed. Click Authorize to open the Google consent screen.")
                    .font(.system(size: DesignToken.captionSize))
                    .foregroundStyle(Color.dsTextTertiary)
                @ObservedObject var oauth = geminiOAuth
                HStack(spacing: 8) {
                    if geminiOAuth.isAuthorized {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.dsGreen)
                        Text("Authorized")
                            .font(.system(size: DesignToken.caption2Size))
                            .foregroundStyle(Color.dsGreen)
                    } else if geminiOAuth.isAuthorizing {
                        ProgressView().controlSize(.small)
                        Text("Waiting for Google consent…")
                            .font(.system(size: DesignToken.caption2Size))
                            .foregroundStyle(Color.dsTextTertiary)
                    } else {
                        verificationIndicator(providerChecks["gemini-oauth"] ?? .unknown)
                    }

                    if geminiOAuth.isAuthorized {
                        Button("Sign Out") {
                            geminiOAuth.signOut()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .font(.system(size: DesignToken.caption2Size))
                    } else {
                        Button("Authorize with Google") {
                            Task { await geminiOAuth.authorize() }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .font(.system(size: DesignToken.caption2Size))
                        .disabled(geminiOAuth.isAuthorizing)
                    }

                    if provider == "gemini-oauth" {
                        Text("Default")
                            .font(.system(size: DesignToken.caption2Size, weight: .semibold))
                            .foregroundStyle(Color.dsGreen)
                    }
                }
                if let error = geminiOAuth.authError {
                    Text(error)
                        .font(.system(size: DesignToken.caption2Size))
                        .foregroundStyle(Color.dsRed)
                        .lineLimit(2)
                }

                // Custom OAuth client ID — Google blocks the shared community
                // client ID ("This app is blocked"). A client the user creates
                // in their own Google Cloud project is never blocked.
                labeledField("OAuth Client ID (optional)", caption: "Google blocks the bundled community client ID. Create your own Desktop-app OAuth client in Google Cloud Console and paste it here — your own client is never blocked.", savedID: "geminiOAuthClientId") {
                    TextField("619142661668-….apps.googleusercontent.com", text: $geminiOAuthClientId)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: DesignToken.caption2Size, design: .monospaced))
                        .onChange(of: geminiOAuthClientId) { _, newValue in
                            GeminiOAuthManager.shared.setClientId(newValue)
                        }
                    HStack(spacing: 8) {
                        Button("Open Google Cloud Console") {
                            if let url = URL(string: "https://console.cloud.google.com/apis/credentials") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: DesignToken.caption2Size))
                        .foregroundStyle(Color.dsAccent)
                        .help("Open Cloud Console → APIs & Services → Credentials to create an OAuth client ID")

                        Button("Reset to Default") {
                            geminiOAuthClientId = ""
                            GeminiOAuthManager.shared.setClientId("")
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: DesignToken.caption2Size))
                        .foregroundStyle(Color.dsRed)
                        .help("Reset to the bundled community client ID (may be blocked by Google)")
                    }
                    Text("Steps: Create OAuth client ID → Desktop app → copy the client ID → paste above. The Generative Language API must be enabled in your Google Cloud project.")
                        .font(.system(size: DesignToken.caption2Size))
                        .foregroundStyle(Color.dsTextTertiary)
                }
            }

            Divider().padding(.vertical, DesignToken.spacing4)

            sectionGroup("Endpoints (Local Runtime & Gateway)") {
                Text("Configure your local model runtime (Llama.app, LM Studio, Ollama) and upstream OpenAI-compatible gateway. JXProxy auto-detects active local models and keeps them synced.")
                    .font(.system(size: DesignToken.captionSize))
                    .foregroundStyle(Color.dsTextTertiary)

                // Quick runtime selector chips
                HStack(spacing: 8) {
                    let livePort = LocalServerDiscovery.liveLlamaPort()
                    Button {
                        localBaseUrl = "http://127.0.0.1:\(livePort)/v1"
                        saveConfigImmediately()
                        Task { await fetchLocalEndpointModels() }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "desktopcomputer")
                            Text("Llama.app (:\(livePort))")
                        }
                        .font(.system(size: DesignToken.caption2Size, weight: localBaseUrl.contains(":\(livePort)") ? .bold : .regular))
                    }
                    .buttonStyle(.bordered)
                    .tint(localBaseUrl.contains(":\(livePort)") ? Color.dsAccent : Color.secondary)

                    Button {
                        localBaseUrl = "http://127.0.0.1:1234/v1"
                        saveConfigImmediately()
                        Task { await fetchLocalEndpointModels() }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "cpu")
                            Text("LM Studio (:1234)")
                        }
                        .font(.system(size: DesignToken.caption2Size, weight: localBaseUrl.contains(":1234") ? .bold : .regular))
                    }
                    .buttonStyle(.bordered)
                    .tint(localBaseUrl.contains(":1234") ? Color.dsAccent : Color.secondary)

                    Button {
                        localBaseUrl = "http://127.0.0.1:11434/v1"
                        saveConfigImmediately()
                        Task { await fetchLocalEndpointModels() }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "shippingbox")
                            Text("Ollama (:11434)")
                        }
                        .font(.system(size: DesignToken.caption2Size, weight: localBaseUrl.contains(":11434") ? .bold : .regular))
                    }
                    .buttonStyle(.bordered)
                    .tint(localBaseUrl.contains(":11434") ? Color.dsAccent : Color.secondary)

                    Spacer()

                    if isFetchingLocalEndpointModels {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Button {
                            Task { await fetchLocalEndpointModels() }
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                                .font(.system(size: DesignToken.caption2Size))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.dsAccent)
                    }
                }

                if !localEndpointStatus.isEmpty {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(localEndpointStatus.hasPrefix("Connected") ? Color.dsGreen : Color.dsOrange)
                            .frame(width: 6, height: 6)
                        Text(localEndpointStatus)
                            .font(.system(size: DesignToken.caption2Size))
                            .foregroundStyle(Color.dsTextSecondary)
                    }
                    .padding(.vertical, 2)
                }

                labeledField("Local Inference Base URL", caption: "Active endpoint for local LLM inference (Llama.app, LM Studio, Ollama)", savedID: "localBaseUrl") {
                    TextField("http://127.0.0.1:9931/v1", text: $localBaseUrl)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            saveConfigImmediately()
                            Task { await fetchLocalEndpointModels() }
                        }
                }

                labeledField("Local Inference Model", caption: "Active model served by the local runtime", savedID: "localModel") {
                    VStack(alignment: .leading, spacing: 6) {
                        if !localEndpointModels.isEmpty {
                            Picker("Discovered Models", selection: $localModel) {
                                ForEach(localEndpointModels, id: \.self) { mid in
                                    Text(mid).tag(mid)
                                }
                            }
                            .pickerStyle(.menu)
                            .onChange(of: localModel) {
                                saveConfigImmediately()
                            }
                        }
                        TextField("e.g. local/ornith:Q8_0", text: $localModel)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit {
                                saveConfigImmediately()
                            }
                    }
                }

                labeledField("OpenAI-Compatible Base URL", caption: "Fallback endpoint for upstream OpenAI-compatible calls", savedID: "openaiBaseUrl") {
                    TextField("https://api.openai.com/v1", text: $openaiBaseUrl)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            saveConfigImmediately()
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

            Divider().padding(.vertical, DesignToken.spacing4)

            // Model Health Check — test all registered providers' models
            sectionGroup("Model Health Check") {
                Text("Test every model from your configured providers for connectivity. Results are sorted by response speed (fastest first).")
                    .font(.system(size: DesignToken.captionSize))
                    .foregroundStyle(Color.dsTextTertiary)

                HStack(spacing: 8) {
                    Button {
                        Task { await runModelHealthCheck() }
                    } label: {
                        Label(isRunningHealthCheck ? "Testing…" : "Test All Models",
                              systemImage: isRunningHealthCheck ? "hourglass" : "bolt.circle.fill")
                            .font(.system(size: DesignToken.captionSize, weight: .medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(isRunningHealthCheck)

                    if isRunningHealthCheck {
                        ProgressView().controlSize(.small)
                        Text(healthCheckProgress)
                            .font(.system(size: DesignToken.caption2Size))
                            .foregroundStyle(Color.dsTextTertiary)
                    } else if !modelHealthResults.isEmpty {
                        Text("\(modelHealthResults.filter { $0.status == .healthy || $0.status == .rateLimited }.count)/\(modelHealthResults.count) healthy")
                            .font(.system(size: DesignToken.caption2Size))
                            .foregroundStyle(Color.dsGreen)
                    }
                    Spacer()
                }

                if !modelHealthResults.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(modelHealthResults) { result in
                            modelHealthRow(result)
                            if result.id != modelHealthResults.last?.id {
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
                } else if !isRunningHealthCheck {
                    Text("Click \"Test All Models\" to check connectivity for every configured provider.")
                        .font(.system(size: DesignToken.caption2Size))
                        .foregroundStyle(Color.dsTextTertiary)
                }
            }
        }
    }

    // MARK: - Model Health Check

    /// Test every model from configured providers for connectivity.
    /// Results are sorted by latency (fastest first).
    private func runModelHealthCheck() async {
        isRunningHealthCheck = true
        modelHealthResults = []
        healthCheckProgress = "Collecting models…"

        // Gather all unique (provider, model) pairs from presets + live fetches.
        var targets: [(pid: String, name: String, model: String)] = []
        var seen = Set<String>()

        for preset in ProviderPreset.all where preset.requiresKey || preset.id == "opencode-zen" || preset.id == "opencode-go" {
            let key = apiKeyForProvider(preset.id)
            if !preset.requiresKey || !key.isEmpty {
                let base = config.baseUrl(for: preset.id)
                guard !base.isEmpty else { continue }
                for m in preset.models {
                    let bare = ProviderPreset.bareModel(m, for: preset.id)
                    let key2 = "\(preset.id)|\(bare)"
                    if !seen.contains(key2) {
                        seen.insert(key2)
                        targets.append((preset.id, preset.name, bare))
                    }
                }
            }
        }
        // Include custom providers
        for def in customProviders {
            let key = apiKeyForProvider(def.id)
            guard !key.isEmpty || !config.baseUrl(for: def.id).isEmpty else { continue }
            // Try to fetch models for custom providers
            if let models = tierLiveModels["custom-\(def.id)"], !models.isEmpty {
                for m in models {
                    let bare = ProviderPreset.bareModel(m, for: def.id)
                    let key2 = "\(def.id)|\(bare)"
                    if !seen.contains(key2) {
                        seen.insert(key2)
                        targets.append((def.id, def.name, bare))
                    }
                }
            }
        }

        guard !targets.isEmpty else {
            isRunningHealthCheck = false
            healthCheckProgress = ""
            return
        }

        // Test each model concurrently (max 8 at a time to avoid hammering).
        let semaphore = AsyncSemaphore(count: 8)
        var results: [ModelHealthResult] = []
        let resultsLock = NSLock()

        // Snapshot the per-target auth data on the main actor BEFORE fanning
        // out: apiKeyForProvider and config are MainActor-isolated and cannot
        // be touched from the task-group closures (an error in the Swift 6
        // language mode).
        let authedTargets = targets.map { target -> (pid: String, name: String, model: String, key: String, base: String) in
            (target.pid, target.name, target.model, apiKeyForProvider(target.pid), config.baseUrl(for: target.pid))
        }

        await withTaskGroup(of: ModelHealthResult?.self) { group in
            for target in authedTargets {
                group.addTask {
                    await semaphore.wait()
                    defer { semaphore.signal() }

                    let pid = target.pid
                    let key = target.key
                    let base = target.base
                    let startTime = Date()

                    let check = await ProviderValidator.validateModel(
                        providerId: pid,
                        model: target.model,
                        apiKey: key,
                        baseUrl: base
                    )
                    let elapsed = Date().timeIntervalSince(startTime) * 1000

                    await MainActor.run {
                        healthCheckProgress = "Testing \(target.model)…"
                    }

                    return ModelHealthResult(
                        providerId: pid,
                        providerName: target.name,
                        model: target.model,
                        status: check.ok ? .healthy : (check.message.contains("429") ? .rateLimited : .unhealthy(check.message)),
                        latencyMs: check.ok ? elapsed : nil,
                        errorMessage: check.ok ? nil : check.message
                    )
                }
            }
            for await result in group {
                if let result {
                    // Scoped locking — raw lock()/unlock() is unavailable from
                    // async contexts in the Swift 6 language mode.
                    resultsLock.withLock {
                        results.append(result)
                    }
                }
            }
        }

        // Sort: healthy first (by latency), then rate-limited, then unhealthy.
        modelHealthResults = results.sorted { a, b in
            switch (a.status, b.status) {
            case (.healthy, .healthy):
                return (a.latencyMs ?? 99999) < (b.latencyMs ?? 99999)
            case (.healthy, _):
                return true
            case (_, .healthy):
                return false
            case (.rateLimited, .unhealthy):
                return true
            case (.unhealthy, .rateLimited):
                return false
            default:
                return a.model < b.model
            }
        }
        isRunningHealthCheck = false
        healthCheckProgress = ""
    }

    @ViewBuilder
    private func modelHealthRow(_ result: ModelHealthResult) -> some View {
        HStack(spacing: 8) {
            // Status icon
            switch result.status {
            case .checking:
                ProgressView().controlSize(.mini)
            case .healthy:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.dsGreen)
            case .unhealthy:
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.dsRed)
            case .rateLimited:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.dsOrange)
            }

            // Provider name
            Text(result.providerName)
                .font(.system(size: DesignToken.caption2Size, weight: .medium))
                .foregroundStyle(Color.dsTextSecondary)
                .frame(width: 100, alignment: .leading)

            // Model name
            Text(result.model)
                .font(.system(size: DesignToken.caption2Size, design: .monospaced))
                .foregroundStyle(Color.dsTextPrimary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            // Latency or error
            switch result.status {
            case .healthy:
                if let ms = result.latencyMs {
                    Text(String(format: "%.0fms", ms))
                        .font(.system(size: DesignToken.caption2Size, design: .monospaced))
                        .foregroundStyle(ms < 500 ? Color.dsGreen : (ms < 2000 ? Color.dsOrange : Color.dsRed))
                }
            case .rateLimited:
                Text("Rate limited")
                    .font(.system(size: DesignToken.caption2Size))
                    .foregroundStyle(Color.dsOrange)
            case .unhealthy(let msg):
                Text(msg)
                    .font(.system(size: DesignToken.caption2Size))
                    .foregroundStyle(Color.dsRed)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(msg)
            case .checking:
                EmptyView()
            }
        }
        .padding(.horizontal, DesignToken.spacing12)
        .padding(.vertical, DesignToken.spacing6)
    }

    private var routingTab: some View {
        VStack(alignment: .leading, spacing: DesignToken.spacing20) {
            sectionGroup("App Routing Rules") {
                Text("Choose which apps route through JXProxy. Drag .app files from Finder to add rules. \"Pass Through OpenAI\" lets an app (e.g. Codex) use the real OpenAI API even when Route OpenAI is on — other AI traffic from that app still routes.")
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
                        // Value-based rows (no ForEach($appRoutes) bindings):
                        // mutations go through id lookups, so a delete can
                        // never leave a dangling binding behind — that dangling
                        // copy crashed the app (SIGSEGV in AppRuleRow during
                        // view-graph updates).
                        ForEach(appRoutes) { rule in
                            AppRuleRow(
                                rule: rule,
                                onEnabledChange: { newValue in
                                    if let idx = appRoutes.firstIndex(where: { $0.id == rule.id }) {
                                        appRoutes[idx].enabled = newValue
                                    }
                                },
                                onActionChange: { newValue in
                                    if let idx = appRoutes.firstIndex(where: { $0.id == rule.id }) {
                                        appRoutes[idx].action = newValue
                                    }
                                },
                                onDelete: {
                                    appRoutes.removeAll { $0.id == rule.id }
                                }
                            )
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

    /// One selectable theme card: swatch strip + name, check-marked when
    /// active. Tapping applies the theme app-wide immediately.
    private func themeCard(_ theme: Theme) -> some View {
        let isActive = ThemeController.shared.currentThemeId == theme.id
        return Button {
            ThemeController.shared.setTheme(theme)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                // Swatch strip: background, surface, raised, accent, sky.
                HStack(spacing: 3) {
                    ForEach([theme.background, theme.surface, theme.surfaceRaised,
                             theme.accent, theme.sky], id: \.light) { role in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color(nsColor: role.dark))
                            .frame(width: 16, height: 22)
                    }
                }
                HStack(spacing: 4) {
                    Text(theme.name)
                        .font(.system(size: DesignToken.caption2Size, weight: .medium))
                        .foregroundStyle(Color.dsTextPrimary)
                    if isActive {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(Color.dsAccent)
                    }
                }
            }
            .padding(8)
            .frame(width: 118, alignment: .leading)
            .background(isActive ? Color.dsAccentDim : Color.dsSurface)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isActive ? Color.dsAccent : Color.dsBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help("Apply the \(theme.name) theme")
    }

    private var systemTab: some View {
        VStack(alignment: .leading, spacing: DesignToken.spacing20) {
            // Theme & Appearance controls
            sectionGroup("Theme & Appearance") {
                VStack(alignment: .leading, spacing: DesignToken.spacing12) {
                    // Appearance Mode (Light / Dark / System)
                    HStack(spacing: DesignToken.spacing12) {
                        Text("Appearance")
                            .font(.system(size: DesignToken.subheadSize, weight: .medium))
                            .foregroundStyle(Color.dsTextPrimary)

                        Picker("", selection: Binding(
                            get: { AppearanceController.shared.mode },
                            set: { AppearanceController.shared.mode = $0 }
                        )) {
                            Text("System").tag(AppearanceMode.system)
                            Text("Light").tag(AppearanceMode.light)
                            Text("Dark").tag(AppearanceMode.dark)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 220)

                        Spacer()
                    }

                    // Theme palette cards
                    VStack(alignment: .leading, spacing: DesignToken.spacing6) {
                        Text("Color Palette")
                            .font(.system(size: DesignToken.captionSize, weight: .medium))
                            .foregroundStyle(Color.dsTextSecondary)

                        HStack(spacing: DesignToken.spacing8) {
                            ForEach(Theme.all) { theme in
                                themeCard(theme)
                            }
                            Spacer()
                        }
                    }

                    Text("Themes customize the semantic palette (JX Default or Opcode Dark/Light). Appearance toggles Light/Dark mode. Changes apply immediately across all windows.")
                        .font(.system(size: DesignToken.caption2Size))
                        .foregroundStyle(Color.dsTextTertiary)
                }
            }

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

                HStack(spacing: 8) {
                    Toggle(isOn: $routeOpenAI) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Route OpenAI connections")
                                .font(.system(size: DesignToken.bodySize))
                            Text("Intercept api.openai.com (Codex, OpenAI SDK clients) and route it through your configured providers. Turn off to let OpenAI traffic pass through unmodified — Claude (Anthropic) routing is unaffected.")
                                .font(.system(size: DesignToken.caption2Size))
                                .foregroundStyle(Color.dsTextTertiary)
                        }
                    }
                    .toggleStyle(.switch)
                    savedFieldCheckmark("routeOpenAI")
                }
                .onChange(of: routeOpenAI) { _, _ in scheduleAutoSave() }

                Text("Routes every app's HTTP/HTTPS traffic through JXProxy. Anthropic (api.anthropic.com) and OpenAI (api.openai.com) connections are routed through your configured providers — every other request passes through unmodified. Claude Code is routed automatically via its settings and doesn't need this. HTTPS interception requires trusting the JXProxy CA (menu-bar icon → Security → Install CA Certificate).")
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

            sectionGroup("Remote Web Control") {
                HStack(spacing: 8) {
                    Toggle(isOn: $webControlEnabled) {
                        Text("Enable Remote Web Control")
                            .font(.system(size: DesignToken.bodySize))
                    }
                    .toggleStyle(.switch)
                    savedFieldCheckmark("webControlEnabled")
                }
                .onChange(of: webControlEnabled) { _, _ in scheduleAutoSave() }

                if webControlEnabled {
                    labeledField("Web Port") {
                        TextField("5355", text: $webControlPort)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                            .onChange(of: webControlPort) { _, _ in scheduleAutoSave() }
                    }
                    Text("Serves the JXProxy control panel + JSON API on your LAN for the iOS/Android web-wrapper apps. Point them at http://<this Mac's IP>:\(webControlPort.isEmpty ? "5355" : webControlPort) and sign in with the proxy auth token (Settings → General). Requests are token-authenticated, but the port is reachable on your network — only enable on trusted Wi-Fi.")
                        .font(.system(size: DesignToken.captionSize))
                        .foregroundStyle(Color.dsTextTertiary)
                }
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

    /// Composite hash of all editable settings – observed to detect unsaved
    /// changes. Implemented with `Hasher` (not string concatenation) so the
    /// per-keystroke recompute during body evaluation stays cheap — the old
    /// string-building version ran on every render and contributed to the
    /// interaction lag.
    private var settingsHash: Int {
        var hasher = Hasher()
        hasher.combine(port)
        hasher.combine(authToken)
        hasher.combine(model)
        hasher.combine(enableThinking)
        hasher.combine(reasoningPolicies.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.rawValue)" })
        hasher.combine(provider)
        hasher.combine(fallbackProviders)
        hasher.combine(tierProviders.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" })
        hasher.combine(modelOpus)
        hasher.combine(modelSonnet)
        hasher.combine(modelHaiku)
        hasher.combine(openaiBaseUrl)
        hasher.combine(localBaseUrl)
        hasher.combine(localModel)
        hasher.combine(ggufModelPath)
        hasher.combine(ggufModelAlias)
        hasher.combine(ggufGpuLayers)
        hasher.combine(ggufContextSize)
        hasher.combine(ggufPort)
        hasher.combine(providerUrlOverrides.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" })
        hasher.combine(enableSystemProxy)
        hasher.combine(appRoutes.map { "\($0.bundleIdentifier ?? "")|\($0.appName)|\($0.enabled)" })
        hasher.combine(anthropicKey)
        hasher.combine(openaiKey)
        hasher.combine(openrouterKey)
        hasher.combine(opencodeKey)
        hasher.combine(nvidiaKey)
        hasher.combine(deepseekKey)
        hasher.combine(geminiKey)
        hasher.combine(mistralKey)
        hasher.combine(codestralKey)
        hasher.combine(cohereKey)
        hasher.combine(groqKey)
        hasher.combine(fireworksKey)
        hasher.combine(sambanovaKey)
        hasher.combine(cerebrasKey)
        hasher.combine(huggingfaceKey)
        hasher.combine(xaiKey)
        hasher.combine(antigravityKey)
        hasher.combine(customUrl)
        hasher.combine(customKey)
        hasher.combine(customProviders
            .sorted(by: { $0.id < $1.id })
            .map { "\($0.id)|\($0.name)|\($0.baseUrl)|\(customProviderKeys[$0.id] ?? "")" })
        hasher.combine(botIntegrationEnabled)
        hasher.combine(telegramBotToken)
        hasher.combine(routeOpenAI)
        return hasher.finalize()
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
        openaiBaseUrl = config.openaiBaseUrl
        localBaseUrl = config.localLlmBaseUrl
        localModel = config.localLlmModel
        if localModel == "ollama/qwen3:latest" {
            let active = config.model
            if !active.isEmpty && (active.hasPrefix("local/") || active.hasPrefix("llamaapp/")) {
                localModel = active
            } else {
                localModel = "local/ornith:Q8_0"
            }
        }
        if localBaseUrl == "http://127.0.0.1:11434/v1" {
            let livePort = LocalServerDiscovery.liveLlamaPort()
            localBaseUrl = "http://127.0.0.1:\(livePort)/v1"
        }
        ggufModelPath = config.ggufModelPath
        ggufModelAlias = config.ggufModelAlias
        ggufGpuLayers = config.ggufGpuLayers
        ggufContextSize = config.ggufContextSize
        ggufPort = String(config.ggufPort)
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
        reloadApiKeysFromConfig()
        enableSystemProxy = manager.systemProxyEnabled
        routeOpenAI = config.routeOpenAI
        webControlEnabled = config.webControlEnabled
        webControlPort = String(config.webControlPort)
        botIntegrationEnabled = config.botIntegrationEnabled
        telegramBotToken = config.getApiKey(chainKey: ConfigManager.KeychainKey.telegramBotToken)
        geminiOAuthClientId = UserDefaults.standard.string(forKey: GeminiOAuthManager.clientIdDefaultsKey) ?? ""
        loadAppRoutesFromConfig()
    }

    /// Reload only the API-key fields from the Keychain (shell-config imports
    /// land there). Shared by `loadFromConfig()`, the live ~/.zshrc watcher,
    /// and the "Detect keys from ~/.zshrc" button — so a key detected while
    /// the panel is open appears in its field immediately.
    private func reloadApiKeysFromConfig() {
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
        antigravityKey = config.apiKey(for: "antigravity")
        customKey = config.apiKey(for: "custom")
        customProviderKeys = [:]
        for def in customProviders {
            customProviderKeys[def.id] = config.apiKey(for: def.id)
        }
        // The reloaded fields now match the persisted state — don't flash a
        // spurious checkmark (or trigger a redundant auto-save) for them.
        lastSavedValues = currentFieldValues()
    }

    /// "Detect keys from ~/.zshrc" — re-scan the shell configs and show what
    /// was imported (or that everything was already saved).
    private func detectKeysFromShellConfigs() {
        let imported = config.importKeysFromShellConfigs()
        reloadApiKeysFromConfig()
        if imported.isEmpty {
            flashShellImport("No new keys found in ~/.zshrc — everything you have is already saved.")
        } else {
            flashShellImport("Imported from ~/.zshrc: \(imported.joined(separator: ", "))")
        }
    }

    /// Show a transient detection-feedback message under the provider buttons.
    private func flashShellImport(_ message: String) {
        shellImportFlashTask?.cancel()
        shellImportFlash = message
        shellImportFlashTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            shellImportFlash = nil
        }
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
        config.ggufModelPath = ggufModelPath
        config.ggufModelAlias = ggufModelAlias
        config.ggufGpuLayers = ggufGpuLayers
        config.ggufContextSize = ggufContextSize
        if let ggufPortVal = Int(ggufPort) { config.ggufPort = ggufPortVal }
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

        // API keys are written ONLY when their value actually changed since the
        // last save. Every `setApiKey` is a blocking Keychain round-trip (up to
        // 3s each when the Keychain daemon stalls), so writing all ~40 keys on
        // every debounced save — i.e. every keystroke — was the interaction
        // lag: each edit triggered a full Keychain write storm on the main
        // actor. The diff keeps the autosave fast while staying exact.
        let current = currentFieldValues()
        let keyWrites: [(field: String, chainKey: String)] = [
            ("key:direct", ConfigManager.KeychainKey.anthropic),
            ("key:openai", ConfigManager.KeychainKey.openai),
            ("key:openrouter", ConfigManager.KeychainKey.openrouter),
            ("key:opencode-zen", ConfigManager.KeychainKey.opencode),
            ("key:nvidia-nim", ConfigManager.KeychainKey.nvidia),
            ("key:deepseek", ConfigManager.KeychainKey.deepseek),
            ("key:gemini", ConfigManager.KeychainKey.gemini),
            ("key:mistral", ConfigManager.KeychainKey.mistral),
            ("key:codestral", ConfigManager.KeychainKey.codestral),
            ("key:cohere", ConfigManager.KeychainKey.cohere),
            ("key:groq", ConfigManager.KeychainKey.groq),
            ("key:fireworks", ConfigManager.KeychainKey.fireworks),
            ("key:sambanova", ConfigManager.KeychainKey.sambanova),
            ("key:cerebras", ConfigManager.KeychainKey.cerebras),
            ("key:huggingface", ConfigManager.KeychainKey.huggingface),
            ("key:xai", ConfigManager.KeychainKey.xai),
            ("key:antigravity", ConfigManager.KeychainKey.antigravity),
        ]
        for write in keyWrites {
            let value = current[write.field] ?? ""
            if lastSavedValues[write.field] != value || config.getApiKey(chainKey: write.chainKey) != value {
                config.setApiKey(chainKey: write.chainKey, value: value)
            }
        }
        if lastSavedValues["customKey"] != customKey || config.getApiKey(chainKey: ConfigManager.KeychainKey.custom) != customKey {
            config.setApiKey(chainKey: ConfigManager.KeychainKey.custom, value: customKey)
        }
        for def in customProviders {
            let value = customProviderKeys[def.id] ?? ""
            let field = "customProvider:\(def.id)"
            let chainKey = ConfigManager.customProviderKey(def.id)
            if lastSavedValues[field] != "\(def.name)|\(def.baseUrl)|\(value)" || config.getApiKey(chainKey: chainKey) != value {
                config.setApiKey(chainKey: chainKey, value: value)
            }
        }
        if !geminiOAuthClientId.isEmpty {
            GeminiOAuthManager.shared.setClientId(geminiOAuthClientId)
        }
        config.botIntegrationEnabled = botIntegrationEnabled
        if botIntegrationEnabled {
            config.setApiKey(chainKey: ConfigManager.KeychainKey.telegramBotToken, value: telegramBotToken)
        }
        config.routeOpenAI = routeOpenAI
        config.webControlEnabled = webControlEnabled
        if let webPort = Int(webControlPort) { config.webControlPort = webPort }

        saveAppRoutesToConfig()
        // Lightweight sync only: `manager.loadAllFromConfig()` re-reads EVERY
        // provider key from the Keychain and rebuilds the providers array,
        // whose didSet triggers another debounced flushSave (another ~40
        // Keychain writes) — the full chain ran on every auto-save. The
        // settings just written are already in ConfigManager, so syncing the
        // proxy's port/auth/config caches is sufficient and fast.
        manager.syncFromConfig()
        manager.applyWebControl()
    }

    /// Immediately flush and persist all settings to ConfigManager and Keychain.
    /// Cancels any debounced autoSaveTask, writes config, updates lastSavedValues,
    /// and flushes UserDefaults to disk so changes are never lost on window close.
    private func saveConfigImmediately() {
        autoSaveTask?.cancel()
        saveConfig()
        let current = currentFieldValues()
        let changed = Set(current.compactMap { key, value in
            lastSavedValues[key] == value ? nil : key
        })
        lastSavedValues = current
        if !changed.isEmpty {
            savedFieldFlash = changed
            savedFieldFlashTask?.cancel()
            savedFieldFlashTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                guard !Task.isCancelled else { return }
                savedFieldFlash = []
            }
        }
        UserDefaults.standard.synchronize()
    }

    /// Auto-save: persist all settings shortly after the last edit so nothing
    /// is ever lost between an edit and an explicit Save (there is none).
    /// Uses a tight 200ms debounce and flushes immediately.
    private func scheduleAutoSave() {
        autoSaveTask?.cancel()
        let snapshotGeneration = saveGeneration
        autoSaveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            // Skip this save if a newer edit arrived while the debounce was sleeping.
            guard saveGeneration == snapshotGeneration else { return }
            saveConfigImmediately()

            // Flash the "Saved ✓" indicator
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
            }
        }
    }

    /// Live query of local endpoint models (e.g. Llama.app :9931, LM Studio :1234, Ollama :11434).
    private func fetchLocalEndpointModels() async {
        guard !isFetchingLocalEndpointModels else { return }
        isFetchingLocalEndpointModels = true
        defer { isFetchingLocalEndpointModels = false }

        let trimmedUrl = localBaseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmedUrl.hasSuffix("/") ? "\(trimmedUrl)models" : "\(trimmedUrl)/models") else {
            localEndpointStatus = "Invalid URL"
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 2.0
        request.httpMethod = "GET"

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                localEndpointStatus = "Offline / Unreachable"
                return
            }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let list = json["data"] as? [[String: Any]] {
                var modelIds: [String] = []
                var loadedModel: String?
                for item in list {
                    if let id = item["id"] as? String {
                        modelIds.append(id)
                        if let status = item["status"] as? [String: Any],
                           (status["value"] as? String) == "loaded" {
                            loadedModel = id
                        }
                    }
                }
                localEndpointModels = modelIds
                if !modelIds.isEmpty {
                    let count = modelIds.count
                    localEndpointStatus = "Connected (\(count) model\(count == 1 ? "" : "s") found)"
                    if localModel.isEmpty || localModel == "ollama/qwen3:latest" {
                        localModel = loadedModel ?? modelIds.first ?? "local/ornith:Q8_0"
                        saveConfigImmediately()
                    }
                } else {
                    localEndpointStatus = "Connected (no models reported)"
                }
            } else {
                localEndpointStatus = "Connected (unrecognized format)"
            }
        } catch {
            localEndpointStatus = "Offline"
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
        values["fallbackProviders"] = fallbackProviders
        values["model"] = model
        values["enableThinking"] = String(enableThinking)
        values["openaiBaseUrl"] = openaiBaseUrl
        values["localBaseUrl"] = localBaseUrl
        values["localModel"] = localModel
        values["ggufModelPath"] = ggufModelPath
        values["ggufModelAlias"] = ggufModelAlias
        values["ggufGpuLayers"] = String(ggufGpuLayers)
        values["ggufContextSize"] = String(ggufContextSize)
        values["ggufPort"] = ggufPort
        values["customUrl"] = customUrl
        values["customKey"] = customKey
        values["enableSystemProxy"] = String(enableSystemProxy)
        values["routeOpenAI"] = String(routeOpenAI)
        values["webControlEnabled"] = String(webControlEnabled)
        values["webControlPort"] = webControlPort
        values["botIntegration"] = String(botIntegrationEnabled)
        values["appRoutes"] = appRoutes.map { "\($0.bundleIdentifier ?? "")\($0.appName)\($0.enabled)" }.joined(separator: ",")
        // API keys — one id per provider.
        for (pid, key) in [            ("direct", anthropicKey), ("openai", openaiKey), ("openrouter", openrouterKey),
            ("opencode-zen", opencodeKey), ("nvidia-nim", nvidiaKey), ("deepseek", deepseekKey),
            ("gemini", geminiKey), ("mistral", mistralKey), ("codestral", codestralKey),
            ("cohere", cohereKey), ("groq", groqKey), ("fireworks", fireworksKey),
            ("sambanova", sambanovaKey), ("cerebras", cerebrasKey), ("huggingface", huggingfaceKey), ("xai", xaiKey), ("antigravity", antigravityKey), ("custom", customKey),
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
        fallbackProviders = ""
        tierProviders = [:]
        tierLiveModels = [:]
        tierFetchStates = [:]
        // Model defaults are populated from the provider preset when one is selected
        model = providerPreset(provider)?.models.first ?? ""
        modelOpus = ""
        modelSonnet = ""
        modelHaiku = ""
        openaiBaseUrl = "https://api.openai.com/v1"
        localBaseUrl = "http://127.0.0.1:\(LocalServerDiscovery.liveLlamaPort())/v1"
        localModel = "local/ornith:Q8_0"
        ggufModelPath = ""
        ggufModelAlias = "local-model"
        ggufGpuLayers = 0
        ggufContextSize = 0
        ggufPort = "8081"
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
        antigravityKey = ""
        enableSystemProxy = false
        routeOpenAI = true
        appRoutes = []
        webControlEnabled = false
        webControlPort = "5355"
        botIntegrationEnabled = false
        telegramBotToken = ""
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

    /// Quick "Run Local Model" for the General tab's local provider panel:
    /// maps the selected preset to the local server provider, then runs the
    /// one-click flow (auto-detect model → start in background, or onboarding).
    private func runLocalModel() {
        let mgr = LocalModelManager.shared
        let newProvider: LocalModelManager.LocalProvider = provider == "ollama" ? .ollama : .llamaapp
        // Only reset the port when the provider actually changes, so a custom
        // port isn't clobbered by re-tapping Run.
        if mgr.provider != newProvider {
            mgr.provider = newProvider
            mgr.port = newProvider.defaultPort
        }
        onboardingProvider = mgr.provider

        switch mgr.readiness() {
        case .needsInstall:
            showLocalOnboarding = true
        case .ready:
            Task {
                await mgr.start()
                await fetchTierModels(for: .defaultModel)
            }
        }
    }

    // MARK: - Fallback Providers

    /// The current fallback chain as a list of provider ids, in priority order.
    private var fallbackList: [String] {
        fallbackProviders
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Add/remove a provider from the fallback chain (append keeps priority order).
    private func toggleFallback(_ pid: String) {
        var list = fallbackList
        if let idx = list.firstIndex(of: pid) {
            list.remove(at: idx)
        } else {
            list.append(pid)
        }
        fallbackProviders = list.joined(separator: ",")
    }

    /// Multi-select control for the automatic provider fallback chain: if the
    /// active provider fails (bad model, auth error, rate limit), JXProxy
    /// retries each selected fallback in order before giving up.
    private var fallbackControl: some View {
        let current = fallbackList
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Fallback Providers")
                    .font(.system(size: DesignToken.captionSize))
                    .foregroundStyle(Color.dsTextSecondary)
                savedFieldCheckmark("fallbackProviders")
                Spacer()
            }
            Menu {
                ForEach(availableProviders.filter { $0.id != provider }) { preset in
                    Button {
                        toggleFallback(preset.id)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: preset.symbol)
                                .frame(width: 14, height: 14)
                            Text(preset.name)
                            Spacer()
                            if current.contains(preset.id) {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.dsAccent)
                            }
                        }
                    }
                }
                if availableProviders.filter({ $0.id != provider }).isEmpty {
                    Button("No other providers configured") {}.disabled(true)
                }
            } label: {
                HStack(spacing: 6) {
                    Text(current.isEmpty
                        ? "None — route only through the primary provider"
                        : current.map { providerPreset($0)?.name ?? $0 }.joined(separator: " → "))
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
            Text("If the active provider fails (bad model, auth error, rate limit), requests automatically retry each fallback in order.")
                .font(.system(size: DesignToken.caption2Size))
                .foregroundStyle(Color.dsTextTertiary)
        }
    }

    /// Providers whose local server JXProxy can launch in the background.
    /// (LM Studio runs itself, so it is excluded.)
    private var isLocalAutoProvider: Bool {
        provider == "ollama" || provider == "llamaapp" || provider == "gguf"
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
            // Live feedback for the auto-fetch: spinner while in flight, a
            // failure reason + Retry when the provider can't be reached, and a
            // short confirmation once models land — the dropdown never looks
            // silently broken.
            modelFetchStatus(for: tier, providerId: pid)
        }
        .padding(10)
        .background(Color.dsSurface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.dsBorder, lineWidth: 1)
        )
    }

    /// Live feedback for a tier's model-list auto-fetch: a spinner while the
    /// request is in flight, a failure reason + Retry when the provider can't
    /// be reached, and a short confirmation caption once models have landed.
    @ViewBuilder
    private func modelFetchStatus(for tier: TierKey, providerId: String) -> some View {
        switch tierFetchStates[tier.rawValue] ?? .idle {
        case .idle:
            EmptyView()
        case .fetching:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.mini)
                Text("Fetching models…")
                    .font(.system(size: DesignToken.caption2Size))
                    .foregroundStyle(Color.dsTextTertiary)
            }
        case .failed(let reason):
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.dsOrange)
                Text(reason)
                    .font(.system(size: DesignToken.caption2Size))
                    .foregroundStyle(Color.dsTextSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(reason)
                Button("Retry") {
                    Task { await fetchTierModels(for: tier) }
                }
                .buttonStyle(.plain)
                .font(.system(size: DesignToken.caption2Size))
                .foregroundStyle(Color.dsAccent)
                .accessibilityLabel("Retry fetching models for \(tier.displayName)")
            }
        case .loaded:
            if let models = tierLiveModels[tier.rawValue], !models.isEmpty {
                Text("\(models.count) model\(models.count == 1 ? "" : "s") auto-fetched from \(providerPreset(providerId)?.name ?? providerId)")
                    .font(.system(size: DesignToken.caption2Size))
                    .foregroundStyle(Color.dsTextTertiary)
            }
        }
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
        // Immediately select it as the Default provider — onChange(of: provider)
        // syncs the Default tier's model and auto-fetches its model list.
        provider = id
        saveConfigImmediately()
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
                    saveConfigImmediately()
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
            if (customProviderKeys[def.id] ?? "").isEmpty,
               let source = config.inheritedKeySource(for: def.baseUrl) {
                HStack(spacing: 4) {
                    Image(systemName: "link.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.dsAccent)
                    Text("Using \(providerPreset(source)?.name ?? source)'s API key — same endpoint")
                        .font(.system(size: DesignToken.caption2Size))
                        .foregroundStyle(Color.dsTextSecondary)
                }
                .help("This custom provider points at the same endpoint as \(providerPreset(source)?.name ?? source); its verified API key is used automatically.")
            }
            HStack(spacing: DesignToken.spacing6) {
                SecureField("••••••••", text: Binding(
                    get: { customProviderKeys[def.id] ?? "" },
                    set: { customProviderKeys[def.id] = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    saveConfigImmediately()
                }
                .onChange(of: customProviderKeys[def.id] ?? "") {
                    providerChecks[def.id] = .unknown
                }
                Button("Verify") {
                    saveConfigImmediately()
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

    /// Set a tier's provider, keep its model in sync, and autofetch its model
    /// list immediately. Each pair is independent.
    ///
    /// The Default tier follows the primary provider: changing it goes through
    /// `provider`, whose onChange handler runs the same sync+fetch for the
    /// Default pair — so the model dropdown always reflects the provider the
    /// user just picked.
    private func setTierProvider(_ tier: TierKey, _ pid: String) {
        if tier == .defaultModel {
            provider = pid
        } else {
            tierProviders[tier.rawValue] = pid
            syncTierToProvider(tier, pid)
        }
    }

    /// Re-sync a tier after its provider changes: drop the previous provider's
    /// cached models, reselect the model when it no longer belongs to the new
    /// provider, and auto-fetch the new provider's list.
    private func syncTierToProvider(_ tier: TierKey, _ pid: String) {
        tierLiveModels[tier.rawValue] = []
        tierFetchStates[tier.rawValue] = .idle
        // A different provider means the previous test result is meaningless —
        // clear it so the row shows "Not tested" instead of the old provider's
        // stale error until the user re-runs Test All Models.
        tierModelChecks[tier.rawValue] = .unknown
        sanitizeTierModel(for: tier)
        Task { await fetchTierModels(for: tier) }
    }

    /// Keep the tier's model aligned with its provider. The model is only
    /// replaced when it is clearly stale: an empty selection picks the
    /// provider's first preset, and a model that belongs to a *different*
    /// provider's preset list is swapped for the new provider's first preset.
    /// Anything else (e.g. a custom model id the user typed) is preserved.
    private func sanitizeTierModel(for tier: TierKey) {
        let pid = tierProviderId(for: tier)
        let current = tierModelValue(tier)
        guard !current.isEmpty else {
            if let preset = providerPreset(pid), let first = preset.models.first {
                setTierModel(tier, ProviderPreset.bareModel(first, for: pid))
            }
            return
        }
        let options = tierModelOptions(for: tier)
        if !options.contains(ProviderPreset.bareModel(current, for: pid)),
           modelBelongsToAnotherProvider(current, excluding: pid),
           let preset = providerPreset(pid),
           let first = preset.models.first {
            setTierModel(tier, ProviderPreset.bareModel(first, for: pid))
        }
    }

    /// True when the model id (stripped of its own routing prefix) matches a
    /// preset of any provider other than `pid` — i.e. a leftover from a
    /// previous provider selection, not a custom id the user typed.
    private func modelBelongsToAnotherProvider(_ model: String, excluding pid: String) -> Bool {
        let bare = ProviderPreset.bareModel(model, for: pid)
        return ProviderPreset.all.contains { other in
            other.id != pid && other.models.contains { ProviderPreset.bareModel($0, for: other.id) == bare }
        }
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
        // The app-wide auto-fetch results — the provider's full live list
        // (free tier included) — merge in here too.
        for m in providerLiveModels[pid] ?? [] {
            models.insert(ProviderPreset.bareModel(m, for: pid))
        }
        return Array(models).sorted()
    }

    /// Fetch available models from a tier's provider and cache them locally.
    /// Drives the per-tier fetch state so the dropdown shows a spinner, a
    /// failure reason + Retry, or a model count instead of failing silently.
    private func fetchTierModels(for tier: TierKey) async {
        let pid = tierProviderId(for: tier)
        var baseUrl = config.baseUrl(for: pid)
        if pid == "llamaapp" {
            // llama.app's server port is NOT stable — it rebinds to a free
            // port after relaunches (observed moving 8080 → 9931). Always use
            // the LIVE port discovered from the running `llama serve` process;
            // the hardcoded 8080 fallback silently broke model detection
            // whenever llama.app picked a different port.
            let livePort = LocalServerDiscovery.liveLlamaPort()
            baseUrl = "http://127.0.0.1:\(livePort)"
        }
        // Only a TRAILING "/v1" marks the API root. A contains-replace would
        // mangle endpoints whose path merely contains "/v1" (Gemini's
        // "/v1beta" → "/beta"), producing a dead URL. Strip exactly one
        // trailing "/v1"; the root is re-appended below.
        if baseUrl.hasSuffix("/v1") { baseUrl = String(baseUrl.dropLast(3)) }
        guard let url = URL(string: baseUrl + "/v1/models") else {
            tierFetchStates[tier.rawValue] = .failed("Invalid endpoint \(baseUrl)")
            return
        }
        tierFetchStates[tier.rawValue] = .fetching
        do {
            var req = URLRequest(url: url)
            req.timeoutInterval = 12
            // Reactive @State key (same reasoning as the provider verify) so a
            // freshly typed key authenticates the models request immediately.
            let key = apiKeyForProvider(pid)
            if !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
            // Use a URLSession that ignores cache so fresh fetches always land.
            let (data, _) = try await URLSession(configuration: .ephemeral).data(for: req)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let modelList = json["data"] as? [[String: Any]] else {
                await MainActor.run {
                    // The endpoint answered but with an unreadable body (e.g. a
                    // plain-text 401 from a gateway) — surface it, don't stall.
                    guard tierProviderId(for: tier) == pid else { return }
                    tierFetchStates[tier.rawValue] = .failed("Provider returned no model list")
                }
                return
            }
            let names = modelList.compactMap { $0["id"] as? String }.filter { !$0.isEmpty }
            await MainActor.run {
                // Only apply when the tier is still on this provider — a quick
                // provider switch must never be clobbered by a slow response
                // from the previous one.
                guard tierProviderId(for: tier) == pid else { return }
                guard !names.isEmpty else {
                    tierFetchStates[tier.rawValue] = .failed("No models returned")
                    return
                }
                tierLiveModels[tier.rawValue] = names
                tierFetchStates[tier.rawValue] = .loaded
                if let idx = manager.providers.firstIndex(where: { $0.id == pid }) {
                    manager.providers[idx].visibleModelIds.formUnion(names)
                }
                // Auto-populate an empty tier model from the first live model —
                // custom/local providers (e.g. llama.app) expose their models
                // only via this fetch, so a freshly selected provider would
                // otherwise sit at "No model selected".
                let current = tierModelValue(tier)
                if current.isEmpty {
                    setTierModel(tier, ProviderPreset.bareModel(names[0], for: pid))
                } else if !tierModelOptions(for: tier).contains(ProviderPreset.bareModel(current, for: pid)),
                          modelBelongsToAnotherProvider(current, excluding: pid) {
                    // Stale model from a different provider — adopt the first
                    // fetched model so the pair stays consistent.
                    setTierModel(tier, ProviderPreset.bareModel(names[0], for: pid))
                }
            }
        } catch {
            await MainActor.run {
                guard tierProviderId(for: tier) == pid else { return }
                tierLiveModels[tier.rawValue] = []
                tierFetchStates[tier.rawValue] = .failed(fetchFailureText(error, baseUrl: baseUrl))
            }
            print("[SettingsView] Failed to fetch tier models from \(url): \(error)")
        }
    }

    /// Human-readable reason for a failed model fetch — local endpoints get a
    /// "is the server running?" hint, everything else shows the error.
    private func fetchFailureText(_ error: Error, baseUrl: String) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost,
                 .timedOut, .notConnectedToInternet:
                let host = URL(string: baseUrl)?.host ?? baseUrl
                return "Couldn't reach \(host) — is the server running?"
            default:
                return urlError.localizedDescription
            }
        }
        return error.localizedDescription
    }

    // MARK: - App-Wide Provider Model Auto-Fetch (free tier included)

    /// Fetch EVERY remote provider's live model list once and union the FREE
    /// models into that provider's visible set. This auto-selects "all the
    /// free tier models" per provider:
    /// - OpenRouter / OpenCode Zen serve their catalogs PUBLICLY (no key) —
    ///   fetched even before the user pastes a key.
    /// - Providers with per-model pricing (OpenRouter: `pricing == 0`;
    ///   OpenCode: `-free` suffix) get ONLY their free models.
    /// - Providers whose whole catalog is free (Groq, Cerebras, SambaNova —
    ///   rate-limited free usage) get the full live list.
    private func fetchAllProviderModels() async {
        guard !isFetchingAllProviderModels else { return }
        isFetchingAllProviderModels = true
        defer { isFetchingAllProviderModels = false }

        // Every remote provider that can serve a free tier — iterated over ALL
        // presets (not just availableProviders, which drops keyed presets when
        // no key is set): a provider is a target when it has a key, OR its
        // /models endpoint is public (OpenRouter/OpenCode free catalogs are
        // fetchable keylessly).
        let targets = ProviderPreset.all.filter { preset in
            guard ProviderFreeTier.hasFreeTier(providerId: preset.id) else { return false }
            if ProviderFreeTier.publicModelsEndpoints.contains(preset.id) { return true }
            return !apiKeyForProvider(preset.id).isEmpty
        }

        await withTaskGroup(of: (String, [String]).self) { group in
            for preset in targets {
                group.addTask {
                    (preset.id, await self.fetchProviderModelList(preset))
                }
            }
            var results: [String: [String]] = [:]
            for await (pid, models) in group where !models.isEmpty {
                results[pid] = models
            }
            guard !results.isEmpty else { return }
            await MainActor.run {
                for (pid, models) in results {
                    providerLiveModels[pid] = models
                    // Union into the per-tier cache so dropdowns show them even
                    // before that tier's own fetch runs.
                    for tier in TierKey.allCases where tierProviderId(for: tier) == pid {
                        tierLiveModels[tier.rawValue] = Array(
                            Set((tierLiveModels[tier.rawValue] ?? []) + models)
                        ).sorted()
                    }
                    if let idx = manager.providers.firstIndex(where: { $0.id == pid }) {
                        manager.providers[idx].visibleModelIds.formUnion(models)
                    }
                }
            }
        }
    }

    /// One provider's live model list via its OpenAI-compatible /models
    /// endpoint. Returns [] on any failure (the tier fetch surfaces errors;
    /// this background pass is best-effort).
    private func fetchProviderModelList(_ preset: ProviderPreset) async -> [String] {
        var baseUrl = config.baseUrl(for: preset.id)
        if baseUrl.hasSuffix("/v1") { baseUrl = String(baseUrl.dropLast(3)) }
        guard baseUrl.hasPrefix("https://") || baseUrl.hasPrefix("http://"),
              let url = URL(string: baseUrl + "/v1/models") else { return [] }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        let key = apiKeyForProvider(preset.id)
        if !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        // Some gateways (Anthropic-style) key on x-api-key instead.
        if !key.isEmpty { req.setValue(key, forHTTPHeaderField: "x-api-key") }
        do {
            let (data, response) = try await URLSession(configuration: .ephemeral).data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let modelList = json["data"] as? [[String: Any]] else { return [] }
            // Filter to the provider's free tier (no-op for whole-catalog-free
            // providers — see ProviderFreeTier.freeModels).
            return ProviderFreeTier.freeModels(providerId: preset.id, rawModels: modelList)
        } catch {
            return []
        }
    }

    // MARK: - API Key Removal (with model cascade)

    /// Providers that share a single API key field. The OpenCode key is shared
    /// between OpenCode Zen and OpenCode Go; every other key is one-to-one.
    private func providerIdsSharingKey(with providerId: String) -> [String] {
        switch providerId {
        case "opencode-zen", "opencode-go": return ["opencode-zen", "opencode-go"]
        default: return [providerId]
        }
    }

    /// Keychain account key for a built-in provider key field.
    private func chainKeyForProviderField(_ providerId: String) -> String? {
        switch providerId {
        case "direct": return ConfigManager.KeychainKey.anthropic
        case "openai": return ConfigManager.KeychainKey.openai
        case "openrouter": return ConfigManager.KeychainKey.openrouter
        case "opencode-zen", "opencode-go": return ConfigManager.KeychainKey.opencode
        case "nvidia-nim": return ConfigManager.KeychainKey.nvidia
        case "deepseek": return ConfigManager.KeychainKey.deepseek
        case "gemini": return ConfigManager.KeychainKey.gemini
        case "mistral": return ConfigManager.KeychainKey.mistral
        case "codestral": return ConfigManager.KeychainKey.codestral
        case "cohere": return ConfigManager.KeychainKey.cohere
        case "groq": return ConfigManager.KeychainKey.groq
        case "fireworks": return ConfigManager.KeychainKey.fireworks
        case "sambanova": return ConfigManager.KeychainKey.sambanova
        case "cerebras": return ConfigManager.KeychainKey.cerebras
        case "huggingface": return ConfigManager.KeychainKey.huggingface
        case "xai": return ConfigManager.KeychainKey.xai
        case "antigravity": return ConfigManager.KeychainKey.antigravity
        default: return nil
        }
    }

    /// Clear the matching @State key field for a provider.
    private func clearApiKeyField(_ providerId: String) {
        switch providerId {
        case "direct": anthropicKey = ""
        case "openai": openaiKey = ""
        case "openrouter": openrouterKey = ""
        case "opencode-zen", "opencode-go": opencodeKey = ""
        case "nvidia-nim": nvidiaKey = ""
        case "deepseek": deepseekKey = ""
        case "gemini": geminiKey = ""
        case "mistral": mistralKey = ""
        case "codestral": codestralKey = ""
        case "cohere": cohereKey = ""
        case "groq": groqKey = ""
        case "fireworks": fireworksKey = ""
        case "sambanova": sambanovaKey = ""
        case "cerebras": cerebrasKey = ""
        case "huggingface": huggingfaceKey = ""
        case "xai": xaiKey = ""
        case "antigravity": antigravityKey = ""
        default: break
        }
    }

    /// Show a confirmation sheet before removing a key. Deletion is
    /// destructive but the key can be re-entered; the model cascade is the
    /// irreversible part.
    private func confirmRemoveApiKey(providerId: String, label: String) {
        let affected = providerIdsSharingKey(with: providerId)
        let modelNote = affected.count > 1
            ? "\n\nAll models installed with this key (\(affected.map { providerPreset($0)?.name ?? $0 }.joined(separator: ", "))) will be uninstalled from the model selection lists."
            : ""
        let alert = NSAlert()
        alert.messageText = "Remove \(label)?"
        alert.informativeText = "The API key will be deleted from the Keychain.\(modelNote)"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        removeApiKey(providerId: providerId)
    }

    /// Remove an API key and cascade: uninstall every model that was installed
    /// via this key, clear tier/provider selections that referenced affected
    /// providers, and repair any orphaned tier model selections.
    private func removeApiKey(providerId: String) {
        let affectedProviders = providerIdsSharingKey(with: providerId)

        // 1. Clear the key field + the Keychain entry.
        clearApiKeyField(providerId)
        if let chainKey = chainKeyForProviderField(providerId) {
            config.setApiKey(chainKey: chainKey, value: "")
        }

        // 2. Determine which tier models were installed via this key (capture
        //    membership BEFORE clearing the live lists below).
        let orphanedTiers = TierKey.allCases.filter { tier in
            let model = tierModelValue(tier)
            return !model.isEmpty && affectedProviders.contains(where: { modelBelongsToProvider(model, $0) })
        }

        // 3. Uninstall every live-fetched model for affected providers.
        for pid in affectedProviders {
            uninstallModels(for: pid)
        }

        // 4. Drop tier/provider selections referencing an affected provider.
        for tier in TierKey.allCases where tier != .defaultModel {
            if let pid = tierProviders[tier.rawValue], affectedProviders.contains(pid) {
                tierProviders.removeValue(forKey: tier.rawValue)
            }
        }
        if affectedProviders.contains(provider) {
            if let first = availableProviders.first {
                provider = first.id
            }
        }

        // 5. Clear orphaned tier models and re-sanitize.
        for tier in orphanedTiers {
            setTierModel(tier, "")
        }
        for tier in TierKey.allCases {
            sanitizeTierModel(for: tier)
        }

        providerChecks[providerId] = .unknown
        // Also invalidate checks for sibling providers that share this key.
        for pid in affectedProviders where pid != providerId {
            providerChecks[pid] = .unknown
        }
        scheduleAutoSave()
    }

    /// Uninstall the live-fetched ("installed via key") models for a provider:
    /// clear the tier fetch caches and the persisted visible-model list, so
    /// model dropdowns no longer offer models that can't be served.
    private func uninstallModels(for pid: String) {
        for tier in TierKey.allCases {
            if tierProviderId(for: tier) == pid {
                tierLiveModels[tier.rawValue] = []
                tierFetchStates[tier.rawValue] = .idle
                tierModelChecks[tier.rawValue] = .unknown
            }
        }
        // Clear the provider's persisted live models.
        manager.visibleModels[pid] = []
        if let idx = manager.providers.firstIndex(where: { $0.id == pid }) {
            manager.providers[idx].visibleModelIds = []
        }
        // Persist the cleared visible-model list immediately without the full
        // flushSave chain (which re-writes every API key to the Keychain).
        let visibleStr = manager.providers.map { p in
            "\(p.id)=\(p.visibleModelIds.joined(separator: ","))"
        }.joined(separator: ";")
        config.visibleModelsRaw = visibleStr
    }

    /// True when a model id belongs to a provider's preset or its live-fetched
    /// list. Used to detect orphaned tier selections after key removal.
    private func modelBelongsToProvider(_ model: String, _ pid: String) -> Bool {
        guard !model.isEmpty else { return false }
        let bare = ProviderPreset.bareModel(model, for: pid)
        if let preset = providerPreset(pid),
           preset.models.contains(where: { ProviderPreset.bareModel($0, for: pid) == bare }) {
            return true
        }
        if let p = manager.providers.first(where: { $0.id == pid }),
           p.visibleModelIds.contains(bare) {
            return true
        }
        for models in tierLiveModels.values {
            if models.contains(where: { ProviderPreset.bareModel($0, for: pid) == bare }) {
                return true
            }
        }
        return false
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
                
                if let servedBy = entry.servedBy {
                    HStack(spacing: 3) {
                        if entry.usedFallback {
                            Image(systemName: "arrow.triangle.branch")
                                .font(.system(size: 9))
                        }
                        Text(providerDisplayName(servedBy))
                            .lineLimit(1)
                    }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(entry.usedFallback ? Color.dsOrange : Color.dsGreen)
                    .help(entry.usedFallback
                        ? "Served by fallback provider \(providerDisplayName(servedBy))"
                        : "Served by \(providerDisplayName(servedBy))")
                }
                
                Text(actionString(entry.action))
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(actionColor(entry.action))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.method) request to \(entry.host). \(entry.appProcessName != nil ? "From \(entry.appProcessName!)." : "") Status: \(actionString(entry.action))\(entry.servedBy.map { ", served by \(providerDisplayName($0))\(entry.usedFallback ? " (fallback)" : "")" } ?? "")")
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
        case .passthrough, .passThroughOpenAI: return .dsTextSecondary
        case .block: return .dsRed
        }
    }
    
    private func actionString(_ action: RouteAction) -> String {
        switch action {
        case .routeAI: return "ROUTED"
        case .passthrough, .passThroughOpenAI: return "PASSTHROUGH"
        case .block: return "BLOCKED"
        }
    }

    /// Friendly display name for a provider id (built-in presets, the legacy
    /// "local" alias, and named custom providers).
    private func providerDisplayName(_ id: String) -> String {
        if id == "local" { return "Local LLM" }
        if let preset = ProviderPreset.preset(for: id) { return preset.name }
        if let def = ConfigManager.shared.customProviders.first(where: { $0.id == id }) { return def.name }
        return id
    }
}

// MARK: - Local Model Onboarding

/// Step-by-step setup tutorial for running a local LLM (llama.app / Ollama).
/// Shown when the user taps "Run Local Model" but the app/binary is missing.
private struct LocalModelOnboardingView: View {
    let provider: LocalModelManager.LocalProvider
    let onRetry: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: provider == .llamaapp ? "desktopcomputer" : "server.rack")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.dsAccent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Set Up \(provider == .llamaapp ? "Llama" : "Ollama")")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.dsTextPrimary)
                    Text("Run your own local LLM")
                        .font(.system(size: DesignToken.captionSize))
                        .foregroundStyle(Color.dsTextTertiary)
                }
                Spacer()
            }

            onboardingStep(
                number: "1",
                title: provider == .llamaapp ? "Install the Llama app" : "Install Ollama",
                body: provider == .llamaapp
                    ? "The Llama app (llama.app) runs open models locally and serves them with an OpenAI-compatible API on port 8080. Download it free from llama.com or the Mac App Store."
                    : "Ollama serves local models with a single command. Install via Homebrew or download the macOS app.",
                actionTitle: provider == .llamaapp ? "Download llama.com" : "brew install ollama",
                actionURL: provider == .llamaapp ? "https://llama.com" : "https://ollama.com/download"
            )

            onboardingStep(
                number: "2",
                title: provider == .llamaapp ? "Load a model & start its server" : "Pull a model",
                body: provider == .llamaapp
                    ? "Open the Llama app, download a model from its library, and make sure its local server is enabled (it listens on port 8080). Then come back and press Run."
                    : "Pull a model once — Ollama runs it on demand. Try qwen3:8b for a good balance of speed and quality.",
                actionTitle: provider == .llamaapp ? nil : "ollama pull qwen3:8b",
                actionURL: provider == .llamaapp ? nil : nil
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

    private func onboardingStep(number: String, title: String, body: String, actionTitle: String?, actionURL: String?) -> some View {
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
                    if let actionTitle {
                        Button(actionTitle) { copyCommand(actionTitle) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .font(.system(size: DesignToken.captionSize, design: .monospaced))
                    }
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
