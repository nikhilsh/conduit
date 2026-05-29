import SwiftUI

// MARK: - NeonTheme
//
// "Neon Terminal" theme system — a self-contained, resolved token set
// for the cyber-terminal visual language described in
// `design_handoff_neon_mobile_ui/` (neon-theme.jsx + README). This file
// is the iOS source of truth for the four neon palettes and the
// light/dark token resolution; the Android mirror lives at
// `apps/android/.../ui/NeonTheme.kt` and must stay value-for-value in
// sync.
//
// Scope is the theme SYSTEM only (tokens + resolver + environment
// injection). It does NOT render any cards/screens — later card work
// consumes the resolved `NeonTheme` (including the glow descriptors)
// from the SwiftUI environment.
//
// User choices feeding the resolver:
//   - palette : NeonPalette (Ice / Synthwave / Matrix / Amber CRT)
//   - dark    : derived from AppearanceStore.themeMode resolved against
//               the effective \.colorScheme (System → follow OS)
//   - glow    : Bool on/off
// All three are persisted by `AppearanceStore` (palette + glow) and the
// existing themeMode mechanism (mode).

// MARK: - NeonPalette

/// The four curated neon palettes. Raw values are the stable persistence
/// ids (`AppearanceStore.neonPalette` round-trips these through
/// UserDefaults). Hex values are verbatim from `neon-theme.jsx`'s
/// `NEON_PALETTES`.
enum NeonPalette: String, CaseIterable, Identifiable {
    case ice
    case synth
    case matrix
    case amber

    var id: String { rawValue }

    var label: String {
        switch self {
        case .ice:    return "Ice"
        case .synth:  return "Synthwave"
        case .matrix: return "Matrix"
        case .amber:  return "Amber CRT"
        }
    }

    /// Bright accent (used directly in dark mode; the "bright" glow
    /// colour in light mode).
    var accentHex: String {
        switch self {
        case .ice:    return "#22d3ee"
        case .synth:  return "#ff49e0"
        case .matrix: return "#39f08a"
        case .amber:  return "#ffb627"
        }
    }

    /// Secondary accent (`accent2`).
    var accent2Hex: String {
        switch self {
        case .ice:    return "#4f8cff"
        case .synth:  return "#22d3ee"
        case .matrix: return "#b6f23d"
        case .amber:  return "#ff7847"
        }
    }

    /// Darker accent — used as the primary accent in LIGHT mode for
    /// contrast against the near-white surfaces.
    var accentDarkHex: String {
        switch self {
        case .ice:    return "#0a93ad"
        case .synth:  return "#c01ea6"
        case .matrix: return "#14a85c"
        case .amber:  return "#c6810a"
        }
    }
}

// MARK: - Glow descriptors
//
// The neon language renders glow as layered shadows (README §3.5). No
// cards exist yet, so nothing renders these — but the resolved theme
// carries them so step-3 card work can consume them without recomputing
// the rules:
//   - text glow (dark only): 0 0 6px {c}CC, 0 0 16px {c}66 (× strength)
//   - box glow:              0 0 10px {c}33, 0 0 26px {c}1F ; light ×0.5
//   - glow OFF: no shadow (borderStrong hairline instead); light mode
//     keeps a soft card elevation 0 4px 16px rgba(13,26,48,0.10).

/// A single layered shadow (matches a CSS `0 0 <radius> <color@alpha>`).
struct NeonShadowLayer: Equatable {
    let radius: CGFloat
    let color: Color
    /// Alpha multiplier baked into `color` already; kept for callers
    /// that want to re-tint. (0...1)
    let alpha: Double
}

/// Box-glow descriptor (two layered shadows). Radii are pre-scaled for
/// the active mode (×0.5 in light mode per README §3.5).
struct NeonGlowBox: Equatable {
    let inner: NeonShadowLayer
    let outer: NeonShadowLayer
}

