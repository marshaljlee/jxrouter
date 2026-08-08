import AppKit
import SwiftUI
import Observation

// MARK: - Status Item Manager
//
// Replaces the SwiftUI MenuBarExtra with an AppKit NSStatusItem.
// Left-click toggles a persistent NSWindow; right-click shows a context menu.
// Window close/minimize hides to the menu bar; only Quit terminates the app.

@MainActor
final class StatusItemManager: NSObject {
    private var statusItem: NSStatusItem!
    private var window: NSWindow!
    private var proxyManager: ProxyManager

    // MARK: - Init

    init(proxyManager: ProxyManager) {
        self.proxyManager = proxyManager
        super.init()
        setupStatusItem()
        setupWindow()
        observeProxyState()
    }

    // MARK: - Status Item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.variableLength
        )

        guard let button = statusItem.button else { return }

        // Set initial icon
        let iconName = proxyManager.isRunning ? "bolt.fill" : "bolt.slash"
        button.image = NSImage(
            systemSymbolName: iconName,
            accessibilityDescription: "JXProxy"
        )
        button.image?.isTemplate = true

        // Custom view overlay to detect left vs. right click.
        // StatusItemButton does not natively differentiate them, so we
        // place a transparent NSView on top that handles both.
        let clickView = StatusBarClickView(frame: button.bounds)
        clickView.autoresizingMask = [.width, .height]
        clickView.onLeftClick = { [weak self] in
            self?.toggleWindow()
        }
        clickView.onRightClick = { [weak self] in
            self?.showContextMenu()
        }
        button.addSubview(clickView)
    }

    // MARK: - Window

    private func setupWindow() {
        let contentView = JXRouterView(manager: proxyManager)
        let hostingController = NSHostingController(rootView: contentView)
        
        if #available(macOS 13.0, *) {
            hostingController.sizingOptions = [.intrinsicContentSize]
        }

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 820),
            styleMask: [
                .titled,
                .closable,
                .miniaturizable,
                .resizable,
                .fullSizeContentView,
            ],
            backing: .buffered,
            defer: true
        )

        window.contentViewController = hostingController
        window.isReleasedWhenClosed = false
        window.delegate = self

        // Slim transparent title bar — the SwiftUI view provides the background
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "JXProxy"

        // Let the user drag the window from anywhere on the background
        window.isMovableByWindowBackground = true

        // Style the window background to match the SwiftUI material
        window.backgroundColor = .clear
        window.isOpaque = false

        // Allow the window to become key so keyboard events (Cmd+W etc.) work
        window.canBecomeVisibleWithoutLogin = false
    }

    /// Show or hide the main window.
    private func toggleWindow() {
        if window.isVisible {
            window.orderOut(nil)
        } else {
            positionWindow()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Position the window below the status item, centred horizontally.
    private func positionWindow() {
        guard let screen = NSScreen.main,
              let button = statusItem.button else { return }

        let buttonRectInScreen = button.window?.convertToScreen(button.frame)
            ?? .zero
        let windowWidth = window.frame.width
        let x = buttonRectInScreen.midX - windowWidth / 2
        let y = screen.visibleFrame.maxY - window.frame.height

        window.setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: - Context Menu

    private func showContextMenu() {
        guard let button = statusItem.button else { return }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(
            title: proxyManager.isRunning ? "Stop Proxy" : "Start Proxy",
            action: #selector(toggleProxyAction),
            keyEquivalent: "t"
        ))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(
            title: "Open Settings…",
            action: #selector(openSettingsAction),
            keyEquivalent: ","
        ))

        // Security — CA trust management
        menu.addItem(NSMenuItem.separator())
        let securityLabel = NSMenuItem(title: "Security", action: nil, keyEquivalent: "")
        securityLabel.isEnabled = false
        menu.addItem(securityLabel)
        menu.addItem(NSMenuItem(
            title: "Install CA Certificate…",
            action: #selector(installCACertificateAction),
            keyEquivalent: ""
        ))
        menu.addItem(NSMenuItem(
            title: "Remove CA Certificate…",
            action: #selector(removeCACertificateAction),
            keyEquivalent: ""
        ))

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(
            title: "Quit JXProxy",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))

        // Show the menu below the status item button
        let menuOrigin = NSPoint(x: 0, y: button.bounds.height + 5)
        menu.popUp(positioning: nil, at: menuOrigin, in: button)
    }

    @objc
    private func toggleProxyAction() {
        Task { @MainActor in
            if proxyManager.isRunning {
                await proxyManager.stopProxy()
            } else {
                await proxyManager.startProxy()
            }
        }
    }

    @objc
    private func openSettingsAction() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    // MARK: - CA Trust Management

    /// Path of the JXProxy CA certificate, mirroring `CertificateAuthority`
    /// (`~/Library/Application Support/JXProxy/ca-cert.pem`).
    private var caCertificatePath: String {
        let appDir = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return appDir
            .appendingPathComponent("JXProxy", isDirectory: true)
            .appendingPathComponent("ca-cert.pem")
            .path
    }

    /// Path of the user's login keychain.
    private var loginKeychainPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Keychains/login.keychain-db")
            .path
    }

    /// Common name of the JXProxy CA. `CertificateAuthority.generateCA()`
    /// signs it with `-subj /CN=JXProxy CA`.
    private var caCommonName: String { "JXProxy CA" }

    /// Consent-based install of the JXProxy CA into the login keychain,
    /// trusted as a root certificate for TLS interception.
    @objc
    private func installCACertificateAction() {
        guard confirm(
            title: "Install JXProxy CA Certificate?",
            message: "This trusts the JXProxy root certificate (\(caCommonName)) in your login keychain so JXProxy can intercept and inspect TLS traffic to AI providers.\n\nOnly do this if you trust this Mac and the JXProxy app. You can remove the certificate at any time from this menu.",
            confirmButton: "Install"
        ) else { return }

        let caPath = caCertificatePath
        let keychainPath = loginKeychainPath
        Task.detached(priority: .userInitiated) { [weak self] in
            // Make sure the CA has actually been generated before installing.
            guard CertificateAuthority.shared.ensureCA(),
                  FileManager.default.fileExists(atPath: caPath) else {
                await self?.presentError(
                    title: "CA Certificate Not Found",
                    message: "JXProxy could not generate its CA certificate at \(caPath), so nothing was installed."
                )
                return
            }
            let args = [
                "add-trusted-cert",
                "-d",
                "-r", "trustRoot",
                "-k", keychainPath,
                caPath,
            ]
            let result = invokeSecurity(args)
            await self?.finishSecurityRun(
                status: result.status,
                output: result.output,
                args: args,
                actionLabel: "Install CA Certificate"
            )
        }
    }

    /// Consent-based removal of the JXProxy CA from the login keychain.
    @objc
    private func removeCACertificateAction() {
        guard confirm(
            title: "Remove JXProxy CA Certificate?",
            message: "This removes the \(caCommonName) certificate from your login keychain. After removal, JXProxy's TLS interception will no longer be trusted by this Mac.",
            confirmButton: "Remove"
        ) else { return }

        let caName = caCommonName
        let keychainPath = loginKeychainPath
        Task.detached(priority: .userInitiated) { [weak self] in
            let args = ["delete-certificate", "-c", caName, "-k", keychainPath]
            let result = invokeSecurity(args)
            await self?.finishSecurityRun(
                status: result.status,
                output: result.output,
                args: args,
                actionLabel: "Remove CA Certificate"
            )
        }
    }

    /// Shows a modal confirmation dialog. Returns true when the user accepts.
    private func confirm(title: String, message: String, confirmButton: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: confirmButton)
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Shows a modal error dialog on the main actor.
    private func presentError(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// Handles the outcome of a `security` subprocess on the main actor:
    /// logs a completion line and surfaces failures via NSAlert.
    private func finishSecurityRun(
        status: Int32,
        output: String,
        args: [String],
        actionLabel: String
    ) {
        print("[CA Trust] \(actionLabel) completed: security \(args.joined(separator: " ")) -> exit \(status)")
        guard status != 0 else { return }
        let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
        presentError(
            title: "\(actionLabel) Failed",
            message: detail.isEmpty
                ? "The security command exited with code \(status)."
                : detail
        )
    }

    // MARK: - Icon Observation

    /// Observe the `@Observable` ProxyManager so the status item icon updates
    /// when the proxy starts or stops (even from background changes such as
    /// auto-restart or watchdog).
    private func observeProxyState() {
        // Recursive pattern: register observation, wait for change, update icon,
        // then re-register for the next change.
        withObservationTracking { [weak self] in
            _ = self?.proxyManager.isRunning
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.updateIcon()
                self.observeProxyState() // re-observe for next change
            }
        }
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        let iconName = proxyManager.isRunning ? "bolt.fill" : "bolt.slash"
        button.image = NSImage(
            systemSymbolName: iconName,
            accessibilityDescription: "JXProxy"
        )
        button.image?.isTemplate = true
    }

    deinit {
        // withObservationTracking does not hold a strong reference to the
        // onChange closure once it fires, but we are safe regardless.
    }
}

