import SwiftUI
import AppKit

/// Settings UI for the source-of-truth gateway.
///
/// Lives in its own file because `SettingsView`'s `sectionGroup` helper is
/// file-private; this view is self-contained and dropped into the System tab.
struct GatewaySettingsSection: View {
    @State private var gateway = SourceOfTruthGateway.shared
    @State private var excludesDraft: String = ""
    @State private var contextDraft: String = ""
    @State private var showFiles = false

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { gateway.settings.enabled },
            set: { newValue in gateway.update { $0.enabled = newValue } }
        )
    }

    private var injectBinding: Binding<Bool> {
        Binding(
            get: { gateway.settings.injectIntoSystemPrompt },
            set: { newValue in gateway.update { $0.injectIntoSystemPrompt = newValue } }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignToken.spacing12) {
            Toggle(isOn: enabledBinding) {
                Text("Enable Source-of-Truth Gateway")
                    .font(.system(size: DesignToken.bodySize))
            }
            .toggleStyle(.switch)

            Text("Watches a project folder and prepends its real contents to the system prompt, so the local model answers from your files instead of guessing.")
                .font(.system(size: DesignToken.caption2Size))
                .foregroundStyle(Color.dsTextTertiary)
                .fixedSize(horizontal: false, vertical: true)

            folderRow
            excludesRow
            contextRow

            Toggle(isOn: injectBinding) {
                Text("Inject into every system prompt")
                    .font(.system(size: DesignToken.bodySize))
            }
            .toggleStyle(.switch)
            .disabled(!gateway.settings.enabled)

            statusRow
        }
        .onAppear(perform: syncDrafts)
        .onChange(of: gateway.settings.rootPath) { syncDrafts() }
        .onChange(of: gateway.settings.contextTokens) { syncDrafts() }
    }

    // MARK: - Rows

    private var folderRow: some View {
        VStack(alignment: .leading, spacing: DesignToken.spacing6) {
            Text("Watched Folder")
                .font(.system(size: DesignToken.captionSize, weight: .medium))
                .foregroundStyle(Color.dsTextSecondary)

            HStack(spacing: DesignToken.spacing8) {
                Text(gateway.settings.rootPath.isEmpty ? "No folder selected" : gateway.settings.rootPath)
                    .font(.system(size: DesignToken.captionSize, design: .monospaced))
                    .foregroundStyle(gateway.settings.rootPath.isEmpty ? Color.dsTextTertiary : Color.dsTextPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button("Choose…") { chooseFolder() }
                if !gateway.settings.rootPath.isEmpty {
                    Button("Clear") { gateway.update { $0.rootPath = "" } }
                }
                Button("Rescan") { gateway.rescan() }
                    .disabled(!gateway.settings.enabled || gateway.settings.rootPath.isEmpty)
            }
        }
        .disabled(!gateway.settings.enabled)
    }

    private var excludesRow: some View {
        VStack(alignment: .leading, spacing: DesignToken.spacing6) {
            Text("Extra Excludes (gitignore-style, one per line)")
                .font(.system(size: DesignToken.captionSize, weight: .medium))
                .foregroundStyle(Color.dsTextSecondary)

            TextEditor(text: $excludesDraft)
                .font(.system(size: DesignToken.captionSize, design: .monospaced))
                .frame(height: 64)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.dsSeparator, lineWidth: 1)
                )
                .onChange(of: excludesDraft) { commitExcludes() }

            Text(".git, node_modules, dist, build, .next, target, venv and binary files are always excluded.")
                .font(.system(size: DesignToken.caption2Size))
                .foregroundStyle(Color.dsTextTertiary)
        }
        .disabled(!gateway.settings.enabled)
    }

    private var contextRow: some View {
        VStack(alignment: .leading, spacing: DesignToken.spacing6) {
            Text("Context Window (tokens)")
                .font(.system(size: DesignToken.captionSize, weight: .medium))
                .foregroundStyle(Color.dsTextSecondary)

            HStack(spacing: DesignToken.spacing8) {
                TextField("0 = unknown", text: $contextDraft)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
                    .onChange(of: contextDraft) { commitContext() }

                let modelCtx = ConfigManager.shared.ggufContextSize
                if modelCtx > 0 {
                    Button("Use model context (\(modelCtx))") {
                        gateway.update { $0.contextTokens = modelCtx }
                    }
                }
                Spacer()
            }

            Text("Used for the 70% budget guard. Above it the gateway degrades to a file index instead of inlining contents.")
                .font(.system(size: DesignToken.caption2Size))
                .foregroundStyle(Color.dsTextTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .disabled(!gateway.settings.enabled)
    }

    private var statusRow: some View {
        VStack(alignment: .leading, spacing: DesignToken.spacing6) {
            if let snap = gateway.snapshot, gateway.settings.enabled {
                let budget = gateway.budgetReport()

                HStack(spacing: DesignToken.spacing12) {
                    Label {
                        Text("\(snap.inlinedCount) files inlined")
                    } icon: {
                        Image(systemName: "doc.text")
                    }
                    .font(.system(size: DesignToken.captionSize))
                    .foregroundStyle(Color.dsTextSecondary)

                    Text("~\(snap.totalTokens) tokens")
                        .font(.system(size: DesignToken.captionSize))
                        .foregroundStyle(Color.dsTextSecondary)

                    if gateway.settings.contextTokens > 0 {
                        Text(String(format: "%.1f%% of context", budget.percent))
                            .font(.system(size: DesignToken.captionSize, weight: .medium))
                            .foregroundStyle(budget.exceeded ? Color.red : Color.dsTextSecondary)
                    }
                    if gateway.isScanning {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                }

                Text(budget.advice)
                    .font(.system(size: DesignToken.caption2Size))
                    .foregroundStyle(budget.exceeded ? Color.orange : Color.dsTextTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                DisclosureGroup("Indexed files", isExpanded: $showFiles) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(snap.files.prefix(50)) { f in
                            HStack(spacing: 6) {
                                Text(f.path)
                                    .font(.system(size: DesignToken.caption2Size, design: .monospaced))
                                    .lineLimit(1)
                                Spacer()
                                Text(f.kind.rawValue)
                                    .font(.system(size: DesignToken.caption2Size))
                                    .foregroundStyle(f.kind == .text ? Color.dsTextTertiary : Color.orange)
                            }
                        }
                        if snap.files.count > 50 {
                            Text("…and \(snap.files.count - 50) more")
                                .font(.system(size: DesignToken.caption2Size))
                                .foregroundStyle(Color.dsTextTertiary)
                        }
                    }
                }
                .font(.system(size: DesignToken.captionSize))
            } else if gateway.settings.enabled {
                Text("Pick a folder to build the first snapshot.")
                    .font(.system(size: DesignToken.captionSize))
                    .foregroundStyle(Color.dsTextTertiary)
            }

            if let err = gateway.lastError {
                Text(err)
                    .font(.system(size: DesignToken.caption2Size))
                    .foregroundStyle(Color.red)
            }
        }
    }

    // MARK: - Actions

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Watch"
        panel.message = "Choose the folder that should become the source of truth"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        gateway.update { $0.rootPath = url.path }
    }

    private func syncDrafts() {
        excludesDraft = gateway.settings.extraExcludes
        contextDraft = gateway.settings.contextTokens == 0
            ? "" : String(gateway.settings.contextTokens)
    }

    private func commitExcludes() {
        let value = excludesDraft
        guard value != gateway.settings.extraExcludes else { return }
        gateway.update { $0.extraExcludes = value }
    }

    private func commitContext() {
        let trimmed = contextDraft.trimmingCharacters(in: .whitespaces)
        let value = Int(trimmed) ?? 0
        guard value != gateway.settings.contextTokens else { return }
        gateway.update { $0.contextTokens = value }
    }
}