/// Text-glow descriptor (dark mode only — `nil` in light mode and when
/// glow is off). Two layered shadows.
struct NeonTextGlow: Equatable {
    let inner: NeonShadowLayer
    let outer: NeonShadowLayer
}

/// Soft card elevation used in LIGHT mode when glow is OFF
/// (`0 4px 16px rgba(13,26,48,0.10)`).
struct NeonCardElevation: Equatable {
    let radius: CGFloat
    let yOffset: CGFloat
    let color: Color
}

// MARK: - NeonTheme (resolved tokens)

/// Fully resolved Neon Terminal token set for one (palette, mode, glow)
/// combination. Value type — cheap to recompute and inject. Every token
/// from `makeNeon()` is present as a `Color`, plus gradient + glow
/// descriptors.
///
/// Not `Equatable`: it carries `appBg: RadialGradient`, which isn't
/// Equatable, and nothing compares whole themes (the environment
/// re-injects a freshly resolved value on each appearance change).
struct NeonTheme {
    // Identity / inputs
    let paletteId: String
    let mode: String       // "dark" | "light"
    let dark: Bool
    let glow: Bool

    // Accents
    let accent: Color
    let accent2: Color
    /// Bright accent — equals `accent` in dark mode, the palette's bright
    /// accent in light mode (where `accent` is the darker variant). Used
    /// for glows / badges.
    let accentBright: Color

    // Brand / semantic
    let claude: Color
    let codex: Color
    let purple: Color
    let blue: Color
    let green: Color
    let red: Color
    let yellow: Color

    // Surfaces / chrome
    let bg: Color
    let surface: Color
    let surface2: Color
    let surfaceSolid: Color
    let panel: Color
    let border: Color
    let borderStrong: Color
    let grid: Color

    // Text
    let text: Color
    let textDim: Color
    let textFaint: Color
    let accentText: Color

    // Code
    let codeBg: Color
    let codeText: Color

    // Shape
    let radius: CGFloat

    // Background gradient (approximates the CSS radial-gradient stops).
    let appBg: RadialGradient

    // Glow
    /// Colour glows are tinted with (`accentBright`).
    let glowColor: Color
    /// Whether text-glow is available (dark mode AND glow on).
    let textGlowEnabled: Bool
    /// Text-glow layers, or `nil` when unavailable.
    let textGlow: NeonTextGlow?
    /// Box-glow layers, or `nil` when glow is off.
    let glowBox: NeonGlowBox?
    /// Light-mode card elevation used when glow is off, else `nil`.
    let cardElevation: NeonCardElevation?

    static let radiusValue: CGFloat = 20

    // MARK: Resolve

