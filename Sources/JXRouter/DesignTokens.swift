import SwiftUI
import AppKit

/// Centralised design tokens — spacing, radii, font sizes, durations, and
/// semantic colours used across every view.
enum DesignToken {

    // MARK: - Spacing

    static let spacing2:  CGFloat = 2
    static let spacing4:  CGFloat = 4
    static let spacing6:  CGFloat = 6
    static let spacing8:  CGFloat = 8
    static let spacing10: CGFloat = 10
    static let spacing12: CGFloat = 12
    static let spacing16: CGFloat = 16
    static let spacing20: CGFloat = 20
    static let spacing24: CGFloat = 24
    static let spacing32: CGFloat = 32

    // MARK: - Radii

    static let radiusSmall:  CGFloat = 4
    static let radiusButton: CGFloat = 8
    static let radiusCard:   CGFloat = 10
    static let radiusPanel:  CGFloat = 12

    // MARK: - Shadows

    static let shadowY:       CGFloat = 2
    static let shadowBlur:    CGFloat = 8
    static let shadowOpacity: Double  = 0.08

    // MARK: - Animation Durations

    static let hoverDuration:      Double = 0.12
    static let pressDuration:      Double = 0.08
    static let transitionDuration: Double = 0.22

    // MARK: - Springs

    static let buttonSpring = Spring(response: 0.3, dampingRatio: 0.7)
    static let contentSpring = Spring(response: 0.35, dampingRatio: 0.8)

    // MARK: - Font Sizes

    static let caption2Size: CGFloat = 10
    static let captionSize:  CGFloat = 12
    static let bodySize:     CGFloat = 13
    static let subheadSize:  CGFloat = 14
    static let headingSize:  CGFloat = 16
    static let titleSize:    CGFloat = 20
}

// MARK: - Appearance Mode (Dark / Light)

/// The app's appearance mode. Persisted in UserDefaults and applied at the
/// `NSApp` level so every window (dashboard + Settings) follows the toggle.
enum AppearanceMode: String {
    case system = "system"
    case light = "light"
    case dark = "dark"

    /// The matching `NSAppearance` — nil means "follow the system".
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    var isDark: Bool {
        switch self {
        case .dark: return true
        case .light: return false
        case .system:
            return NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }
    }

    var symbolName: String {
        isDark ? "moon.fill" : "sun.max.fill"
    }

    var displayName: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

/// Applies and persists the app's light/dark appearance.
///
/// The dashboard window and the Settings window both inherit the appearance
/// from `NSApp`; applying it explicitly to every window keeps them in sync
/// even when a window was created before the first toggle.
@Observable
@MainActor
final class AppearanceController {
    static let shared = AppearanceController()

    private let modeKey = "appearanceMode"

    var currentMode: AppearanceMode = .system

    /// The current appearance mode (defaults to .system).
    var mode: AppearanceMode {
        get { currentMode }
        set {
            currentMode = newValue
            UserDefaults.standard.set(newValue.rawValue, forKey: modeKey)
            apply()
        }
    }

    private init() {
        let saved = UserDefaults.standard.string(forKey: modeKey) ?? "system"
        self.currentMode = AppearanceMode(rawValue: saved) ?? .system
    }

    /// Apply the current mode to the whole app and every open window.
    func apply() {
        NSApp.appearance = mode.nsAppearance
        for window in NSApp.windows {
            window.appearance = mode.nsAppearance
        }
    }

    /// Flip between dark and light (used by the top-right toggle button).
    func toggle() {
        mode = mode.isDark ? .light : .dark
    }
}

// MARK: - Semantic Colour Palette (theme-driven, adaptive light / dark)

extension Color {

