import SwiftUI

/// Centralised semantic tokens for the app. Replaces the original ad-hoc
/// enum in `DesignSystem.swift`. Mirrors litter's `LitterTheme` shape:
/// adaptive colors + corner radii + a background gradient builder.
enum SweKittyTheme {
    // MARK: - Adaptive colours

    static var accent: Color          { SweKittyPalette.accent.color }
    static var accentStrong: Color    { SweKittyPalette.accentStrong.color }
    static var claudeAccent: Color    { SweKittyPalette.claudeAccent.color }
    static var codexAccent: Color     { SweKittyPalette.codexAccent.color }
    static var hermesAccent: Color    { SweKittyPalette.hermesAccent.color }
    static var piAccent: Color        { SweKittyPalette.piAccent.color }
    static var opencodeAccent: Color  { SweKittyPalette.opencodeAccent.color }

    /// Per-agent accent. Each adapter that ships with the harness
    /// gets a distinct hue so users can see *which* agent they're
    /// talking to at a glance — Claude copper, Codex green, Hermes
    /// purple, Pi blue, opencode orange. Falls back to the neutral
    /// gray `accent` token for unknown agents (rather than the
    /// copper brand accent, so an unknown agent doesn't masquerade
    /// as Claude).
    static func accent(forAgent assistant: String) -> Color {
        switch assistant.lowercased() {
        case "claude":   return claudeAccent
        case "codex":    return codexAccent
        case "hermes":   return hermesAccent
        case "pi":       return piAccent
        case "opencode": return opencodeAccent
        default:         return accent
        }
    }

    /// High-emphasis sibling of `accent(forAgent:)`. Use for filled
    /// avatars, the user-bubble background on agent-tinted surfaces,
    /// or any chrome where the regular accent reads too light against
    /// `textOnAccent`. Same fallback policy: neutral gray for unknown.
    static func accentStrong(forAgent assistant: String) -> Color {
        switch assistant.lowercased() {
        case "claude":   return SweKittyPalette.claudeAccentStrong.color
        case "codex":    return SweKittyPalette.codexAccentStrong.color
        case "hermes":   return SweKittyPalette.hermesAccentStrong.color
        case "pi":       return SweKittyPalette.piAccentStrong.color
        case "opencode": return SweKittyPalette.opencodeAccentStrong.color
        default:         return accent
        }
    }
    static var textPrimary: Color   { SweKittyPalette.textPrimary.color }
    static var textSecondary: Color { SweKittyPalette.textSecondary.color }
    static var textMuted: Color     { SweKittyPalette.textMuted.color }
    static var textBody: Color      { SweKittyPalette.textBody.color }
    /// System/handoff text tone added in PLAN-LITTER-VISUAL-PARITY PR 1
    /// (muted-green) so handoff/system rows can stop opacity-tinting
    /// `textSecondary` ad-hoc.
    static var textSystem: Color    { SweKittyPalette.textSystem.color }
    static var textOnAccent: Color  { SweKittyPalette.textOnAccent.color }
    static var surface: Color       { SweKittyPalette.surface.color }
    static var surfaceLight: Color  { SweKittyPalette.surfaceLight.color }
    static var border: Color        { SweKittyPalette.border.color }
    static var separator: Color     { SweKittyPalette.separator.color }
    /// Inline-code / fenced-code background. Matches LitterPalette.
    static var codeBackground: Color { SweKittyPalette.codeBackground.color }
    static var danger: Color        { SweKittyPalette.danger.color }
    static var success: Color       { SweKittyPalette.success.color }
    static var warning: Color       { SweKittyPalette.warning.color }

    /// Back-compat alias kept while the rest of the codebase is still
    /// reaching for the old "muted foreground" token.
    static var mutedFG: Color { textMuted }

    // MARK: - Shape tokens

    /// Settings / list-panel card radius. PLAN-LITTER-VISUAL-PARITY
    /// PR 1 reduced this from 22 → 14 to match litter's flatter card
    /// shape; hero-style cards that intentionally want the larger
    /// radius should reach for [heroCardCornerRadius] instead.
    static let cardCornerRadius: CGFloat = 14
    /// Opt-in for the legacy 22pt card radius — keep for the
    /// occasional hero card (chat empty state, agent-picker featured
    /// row) where the rounder shape carries weight. Default cards
    /// use [cardCornerRadius] = 14.
    static let heroCardCornerRadius: CGFloat = 22
    static let smallCornerRadius: CGFloat = 14
    /// Hard-edged inline tag / status chip (matches litter).
    static let tagCornerRadius: CGFloat = 4
    /// Fenced + inline code block radius.
    static let codeBlockCornerRadius: CGFloat = 10

    // MARK: - Background gradient

    /// Flat `surface` background (PLAN-LITTER-VISUAL-PARITY PR 1
    /// dropped the brightness-shifted 3-stop gradient — litter renders
    /// a flat surface and the extra shimmer added noise without
    /// value). Returned as a `LinearGradient` with identical stops so
    /// call sites that expect the gradient type compile unchanged; the
    /// rendered result is a flat fill.
    static func backgroundGradient(for scheme: ColorScheme) -> LinearGradient {
        let base = SweKittyPalette.background.color(for: scheme)
        return LinearGradient(colors: [base, base], startPoint: .top, endPoint: .bottom)
    }
}
