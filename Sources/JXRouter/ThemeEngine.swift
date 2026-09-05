import SwiftUI
import AppKit

/// A named UI theme: one semantic palette the whole app renders through.
///
/// Every role carries a light AND a dark NSColor. The pair is wrapped in a
/// dynamic NSColor (resolved at draw time from the current appearance), so
/// the existing light/dark `AppearanceController` toggle keeps working inside
/// any theme.
///
/// The "Opcode" themes are extracted from the OPCODE design reference
/// (`jxcode/Draft/Design.md`): #111111 canvas, #1A1A1A surfaces,
/// #1E1E1E/#2D2D2D code panels, #3B82F6 primary action blue, #10B981 success,
/// and the #50CDDB/#4CCFBA teal swatch pair.
struct Theme: Identifiable, Equatable {
    let id: String
    let name: String
    let symbol: String

    var background: Role
    var surface: Role
    var surfaceRaised: Role
    var controlBackground: Role
    var textPrimary: Role
    var textSecondary: Role
    var textTertiary: Role
    var border: Role
    var separator: Role
    var accent: Role
    var success: Role
    var danger: Role
    var warning: Role
    var purple: Role
    var sky: Role

    /// One semantic color role — a light and a dark NSColor.
    struct Role: Equatable {
        let light: NSColor
        let dark: NSColor
    }