    /// Resolve the token set for a (palette, dark, glow) combination.
    /// Reproduces `makeNeon({mode, palette, glow})` from neon-theme.jsx.
    static func resolve(palette: NeonPalette, dark: Bool, glow: Bool) -> NeonTheme {
        let aBright = Color(hex: palette.accentHex)          // A
        let a2 = Color(hex: palette.accent2Hex)              // A2
        let accent = dark ? aBright : Color(hex: palette.accentDarkHex)

        // Common (mode-independent) brand/semantic tokens.
        let claude = dark ? Color(hex: "#ff9d4d") : Color(hex: "#d9731a")
        let codex = aBright
        let purple = dark ? Color(hex: "#b487ff") : Color(hex: "#7a48d8")
        let blue = a2
        let green = dark ? Color(hex: "#3ef0a0") : Color(hex: "#12a866")
        let red = dark ? Color(hex: "#ff5c72") : Color(hex: "#d83048")
        let yellow = dark ? Color(hex: "#ffd24d") : Color(hex: "#c79200")

        let bg: Color
        let surface: Color
        let surface2: Color
        let surfaceSolid: Color
        let panel: Color
        let border: Color
        let borderStrong: Color
        let grid: Color
        let text: Color
        let textDim: Color
        let textFaint: Color
        let accentText: Color
        let codeBg: Color
        let codeText: Color
        let appBg: RadialGradient

        if dark {
            bg = Color(hex: "#04050a")
            surface = Color(red: 16 / 255, green: 24 / 255, blue: 42 / 255, opacity: 0.66)
            surface2 = Color(red: 26 / 255, green: 38 / 255, blue: 64 / 255, opacity: 0.74)
            surfaceSolid = Color(hex: "#0a1120")
            panel = Color(hex: "#0b1322")
            border = Color(hex: palette.accentHex, alpha: 0x22)
            borderStrong = Color(hex: palette.accentHex, alpha: 0x44)
            grid = Color(hex: palette.accentHex, alpha: 0x0e)
            text = Color(hex: "#eaf3ff")
            textDim = Color(red: 196 / 255, green: 214 / 255, blue: 244 / 255, opacity: 0.66)
            textFaint = Color(red: 160 / 255, green: 184 / 255, blue: 224 / 255, opacity: 0.40)
            accentText = Color(hex: "#03121a")
            codeBg = Color(red: 0, green: 4 / 255, blue: 12 / 255, opacity: 0.6)
            codeText = text
            // radial-gradient(125% 90% at 50% -12%, {A}14, #0a1020 34%, #05060d 70%, #04050a 100%)
            appBg = RadialGradient(
                gradient: Gradient(stops: [
                    .init(color: Color(hex: palette.accentHex, alpha: 0x14), location: 0.0),
                    .init(color: Color(hex: "#0a1020"), location: 0.34),
                    .init(color: Color(hex: "#05060d"), location: 0.70),
                    .init(color: Color(hex: "#04050a"), location: 1.0),
                ]),
                center: UnitPoint(x: 0.5, y: -0.12),
                startRadius: 0,
                endRadius: 900
            )
        } else {
            bg = Color(hex: "#dfe6f2")
            surface = Color(red: 1, green: 1, blue: 1, opacity: 0.8)
            surface2 = Color(hex: "#ffffff")
            surfaceSolid = Color(hex: "#ffffff")
            panel = Color(hex: "#f4f7fc")
            border = Color(red: 18 / 255, green: 32 / 255, blue: 58 / 255, opacity: 0.12)
            borderStrong = Color(hex: palette.accentDarkHex, alpha: 0x55)
            grid = Color(red: 18 / 255, green: 32 / 255, blue: 58 / 255, opacity: 0.05)
            text = Color(hex: "#0d1a30")
            textDim = Color(red: 28 / 255, green: 46 / 255, blue: 78 / 255, opacity: 0.66)
            textFaint = Color(red: 40 / 255, green: 60 / 255, blue: 96 / 255, opacity: 0.42)
            accentText = Color(hex: "#ffffff")
            codeBg = Color(hex: "#0c1322")   // code stays DARK in light mode
            codeText = Color(hex: "#d6e6ff")
            // radial-gradient(125% 90% at 50% -12%, {A}1f, #eef3fb 40%, #e7edf7 100%)
            appBg = RadialGradient(
                gradient: Gradient(stops: [
                    .init(color: Color(hex: palette.accentHex, alpha: 0x1f), location: 0.0),
                    .init(color: Color(hex: "#eef3fb"), location: 0.40),
                    .init(color: Color(hex: "#e7edf7"), location: 1.0),
                ]),
                center: UnitPoint(x: 0.5, y: -0.12),
                startRadius: 0,
                endRadius: 900
            )
        }

        // Glow descriptors. Glow colour is the bright accent.
        let glowColor = aBright
        let textGlowEnabled = dark && glow
        let textGlow: NeonTextGlow? = textGlowEnabled
            ? NeonTextGlow(
                inner: NeonShadowLayer(radius: 6, color: aBright.opacity(0.80), alpha: 0.80),
                outer: NeonShadowLayer(radius: 16, color: aBright.opacity(0.40), alpha: 0.40)
            )
            : nil

        let glowBox: NeonGlowBox?
        let cardElevation: NeonCardElevation?
        if glow {
            // Light mode softens box-glow radii to ~50%.
            let scale: CGFloat = dark ? 1.0 : 0.5
            glowBox = NeonGlowBox(
                inner: NeonShadowLayer(radius: 10 * scale, color: aBright.opacity(0.20), alpha: 0.20),
                outer: NeonShadowLayer(radius: 26 * scale, color: aBright.opacity(0.12), alpha: 0.12)
            )
            cardElevation = nil
        } else {
            // Glow OFF: no shadow, except a soft card elevation in light.
            glowBox = nil
            cardElevation = dark
                ? nil
                : NeonCardElevation(
                    radius: 16,
                    yOffset: 4,
                    color: Color(red: 13 / 255, green: 26 / 255, blue: 48 / 255, opacity: 0.10)
                )
        }

        return NeonTheme(
            paletteId: palette.rawValue,
            mode: dark ? "dark" : "light",
            dark: dark,
            glow: glow,
            accent: accent,
            accent2: a2,
            accentBright: aBright,
            claude: claude,
            codex: codex,
            purple: purple,
            blue: blue,
            green: green,
            red: red,
            yellow: yellow,
            bg: bg,
            surface: surface,
            surface2: surface2,
            surfaceSolid: surfaceSolid,
            panel: panel,
            border: border,
            borderStrong: borderStrong,
            grid: grid,
            text: text,
            textDim: textDim,
            textFaint: textFaint,
            accentText: accentText,
            codeBg: codeBg,
            codeText: codeText,
            radius: radiusValue,
            appBg: appBg,
            glowColor: glowColor,
            textGlowEnabled: textGlowEnabled,
            textGlow: textGlow,
            glowBox: glowBox,
            cardElevation: cardElevation
        )
    }

