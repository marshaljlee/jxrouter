import SwiftUI

// MARK: - Design System Tokens — Flat Dark
//
// Google-inspired dark mode. Deep desaturated grays with vibrant blue accent.
// Depth is established through color stepping (Background → Surface → Raised),
// not drop shadows. Generous corner radii throughout.
//
// Palette:
//   Background Base  #131517  — deepest canvas
//   Surface          #1C1E22  — card / elevated panel
//   Surface Raised   #25282D  — hover state, actionable surfaces
//   Accent           #1A73E8  — Google Blue, primary actions
//   Text Primary     #F3F4F6  — off-white headings
//   Text Secondary   #8A8F98  — muted gray, placeholders
//   Borders          #2E3238  — subtle outlines
//   Green            #22C55E  — success / running
//   Red              #FF6B6B  — danger / blocked
//   Purple           #8B5CF6  — secondary badge
//   Orange           #F97316  — warning

enum DesignToken {

    // MARK: - Spacing (8pt grid)
    static let spacing2: CGFloat = 2
    static let spacing4: CGFloat = 4
    static let spacing6: CGFloat = 6
    static let spacing8: CGFloat = 8
    static let spacing10: CGFloat = 10
    static let spacing12: CGFloat = 12
    static let spacing16: CGFloat = 16
    static let spacing20: CGFloat = 20
    static let spacing24: CGFloat = 24
    static let spacing32: CGFloat = 32

    // MARK: - Corner Radii (generous, friendly)
    /// Small chips, badges, tight controls.
    static let radiusSmall: CGFloat = 6
    /// Buttons, list items, toggle backgrounds.
    static let radiusButton: CGFloat = 10
    /// Cards, input fields, internal panels.
    static let radiusCard: CGFloat = 16
    /// Outer window / popover.
    static let radiusPanel: CGFloat = 24

    // MARK: - Shadows (flat design — avoid where possible)
    static let shadowY: CGFloat = 0
    static let shadowBlur: CGFloat = 0
    static let shadowOpacity: Double = 0

    // MARK: - Animation Durations
    static let hoverDuration: Double = 0.15
    static let pressDuration: Double = 0.1
    static let transitionDuration: Double = 0.2

    // MARK: - Spring Physics
    static let buttonSpring = Spring(response: 0.35, dampingRatio: 0.7)
    static let contentSpring = Spring(response: 0.4, dampingRatio: 0.75)

    // MARK: - Typography Scale (macOS system font — SF Pro)
    static let captionSize: CGFloat = 11
    static let caption2Size: CGFloat = 10
    static let bodySize: CGFloat = 13
    static let subheadSize: CGFloat = 15
    static let headingSize: CGFloat = 17
    static let titleSize: CGFloat = 20
}

// MARK: - Flat Dark Color Palette

extension Color {

    // MARK: - Backgrounds (dark → lighter stepping)
    /// Deepest canvas — #131517
    static let dsBackground = Color(red: 0.075, green: 0.082, blue: 0.090)
    /// Card / elevated surface — #1C1E22
    static let dsSurface = Color(red: 0.110, green: 0.118, blue: 0.133)
    /// Hovered / active / raised surface — #25282D
    static let dsSurfaceRaised = Color(red: 0.145, green: 0.157, blue: 0.176)
    /// Control background (matches surface) — #1C1E22
    static let dsControlBackground = Color(red: 0.110, green: 0.118, blue: 0.133)

    // MARK: - Text
    /// Off-white headings — #F3F4F6
    static let dsTextPrimary = Color(red: 0.953, green: 0.957, blue: 0.965)
    /// Muted secondary / placeholders — #8A8F98
    static let dsTextSecondary = Color(red: 0.541, green: 0.561, blue: 0.596)
    /// Tertiary / captions — #8A8F98 (same hue, slightly lighter at low alpha)
    static let dsTextTertiary = Color(red: 0.541, green: 0.561, blue: 0.596)

    // MARK: - Borders & Separators
    /// Subtle outlines, dividers — #2E3238
    static let dsBorder = Color(red: 0.180, green: 0.196, blue: 0.220)
    /// Alias for backward compatibility.
    static let dsSeparator = Color(red: 0.180, green: 0.196, blue: 0.220)

    // MARK: - Primary Accent (Google Blue)
    /// Interactive elements, active state — #1A73E8
    static let dsAccent = Color(red: 0.102, green: 0.451, blue: 0.910)
    /// Dimmed accent background (used for selected tab, etc.)
    static let dsAccentDim = Color(red: 0.102, green: 0.451, blue: 0.910, opacity: 0.12)

    // MARK: - Status Colors
    /// Success / proxy running / AI traffic — #22C55E
    static let dsGreen = Color(red: 0.133, green: 0.773, blue: 0.369)
    static let dsGreenDim = Color(red: 0.133, green: 0.773, blue: 0.369, opacity: 0.08)

    /// Danger / blocked traffic — #FF6B6B
    static let dsRed = Color(red: 1.000, green: 0.420, blue: 0.420)
    static let dsRedDim = Color(red: 1.000, green: 0.420, blue: 0.420, opacity: 0.10)

    /// Warning — #F97316
    static let dsOrange = Color(red: 0.976, green: 0.451, blue: 0.086)
    static let dsOrangeDim = Color(red: 0.976, green: 0.451, blue: 0.086, opacity: 0.10)

    /// Secondary badge — #8B5CF6
    static let dsPurple = Color(red: 0.545, green: 0.361, blue: 0.965)
    static let dsPurpleDim = Color(red: 0.545, green: 0.361, blue: 0.965, opacity: 0.08)

    // MARK: - Extended / Remapped

    /// Info / passthrough traffic (muted blue accent).
    static let dsSky = Color(red: 0.102, green: 0.451, blue: 0.910).opacity(0.55)
}
