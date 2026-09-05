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

        // Capture uncaught NSExceptions (e.g. the recurring window-layout
        // crash) with their actual reason before the process dies, so the
        // crash is diagnosable from the log alone.
        NSSetUncaughtExceptionHandler { exception in
            let reason = "\(exception.name.rawValue): \(exception.reason ?? "(no reason)")"
            let stack = exception.callStackSymbols.prefix(20).joined(separator: "\n")
            let entry = "\(ISO8601DateFormatter().string(from: Date())) EXCEPTION \(reason)\n\(stack)\n"
            // FileHandle(forWritingAtPath:) requires the file to already exist —
            // create it first so the FIRST crash is always captured.
            let logURL = URL(fileURLWithPath: "/tmp/jxproxy-crash.log")
            if !FileManager.default.fileExists(atPath: logURL.path) {
                FileManager.default.createFile(atPath: logURL.path, contents: nil)
            }
            if let data = entry.data(using: .utf8),
               let handle = try? FileHandle(forWritingTo: logURL) {
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                handle.write(data)
            }

            // Permanent fix: a crash must NOT strand the System-Wide Proxy on
            // a dead port — that kills internet for every app on the machine
            // until a relaunch (the launch sweep clears it). emergencyDisable-
            // AllInterfaces is nonisolated and spawns networksetup directly,
            // so it is safe to call from this C-context handler on the
            // crashing thread (best-effort — the process is dying anyway).
            SystemProxyManager.emergencyDisableAllInterfaces()
        }

        // Menu-bar agent (LSUIElement = true): macOS may auto-terminate an
        // "inactive" background-only app — but this app must keep serving the
        // proxy (Claude Code & co. route through it continuously), so opt out
        // of automatic termination explicitly.
        ProcessInfo.processInfo.disableAutomaticTermination("com.jxproxy.proxy-server")

        // Create the status-bar + window manager (replaces MenuBarExtra).
        statusItemManager = StatusItemManager(proxyManager: manager)

        // Install termination-signal handlers so `killall JXRouter`, logout,
        // and Ctrl-C clean up the system proxy before the process dies.
        // SIGTERM does NOT run applicationWillTerminate — without this, a
        // scripted kill leaves the system proxy pointing at a dead port and
        // ALL internet breaks until the app is relaunched.
        installSignalHandlers()

        // Register for NSWorkspace sleep/wake notifications to suspend and
        // resume the proxy around system sleep — prevents stale connections
        // from piling up during sleep and avoids the watchdog thinking the
        // proxy is dead while the machine is actually asleep.
        NotificationCenter.default.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { _ in
            print("[AppDelegate] System going to sleep — pausing proxy")
            // queue: .main guarantees main-thread execution; use assumeIsolated
            // to satisfy @MainActor isolation without async overhead.
            MainActor.assumeIsolated {
                manager.stopProxy()
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { _ in
            if UserDefaults.standard.bool(forKey: "autoStartProxy") {
                print("[AppDelegate] System woke — auto-restarting proxy")
                Task { @MainActor in
                    await manager.startProxy()
                }
            }
        }

        // Stale-state sweep: if the app was force-killed last time, the system
        // proxy may still point at a dead port on ANY network interface. Clear
        // it all, plus any leftover DNS/pf redirection from the old session.
        manager.discoverNetworkInterfaces()
        manager.querySystemProxyState()
        if manager.systemProxyEnabled {
            print("[AppDelegate] Stale system proxy detected from previous session — disabling on all interfaces")
            manager.disableSystemProxy()
        }

        // Stale-state sweep: the app NEVER installs DNS/pf hijacking anymore
        // (see DNSRedirectionManager), but old versions may have left /etc/hosts
        // hijack blocks or a pf anchor behind. Sweep them unconditionally — it
        // is a no-op with no admin prompt when the system is already clean.
        DNSRedirectionManager.shared.uninstall()

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
        // Cancel signal dispatch sources so they don't fire after the proxy
        // has stopped — they hold strong references to `self` through the
        // closure, so failing to cancel leaks the AppDelegate and prevents
        // deallocation until the process exits.
        for source in signalSources {
            source.cancel()
        }
        signalSources.removeAll()
        // applicationWillTerminate is always called on the main thread by AppKit,
        // so MainActor.assumeIsolated is safe here and eliminates the
        // "call to main actor-isolated instance method in nonisolated context"
        // warning without adding async/Task overhead at process-exit time.
        MainActor.assumeIsolated {
            ProxyManager.shared.stopProxy()
        }
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

        Settings { EmptyView() }
        // SwiftUI Settings scene is required for .commands to compile.
        // The real Settings window is a standalone NSWindow in
        // StatusItemManager.openSettingsWindow().

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
                        // stopProxy() is synchronous — no await needed (the Task
                        // inherits this MainActor context).
                        if ProxyManager.shared.isRunning {
                            ProxyManager.shared.stopProxy()
                        } else {
                            await ProxyManager.shared.startProxy()
                        }
                    }
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])

                Divider()

                Button("Open Vault Workspace") {
                    openVaultWorkspace()
                }
                .keyboardShortcut("v", modifiers: [.command, .shift])

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

    /// Open the settings window — posts a notification that StatusItemManager
    /// handles (creates a standalone NSWindow, positions it, pairs it).
    private func openSettingsWindow() {
        NotificationCenter.default.post(name: .jxproxyOpenSettings, object: nil)
    }

    /// Open the Vault workspace window.
    private func openVaultWorkspace() {
        NotificationCenter.default.post(name: .jxproxyOpenVault, object: nil)
    }
}
