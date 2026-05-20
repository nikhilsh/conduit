import SwiftUI

/// Centralised semantic tokens for the app. Replaces the original ad-hoc
/// enum in `DesignSystem.swift`. Mirrors litter's `LitterTheme` shape:
/// adaptive colors + corner radii + a background gradient builder.
enum SweKittyTheme {
    // MARK: - Adaptive colours

    static var accent: Color        { SweKittyPalette.accent.color }
    static var accentStrong: Color  { SweKittyPalette.accentStrong.color }
    static var claudeAccent: Color  { SweKittyPalette.claudeAccent.color }
    static var codexAccent: Color   { SweKittyPalette.codexAccent.color }

    /// Per-agent accent. Falls back to `accentStrong` for unknown agents.
    static func accent(forAgent assistant: String) -> Color {
        switch assistant.lowercased() {
        case "claude": return claudeAccent
        case "codex":  return codexAccent
        default:       return accentStrong
        }
    }
    static var textPrimary: Color   { SweKittyPalette.textPrimary.color }
    static var textSecondary: Color { SweKittyPalette.textSecondary.color }
    static var textMuted: Color     { SweKittyPalette.textMuted.color }
    static var textBody: Color      { SweKittyPalette.textBody.color }
    static var textOnAccent: Color  { SweKittyPalette.textOnAccent.color }
    static var surface: Color       { SweKittyPalette.surface.color }
    static var surfaceLight: Color  { SweKittyPalette.surfaceLight.color }
    static var border: Color        { SweKittyPalette.border.color }
    static var separator: Color     { SweKittyPalette.separator.color }
    static var danger: Color        { SweKittyPalette.danger.color }
    static var success: Color       { SweKittyPalette.success.color }
    static var warning: Color       { SweKittyPalette.warning.color }

    /// Back-compat alias kept while the rest of the codebase is still
    /// reaching for the old "muted foreground" token.
    static var mutedFG: Color { textMuted }

    // MARK: - Shape tokens

    static let cardCornerRadius: CGFloat = 22
    static let smallCornerRadius: CGFloat = 14

    // MARK: - Background gradient

    static func backgroundGradient(for scheme: ColorScheme) -> LinearGradient {
        let base = SweKittyPalette.background.color(for: scheme)
        return LinearGradient(
            colors: [
                base,
                adjust(base, brightnessDelta: scheme == .dark ?  0.02 : -0.01),
                adjust(base, brightnessDelta: scheme == .dark ? -0.01 :  0.01),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private static func adjust(_ color: Color, brightnessDelta: Double) -> Color {
        let ui = UIColor(color)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        let nb = max(0, min(1, b + CGFloat(brightnessDelta)))
        return Color(hue: Double(h), saturation: Double(s), brightness: Double(nb), opacity: Double(a))
    }
}
