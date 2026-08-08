import SwiftUI

// MARK: - App Delegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemManager: StatusItemManager?
    private var signalSources: [DispatchSourceSignal] = []
    private var signalCleanupDone = false

    /// Called once on app launch.
    func applicationDidFinishLaunching(_ notification: Notification) {
        let manager = ProxyManager.shared

        // Create the status-bar + window manager (replaces MenuBarExtra).
        statusItemManager = StatusItemManager(proxyManager: manager)

        // Install termination-signal handlers so `killall JXRouter`, logout,
        // and Ctrl-C clean up the system proxy before the process dies.
        // SIGTERM does NOT run applicationWillTerminate — without this, a
        // scripted kill leaves the system proxy pointing at a dead port and
        // ALL internet breaks until the app is relaunched.
        installSignalHandlers()

        // Stale-state sweep: if the app was force-killed last time, the system
        // proxy may still point at a dead port on ANY network interface. Clear
        // it all, plus any leftover DNS/pf redirection from the old session.
        manager.discoverNetworkInterfaces()
        manager.querySystemProxyState()
        if manager.systemProxyEnabled {
            print("[AppDelegate] Stale system proxy detected from previous session — disabling on all interfaces")
            manager.disableSystemProxy()
        }

        // Stale-state sweep: if the app was force-killed last time, stale DNS
        // entries may still hijack AI hosts. When auto-start is OFF, clean them
        // up now (one admin prompt only when something is actually installed).
        // When auto-start is ON but DNS redirection is DISABLED in settings,
        // entries must still be swept — the proxy won't reinstall them, so a
        // stale hijack would silently keep routing traffic the user turned off.
        // Only when auto-start + redirection are both ON does startProxy()
        // re-apply/repair below via the idempotent install (no double teardown).
        let autoStart = UserDefaults.standard.bool(forKey: "autoStartProxy")
        let dnsEnabled = ConfigManager.shared.dnsRedirectEnabled
        if !autoStart || !dnsEnabled {
            DNSRedirectionManager.shared.uninstall()
        }

        // Stale-state sweep: if the app was force-killed last time, the routing
        // block in ~/.claude/settings.json may still point Claude at the (now
        // dead) proxy port. Clear it — unless the proxy is about to auto-start,
        // in which case startProxy() re-applies it a moment later.
        if !UserDefaults.standard.bool(forKey: "autoStartProxy") {
            ClaudeSettingsWriter.shared.remove()
        }

        // Auto-start the proxy on app launch if enabled in Settings.
        if UserDefaults.standard.bool(forKey: "autoStartProxy") {
            Task { @MainActor in
                await manager.startProxy()
            }
        }
    }

    /// User-initiated quit: full cleanup — system proxy (all interfaces) plus
    /// DNS/pf redirection. (An admin prompt appears only when redirection is
    /// actually installed.) stopProxy() already disables the system proxy on
    /// every interface, so no separate emergency cleanup is needed here.
    func applicationWillTerminate(_ notification: Notification) {
        ProxyManager.shared.stopProxy()
    }

    // MARK: - Termination Signal Handling

    /// Redirect SIGTERM/SIGINT/SIGHUP to a dispatch source so the app can
    /// disable the system proxy (prompt-free) before exiting. Without a
    /// handler, the default action terminates the process immediately and
    /// skips every cleanup path.
    private func installSignalHandlers() {
        let queue = DispatchQueue(label: "com.jxproxy.termination-signals")
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: queue)
            source.setEventHandler { [weak self] in
                Task { @MainActor in
                    self?.handleTerminationSignal()
                }
            }
            source.resume()
            signalSources.append(source)
        }
    }

    @MainActor
    private func handleTerminationSignal() {
        guard !signalCleanupDone else { return }
        signalCleanupDone = true
        print("[AppDelegate] ⚠ Termination signal received — disabling system proxy")
        ProxyManager.shared.emergencyCleanup()
        exit(0)
    }
}

// MARK: - App Scene

@main
struct JXRouterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // The main window is managed programmatically by StatusItemManager.
        // No MenuBarExtra or WindowGroup scene here — the app lives in the
        // menu bar with an NSStatusItem and shows/hides a real window.

        Settings {
            SettingsView(manager: ProxyManager.shared)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 560, height: 780)

        // MARK: - Keyboard Shortcuts (registered via the invisible menu bar)

        .commands {
            CommandGroup(before: .windowArrangement) {
                Divider()
            }

            CommandMenu("Proxy") {
                Button("Restart Proxy") {
                    Task { await ProxyManager.shared.restartProxy() }
                }
                .keyboardShortcut("r", modifiers: .command)

                Button("Toggle Proxy") {
                    Task {
                        if ProxyManager.shared.isRunning {
                            await ProxyManager.shared.stopProxy()
                        } else {
                            await ProxyManager.shared.startProxy()
                        }
                    }
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])

                Divider()

                Button("Export Configuration…") {
                    exportConfig()
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])

                Divider()

                Button("Open Settings…") {
                    openSettingsWindow()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }

    /// Export config as a text file opened in the default editor.
    private func exportConfig() {
        let config = ProxyManager.shared.exportConfig()
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("jxproxy-config.txt")
        try? config.write(to: tempURL, atomically: true, encoding: .utf8)
        NSWorkspace.shared.open(tempURL)
    }

    /// Open the settings window programmatically via the standard Settings scene.
    private func openSettingsWindow() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: NSApp, from: nil)
    }
}
