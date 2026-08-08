import Foundation
import Observation
import SwiftUI
import ServiceManagement

@MainActor
@Observable
final class ProxyManager {
    // MARK: - Singleton

    static let shared = ProxyManager()

    // MARK: - Config
    private let config = ConfigManager.shared

    // MARK: - Proxy State
    var isRunning: Bool = false
    var currentPort: Int {
        config.port
    }
    var currentModel: String {
        config.model
    }

    // MARK: - Dashboard Connection Details

    /// Loopback proxy address clients point at (e.g. 127.0.0.1:5255).
    var proxyAddress: String {
        "127.0.0.1:\(config.port)"
    }

    /// TLS listener port (proxy port + 1) used by DNS-redirected HTTPS traffic.
    var tlsPort: Int {
        config.port + 1
    }

    /// Display name of the active provider.
    var activeProviderName: String {
        ProviderPreset.preset(for: config.provider)?.name ?? config.provider
    }

    /// Resolved backend URL of the active provider.
    var activeProviderBackend: String {
        config.baseUrl(for: config.provider)
    }

    /// Proxy auth token clients must send as x-api-key.
    var authToken: String {
        config.authToken
    }
    var currentProvider: String = "opencode-zen"
    var activeModel: String = "big-pickle"
    var latency: Double {
        config.lastLatencyMs
    }
    var configEnv: [String: String] = [:]

    // MARK: - Built-in Proxy Server
    var proxyServer = ProxyServer()
    var systemProxyManager = SystemProxyManager()
    var builtInProxyRunning = false
    var systemProxyEnabled = false

    // MARK: - Provider Management
    var providers: [ProviderSettings] = [] {
        didSet { if autoSave { scheduleSave() } }
    }
    var fallbackOrder: [String] = [] {
        didSet { if autoSave { scheduleSave() } }
    }
    var providerBackendUrls: [String: String] = [:] {
        didSet { if autoSave { scheduleSave() } }
    }
    var visibleModels: [String: [String]] = [:] {
        didSet { if autoSave { scheduleSave() } }
    }

    // MARK: - UI State
    var lockUI: Bool = false
    var autoSave: Bool = true
    @ObservationIgnored
    var hasOpenedClaudeFirstTime: Bool {
        get { UserDefaults.standard.bool(forKey: "hasOpenedClaudeFirstTime") }
        set { UserDefaults.standard.set(newValue, forKey: "hasOpenedClaudeFirstTime") }
    }
    var showClaudeInstallPrompt = false
    var autoLaunchEnabled: Bool = false {
        didSet { applyAutoLaunch() }
    }

    /// Published error message for UI display (nil = no error).
    var errorMessage: String? = nil

    /// True if the error has been acknowledged by the user.
    var errorAcknowledged: Bool = false

    // MARK: - Traffic
    var trafficLog = TrafficLog()
    var appDetector = AppDetector()
    var startTime: Date? = nil
    
    var uptime: TimeInterval {
        guard let startTime = startTime else { return 0 }
        return Date().timeIntervalSince(startTime)
    }

    // MARK: - App Rules
    var appRoutes: [AppRouteRule] = [] {
        didSet { if autoSave { saveAppRoutesToConfig() } }
    }

    // MARK: - Provider Router
    var providerRouter = ProviderRouter()

    private var saveTask: Task<Void, Never>?
    private var saveDebounce: Date = .init()

    /// Whether the active provider has an API key configured.
    var keysConfigured: Bool {
        !config.apiKey(for: config.provider).isEmpty
    }

    /// Whether DNS redirection is enabled (redirects AI hosts to local proxy).
    var dnsRedirectEnabled: Bool {
        get { config.dnsRedirectEnabled }
        set { config.dnsRedirectEnabled = newValue; proxyServer.dnsRedirectEnabled = newValue }
    }

