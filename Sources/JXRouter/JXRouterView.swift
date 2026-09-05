import SwiftUI
import AppKit

struct JXRouterView: View {
    @Bindable var manager: ProxyManager
    /// Observed so the YOUR SETUP card reflects the Route OpenAI switch live.
    @State private var config = ConfigManager.shared
    @State private var showOnboarding = false
    /// Whether the Detected Apps list is collapsed (the card keeps its fixed
    /// height — the window's content size must never change, see below).
    @State private var isDetectedAppsCollapsed = false
    /// Free API key guide — auto-presented after first-launch onboarding when
    /// the user hasn't configured any provider key yet.
    @State private var showApiKeyGuide = false
    /// Current light/dark appearance — tracks AppearanceController.shared.mode
    private var appearanceMode: AppearanceMode {
        AppearanceController.shared.mode
    }
    // Derived proxy stats for the dashboard
    private var requestsCount: Int {
        manager.proxyServer.stats.aiRouted + manager.proxyServer.stats.passthrough
    }

    var body: some View {
        // Top-aligned so the dashboard starts at the very top of the window —
        // when the taller settings panel is open, no deadspace appears above it.
        HStack(alignment: .top, spacing: 0) {
            // Main Dashboard Panel — fixed-width, no page scrollbar. The
            // detected-apps list scrolls inside its own card below.
            VStack(spacing: 0) {
                // Hero Status — starts at the very top of the panel; the window's
                // traffic lights float in the top-left corner (fullSizeContentView),
                // so no separate header band is needed. The ? and gear actions sit
                // at the upper-right corner of this page (see the overlay below).
                VStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .stroke(Color.dsBorder, lineWidth: 2)
                            .frame(width: 64, height: 64)

                        Image(systemName: "bolt.shield.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(manager.isRunning ? Color.dsGreen : Color.dsTextSecondary)
                    }

                    Text(manager.isRunning ? "Running" : "Stopped")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Color.dsTextPrimary)
                        .accessibilityAddTraits(.isHeader)
                }
                .padding(.top, DesignToken.spacing10)
            
            Spacer().frame(height: 10)
            
            // Actions
            HStack(spacing: 12) {
                Button(action: { Task { await manager.isRunning ? manager.stopProxy() : manager.startProxy() } }) {
                    HStack {
                        Image(systemName: manager.isRunning ? "stop.fill" : "play.fill")
                        Text(manager.isRunning ? "Stop" : "Start")
                            .fontWeight(.medium)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(manager.isRunning ? Color.dsRedDim : Color.dsGreenDim)
                    .foregroundColor(manager.isRunning ? Color.dsRed : Color.dsGreen)
                    .clipShape(RoundedRectangle(cornerRadius: DesignToken.radiusButton))
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignToken.radiusButton)
                            .stroke(manager.isRunning ? Color.dsRed.opacity(0.3) : Color.dsGreen.opacity(0.3), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(manager.isRunning ? "Stop Proxy" : "Start Proxy")
                
                Button(action: { Task { await manager.restartProxy() } }) {
                    HStack {
                        Image(systemName: "arrow.triangle.2.circlepath")
                        Text("Restart")
                            .fontWeight(.medium)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color.dsOrangeDim)
                    .foregroundColor(Color.dsOrange)
                    .clipShape(RoundedRectangle(cornerRadius: DesignToken.radiusButton))
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignToken.radiusButton)
                            .stroke(Color.dsOrange.opacity(0.3), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Restart Proxy")
                
                Button(action: performUninstall) {
                    HStack {
                        Image(systemName: "trash.fill")
                        Text("Uninstall")
                            .fontWeight(.medium)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color.dsSurfaceRaised)
                    .foregroundColor(Color.dsTextSecondary)
                    .clipShape(RoundedRectangle(cornerRadius: DesignToken.radiusButton))
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignToken.radiusButton)
                            .stroke(Color.dsBorder, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Uninstall JXProxy")
            }
            .padding(.horizontal, 16)

            if !manager.errorAcknowledged, let errorText = manager.errorMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(errorText)
                        .font(.system(size: 11))
                        .lineLimit(3)
                    Spacer()
                    Button {
                        manager.errorAcknowledged = true
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss error")
                }
                .padding(10)
                .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                )
                .padding(.horizontal, 16)
            }
            
            Spacer().frame(height: 20)
            
            // Plain-language status summary (replaces the old stats grid)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 10, weight: .semibold))
                    Text("YOUR SETUP")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(Color.dsTextSecondary)
                .padding(.horizontal, 20)

                VStack(spacing: 0) {
                    StatusSummaryRow(icon: "bolt.fill", label: "Proxy", value: manager.isRunning ? "Running" : "Stopped", valueColor: manager.isRunning ? .dsGreen : .dsTextSecondary)
                    Divider().overlay(Color.dsBorder.opacity(0.5))
                    StatusSummaryRow(icon: "arrow.triangle.branch", label: "Provider", value: manager.activeProviderName)
                    Divider().overlay(Color.dsBorder.opacity(0.5))
                    StatusSummaryRow(icon: "cpu", label: "Model", value: manager.currentModel.isEmpty ? "—" : manager.currentModel)
                    Divider().overlay(Color.dsBorder.opacity(0.5))
                    // Route OpenAI switch — visible at a glance, changes live with
                    // the Settings toggle (ConfigManager is @Observable).
                    StatusSummaryRow(
                        icon: "globe",
                        label: "OpenAI",
                        value: config.routeOpenAI ? "Routed" : "Pass Through",
                        valueColor: config.routeOpenAI ? .dsGreen : .dsTextSecondary
                    )
                    Divider().overlay(Color.dsBorder.opacity(0.5))
                    StatusSummaryRow(icon: "network", label: "Traffic", value: "\(requestsCount) request\(requestsCount == 1 ? "" : "s") handled")
                }
                .background(Color.dsSurface)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.dsBorder, lineWidth: 1)
                )
                .padding(.horizontal, 16)
            }
            