    /// Hex convenience for building roles.
    private static func hex(_ value: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255.0,
                green: CGFloat((value >> 8) & 0xFF) / 255.0,
                blue: CGFloat(value & 0xFF) / 255.0,
                alpha: alpha)
    }

    /// The app's original adaptive palette — preserved exactly so existing
    /// users see no change until they opt into a theme.
    static let jxDefault = Theme(
        id: "jx-default", name: "JX Default", symbol: "circle.lefthalf.filled",
        background: Role(light: NSColor(calibratedRed: 0.97, green: 0.97, blue: 0.98, alpha: 1),
                         dark: NSColor(calibratedRed: 0.10, green: 0.10, blue: 0.12, alpha: 1)),
        surface: Role(light: NSColor(calibratedRed: 0.93, green: 0.93, blue: 0.95, alpha: 1),
                      dark: NSColor(calibratedRed: 0.16, green: 0.16, blue: 0.19, alpha: 1)),
        surfaceRaised: Role(light: NSColor(calibratedRed: 1.0, green: 1.0, blue: 1.0, alpha: 1),
                            dark: NSColor(calibratedRed: 0.21, green: 0.21, blue: 0.25, alpha: 1)),
        controlBackground: Role(light: NSColor(calibratedRed: 0.95, green: 0.95, blue: 0.96, alpha: 1),
                                dark: NSColor(calibratedRed: 0.17, green: 0.17, blue: 0.20, alpha: 1)),
        textPrimary: Role(light: NSColor(calibratedRed: 0.10, green: 0.10, blue: 0.12, alpha: 1),
                          dark: NSColor(calibratedRed: 0.95, green: 0.95, blue: 0.97, alpha: 1)),
        textSecondary: Role(light: NSColor(calibratedRed: 0.35, green: 0.35, blue: 0.38, alpha: 1),
                            dark: NSColor(calibratedRed: 0.68, green: 0.68, blue: 0.72, alpha: 1)),
        textTertiary: Role(light: NSColor(calibratedRed: 0.55, green: 0.55, blue: 0.58, alpha: 1),
                           dark: NSColor(calibratedRed: 0.52, green: 0.52, blue: 0.57, alpha: 1)),
        border: Role(light: NSColor(calibratedRed: 0.82, green: 0.82, blue: 0.85, alpha: 1),
                     dark: NSColor(calibratedRed: 0.32, green: 0.32, blue: 0.36, alpha: 1)),
        separator: Role(light: NSColor(calibratedRed: 0.88, green: 0.88, blue: 0.90, alpha: 1),
                        dark: NSColor(calibratedRed: 0.26, green: 0.26, blue: 0.30, alpha: 1)),
        accent: Role(light: NSColor(calibratedRed: 0.22, green: 0.47, blue: 0.95, alpha: 1),
                     dark: NSColor(calibratedRed: 0.47, green: 0.67, blue: 1.0, alpha: 1)),
        success: Role(light: NSColor(calibratedRed: 0.18, green: 0.72, blue: 0.40, alpha: 1),
                      dark: NSColor(calibratedRed: 0.36, green: 0.86, blue: 0.55, alpha: 1)),
        danger: Role(light: NSColor(calibratedRed: 0.90, green: 0.25, blue: 0.25, alpha: 1),
                     dark: NSColor(calibratedRed: 1.0, green: 0.45, blue: 0.45, alpha: 1)),
        warning: Role(light: NSColor(calibratedRed: 0.95, green: 0.55, blue: 0.15, alpha: 1),
                      dark: NSColor(calibratedRed: 1.0, green: 0.72, blue: 0.34, alpha: 1)),
        purple: Role(light: NSColor(calibratedRed: 0.55, green: 0.30, blue: 0.85, alpha: 1),
                     dark: NSColor(calibratedRed: 0.73, green: 0.57, blue: 1.0, alpha: 1)),
        sky: Role(light: NSColor(calibratedRed: 0.25, green: 0.60, blue: 0.90, alpha: 1),
                  dark: NSColor(calibratedRed: 0.42, green: 0.73, blue: 1.0, alpha: 1))
    )

    /// OPCODE dark — Design.md's left window: #111111 canvas, #1A1A1A
    /// surfaces, #1E1E1E controls, #2D2D2D raised panels, #3B82F6 primary,
    /// #10B981 success, #50CDDB teal sky.
    static let opcodeDark = Theme(
        id: "opcode-dark", name: "Opcode Dark", symbol: "terminal.fill",
        background: Role(light: hex(0x111111), dark: hex(0x111111)),
        surface: Role(light: hex(0x1A1A1A), dark: hex(0x1A1A1A)),
        surfaceRaised: Role(light: hex(0x2D2D2D), dark: hex(0x2D2D2D)),
        controlBackground: Role(light: hex(0x1E1E1E), dark: hex(0x1E1E1E)),
        textPrimary: Role(light: hex(0xFFFFFF), dark: hex(0xFFFFFF)),
        textSecondary: Role(light: hex(0xA3A3A3), dark: hex(0xA3A3A3)),
        textTertiary: Role(light: hex(0x666666), dark: hex(0x666666)),
        border: Role(light: hex(0x333333), dark: hex(0x333333)),
        separator: Role(light: hex(0x2A2A2A), dark: hex(0x2A2A2A)),
        accent: Role(light: hex(0x3B82F6), dark: hex(0x3B82F6)),
        success: Role(light: hex(0x10B981), dark: hex(0x10B981)),
        danger: Role(light: hex(0xEF4444), dark: hex(0xEF4444)),
        warning: Role(light: hex(0xF59E0B), dark: hex(0xF59E0B)),
        purple: Role(light: hex(0x8B5CF6), dark: hex(0x8B5CF6)),
        sky: Role(light: hex(0x50CDDB), dark: hex(0x4CCFBA))
    )

    /// OPCODE light — Design.md's right window: #F3F4F6 canvas, #E5E7EB
    /// sidebar, white raised panels, #111827 ink, same #3B82F6 accent.
    static let opcodeLight = Theme(
        id: "opcode-light", name: "Opcode Light", symbol: "sun.max.fill",
        background: Role(light: hex(0xF3F4F6), dark: hex(0x2D2D2D)),
        surface: Role(light: hex(0xE5E7EB), dark: hex(0x1A1A1A)),
        surfaceRaised: Role(light: hex(0xFFFFFF), dark: hex(0x2D2D2D)),
        controlBackground: Role(light: hex(0xF9FAFB), dark: hex(0x1E1E1E)),
        textPrimary: Role(light: hex(0x111827), dark: hex(0xFFFFFF)),
        textSecondary: Role(light: hex(0x374151), dark: hex(0xA3A3A3)),
        textTertiary: Role(light: hex(0x9CA3AF), dark: hex(0x666666)),
        border: Role(light: hex(0xD1D5DB), dark: hex(0x333333)),
        separator: Role(light: hex(0xE5E7EB), dark: hex(0x2A2A2A)),
        accent: Role(light: hex(0x3B82F6), dark: hex(0x3B82F6)),
        success: Role(light: hex(0x10B981), dark: hex(0x10B981)),
        danger: Role(light: hex(0xEF4444), dark: hex(0xEF4444)),
        warning: Role(light: hex(0xF59E0B), dark: hex(0xF59E0B)),
        purple: Role(light: hex(0x8B5CF6), dark: hex(0x8B5CF6)),
        sky: Role(light: hex(0x0EA5E9), dark: hex(0x50CDDB))
    )

    static let all: [Theme] = [.jxDefault, .opcodeDark, .opcodeLight]

    static func theme(for id: String) -> Theme {
        all.first { $0.id == id } ?? .jxDefault
    }
}