    /// Whether this is the very first launch (no keys anywhere).
    var isFirstLaunch: Bool {
        config.apiKey(for: "opencode-zen").isEmpty
            && config.apiKey(for: "direct").isEmpty
            && config.apiKey(for: "openrouter").isEmpty
            && config.apiKey(for: "openai").isEmpty
    }

    /// Whether the user has configured any provider API key — built-in
    /// key-requiring providers or named custom providers. Used to auto-show the
    /// free API key guide after the first-launch onboarding splash.
    var hasNoProviderKey: Bool {
        let builtIn = ProviderPreset.all.contains { preset in
            preset.requiresKey && !config.apiKey(for: preset.id).isEmpty
        }
        let custom = config.customProviders.contains { def in
            !config.apiKey(for: def.id).isEmpty
        }
        return !builtIn && !custom
    }

    private init() {
        config.providerRouter = providerRouter
        proxyServer.providerRouter = providerRouter
        proxyServer.onTrafficEntry = { @MainActor [weak self] entry in
            self?.trafficLog.append(entry)
        }
        loadAllFromConfig()
        proxyServer.port = resolvedPort(config.port)
        proxyServer.authToken = config.authToken
        autoLaunchEnabled = SMAppService.mainApp.status == .enabled

        // Listen for config changes
        config.onConfigChanged = { [weak self] in
            Task { @MainActor [weak self] in
                self?.syncFromConfig()
            }
        }
    }

    // MARK: - Load from Config

    func loadAllFromConfig() {
        currentProvider = config.provider
        activeModel = config.model
        proxyServer.authToken = config.authToken
        proxyServer.port = resolvedPort(config.port)
        proxyServer.dnsRedirectEnabled = config.dnsRedirectEnabled

        loadProvidersFromConfig()
        loadFallbackOrder()
        loadAppRoutesFromConfig()
    }

    private func syncFromConfig() {
        proxyServer.port = resolvedPort(config.port)
        proxyServer.authToken = config.authToken
        proxyServer.dnsRedirectEnabled = config.dnsRedirectEnabled
    }

    private func loadProvidersFromConfig() {
        let configuredIds = config.enabledProviders
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let visibleRaw = config.visibleModelsRaw
        var parsedVisible: [String: [String]] = [:]
        for chunk in visibleRaw.components(separatedBy: ";") {
            let parts = chunk.components(separatedBy: "=")
            if parts.count == 2 {
                parsedVisible[parts[0]] = parts[1].components(separatedBy: ",")
            }
        }
        visibleModels = parsedVisible

        providers = ProviderPreset.all.map { preset in
            let isEnabled = configuredIds.isEmpty || configuredIds.contains(preset.id)
            let url = config.baseUrl(for: preset.id)
            let models = parsedVisible[preset.id] ?? preset.models
            let key = config.apiKey(for: preset.id)
            return ProviderSettings(
                id: preset.id,
                enabled: isEnabled,
                backendUrl: url,
                visibleModelIds: Set(models),
                apiKey: key
            )
        }
    }

    private func loadFallbackOrder() {
        fallbackOrder = config.fallbackProviders
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
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

    // MARK: - Auto-Save

    private func scheduleSave() {
        saveTask?.cancel()
        saveDebounce = Date()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard let self, !Task.isCancelled else { return }
            flushSave()
        }
    }

    func flushSave() {
        config.enabledProviders = providers.filter(\.enabled).map(\.id).joined(separator: ",")

        let visibleStr = providers.map { p in
            "\(p.id)=\(p.visibleModelIds.joined(separator: ","))"
        }.joined(separator: ";")
        config.visibleModelsRaw = visibleStr

        for p in providers {
            config.setApiKey(chainKey: apiChainKey(for: p.id), value: p.apiKey)
        }
        saveAppRoutesToConfig()
    }

