import SwiftUI
import UIKit

/// Light/dark colour pairs used by `ConduitTheme`. The neutrals are
/// the system grays Apple ships in its HIG palette; `accentStrong` is
/// tuned to the Conduit brand.
enum ConduitPalette {
    struct Pair {
        let light: String
        let dark: String
    }

    static let accent          = Pair(light: "#4A4A4A", dark: "#B0B0B0")
    // Brand accent — switched from green (#00A86B / #34C759) to
    // Anthropic copper to match the upstream visual reference (the
    // entire UI in their screenshots tints orange — badges, +,
    // user bubble, status, stat numbers). Per-agent tints below
    // (`codexAccent`, `hermesAccent`, …) live alongside.
    static let accentStrong    = Pair(light: "#CC785C", dark: "#E89677")
    /// Conduit redesign agent tint — Claude reads as a warm orange
    /// (`--claude #FF9D4D`, BRAND.md §3, confirmed against the target
    /// art). Dark ships first, so the dark value is the canonical hex;
    /// the light value is deepened for legibility on a light surface.
    static let claudeAccent    = Pair(light: "#E07A1E", dark: "#FF9D4D")
    /// Claude tint — strong variant for high-emphasis surfaces.
    static let claudeAccentStrong = Pair(light: "#C2630F", dark: "#FFB264")
    /// Conduit redesign agent tint — Codex reads as the brand cyan
    /// (`#22D3EE`, build-prompt theme line + target art). Yes, this
    /// matches the primary accent: that's intentional in the ice
    /// palette. Light value deepened for legibility.
    static let codexAccent     = Pair(light: "#0E90A8", dark: "#22D3EE")
    /// Cyan Codex — strong variant for high-emphasis surfaces.
    static let codexAccentStrong  = Pair(light: "#0A7E95", dark: "#5BDFF2")
    /// Hermes purple. Mythological messenger — a Tailwind purple-500.
    /// No public Hermes adapter brand to anchor to, so this is a
    /// defensible choice that contrasts cleanly with claude/codex.
    static let hermesAccent    = Pair(light: "#A855F7", dark: "#C084FC")
    static let hermesAccentStrong = Pair(light: "#7E22CE", dark: "#A855F7")
    /// Inflection Pi blue. Tailwind blue-500 — Inflection's brand
    /// reads as a cool blue in their marketing.
    static let piAccent        = Pair(light: "#3B82F6", dark: "#60A5FA")
    static let piAccentStrong  = Pair(light: "#1D4ED8", dark: "#3B82F6")
    /// opencode orange. Tailwind orange-500 — sst.dev's opencode
    /// reads orange on its docs site.
    static let opencodeAccent  = Pair(light: "#F97316", dark: "#FB923C")
    static let opencodeAccentStrong = Pair(light: "#C2410C", dark: "#F97316")
    static let textPrimary     = Pair(light: "#1A1A1A", dark: "#FFFFFF")
    static let textSecondary   = Pair(light: "#6B6B6B", dark: "#888888")
    static let textMuted       = Pair(light: "#9E9E9E", dark: "#555555")
    static let textBody        = Pair(light: "#2D2D2D", dark: "#E0E0E0")
    /// Muted-green tone used by handoff / system-emitted bubble rendering
    /// (mirrors upstream's `ConduitPalette.textSystem`). Added in the
    /// PLAN-CONDUIT-VISUAL-PARITY PR 1 foundation pass so non-ConduitUI
    /// surfaces stop falling back to ad-hoc opacity tricks.
    static let textSystem      = Pair(light: "#3A4A3F", dark: "#C6D0CA")
    static let textOnAccent    = Pair(light: "#FFFFFF", dark: "#0D0D0D")
    static let surface         = Pair(light: "#F2F2F7", dark: "#1A1A1A")
    static let surfaceLight    = Pair(light: "#E5E5EA", dark: "#2A2A2A")
    static let border          = Pair(light: "#D1D1D6", dark: "#333333")
    static let separator       = Pair(light: "#E0E0E0", dark: "#1E1E1E")
    /// Background tone for inline code / code blocks (mirrors upstream's
    /// `ConduitPalette.codeBackground`). Until PR 1 we used
    /// `surface.opacity(0.72)` ad-hoc, which read differently per scheme.
    static let codeBackground  = Pair(light: "#F0F0F5", dark: "#111111")
    static let danger          = Pair(light: "#D32F2F", dark: "#FF5555")
    static let success         = Pair(light: "#2E7D32", dark: "#6EA676")
    static let warning         = Pair(light: "#E65100", dark: "#E2A644")
    static let background      = Pair(light: "#FAFAFA", dark: "#0C0E12")
}

extension Color {
    /// Hex initializer mirroring upstream's `Color(hex:)`. Accepts `#RRGGBB`
    /// or `RRGGBB`; ignores non-hex characters.
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xFF) / 255
        let g = Double((int >> 8) & 0xFF) / 255
        let b = Double(int & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

extension ConduitPalette.Pair {
    /// Adaptive SwiftUI color resolved per-trait so the same value works
    /// in light/dark mode without sprinkling `@Environment(\.colorScheme)`.
    var color: Color {
        Color(uiColor: UIColor { trait in
            switch trait.userInterfaceStyle {
            case .dark: return UIColor(Color(hex: dark))
            default:    return UIColor(Color(hex: light))
            }
        })
    }

    /// Per-scheme resolution (for previews / gradient builders that need
    /// an explicit scheme rather than the trait-based dynamic value).
    func color(for scheme: ColorScheme) -> Color {
        Color(hex: scheme == .dark ? dark : light)
    }
}