    /// A SwiftUI `Color` that resolves differently for light and dark
    /// appearances. Dynamic NSColors resolve at draw time, so flipping
    /// `NSApp.appearance` (via `AppearanceController`) updates every view
    /// instantly — no re-render or @Environment colourScheme plumbing needed.
    static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark ? dark : light
        })
    }

    // Backgrounds.
    //
    // The `ds*` tokens are COMPUTED properties that read the active theme
    // (ThemeController) on every access — a static let would capture one
    // theme's colors at first touch and never switch. Each access builds a
    // dynamic NSColor resolving to the theme's light or dark variant at draw
    // time, so both theme switches AND light/dark appearance flips apply
    // live. The JX Default theme reproduces the original hardcoded palette
    // exactly, so default-theme rendering is unchanged.
    static var dsBackground: Color { ThemeController.shared.color(.background) }
    static var dsSurface: Color { ThemeController.shared.color(.surface) }
    static var dsSurfaceRaised: Color { ThemeController.shared.color(.surfaceRaised) }
    static var dsControlBackground: Color { ThemeController.shared.color(.controlBackground) }

    // Text
    static var dsTextPrimary: Color { ThemeController.shared.color(.textPrimary) }
    static var dsTextSecondary: Color { ThemeController.shared.color(.textSecondary) }
    static var dsTextTertiary: Color { ThemeController.shared.color(.textTertiary) }

    // Borders & Separators
    static var dsBorder: Color { ThemeController.shared.color(.border) }
    static var dsSeparator: Color { ThemeController.shared.color(.separator) }

    // Accent
    static var dsAccent: Color { ThemeController.shared.color(.accent) }
    static var dsAccentDim: Color { ThemeController.shared.color(.accentDim) }

    // Semantic
    static var dsGreen: Color { ThemeController.shared.color(.success) }
    static var dsGreenDim: Color { ThemeController.shared.color(.successDim) }
    static var dsRed: Color { ThemeController.shared.color(.danger) }
    static var dsRedDim: Color { ThemeController.shared.color(.dangerDim) }
    static var dsOrange: Color { ThemeController.shared.color(.warning) }
    static var dsOrangeDim: Color { ThemeController.shared.color(.warningDim) }
    static var dsPurple: Color { ThemeController.shared.color(.purple) }
    static var dsPurpleDim: Color { ThemeController.shared.color(.purpleDim) }
    static var dsSky: Color { ThemeController.shared.color(.sky) }
    static var dsSkyDim: Color { ThemeController.shared.color(.skyDim) }

    // MARK: - Vault Design System (warm yellow/orange primary accent)

    /// Primary accent — warm yellow/orange for active states, CTAs, route badges.
    static let vaultAccent = Color.adaptive(
        light: NSColor(calibratedRed: 0.96, green: 0.62, blue: 0.04, alpha: 1),
        dark: NSColor(calibratedRed: 0.96, green: 0.62, blue: 0.04, alpha: 1)
    )
    static let vaultAccentDim = Color.adaptive(
        light: NSColor(calibratedRed: 0.96, green: 0.62, blue: 0.04, alpha: 0.10),
        dark: NSColor(calibratedRed: 0.96, green: 0.62, blue: 0.04, alpha: 0.16)
    )
    /// Bridge mode — unmistakable red for danger/escape.
    static let vaultBridge = Color.adaptive(
        light: NSColor(calibratedRed: 0.94, green: 0.27, blue: 0.27, alpha: 1),
        dark: NSColor(calibratedRed: 0.94, green: 0.27, blue: 0.27, alpha: 1)
    )
    static let vaultBridgeDim = Color.adaptive(
        light: NSColor(calibratedRed: 0.94, green: 0.27, blue: 0.27, alpha: 0.10),
        dark: NSColor(calibratedRed: 0.94, green: 0.27, blue: 0.27, alpha: 0.16)
    )
    /// Sandbox mode — safe green.
    static let vaultSandbox = Color.adaptive(
        light: NSColor(calibratedRed: 0.06, green: 0.73, blue: 0.51, alpha: 1),
        dark: NSColor(calibratedRed: 0.06, green: 0.73, blue: 0.51, alpha: 1)
    )
    static let vaultSandboxDim = Color.adaptive(
        light: NSColor(calibratedRed: 0.06, green: 0.73, blue: 0.51, alpha: 0.10),
        dark: NSColor(calibratedRed: 0.06, green: 0.73, blue: 0.51, alpha: 0.16)
    )
    /// Route healthy / degraded / down.
    static let vaultRouteHealthy = Color.adaptive(
        light: NSColor(calibratedRed: 0.06, green: 0.73, blue: 0.51, alpha: 1),
        dark: NSColor(calibratedRed: 0.29, green: 0.78, blue: 0.50, alpha: 1)
    )
    static let vaultRouteDegraded = Color.adaptive(
        light: NSColor(calibratedRed: 0.86, green: 0.72, blue: 0.08, alpha: 1),
        dark: NSColor(calibratedRed: 0.98, green: 0.82, blue: 0.17, alpha: 1)
    )
    static let vaultRouteDown = Color.adaptive(
        light: NSColor(calibratedRed: 0.94, green: 0.27, blue: 0.27, alpha: 1),
        dark: NSColor(calibratedRed: 0.98, green: 0.45, blue: 0.45, alpha: 1)
    )
    /// Terminal panel background — always dark, even in light mode (design system rule).
    static let vaultTerminalBg = Color(white: 0.06)
    static let vaultTerminalFg = Color(white: 0.88)
    static let vaultTerminalBorder = Color(white: 0.18)
}

// MARK: - Vault-Specific Font Extensions

extension Font {
    /// Modern sans-serif for UI text (Inter/Geist vibe).
    static func vaultUI(size: CGFloat = 13, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
    /// Clean monospace for code/data/terminal text.
    static func vaultMono(size: CGFloat = 12, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
    /// Section header.
    static func vaultHeader() -> Font {
        .system(size: 11, weight: .semibold, design: .rounded)
    }
    /// Large title.
    static func vaultTitle() -> Font {
        .system(size: 20, weight: .bold, design: .rounded)
    }
}