    private func apiChainKey(for providerId: String) -> String {
        switch providerId {
        case "direct": return ConfigManager.KeychainKey.anthropic
        case "openrouter": return ConfigManager.KeychainKey.openrouter
        case "opencode-zen", "opencode-go": return ConfigManager.KeychainKey.opencode
        case "openai": return ConfigManager.KeychainKey.openai
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
        case "custom": return ConfigManager.KeychainKey.custom
        default: return "\(providerId.uppercased())_API_KEY"
        }
    }

    // MARK: - Config Modifiers

    func setProvider(_ provider: String) {
        config.provider = provider
        currentProvider = provider
    }

    func setModel(_ model: String) {
        config.model = model
        activeModel = model
    }

    func setApiKey(key: String, value: String) {
        config.setApiKey(chainKey: key, value: value)
    }

    // MARK: - System Proxy

    func enableSystemProxy(port: Int) {
        setBuiltInProxyPort(resolvedPort(port))
        if !builtInProxyRunning {
            setError("System-Wide Proxy is enabled but the proxy is not running — apps will lose internet access until the proxy is started.")
        }
        systemProxyManager.enable()
        systemProxyEnabled = true
    }

    func disableSystemProxy() {
        systemProxyManager.disable()
        systemProxyEnabled = false
    }

    // MARK: - Controls

    func startProxy() async {
        guard !builtInProxyRunning else { return }  // Already running

        lockUI = true
        errorMessage = nil
        errorAcknowledged = false
        appDetector.start(port: Int(proxyServer.port))
        defer { lockUI = false }

        do {
            // Sync system proxy port with the configured port before starting
            setBuiltInProxyPort(proxyServer.port)

            // Consent gate: re-sync the DNS toggle so ProxyServer skips
            // installDNS when the user turned DNS redirection off.
            proxyServer.dnsRedirectEnabled = config.dnsRedirectEnabled

            try proxyServer.start(port: proxyServer.port)
            builtInProxyRunning = true
            startTime = Date()
            isRunning = true

            // Consent gate: only touch macOS proxy settings when the
            // "Enable System-Wide Proxy" toggle is on. Otherwise the proxy
            // runs loopback-only for launcher clients.
            if systemProxyEnabled {
                systemProxyManager.discoverInterfaces()
                systemProxyManager.enable()
                systemProxyEnabled = true
            } else {
                print("[ProxyManager] System proxy toggle off — leaving macOS proxy settings untouched")
            }

            // Install/reinstall launcher scripts with current provider+model
            installLauncherScripts()

            // Route Claude Code through the proxy from ANY launch context:
            // write the env block into ~/.claude/settings.json (base URL +
            // auth token + ANTHROPIC_DEFAULT_* neutralisation). Removed on stop.
            ClaudeSettingsWriter.shared.apply(proxyPort: config.port, authToken: config.authToken)

            // Seed Claude Code's constitution (~/.claude/CLAUDE.md) with the
            // bundled AGENTS.md (Joshua's Will + mandatory rules) so Claude
            // Code integrates with them at its core. User-authored content
            // already in the constitution is preserved (absorbed).
            ConstitutionManager.shared.apply()

            // Install replacement skills (web-search-free, web-fetch-free,
            // shell-ops, file-editor, desktop-automation) into ~/.claude/skills/
            // so they're available as mandatory overrides for broken native tools.
            SkillManager.shared.apply()

            // First-time Claude Code launch
            if !hasOpenedClaudeFirstTime {
                checkAndLaunchClaude()
            }
        } catch {
            setError("Failed to start proxy: \(error.localizedDescription)")
        }
    }

    func stopProxy() {
        lockUI = true
        defer { lockUI = false }

        proxyServer.stop()
        builtInProxyRunning = false
        isRunning = false
        startTime = nil
        appDetector.stop()

        // Disable system proxy so apps don't route to a dead port
        systemProxyManager.disable()
        systemProxyEnabled = false

        // Stop routing Claude Code through the proxy: restore the user's
        // original ~/.claude/settings.json from backup.
        ClaudeSettingsWriter.shared.remove()

        // Remove JXRouter-managed replacement skills from ~/.claude/skills/.
        SkillManager.shared.remove()
    }

