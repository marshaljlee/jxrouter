import AppKit
import SwiftUI
import Observation

extension Notification.Name {
    /// Posted by the gear button in JXRouterView; observed by StatusItemManager
    /// to open the Settings window with proper positioning and pairing.
    static let jxproxyOpenSettings = Notification.Name("jxproxyOpenSettings")
    /// Posted to open the Vault workspace window.
    static let jxproxyOpenVault = Notification.Name("jxproxyOpenVault")
}

// MARK: - Status Item Manager
//
// Replaces the SwiftUI MenuBarExtra with an AppKit NSStatusItem.
// Left-click toggles a persistent NSWindow; right-click shows a context menu.
// Window close/minimize hides to the menu bar; only Quit terminates the app.

@MainActor
final class StatusItemManager: NSObject {
    private var statusItem: NSStatusItem!
    private var window: NSWindow!
    private var settingsWindow: NSWindow?
    private var vaultWorkspaceWindow: NSWindow?
    private var hostingController: NSHostingController<JXRouterView>!
    private var proxyManager: ProxyManager
    /// Guard against re-entrant slide animations
    private var isAnimatingSettings: Bool = false
    /// Stored notification observer tokens — removed in deinit to prevent leaks.
    private var observerTokens: [NSObjectProtocol] = []

    // MARK: - Init

    init(proxyManager: ProxyManager) {
        self.proxyManager = proxyManager
        super.init()
        setupStatusItem()
        setupWindow()
        observeProxyState()
        observeOpenSettingsNotification()
        observeOpenVaultNotification()
    }