    // MARK: Type intent (README §3.4)
    //
    // sans = Space Grotesk → falls back to the system sans (SF Pro).
    // mono = JetBrains Mono → falls back to SF Mono. No font assets are
    // bundled; these expose the design intent consistent with
    // `SweKittyTypography`.

    /// Sans font at `size` (system sans fallback for Space Grotesk).
    func sans(_ size: CGFloat) -> Font { .system(size: size, design: .default) }
    /// Mono font at `size` (system mono fallback for JetBrains Mono).
    func mono(_ size: CGFloat) -> Font { .system(size: size, design: .monospaced) }
}

// MARK: - Hex with alpha helper
//
// `Color(hex:)` lives in Palette.swift (RGB only). The neon tokens need
// `{hex}AA`-style alpha (e.g. accent at 0x22), so add an alpha-aware
// overload here rather than duplicating the RGB parser.

extension Color {
    /// `#RRGGBB` (or `RRGGBB`) tinted to an 8-bit alpha byte (`0...255`).
    /// Mirrors the CSS `{color}AA` hex-alpha suffix used throughout the
    /// neon tokens (e.g. `border = accent + 0x22`).
    init(hex: String, alpha: Int) {
        self = Color(hex: hex).opacity(Double(alpha) / 255.0)
    }
}

// MARK: - Environment injection

private struct NeonThemeKey: EnvironmentKey {
    /// Sensible default so previews / detached views that forget to
    /// inject still render: dark Ice with glow on.
    static let defaultValue: NeonTheme = NeonTheme.resolve(palette: .ice, dark: true, glow: true)
}

extension EnvironmentValues {
    var neonTheme: NeonTheme {
        get { self[NeonThemeKey.self] }
        set { self[NeonThemeKey.self] = newValue }
    }
}

extension View {
    /// Inject a resolved `NeonTheme` into the environment. Read it
    /// downstream with `@Environment(\.neonTheme) private var neon`.
    func neonTheme(_ theme: NeonTheme) -> some View {
        environment(\.neonTheme, theme)
    }
}