    // MARK: - Comprehensive Recovery (Restart)

    /// Full circuit-breaker recovery. Handles every failure mode that can prevent
    /// the proxy from serving: port conflicts, stale PF rules, stuck DNS entries,
    /// misconfigured system proxy, changed network interfaces, zombie processes,
    /// corrupted certificate store, keychain lockups, and cached DNS poison.
    func restartProxy() async {
        print("[Recovery] ═══ Starting full circuit-breaker recovery ═══")

        // Keep healthy DNS redirection in place across the restart. Tearing it
        // down and reinstalling would trigger two osascript admin prompts for
        // zero benefit; install() is idempotent and re-verifies on the way up.
        // The health check must run BEFORE stopProxy — once the TLS listener is
        // down, the connectivity probe can't succeed, so a post-stop check
        // would falsely report "not installed".
        // Gate on dnsRedirectEnabled too: when the user turned redirection OFF,
        // stale entries must still be cleaned (no suppression), so the hijack
        // never silently keeps running against their wishes.
        let dnsHealthy = config.dnsRedirectEnabled && DNSRedirectionManager.shared.isInstalled()
        DNSRedirectionManager.shared.suppressUninstall = dnsHealthy
        print("[Recovery] ✓ Proxy stopped")

        // 2. Kill any process holding the proxy port
        let port = Int(proxyServer.port)
        recoverKillPort(port)
        try? await Task.sleep(nanoseconds: 300_000_000)

        // 3. Re-check and re-kill if still occupied
        if recoverPortIsBusy(port) {
            recoverKillPort(port)
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        print("[Recovery] ✓ Port \(port) freed")

        // 4. Flush any stale PF anchor from a previous crash/kill
        recoverFlushPF()
        print("[Recovery] ✓ PF rules flushed")

        // 5. Clean up stale /etc/hosts entries — only when redirection was NOT
        //    healthy before the restart. Healthy redirection is preserved (the
        //    suppressed uninstall in stopProxy left it untouched), so a plain
        //    restart no longer prompts for admin twice.
        if !dnsHealthy {
            DNSRedirectionManager.shared.uninstall()
            print("[Recovery] ✓ Stale DNS entries cleaned")
        } else {
            print("[Recovery] ✓ DNS redirection already functional — preserved")
        }
        // Re-enable prompts; install() below re-verifies idempotently and only
        // prompts when the preserved state actually needs repair.
        DNSRedirectionManager.shared.suppressUninstall = false

        // 6. Reset system proxy on ALL network interfaces (not just the cached one),
        //    not just the selected interface. This handles the case where the
        //    interface changed (Wi-Fi → Ethernet) between sessions.
        systemProxyManager.discoverInterfaces()
        systemProxyManager.disable()
        print("[Recovery] ✓ System proxy disabled on all interfaces")

        // 7. Flush macOS DNS cache (dscacheutil + mDNSResponder)
        recoverFlushDNSCache()
        print("[Recovery] ✓ DNS cache flushed")

        // 8. Reset keychain unavailable flag (in case of previous timeout)
        KeychainManager.resetUnavailable()
        print("[Recovery] ✓ Keychain reset")

        // 9. Regenerate CA if corrupted / missing
        if !CertificateAuthority.shared.ensureCA() {
            print("[Recovery] ⚠ Failed to regenerate CA")
        } else {
            print("[Recovery] ✓ CA ready")
        }

        // 10. Reset proxy server internals (clear error state, restart count, etc.)
        proxyServer.resetForRestart()
        print("[Recovery] ✓ Proxy server internals reset")

        // 11. Fresh start — creates new NWListener, enables system proxy,
        //     installs DNS redirection, regenerates launcher scripts
        await startProxy()
        print("[Recovery] ✓ Proxy started")

        print("[Recovery] ═══ Recovery complete ═══")
    }

    /// Kill processes holding the given port ONLY when their executable or
    /// loaded libraries belong to this app bundle (CWE-404 fix). Unrelated
    /// processes on the port are logged and left alive. Self is always skipped.
    private func recoverKillPort(_ port: Int) {
        let selfPID = String(ProcessInfo.processInfo.processIdentifier)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments = ["-ti", ":\(port)", "-sTCP:LISTEN"]
        let outPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            let pids = String(data: data, encoding: .utf8)?
                .components(separatedBy: .newlines)
                .filter { !$0.isEmpty }
            for pid in pids ?? [] {
                guard pid != selfPID else {
                    print("[Recovery] Skipping self PID \(pid)")
                    continue
                }
                guard let owningPaths = textFilePaths(ofPID: pid) else {
                    print("[Recovery] PID \(pid) on port \(port): cannot determine executable — leaving alive")
                    continue
                }
                if owningPaths.contains(where: { belongsToThisApp($0) }) {
                    let killTask = Process()
                    killTask.executableURL = URL(fileURLWithPath: "/bin/kill")
                    killTask.arguments = ["-9", pid]
                    try? killTask.run()
                    killTask.waitUntilExit()
                    print("[Recovery] Killed PID \(pid) (\(owningPaths[0])) holding port \(port) — owned by this app")
                } else {
                    print("[Recovery] PID \(pid) on port \(port) does not belong to this app (\(owningPaths[0])) — leaving alive")
                }
            }
        } catch {
            print("[Recovery] killPort error: \(error)")
        }
    }