// MARK: - Semantic Token

/// The semantic color tokens every view references (the `Color.ds*` family).
/// `ThemeController` maps each token to its role in the active theme.
enum SemanticToken: String, CaseIterable {
    case background, surface, surfaceRaised, controlBackground
    case textPrimary, textSecondary, textTertiary
    case border, separator
    case accent, success, danger, warning, purple, sky
    case accentDim, successDim, dangerDim, warningDim, purpleDim, skyDim

    /// The (non-dim) role this token reads from the given theme.
    func baseRole(in t: Theme) -> Theme.Role {
        switch self {
        case .background: return t.background
        case .surface: return t.surface
        case .surfaceRaised: return t.surfaceRaised
        case .controlBackground: return t.controlBackground
        case .textPrimary: return t.textPrimary
        case .textSecondary: return t.textSecondary
        case .textTertiary: return t.textTertiary
        case .border: return t.border
        case .separator: return t.separator
        case .accent, .accentDim: return t.accent
        case .success, .successDim: return t.success
        case .danger, .dangerDim: return t.danger
        case .warning, .warningDim: return t.warning
        case .purple, .purpleDim: return t.purple
        case .sky, .skyDim: return t.sky
        }
    }

    /// Alpha applied for the dim variants (matches the original palette).
    var isDim: Bool {
        switch self {
        case .accentDim, .successDim, .dangerDim, .warningDim, .purpleDim, .skyDim: return true
        default: return false
        }
    }
}

// MARK: - Theme Controller

extension Notification.Name {
    static let themeDidChange = Notification.Name("JXProxyThemeDidChange")
}

/// Holds the active theme and produces the `Color` for every semantic token.
/// `Color.ds*` in DesignTokens delegate here, so switching the theme re-colors
/// the whole app without touching any view code.
@Observable
@MainActor
final class ThemeController {
    static let shared = ThemeController()

    private let themeKey = "uiThemeId"

    var currentThemeId: String = Theme.jxDefault.id

    /// The active theme (persisted in UserDefaults; defaults to JX Default).
    var theme: Theme {
        get { Theme.theme(for: currentThemeId) }
        set {
            currentThemeId = newValue.id
            UserDefaults.standard.set(newValue.id, forKey: themeKey)
            apply()
        }
    }

    private init() {
        let saved = UserDefaults.standard.string(forKey: themeKey) ?? Theme.jxDefault.id
        self.currentThemeId = saved
        if saved != Theme.jxDefault.id {
            refreshAppearance()
        }
    }

    /// Sets the theme and updates appearance mode if appropriate.
    func setTheme(_ newTheme: Theme) {
        self.theme = newTheme
        if newTheme.id == "opcode-dark" {
            AppearanceController.shared.mode = .dark
        } else if newTheme.id == "opcode-light" {
            AppearanceController.shared.mode = .light
        }
    }

    /// The SwiftUI Color for a token: a dynamic NSColor that resolves to the
    /// theme's light or dark role at draw time (dim tokens apply the dim
    /// alpha). Reading `currentThemeId` ensures SwiftUI views establish observation.
    nonisolated func color(_ token: SemanticToken) -> Color {
        MainActor.assumeIsolated {
            _ = currentThemeId // Establish SwiftUI Observation dependency
            let dynamic = NSColor(name: nil) { [weak self] appearance in
                let activeTheme = self?.theme ?? Theme.jxDefault
                let role = token.baseRole(in: activeTheme)
                let isDim = token.isDim
                let light = isDim ? role.light.withAlphaComponent(0.10) : role.light
                let dark = isDim ? role.dark.withAlphaComponent(0.16) : role.dark
                let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                return isDark ? dark : light
            }
            return Color(nsColor: dynamic)
        }
    }

    /// Nudge every open window so dynamic colors re-resolve immediately.
    func apply() {
        refreshAppearance()
        NotificationCenter.default.post(name: .themeDidChange, object: nil)
    }

    private func refreshAppearance() {
        AppearanceController.shared.apply()
    }
}