            Spacer().frame(height: 12)
            
            // Connection Details
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "network")
                        .font(.system(size: 10, weight: .semibold))
                    Text("CONNECTION")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(Color.dsTextSecondary)
                .padding(.horizontal, 20)
                
                VStack(spacing: 0) {
                    DetailRow(label: "Proxy Address", value: manager.proxyAddress, mono: true, copyable: true)
                    Divider().overlay(Color.dsBorder.opacity(0.5))
                    DetailRow(label: "TLS Port", value: "\(manager.tlsPort)", mono: true)
                    Divider().overlay(Color.dsBorder.opacity(0.5))
                    DetailRow(label: "Active Provider", value: manager.activeProviderName)
                    Divider().overlay(Color.dsBorder.opacity(0.5))
                    DetailRow(label: "Backend", value: manager.activeProviderBackend, mono: true)
                    Divider().overlay(Color.dsBorder.opacity(0.5))
                    DetailRow(label: "Model", value: manager.currentModel.isEmpty ? "—" : manager.currentModel, mono: true)
                    Divider().overlay(Color.dsBorder.opacity(0.5))
                    DetailRow(label: "Auth Token", value: manager.authToken, mono: true, copyable: true)
                    Divider().overlay(Color.dsBorder.opacity(0.5))
                    DetailRow(label: "Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
                }
                .background(Color.dsSurface)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.dsBorder, lineWidth: 1)
                )
                .padding(.horizontal, 16)
            }
            
            Spacer().frame(height: 16)
            
            // Detected Apps (collapsible)
            VStack(alignment: .leading, spacing: 8) {
                Button(action: toggleDetectedApps) {
                    HStack(spacing: 6) {
                        Image(systemName: isDetectedAppsCollapsed ? "chevron.right" : "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 10, weight: .semibold))
                        Text("DETECTED APPS (\(manager.appDetector.detectedApps.count))")
                            .font(.system(size: 11, weight: .semibold))
                        Spacer()
                    }
                    .foregroundStyle(Color.dsTextSecondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 20)
                .accessibilityLabel(isDetectedAppsCollapsed ? "Expand detected apps" : "Collapse detected apps")
                
                // Detected app list — fixed 168pt card in every state. The
                // window's content size must NEVER change: on macOS 26 any
                // change to the hosting view's ideal size while the window is
                // displayed re-enters the constraint pass and crashes the app
                // (`_postWindowNeedsUpdateConstraints` overflow). Collapsing
                // only blanks the card; the window stays the same size.
                Group {
                    if isDetectedAppsCollapsed {
                        Color.dsSurface
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.dsBorder, lineWidth: 1)
                            )
                    } else if manager.appDetector.detectedApps.isEmpty {
                        // Empty state
                        VStack(spacing: 8) {
                            Image(systemName: "point.3.connected.trianglepath.dotted")
                                .font(.system(size: 20))
                                .foregroundStyle(Color.dsTextSecondary)
                            Text("Listening on port \(manager.currentPort)...")
                                .font(.system(size: 12))
                                .foregroundStyle(Color.dsTextSecondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.dsSurface)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.dsBorder, lineWidth: 1)
                        )
                    } else {
                        ScrollView {
                            VStack(spacing: 0) {
                                ForEach(manager.appDetector.detectedApps, id: \.self) { appName in
                                    HStack(spacing: 8) {
                                        Image(systemName: "app.fill")
                                            .font(.system(size: 10))
                                            .foregroundStyle(Color.dsAccent)
                                        Text(appName)
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundStyle(Color.dsTextPrimary)
                                        Spacer()
                                        Image(systemName: "circle.fill")
                                            .font(.system(size: 6))
                                            .foregroundStyle(Color.dsGreen)
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(Color.dsSurface)
                                    Divider().background(Color.dsBorder)
                                }
                            }
                        }
                        .background(Color.dsSurface)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.dsBorder, lineWidth: 1)
                        )
                    }
                }
                .frame(height: 168)
                .padding(.horizontal, 16)
            }
            }
            // Bottom margin matches the side margins (16pt) — the panel's last
            // card no longer sits flush against the window's bottom edge.
            .padding(.bottom, DesignToken.spacing16)
            .frame(width: 380)
            .background(Color.dsBackground)
            // ? / gear actions at the upper-right corner of the main page. The
            // content area starts below the ~28pt title bar (fullSizeContentView
            // still insets the SwiftUI layout), so a negative top offset plus a
            // top safe-area escape on the overlay itself rides the icons up to
            // the traffic-light row without moving the dashboard content.
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 14) {
                    Button(action: { showOnboarding = true }) {
                        Image(systemName: "questionmark.circle")
                            .font(.system(size: 13))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.dsTextSecondary)
                    .accessibilityLabel("Tutorial")
                    .help("Reopen the onboarding tutorial")

                    Button(action: { openSettings() }) {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 13))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.dsTextSecondary)
                    .accessibilityLabel("Open Settings")
                    .help("Open settings")

                    // Dark / light toggle — sits right next to the settings
                    // gear and follows the app's persisted appearance mode.
                    Button(action: toggleAppearance) {
                        Image(systemName: appearanceMode.symbolName)
                            .font(.system(size: 13))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.dsTextSecondary)
                    .accessibilityLabel("Toggle dark mode")
                    .help(appearanceMode.isDark ? "Switch to light mode" : "Switch to dark mode")
                }
                // Negative top offset compensates the ~28pt title-bar inset of
                // the content area, aligning the icons with the traffic lights.
                .padding(.top, -19)
                .padding(.trailing, 14)
            }
        
        }
        .background(Color.dsBackground)
        .onAppear {
            // Apply the persisted appearance (dark/light) to both windows.
            AppearanceController.shared.apply()
            // First-launch onboarding splash
            if !UserDefaults.standard.bool(forKey: "hasSeenJXOnboarding") {
                showOnboarding = true
            }
        }
        .sheet(isPresented: $showOnboarding) {
            OnboardingView {
                UserDefaults.standard.set(true, forKey: "hasSeenJXOnboarding")
                showOnboarding = false
                // Right after onboarding closes, guide keyless users to the
                // free providers (OpenCode Zen needs no key, NVIDIA NIM gives
                // a free one) instead of leaving them to hunt for help.
                if manager.hasNoProviderKey {
                    scheduleApiKeyGuide()
                }
            }
        }
        .sheet(isPresented: $showApiKeyGuide) {
            FreeApiKeyGuideView {
                showApiKeyGuide = false
            }
        }
        .alert("Claude Code Missing", isPresented: $manager.showClaudeInstallPrompt) {
            Button("Install Now") {
                manager.installAndLaunchClaude()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Anthropic's Claude Code CLI tool was not found on your system. Would you like JXProxy to install it via npm? (Requires npm to be installed)")
        }
    }
    
    /// Collapse / expand the Detected Apps list. The card keeps its fixed
    /// height in both states, so the window's content size never changes — the
    /// macOS 26 constraint-pass crash (`_postWindowNeedsUpdateConstraints`
    /// overflow) fires whenever the hosting view's ideal size changes while
    /// the window is displayed, so NO runtime window resize is performed.
    /// Settings open in the separate fixed-size Settings window instead.
    private func toggleDetectedApps() {
        isDetectedAppsCollapsed.toggle()
    }

    /// Open the native Settings window (separate from the dashboard).
    private func openSettings() {
        NotificationCenter.default.post(name: .jxproxyOpenSettings, object: nil)
    }

    /// Flip between dark and light appearance across the whole app.
    private func toggleAppearance() {
        AppearanceController.shared.toggle()
    }

    /// Present the free API key guide a beat after the onboarding sheet has
    /// fully closed — presenting two sheets back-to-back without a delay can
    /// hit "already presenting" warnings on macOS.
    private func scheduleApiKeyGuide() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            // Guard: the user may have opened the guide manually (Providers
            // tab) within the delay window — never present it twice.
            guard !showApiKeyGuide else { return }
            showApiKeyGuide = true
        }
    }

    /// Uninstall flow: confirm, clean up everything JXProxy wrote, report.
    private func performUninstall() {
        let alert = NSAlert()
        alert.messageText = "Uninstall JXProxy?"
        alert.informativeText = "This stops the proxy and removes everything JXProxy wrote:\n\u{2022} routing settings in ~/.claude/settings.json\n\u{2022} launcher scripts (~/.local/bin/jx*)\n\u{2022} shell config blocks (.zshrc / .zshenv)\n\u{2022} leftover DNS hijack entries (if any, from old versions)\n\nYour API keys and the app itself are kept. You can reinstall anytime with install.sh."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let summary = manager.performUninstall()
        let done = NSAlert()
        done.messageText = "JXProxy Uninstalled"
        done.informativeText = summary
        done.addButton(withTitle: "OK")
        done.runModal()
    }
    
}