    /// Text-file (executable + loaded libraries) paths for a PID via
    /// `lsof -a -p <pid> -d txt -Fn`. Returns nil when lsof yields nothing.
    private func textFilePaths(ofPID pid: String) -> [String]? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments = ["-a", "-p", pid, "-d", "txt", "-Fn"]
        let outPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            let paths = output.components(separatedBy: .newlines)
                .compactMap { line -> String? in
                    guard line.hasPrefix("n") else { return nil }
                    let path = String(line.dropFirst())
                    return path.isEmpty ? nil : path
                }
            return paths.isEmpty ? nil : paths
        } catch {
            return nil
        }
    }

    /// True when the given file path lives inside this app's bundle.
    private func belongsToThisApp(_ path: String) -> Bool {
        let bundlePath = Bundle.main.bundlePath
        return path == bundlePath || path.hasPrefix(bundlePath + "/")
    }

    /// Check whether something is already listening on the port.
    private func recoverPortIsBusy(_ port: Int) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments = ["-ti", ":\(port)", "-sTCP:LISTEN"]
        let outPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            let pids = String(data: data, encoding: .utf8)?
                .components(separatedBy: .newlines)
                .filter { !$0.isEmpty }
            return (pids ?? []).count > 0
        } catch {
            return false
        }
    }

    /// Flush the JXProxy PF anchor if it exists. Ignores failures silently
    /// (anchor may not exist if it was never installed).
    private func recoverFlushPF() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/sbin/pfctl")
        task.arguments = ["-a", "com.apple/250.jxproxy", "-F", "all"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            // Non-fatal — anchor might not exist
        }
    }

    /// Flush macOS DNS cache (works on macOS 14+).
    private func recoverFlushDNSCache() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/dscacheutil")
        task.arguments = ["-flushcache"]
        try? task.run()
        task.waitUntilExit()

        // Also signal mDNSResponder to flush
        let mTask = Process()
        mTask.executableURL = URL(fileURLWithPath: "/bin/kill")
        mTask.arguments = ["-HUP", "mDNSResponderHelper"]
        try? mTask.run()
        mTask.waitUntilExit()
    }

    private func checkAndLaunchClaude() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Check standard paths where npm installs global binaries
        task.arguments = ["-c", "if [ -x \"/opt/homebrew/bin/claude\" ]; then exit 0; elif [ -x \"$HOME/.npm-global/bin/claude\" ]; then exit 0; elif command -v claude >/dev/null 2>&1; then exit 0; else exit 1; fi"]
        
        do {
            try task.run()
            task.waitUntilExit()
            if task.terminationStatus == 0 {
                // Found claude, launch it
                DispatchQueue.main.async {
                    self.launchClaudeInTerminal()
                    self.hasOpenedClaudeFirstTime = true
                }
            } else {
                // Not found, prompt install
                DispatchQueue.main.async {
                    self.showClaudeInstallPrompt = true
                }
            }
        } catch {
            print("Error checking for claude: \\(error)")
        }
    }

    private func launchClaudeInTerminal() {
        let modelFlag: String
        let modelName = config.model
        if modelName.isEmpty { modelFlag = "" }
        else { modelFlag = "-m \(modelName) " }
        let cmd = "claude \(modelFlag)&& exec $SHELL"
        let appleScript = """
        tell application "Terminal"
            activate
            do script "\(cmd)"
        end tell
        """
        if let script = NSAppleScript(source: appleScript) {
            var error: NSDictionary?
            script.executeAndReturnError(&error)
            if let error = error {
                print("Failed to launch Terminal: \(error)")
            }
        }
    }

    func installAndLaunchClaude() {
        Task {
            do {
                // npm must exist before we attempt the global install.
                let npmCheck = Process()
                npmCheck.executableURL = URL(fileURLWithPath: "/bin/sh")
                npmCheck.arguments = ["-c", "command -v npm >/dev/null 2>&1 || command -v bun >/dev/null 2>&1"]
                try npmCheck.run()
                npmCheck.waitUntilExit()
                guard npmCheck.terminationStatus == 0 else {
                    setError("Could not install Claude Code: npm (or bun) is not installed. Install Node.js from https://nodejs.org, then press Start again.")
                    return
                }

                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/bin/sh")
                task.arguments = ["-c", "npm install -g @anthropic-ai/claude-code"]
                try task.run()
                task.waitUntilExit()
                
                if task.terminationStatus == 0 {
                    DispatchQueue.main.async {
                        if self.claudeCodeInstalled() {
                            self.launchClaudeInTerminal()
                            self.hasOpenedClaudeFirstTime = true
                        } else {
                            self.setError("Claude Code was installed but the `claude` command isn't on PATH yet. Open a new Terminal window and run `claude` — it is now routed through JXProxy.")
                            self.hasOpenedClaudeFirstTime = true
                        }
                    }
                } else {
                    setError("Failed to install Claude Code. Make sure npm is installed: npm install -g @anthropic-ai/claude-code")
                }
            } catch {
                setError("Error running install command: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Claude Code Presence & Install

    /// Whether the Claude Code CLI is installed (checks PATH + common locations).
    func claudeCodeInstalled() -> Bool {
        let paths = [
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(NSHomeDirectory())/.npm-global/bin/claude",
            "\(NSHomeDirectory())/.local/bin/claude",
        ]
        if paths.contains(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return true }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "command -v claude >/dev/null 2>&1"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }

    // MARK: - Uninstall

    /// Removes everything JXProxy wrote while running / installing — claude
    /// settings.json routing, launcher scripts, and the shell-config blocks.
    /// The app bundle itself is left in place (deleting a running app is
    /// handled by the uninstall script / Finder). Returns a summary message.
    func performUninstall() -> String {
        // 1. Stop the proxy (also restores ~/.claude/settings.json and removes DNS).
        if isRunning { stopProxy() }

        // 2. Belt & suspenders: ensure the claude settings env block is gone.
        ClaudeSettingsWriter.shared.remove()

        // 3. Remove launcher scripts we generated.
        let localBin = NSString(string: "~/.local/bin").expandingTildeInPath
        for name in ["jxclaude", "jxcodex", "jxpi", "jxserver", "llama-local", "llama-chat-template.txt"] {
            try? FileManager.default.removeItem(atPath: "\(localBin)/\(name)")
        }

        // 4. Remove the JXProxy blocks (PATH + protective alias) from shell configs.
        for config in [".zshrc", ".bashrc", ".zshenv", ".bash_profile"] {
            removeShellConfigBlock(config)
        }

        // 5. Remove the JXProxy-managed constitution block (~/.claude/CLAUDE.md),
        //    preserving any user-authored content that was absorbed.
        ConstitutionManager.shared.remove()

        // 6. Remove JXRouter-managed replacement skills (~/.claude/skills/).
        SkillManager.shared.remove()

        return "JXProxy has been stopped and every written setting was removed:\n\u{2022} ~/.claude/settings.json restored to its original state\n\u{2022} launcher scripts (~/.local/bin/jx*) deleted\n\u{2022} shell config blocks (.zshrc / .zshenv / …) cleaned\n\u{2022} DNS redirection removed\n\u{2022} JXProxy constitution block removed from ~/.claude/CLAUDE.md\n\u{2022} Replacement skills removed from ~/.claude/skills/\n\nTo finish, delete /Applications/JXRouter.app (or run ./uninstall.sh)."
    }

    /// Remove the JXProxy configuration block and the protective claude alias
    /// from a single shell config file, keeping everything else intact.
    private func removeShellConfigBlock(_ fileName: String) {
        let path = "\(NSHomeDirectory())/\(fileName)"
        guard FileManager.default.fileExists(atPath: path),
              let content = try? String(contentsOfFile: path, encoding: .utf8) else { return }

        var lines: [String] = []
        var inBlock = false
        var changed = false
        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Everything between the block markers (config exports + the
            // protective alias) is removed together.
            if trimmed == "# JXProxy Configuration" { inBlock = true; changed = true; continue }
            if trimmed == "# End JXProxy" { inBlock = false; changed = true; continue }
            if inBlock { changed = true; continue }
            lines.append(line)
        }
        // Also strip any stray alias line that unsets the default models.
        if !changed, content.contains("alias claude=\"unset ANTHROPIC_DEFAULT") {
            lines = content.components(separatedBy: "\n").filter {
                !$0.contains("alias claude=\"unset ANTHROPIC_DEFAULT")
            }
            changed = true
        }
        guard changed else { return }
        try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    // MARK: - System Proxy Controls

    func setBuiltInProxyPort(_ port: UInt16) {
        proxyServer.port = port
        systemProxyManager.proxyPort = port
    }

    /// Safely converts a user-supplied port to `UInt16`, falling back to the
    /// default port (5255) when it is out of range (e.g. > 65535 or <= 0).
    private func resolvedPort(_ port: Int) -> UInt16 {
        guard port > 0, let p = UInt16(exactly: port) else {
            print("[ProxyManager] Invalid port \(port), using default 5255")
            return 5255
        }
        return p
    }

    func toggleSystemProxy() {
        if systemProxyManager.isEnabled {
            systemProxyManager.disable()
        } else {
            systemProxyManager.enable()
        }
        systemProxyEnabled = systemProxyManager.isEnabled
    }

    func discoverNetworkInterfaces() {
        systemProxyManager.discoverInterfaces()
    }

    func querySystemProxyState() {
        systemProxyManager.queryState()
        systemProxyEnabled = systemProxyManager.isEnabled
    }

    // MARK: - App Routes Sync

    private func saveAppRoutesToConfig() {
        guard let data = try? JSONEncoder().encode(appRoutes),
              let json = String(data: data, encoding: .utf8) else { return }
        config.appRoutesJSON = json
    }

    func addAppRule(url: URL) {
        let bundle = Bundle(url: url)
        let appName = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? url.deletingPathExtension().lastPathComponent
        let bundleId = bundle?.bundleIdentifier
        appRoutes.append(AppRouteRule(appName: appName, bundleIdentifier: bundleId, enabled: true, action: .routeAI))
    }

    // MARK: - Auto-Launch

    private func applyAutoLaunch() {
        do {
            if autoLaunchEnabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            setError("Auto-launch toggle failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Config Export / Import

    func exportConfig() -> String {
        var lines: [String] = []
        lines.append("# JXProxy Configuration (exported \(Date()))")
        lines.append("PORT=\(config.port)")
        lines.append("PROVIDER=\(config.provider)")
        lines.append("MODEL=\(config.model)")
        lines.append("FALLBACK_PROVIDERS=\(config.fallbackProviders)")
        // Note: secrets are in Keychain, not exported
        lines.append("")
        lines.append("# API keys are stored in macOS Keychain (service: com.jxproxy)")
        lines.append("# To export keys, use: security dump-keychain -d ~/Library/Keychains/login.keychain-db")
        return lines.joined(separator: "\n")
    }

    func importConfig(_ content: String) {
        // Import from env-format string
        let env = parseSimpleEnv(content)
        if let portStr = env["PORT"], let port = Int(portStr) { config.port = port }
        if let provider = env["PROVIDER"] { config.provider = provider }
        if let model = env["MODEL"] { config.model = model }
        if let fallback = env["FALLBACK_PROVIDERS"] { config.fallbackProviders = fallback }
        loadAllFromConfig()
    }

    private func parseSimpleEnv(_ content: String) -> [String: String] {
        var env: [String: String] = [:]
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let parts = trimmed.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                env[String(parts[0]).trimmingCharacters(in: .whitespaces)] =
                    String(parts[1]).trimmingCharacters(in: .whitespaces)
            }
        }
        return env
    }

    // MARK: - Launcher Scripts

    /// Regenerate launcher scripts (jxclaude, jxcodex, etc.) with the current
    /// provider and model so `jxclaude` launches Claude Code with `-m <model>`.
    func installLauncherScripts() {
        let port = config.port
        let modelName = config.model
        let token = config.authToken
        do {
            try CustomLauncherService.installLaunchers(proxyPort: port, authToken: token, model: modelName)
        } catch {
            print("[ProxyManager] Failed to install launchers: \(error)")
        }
    }

    // MARK: - Error Handling

    func setError(_ message: String) {
        errorMessage = message
        errorAcknowledged = false
        print("[JXProxy] \(message)")

        // Write to persistent error log
        let logURL = errorLogURL()
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let entry = "[\(timestamp)] \(message)\n"
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            if let data = entry.data(using: .utf8) {
                handle.write(data)
            }
            try? handle.close()
        } else {
            try? entry.data(using: .utf8)?.write(to: logURL, options: .atomic)
        }
    }

    private func errorLogURL() -> URL {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        let logs = library.appendingPathComponent("Logs")
        return logs.appendingPathComponent("jxproxy-error.log")
    }

    func clearError() {
        errorMessage = nil
        errorAcknowledged = true
    }

    // MARK: - Termination Cleanup

    /// Synchronous, prompt-free cleanup for process termination — both normal
    /// quits and termination signals (SIGTERM/SIGINT from `killall JXRouter`,
    /// logout, Ctrl-C, which do NOT run `applicationWillTerminate`).
    ///
    /// The system proxy is the one setting that blocks ALL internet when stale,
    /// so it is cleared on every exit path. DNS/pf redirection is intentionally
    /// skipped here (it needs an admin prompt that would hang a signal exit);
    /// leftover redirection is cleaned by `stopProxy()` on normal quit and by
    /// the launch-time sweep after a kill.
    func emergencyCleanup() {
        print("[ProxyManager] 🧹 Emergency cleanup — disabling system proxy on all interfaces")
        systemProxyManager.disable()
        systemProxyEnabled = false
    }

    /// Set the network service the system proxy applies to (Settings picker).
    func setSystemProxyInterface(_ interface: String) {
        systemProxyManager.selectedInterface = interface
    }

    // MARK: - Health Check (simplified — passive)

    func checkStatus() {
        isRunning = builtInProxyRunning
    }
}
