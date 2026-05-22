import SwiftUI

// MARK: - LitterPalette
//
// Clean-room reimplementation of litter's `Models/LitterPalette.swift`
// color system. Hex values were extracted from the litter source via
// the GitHub API (see the LitterUI.swift header for the license +
// research notes), then re-typed by hand here so we don't carry over
// any GPLv3 source. Every named color is a (light, dark) pair, the
// shape matches litter's `LitterColor` indirection so callers in the
// LitterUI views can write `.litterAccentStrong` etc. without
// reaching into SweKittyPalette.
//
// Mapping notes:
//   - litter's `accentStrong` (00995D / 00FF9C) is litter's brand
//     hue — green. SweKitty's brand accent is copper (#CC785C, decided
//     in PR b22bd63). For visual parity with litter we keep litter's
//     green for `accentStrong`, but use SweKitty's copper for the
//     `brand` accent. Views that previously read `accentStrong` for
//     the brand color (e.g. the "+" FAB) should switch to `.brand`.
//   - "accent" in litter is a neutral gray, used for muted icon
//     buttons. We mirror that here.

extension LitterUI {

    /// Adaptive (light, dark) color pair. Helper that mirrors the
    /// shape of litter's `LitterColor` so LitterUI call sites read
    /// identically to litter's source.
    struct AdaptiveColor: Sendable {
        let light: Color
        let dark: Color

        init(_ light: Color, _ dark: Color) {
            self.light = light
            self.dark = dark
        }

        init(lightHex: UInt32, darkHex: UInt32) {
            self.light = Color(hex: lightHex)
            self.dark  = Color(hex: darkHex)
        }

        /// Resolved color for a specific `ColorScheme`. Falls back to
        /// light for `.unspecified`.
        func color(for scheme: ColorScheme) -> Color {
            scheme == .dark ? dark : light
        }

        /// SwiftUI-friendly value that resolves at render time.
        var color: Color {
            Color(uiColor: UIColor { trait in
                trait.userInterfaceStyle == .dark
                    ? UIColor(self.dark)
                    : UIColor(self.light)
            })
        }
    }

    /// Litter-faithful color palette. Every token has a (light, dark)
    /// pair; consumers call `.color` to get a SwiftUI `Color` that
    /// resolves adaptively at render time.
    enum Palette {
        // MARK: Brand + accent

        /// Litter's neutral accent (4A4A4A / B0B0B0). Used for chrome
        /// icons / muted controls.
        static let accent = AdaptiveColor(
            lightHex: 0x4A4A4A, darkHex: 0xB0B0B0
        )
        /// Litter's brand "strong" accent (00995D / 00FF9C). Kept for
        /// surfaces where we want to read as litter (e.g. status
        /// dots, success states). For the *SweKitty* brand color
        /// (the "+" FAB, header active state) use `.brand`.
        static let accentStrong = AdaptiveColor(
            lightHex: 0x00995D, darkHex: 0x00FF9C
        )
        /// SweKitty brand accent — copper. Set in PR b22bd63 and kept
        /// as the dominant global accent.
        static let brand = AdaptiveColor(
            lightHex: 0xCC785C, darkHex: 0xCC785C
        )

        // MARK: Text

        static let textPrimary = AdaptiveColor(
            lightHex: 0x1A1A1A, darkHex: 0xFFFFFF
        )
        static let textSecondary = AdaptiveColor(
            lightHex: 0x6B6B6B, darkHex: 0x888888
        )
        static let textMuted = AdaptiveColor(
            lightHex: 0x9E9E9E, darkHex: 0x555555
        )
        static let textBody = AdaptiveColor(
            lightHex: 0x2D2D2D, darkHex: 0xE0E0E0
        )
        static let textSystem = AdaptiveColor(
            lightHex: 0x3A4A3F, darkHex: 0xC6D0CA
        )
        static let textOnAccent = AdaptiveColor(
            lightHex: 0xFFFFFF, darkHex: 0x0D0D0D
        )

        // MARK: Surfaces + chrome

        static let surface = AdaptiveColor(
            lightHex: 0xF2F2F7, darkHex: 0x1A1A1A
        )
        static let surfaceLight = AdaptiveColor(
            lightHex: 0xE5E5EA, darkHex: 0x2A2A2A
        )
        static let border = AdaptiveColor(
            lightHex: 0xD1D1D6, darkHex: 0x333333
        )
        static let separator = AdaptiveColor(
            lightHex: 0xE0E0E0, darkHex: 0x1E1E1E
        )
        static let codeBackground = AdaptiveColor(
            lightHex: 0xF0F0F5, darkHex: 0x111111
        )

        // MARK: Semantic

        static let danger = AdaptiveColor(
            lightHex: 0xD32F2F, darkHex: 0xFF5555
        )
        static let success = AdaptiveColor(
            lightHex: 0x2E7D32, darkHex: 0x6EA676
        )
        static let warning = AdaptiveColor(
            lightHex: 0xE65100, darkHex: 0xE2A644
        )
    }
}

// MARK: - Color hex helper

private extension Color {
    /// Initialize from a 0xRRGGBB int. Local to this file because we
    /// only need it for the static palette table.
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >>  8) & 0xFF) / 255.0
        let b = Double( hex        & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1.0)
    }
}