/// What each connected app is actually doing right now.
///
/// Complements the Routing tab's rules: a rule says what *should* happen,
/// this shows what *is* happening.
struct RoutingTelemetryRow: View {
    @State private var entries: [AppRoutingTelemetry] = []
    @State private var ticker = false

    private let timer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: DesignToken.spacing6) {
            if entries.isEmpty {
                Text("No app has connected yet. Traffic appears here once a client routes through JXRouter.")
                    .font(.system(size: DesignToken.caption2Size))
                    .foregroundStyle(Color.dsTextTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(entries) { e in
                    HStack(spacing: DesignToken.spacing8) {
                        Circle()
                            .fill(e.isActive ? Color.green : Color.dsTextTertiary)
                            .frame(width: 6, height: 6)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(e.name)
                                .font(.system(size: DesignToken.captionSize, weight: .medium))
                                .lineLimit(1)
                            Text(e.subtitle)
                                .font(.system(size: DesignToken.caption2Size, design: .monospaced))
                                .foregroundStyle(Color.dsTextTertiary)
                                .lineLimit(1)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 1) {
                            Text("\(e.connectionCount) conn")
                                .font(.system(size: DesignToken.caption2Size))
                            Text(e.lastSeenText)
                                .font(.system(size: DesignToken.caption2Size))
                                .foregroundStyle(Color.dsTextTertiary)
                        }
                        if !e.processText.isEmpty {
                            Text(e.processText)
                                .font(.system(size: DesignToken.caption2Size, design: .monospaced))
                                .foregroundStyle(Color.dsTextTertiary)
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
        .onReceive(timer) { _ in
            // Refresh on a timer: telemetry is recorded from proxy threads.
            entries = RoutingTelemetry.shared.snapshot()
        }
        .onAppear { entries = RoutingTelemetry.shared.snapshot() }
    }
}

/// In-process llama.cpp vs. the `llama-server` subprocess.
struct InProcessEngineRow: View {
    @State private var engine = InProcessLlamaEngine.shared

    private var enabled: Binding<Bool> {
        Binding(
            get: { ConfigManager.shared.preferInProcessEngine },
            set: { ConfigManager.shared.preferInProcessEngine = $0 }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignToken.spacing6) {
            Toggle(isOn: enabled) {
                Text("Run models in-process (no llama-server subprocess)")
                    .font(.system(size: DesignToken.bodySize))
            }
            .toggleStyle(.switch)
            .disabled(!engine.isAvailable)

            if engine.isAvailable {
                Text("llama.cpp is linked directly into JXRouter: no child process, no port to fight over, lower first-token latency. The subprocess stays as the fallback.")
                    .font(.system(size: DesignToken.caption2Size))
                    .foregroundStyle(Color.dsTextTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Unavailable on this Mac — \(engine.unavailableReason ?? "unknown"). Falling back to the llama-server subprocess.")
                    .font(.system(size: DesignToken.caption2Size))
                    .foregroundStyle(Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Machine readout for the auto-config, so context sizing decisions are
/// visible rather than implied.
struct HardwareProfileRow: View {
    @State private var profile = HardwareProfile.current()

    var body: some View {
        VStack(alignment: .leading, spacing: DesignToken.spacing6) {
            Text(profile.summary)
                .font(.system(size: DesignToken.captionSize, design: .monospaced))
                .foregroundStyle(Color.dsTextPrimary)

            let budget = profile.inferenceBudgetBytes
            Text(String(format: "%.1f GB usable for inference after %.1f GB reserved for the OS",
                        Double(budget) / 1_073_741_824,
                        Double(profile.reservedBytes) / 1_073_741_824))
                .font(.system(size: DesignToken.caption2Size))
                .foregroundStyle(Color.dsTextTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}


/// ASD-STE100 simplified-English output rules (ported from the Go build's
/// `internal/linguistics`).
struct STE100Row: View {
    private var enabled: Binding<Bool> {
        Binding(
            get: { ConfigManager.shared.ste100Enforce },
            set: { ConfigManager.shared.ste100Enforce = $0 }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignToken.spacing6) {
            Toggle(isOn: enabled) {
                Text("Enforce ASD-STE100 simplified English")
                    .font(.system(size: DesignToken.bodySize))
            }
            .toggleStyle(.switch)

            Text("Adds short-sentence, active-voice rules to the system prompt so local models answer in plain language. Tool calls, patches and code are detected and left byte-exact. Off by default.")
                .font(.system(size: DesignToken.caption2Size))
                .foregroundStyle(Color.dsTextTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Environment variables JXRouter hands to Claude Code / Codex sessions.
struct EnvManagerSection: View {
    @State private var variables: [EnvManager.EnvVar] = []
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: DesignToken.spacing12) {
            if variables.isEmpty {
                Text("Loading…")
                    .font(.system(size: DesignToken.caption2Size))
                    .foregroundStyle(Color.dsTextTertiary)
            } else {
                ForEach(variables.indices, id: \.self) { i in
                    HStack(alignment: .firstTextBaseline, spacing: DesignToken.spacing12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(variables[i].key)
                                .font(.system(size: DesignToken.captionSize, design: .monospaced))
                                .foregroundStyle(Color.dsTextPrimary)
                            Text(variables[i].helpDescription)
                                .font(.system(size: DesignToken.caption2Size))
                                .foregroundStyle(Color.dsTextTertiary)
                        }
                        .frame(minWidth: 260, alignment: .leading)

                        Text(variables[i].source.rawValue)
                            .font(.system(size: DesignToken.caption2Size))
                            .foregroundStyle(Color.dsTextTertiary)
                            .frame(width: 88, alignment: .leading)

                        Group {
                            if variables[i].isSensitive {
                                SecureField("value", text: binding(at: i))
                            } else {
                                TextField("value", text: binding(at: i))
                            }
                        }
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: DesignToken.captionSize, design: .monospaced))
                    }
                }
            }

            HStack(spacing: DesignToken.spacing12) {
                Button(copied ? "Copied" : "Copy export line") { copySnippet() }
                Button("Reset to defaults") { reset() }
            }
            .controlSize(.small)

            Text("Stored at ~/.jxproxy/config.env (directories 0700, file 0600). Never written to a shell profile.")
                .font(.system(size: DesignToken.caption2Size))
                .foregroundStyle(Color.dsTextTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task { await reload() }
    }

    private func binding(at i: Int) -> Binding<String> {
        Binding(
            get: { i < variables.count ? variables[i].value : "" },
            set: { newValue in
                guard i < variables.count else { return }
                let key = variables[i].key
                variables[i].value = newValue
                Task { await EnvManager.shared.update(key: key, value: newValue) }
            }
        )
    }

    private func reload() async {
        await EnvManager.shared.load()
        let vars = await EnvManager.shared.variables
        await MainActor.run { variables = vars }
    }

    private func copySnippet() {
        Task {
            let snippet = await EnvManager.shared.exportSnippet(port: ConfigManager.shared.port)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(snippet, forType: .string)
            await MainActor.run { copied = true }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await MainActor.run { copied = false }
        }
    }

    private func reset() {
        Task {
            await EnvManager.shared.resetToDefaults()
            await reload()
        }
    }
}
