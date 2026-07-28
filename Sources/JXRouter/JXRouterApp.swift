import SwiftUI

// MARK: - App Delegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemManager: StatusItemManager?

    /// Called once on app launch.
    func applicationDidFinishLaunching(_ notification: Notification) {
        let manager = ProxyManager.shared

        // Create the status-bar + window manager (replaces MenuBarExtra).
        statusItemManager = StatusItemManager(proxyManager: manager)

        // If the app was force-killed last time, the system proxy settings
        // may still point at a dead port. Clean up any stale state first.
        manager.discoverNetworkInterfaces()
        manager.querySystemProxyState()
        if manager.systemProxyEnabled {
            print("[AppDelegate] Stale system proxy detected from previous session — disabling")
            manager.disableSystemProxy()
            DNSRedirectionManager.shared.uninstall()
        }

        // Auto-start the proxy on app launch if enabled in Settings.
        if UserDefaults.standard.bool(forKey: "autoStartProxy") {
            Task { @MainActor in
                await manager.startProxy()
            }
        }
    }

    /// Clean up system proxy, DNS redirection, and PF rules before the process exits.
    /// Without this, the system proxy keeps pointing at 127.0.0.1:<port> (dead)
    /// and /etc/hosts + PF rules stay loaded — blocking all internet.
    func applicationWillTerminate(_ notification: Notification) {
        ProxyManager.shared.stopProxy()
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
        .defaultSize(width: 580, height: 700)

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