// MARK: - NSWindowDelegate

extension StatusItemManager: NSWindowDelegate {

    /// The close button (red dot) just hides the window instead of quitting.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    /// The minimise button (yellow dot) hides the window instead, since the
    /// app has no dock icon (LSUIElement = true) and a minimised window
    /// would be unreachable.
    func windowWillMiniaturize(_ notification: Notification) {
        guard let win = notification.object as? NSWindow else { return }
        win.orderOut(nil)
    }
}

// MARK: - Custom Click View

/// A transparent NSView placed on top of the status item button to detect
/// left-click vs. right-click. The system's NSStatusItemButton does not
/// provide a built-in way to differentiate the two.
private final class StatusBarClickView: NSView {

    var onLeftClick: (() -> Void)?
    var onRightClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onLeftClick?()
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?()
    }

    /// Don't block any events from reaching the underlying button.
    override func hitTest(_ point: NSPoint) -> NSView? {
        // Return self so we receive mouse events, but forward everything else.
        let hit = super.hitTest(point)
        return hit == self ? self : hit
    }
}

// MARK: - Security Subprocess

/// Runs `/usr/bin/security` with the given arguments and returns its exit
/// status plus captured combined output. Safe to call from any thread —
/// used off the main thread by the CA trust flow.
private func invokeSecurity(_ args: [String]) -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    process.arguments = args
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do {
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return (process.terminationStatus, output)
    } catch {
        return (-1, "\(error)")
    }
}