    // MARK: - Status Item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.variableLength
        )

        guard let button = statusItem.button else { return }

        // Set initial icon matching the lightning bolt design
        button.image = makeStatusIcon(isRunning: proxyManager.isRunning)

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
        
        // The window is a fixed size: it is sized ONCE at setup and never
        // resized again. On macOS 26 any change to the hosting view's ideal
        // size while the window is displayed re-enters the window's constraint
        // pass (`_postWindowNeedsUpdateConstraints` overflow) and crashes the
        // app — every build with a resized/auto-sized window hit it. All
        // dashboard views use fixed frames, and Settings open in the separate
        // fixed-size Settings window, so the content size is static.

        // Initial height matches the dashboard's natural content height;
        // the one-time setContentSize below corrects it before the window is
        // ever shown.
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 785),
            styleMask: [
                .titled,
                .closable,
                .miniaturizable,
                .fullSizeContentView,
            ],
            backing: .buffered,
            defer: true
        )

        self.hostingController = hostingController
        window.contentViewController = hostingController

        // ONE-TIME window sizing: match the window to the dashboard's natural
        // size at setup. The window is never resized again — on macOS 26 any
        // change to the hosting view's ideal size while the window is
        // displayed re-enters the window's constraint pass and crashes the app
        // (`_postWindowNeedsUpdateConstraints` overflow). All dashboard views
        // use fixed frames, and Settings open in the separate fixed-size
        // Settings window, so the content size is static after launch.
        let fitting = hostingController.view.fittingSize
        if fitting.width > 0, fitting.height > 0 {
            window.setContentSize(NSSize(width: ceil(fitting.width), height: ceil(fitting.height)))
        }

        window.isReleasedWhenClosed = false
        window.delegate = self

        // Slim transparent title bar — the SwiftUI view provides the background
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "JXProxy"

        // The ? / gear actions are rendered by the SwiftUI view itself, at the
        // upper-right corner of the main page (JXRouterView) — keep them in the
        // content, not the title bar, per user preference.

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
            if let sw = settingsWindow {
                NotificationCenter.default.post(name: .jxproxyFlushSettingsSave, object: nil)
                window.removeChildWindow(sw)
                sw.orderOut(nil)
                settingsWindow = nil
            }
            window.orderOut(nil)
        } else {
            // The two windows are paired — opening the dashboard closes
            // Settings so only one is visible at a time.
            if let sw = settingsWindow {
                NotificationCenter.default.post(name: .jxproxyFlushSettingsSave, object: nil)
                window.removeChildWindow(sw)
                sw.orderOut(nil)
                settingsWindow = nil
            }
            positionWindow()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Position the window below the status item, centred horizontally.
    private func positionWindow() {
        guard let button = statusItem.button,
              let buttonWindow = button.window else { return }

        // Anchor to the menu-bar button's own screen — NOT NSScreen.main,
        // which is the screen with keyboard focus. Opening the dashboard from
        // a multi-display setup while another display has focus would
        // otherwise drop the panel on the WRONG screen (the same family of
        // "appears at a random position" bugs as the Settings anchor).
        guard let screen = buttonWindow.screen else { return }

        let buttonRectInScreen = buttonWindow.convertToScreen(button.frame)
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
            title: "Open Vault Workspace",
            action: #selector(openVaultAction),
            keyEquivalent: "v"
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
                // stopProxy() is synchronous — no await needed.
                proxyManager.stopProxy()
            } else {
                await proxyManager.startProxy()
            }
        }
    }

    @objc
    private func openSettingsAction() {
        openSettingsWindow()
    }

    @objc
    private func openVaultAction() {
        openVaultWorkspaceWindow()
    }

    /// Open the Settings window with a true ROLL-OUT from the main interface:
    /// the panel starts invisibly UNDERNEATH the dashboard (z-ordered below
    /// it), then slides out to the right while fading in — the dashboard
    /// occludes it at the start, so the panel visibly EMERGES from beneath
    /// the interface. Only after the slide completes does the dashboard hide
    /// and the panel come to front.
    ///
    /// Why the geometry: the panel (560pt) is WIDER than the dashboard
    /// (380pt), so "tucking" it slightly behind the dashboard edge shows 95%
    /// of it immediately — no occlusion, no roll-out feel (the previous
    /// attempt's bug). The panel must START overlapping the dashboard's own
    /// area and travel the dashboard's full width to read as sliding out of
    /// it. The Settings window is a standalone NSWindow hosting SwiftUI's
    /// SettingsView — NOT the SwiftUI Settings scene, which doesn't respond
    /// to showSettingsWindow: in LSUIElement apps.
    func openSettingsWindow() {
        NSApp.activate(ignoringOtherApps: true)

        guard !isAnimatingSettings else { return }

        // If already open, toggle it closed with a reverse slide
        if let sw = settingsWindow, sw.isVisible {
            closeSettingsWithSlide()
            return
        }

        let dashboardVisible = window.isVisible
        let anchorFrame: NSRect
        if dashboardVisible {
            anchorFrame = window.frame
        } else if let button = statusItem.button, let buttonWindow = button.window {
            let b = buttonWindow.convertToScreen(button.frame)
            let anchorScreen = buttonWindow.screen ?? NSScreen.main
            let visible = anchorScreen?.visibleFrame ?? .zero
            // Mirror `positionWindow()`: `NSRect.y` is the BOTTOM edge, so the
            // anchor's bottom sits one dashboard-height below the top of the
            // visible frame. Using `visibleFrame.maxY` directly as the bottom
            // edge put the whole rect ABOVE the screen, the intersection below
            // came out empty, `swHeight` was 0, and the panel opened collapsed
            // to its tab bar (560x118) with no content.
            let anchorHeight = min(785, visible.height)
            anchorFrame = NSRect(
                x: b.midX - 190,
                y: visible.maxY - anchorHeight,
                width: 380, height: anchorHeight
            ).intersection(visible)
        } else {
            anchorFrame = window.frame
        }

        let swWidth: CGFloat = 560
        let swHeight = anchorFrame.height

        let sw = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: swWidth, height: swHeight),
            styleMask: [
                .titled,
                .closable,
                .miniaturizable,
                .fullSizeContentView,
            ],
            backing: .buffered,
            defer: false
        )
        sw.titlebarAppearsTransparent = true
        sw.titleVisibility = .hidden
        sw.title = "JXProxy Settings"
        sw.isMovableByWindowBackground = false
        sw.backgroundColor = .clear
        sw.isOpaque = false
        sw.standardWindowButton(.closeButton)?.isHidden = true
        sw.standardWindowButton(.miniaturizeButton)?.isHidden = true
        sw.standardWindowButton(.zoomButton)?.isHidden = true
        sw.contentViewController = NSHostingController(rootView: SettingsView(manager: proxyManager))
        sw.isReleasedWhenClosed = false

        // Determine available space on both sides of the anchor (main window)
        let targetScreen = window.screen ?? statusItem.button?.window?.screen ?? NSScreen.main
        let screenFrame = targetScreen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        // Gap is 0 so the settings window remains seamlessly intact by the end border of the main interface
        let spaceOnRight = screenFrame.maxX - anchorFrame.maxX
        let spaceOnLeft = anchorFrame.minX - screenFrame.minX

        // Choose slide direction based on available space
        let slideToRight = spaceOnRight >= swWidth || (spaceOnRight >= spaceOnLeft && spaceOnLeft < swWidth)

        let finalX: CGFloat
        let startX: CGFloat
        let tuckDistance: CGFloat = 80 // Crisp, responsive reveal distance
        if slideToRight {
            finalX = min(anchorFrame.maxX, screenFrame.maxX - swWidth)
            startX = finalX - tuckDistance
        } else {
            finalX = max(anchorFrame.minX - swWidth, screenFrame.minX)
            startX = finalX + tuckDistance
        }

        // Align exactly with the anchor window vertically (flush top and bottom borders)
        let finalY = anchorFrame.minY
        let finalFrame = NSRect(x: finalX, y: finalY, width: swWidth, height: swHeight)
        let startFrame = NSRect(x: startX, y: finalY, width: swWidth, height: swHeight)

        // Close observer — closing Settings clears reference.
        //
        // The observer is bound to this one window (object: sw) and the window
        // is rebuilt on every open, so the token is captured and removed from
        // inside the handler. Without that, NotificationCenter keeps the block
        // alive forever and each open/close cycle leaks one more.
        let closeToken = NotificationObserverToken()
        closeToken.value = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: sw,
            queue: .main
        ) { [weak self, closeToken] _ in
            closeToken.remove()
            NotificationCenter.default.post(name: .jxproxyFlushSettingsSave, object: nil)
            Task { @MainActor [weak self] in
                if let sw = self?.settingsWindow {
                    self?.window.removeChildWindow(sw)
                }
                self?.settingsWindow = nil
            }
        }

        settingsWindow = sw

        guard dashboardVisible else {
            sw.setFrame(finalFrame, display: false)
            sw.alphaValue = 1.0
            window.addChildWindow(sw, ordered: .below)
            sw.makeKeyAndOrderFront(nil)
            return
        }

        // Window starts partially tucked with 0.1 alpha for a crisp, immediate start
        isAnimatingSettings = true
        sw.setFrame(startFrame, display: true)
        sw.alphaValue = 0.1

        // Order Settings below the dashboard so it visually emerges from beneath it
        sw.order(.below, relativeTo: window.windowNumber)

        // Apple Pro-motion fluid spring curve (cubic-bezier 0.16, 1.0, 0.3, 1.0)
        let springCurve = CAMediaTimingFunction(controlPoints: 0.16, 1.0, 0.3, 1.0)

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            ctx.timingFunction = springCurve
            sw.animator().setFrame(finalFrame, display: true)
            sw.animator().alphaValue = 1.0
        }, completionHandler: { [weak self, weak sw] in
            guard let self, let sw else { return }
            // Lock intact to the main interface as a child window
            self.window.addChildWindow(sw, ordered: .below)
            sw.makeKeyAndOrderFront(nil)
            self.isAnimatingSettings = false
        })
    }

    private func closeSettingsWithSlide() {
        // Flush any pending edits immediately before beginning dismissal
        NotificationCenter.default.post(name: .jxproxyFlushSettingsSave, object: nil)

        guard let sw = settingsWindow, sw.isVisible else {
            if let sw = settingsWindow {
                window.removeChildWindow(sw)
                sw.close()
            }
            settingsWindow = nil
            return
        }

        guard !isAnimatingSettings else { return }

        // Detach from parent window before running reverse slide
        window.removeChildWindow(sw)

        let anchorFrame = window.frame
        let currentFrame = sw.frame
        let isRightOfAnchor = currentFrame.minX >= anchorFrame.minX

        let tuckDistance: CGFloat = 80
        let targetX: CGFloat = isRightOfAnchor
            ? (currentFrame.minX - tuckDistance)
            : (currentFrame.minX + tuckDistance)

        let returnFrame = NSRect(x: targetX, y: currentFrame.origin.y, width: currentFrame.width, height: currentFrame.height)

        isAnimatingSettings = true
        sw.order(.below, relativeTo: window.windowNumber)

        let dismissCurve = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1.0)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            ctx.timingFunction = dismissCurve
            sw.animator().setFrame(returnFrame, display: true)
            sw.animator().alphaValue = 0.0
        }, completionHandler: { [weak self, weak sw] in
            sw?.orderOut(nil)
            self?.settingsWindow = nil
            self?.isAnimatingSettings = false
        })
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

    /// Listen for the gear button's notification so the coordinated
    /// openSettingsWindow (position + pair + close dashboard) runs.
    private func observeOpenSettingsNotification() {
        let token = NotificationCenter.default.addObserver(
            forName: .jxproxyOpenSettings,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.openSettingsWindow()
            }
        }
        observerTokens.append(token)
    }

    /// Listen for the vault workspace notification.
    private func observeOpenVaultNotification() {
        let token = NotificationCenter.default.addObserver(
            forName: .jxproxyOpenVault,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.openVaultWorkspaceWindow()
            }
        }
        observerTokens.append(token)
    }

    /// Open the Vault workspace — a full-featured Claude Code GUI with
    /// vault isolation, routing, agents, analytics, and file explorer.
    func openVaultWorkspaceWindow() {
        NSApp.activate(ignoringOtherApps: true)

        // If already open, just bring it to front
        if let vw = vaultWorkspaceWindow, vw.isVisible {
            vw.makeKeyAndOrderFront(nil)
            return
        }

        let vw = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        vw.title = "Vault — AI Development Workspace"
        vw.contentViewController = NSHostingController(
            rootView: VaultWorkspaceView(manager: proxyManager)
        )
        vw.isReleasedWhenClosed = false
        vw.minSize = NSSize(width: 900, height: 600)
        vw.center()

        vaultWorkspaceWindow = vw
        vw.makeKeyAndOrderFront(nil)

        // Close observer — same self-removing pattern as the Settings window
        // above: this window is also rebuilt on every open.
        let closeToken = NotificationObserverToken()
        closeToken.value = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: vw,
            queue: .main
        ) { [weak self, closeToken] _ in
            closeToken.remove()
            Task { @MainActor [weak self] in
                self?.vaultWorkspaceWindow = nil
            }
        }
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        button.image = makeStatusIcon(isRunning: proxyManager.isRunning)
    }

    /// Renders an authentic template menubar icon matching the app's lightning bolt shape.
    private func makeStatusIcon(isRunning: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { bounds in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.setShouldAntialias(true)
            ctx.interpolationQuality = .high

            ctx.saveGState()
            ctx.translateBy(x: 0, y: bounds.height)
            ctx.scaleBy(x: 1, y: -1)

            let pad: CGFloat = 1.5
            let drawWidth = bounds.width - pad * 2
            let scale = drawWidth / 24.0
            ctx.translateBy(x: pad, y: pad)
            ctx.scaleBy(x: scale, y: scale)

            let boltPath = CGMutablePath()
            boltPath.move(to: CGPoint(x: 5.66953, y: 9.91436))
            boltPath.addLine(to: CGPoint(x: 8.73167, y: 5.77133))
            boltPath.addCurve(to: CGPoint(x: 12.6241, y: 2.03721), control1: CGPoint(x: 10.711, y: 3.09327), control2: CGPoint(x: 11.7007, y: 1.75425))
            boltPath.addCurve(to: CGPoint(x: 13.5474, y: 7.24712), control1: CGPoint(x: 13.5474, y: 2.32018), control2: CGPoint(x: 13.5474, y: 3.96249))
            boltPath.addLine(to: CGPoint(x: 13.5474, y: 7.55682))
            boltPath.addCurve(to: CGPoint(x: 13.926, y: 9.70541), control1: CGPoint(x: 13.5474, y: 8.74151), control2: CGPoint(x: 13.5474, y: 9.33386))
            boltPath.addLine(to: CGPoint(x: 13.946, y: 9.72466))
            boltPath.addCurve(to: CGPoint(x: 16.1822, y: 10.0884), control1: CGPoint(x: 14.3327, y: 10.0884), control2: CGPoint(x: 14.9492, y: 10.0884))
            boltPath.addCurve(to: CGPoint(x: 19.8855, y: 10.7613), control1: CGPoint(x: 18.4011, y: 10.0884), control2: CGPoint(x: 19.5106, y: 10.0884))
            boltPath.addLine(to: CGPoint(x: 19.9036, y: 10.795))
            boltPath.addCurve(to: CGPoint(x: 18.3304, y: 14.0857), control1: CGPoint(x: 20.2576, y: 11.4784), control2: CGPoint(x: 19.6152, y: 12.3475))
            boltPath.addLine(to: CGPoint(x: 15.2683, y: 18.2287))
            boltPath.addCurve(to: CGPoint(x: 11.3758, y: 21.9628), control1: CGPoint(x: 13.2889, y: 20.9067), control2: CGPoint(x: 12.2992, y: 22.2458))
            boltPath.addCurve(to: CGPoint(x: 10.4525, y: 16.7528), control1: CGPoint(x: 10.4525, y: 21.6798), control2: CGPoint(x: 10.4525, y: 20.0375))
            boltPath.addLine(to: CGPoint(x: 10.4526, y: 16.4433))
            boltPath.addCurve(to: CGPoint(x: 10.074, y: 14.2946), control1: CGPoint(x: 10.4526, y: 15.2585), control2: CGPoint(x: 10.4526, y: 14.6662))
            boltPath.addLine(to: CGPoint(x: 10.054, y: 14.2754))
            boltPath.addCurve(to: CGPoint(x: 7.81775, y: 13.9117), control1: CGPoint(x: 9.6673, y: 13.9117), control2: CGPoint(x: 9.05079, y: 13.9117))
            boltPath.addCurve(to: CGPoint(x: 4.1145, y: 13.2387), control1: CGPoint(x: 5.59888, y: 13.9117), control2: CGPoint(x: 4.48945, y: 13.9117))
            boltPath.addLine(to: CGPoint(x: 4.09639, y: 13.205))
            boltPath.addCurve(to: CGPoint(x: 5.66953, y: 9.91436), control1: CGPoint(x: 3.74244, y: 12.5217), control2: CGPoint(x: 4.3848, y: 11.6526))
            boltPath.closeSubpath()

            ctx.addPath(boltPath)
            if isRunning {
                ctx.setFillColor(NSColor.black.cgColor)
                ctx.fillPath()
            } else {
                ctx.setStrokeColor(NSColor.black.cgColor)
                ctx.setLineWidth(1.6 / scale)
                ctx.strokePath()

                ctx.move(to: CGPoint(x: 2, y: 22))
                ctx.addLine(to: CGPoint(x: 22, y: 2))
                ctx.setLineWidth(1.8 / scale)
                ctx.strokePath()
            }

            ctx.restoreGState()
            return true
        }
        image.isTemplate = true
        return image
    }

    deinit {
        // Remove all stored notification observers to prevent leaks.
        for token in observerTokens {
            NotificationCenter.default.removeObserver(token)
        }
        observerTokens.removeAll()
    }
}

// MARK: - NSWindowDelegate

extension StatusItemManager: NSWindowDelegate {

    /// Allow the close button to actually close the window. The app itself is
    /// a background-only agent (LSUIElement) and keeps running — clicking the
    /// menu-bar icon re-opens the dashboard window at any time.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Closing the dashboard also closes the Settings window — the two
        // windows are a paired UI; leaving Settings orphaned would confuse.
        if sender === window, let sw = settingsWindow {
            NotificationCenter.default.post(name: .jxproxyFlushSettingsSave, object: nil)
            window.removeChildWindow(sw)
            sw.orderOut(nil)
            settingsWindow = nil
        }
        return true
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