private struct DetailRow: View {
    let label: String
    let value: String
    var mono: Bool = false
    var copyable: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(Color.dsTextSecondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 10, design: mono ? .monospaced : .default))
                .foregroundStyle(Color.dsTextPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            if copyable {
                Button(action: { copyToPasteboard(value) }) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.dsTextSecondary)
                }
                .buttonStyle(.plain)
                .help("Copy \(label)")
                .accessibilityLabel("Copy \(label)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// A single label/value row in the status summary card.
private struct StatusSummaryRow: View {
    let icon: String
    let label: String
    let value: String
    var valueColor: Color = .dsTextPrimary

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(Color.dsTextSecondary)
                .frame(width: 16)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Color.dsTextSecondary)
            Spacer()
            Text(value)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(valueColor)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: - Onboarding Splash

/// First-launch tutorial splash: explains what JXProxy does and how to use it
/// in plain language, then hands the user to the app.
private struct OnboardingView: View {
    let onDone: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Header
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color.dsAccentDim)
                        .frame(width: 56, height: 56)
                    Image(systemName: "bolt.shield.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(Color.dsAccent)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Welcome to JXProxy")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(Color.dsTextPrimary)
                    Text("One AI router for Claude Code")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.dsTextSecondary)
                }
                Spacer()
            }

            Divider().overlay(Color.dsBorder)

            onboardingStep(
                number: "1",
                title: "Choose a provider",
                body: "Open Settings → General and pick where Claude's traffic should go — Anthropic, OpenRouter, DeepSeek, a free provider, or a local model like Ollama. Add your API key in Settings → Providers (a green tick confirms it works)."
            )
            onboardingStep(
                number: "2",
                title: "Start the proxy",
                body: "Click Start. JXProxy intercepts all api.anthropic.com traffic automatically and routes every tier — Opus, Sonnet, Haiku — to the models you chose. No terminal commands needed."
            )
            onboardingStep(
                number: "3",
                title: "Use Claude as usual",
                body: "Just open Terminal and type `claude`. It's routed through JXProxy from any window, even if your shell config sets model overrides — JXProxy handles that for you."
            )

            HStack {
                Text("Claude Code not installed? Click Start anyway — JXProxy will offer to install it.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.dsTextTertiary)
                Spacer()
            }

            HStack {
                Spacer()
                Button("Get Started") {
                    onDone()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .padding(28)
        .frame(width: 520)
        .background(Color.dsBackground)
    }

    private func onboardingStep(number: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.dsBackground)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.dsAccent))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.dsTextPrimary)
                Text(body)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.dsTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
