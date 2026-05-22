import UIKit

#if canImport(GhosttyVT)
import GhosttyVT
#endif

/// Stage 3 of `docs/PLAN-TERMINAL-REWRITE.md`. Maps the pure-data
/// `SGRColor` enum that the `GhosttyVT` snapshot carries into concrete
/// `UIColor` values the CoreText renderer can apply to a
/// `CFAttributedString` foreground / a `CGContext` background fill.
///
/// This lives in the iOS app target (not the GhosttyVT module) because
/// `UIColor` is UIKit, and the data module deliberately stays
/// UIKit-free so it can compile / test on macOS as well. The renderer
/// reaches across one boundary — `TerminalPalette.default.color(for:
/// fg:)` — to get a `UIColor`.
///
/// **Palette source.** The default palette is a hand-picked
/// "Solarized-ish dark" base for the 16 ANSI slots — black, red,
/// green, yellow, blue, magenta, cyan, white + bright variants chosen
/// to match what a fresh `ghostty` install paints on macOS. Stage 3+
/// will let `AppearanceStore` override these (theme switcher row in
/// `AppearanceSheet`); the static `.default` is the bootstrap value
/// the renderer reads until then.
///
/// **256-palette.** Indices 0..15 alias the 16 ANSI slots; 16..231
/// are the xterm 6×6×6 RGB cube; 232..255 are the 24-step grayscale
/// ramp. This is the same lookup `xterm.js` ships in its `Color`
/// module and matches what Ghostty itself emits.
struct TerminalPalette {

    /// Foreground default when an SGR reset leaves the cell at
    /// `.default`. Picked to match the existing renderer's plain-text
    /// foreground (white) so the flag-on path doesn't shift hue mid-
    /// session.
    let defaultForeground: UIColor

    /// Background default when an SGR reset leaves the cell at
    /// `.default`. The renderer skips the background fill entirely
    /// for `.default` cells so the view's own `backgroundColor`
    /// (black, set in `configure()`) shows through; this value is
    /// kept here for completeness and for the reverse-video swap
    /// (which needs a concrete fill).
    let defaultBackground: UIColor

    /// The 16 ANSI base colors, indexed 0..7 normal, 8..15 bright.
    /// Source: Ghostty's defaults on macOS dark mode.
    let ansi: [UIColor]

    /// Resolve an `SGRColor` into a `UIColor`. `fg` selects whether
    /// `.default` returns the palette's default foreground (true) or
    /// default background (false) — the reverse-video swap relies on
    /// this so a reversed `.default`/`.default` cell paints bg-on-fg
    /// instead of bg-on-bg.
    func color(for sgr: SGRColor, fg: Bool) -> UIColor {
        switch sgr {
        case .default:
            return fg ? defaultForeground : defaultBackground
        case .ansi(let index, let bright):
            let slot = Int(index) + (bright ? 8 : 0)
            // Clamp defensively — `.ansi` is built from a UInt8 0..7
            // by construction at the VT-bridge layer, but the test
            // suite can construct arbitrary indices.
            let safe = max(0, min(ansi.count - 1, slot))
            return ansi[safe]
        case .palette(let index):
            return TerminalPalette.xterm256Color(at: index, palette: self)
        case .rgb(let r, let g, let b):
            return UIColor(
                red: CGFloat(r) / 255.0,
                green: CGFloat(g) / 255.0,
                blue: CGFloat(b) / 255.0,
                alpha: 1.0
            )
        }
    }

    /// xterm 256-color lookup. 0..15 alias the supplied 16-color
    /// palette so theme switches propagate "for free". 16..231 are the
    /// standard 6×6×6 RGB cube using the canonical xterm levels
    /// `[0, 95, 135, 175, 215, 255]`. 232..255 are the 24-step
    /// grayscale ramp running from `0x08` to `0xEE` in steps of 10.
    static func xterm256Color(at index: UInt8, palette: TerminalPalette) -> UIColor {
        let i = Int(index)
        if i < 16 {
            return palette.ansi[i]
        }
        if i < 232 {
            // 6×6×6 RGB cube. Decompose the cube index.
            let cube = i - 16
            let r = (cube / 36) % 6
            let g = (cube / 6) % 6
            let b = cube % 6
            let levels: [CGFloat] = [0, 95, 135, 175, 215, 255]
            return UIColor(
                red: levels[r] / 255.0,
                green: levels[g] / 255.0,
                blue: levels[b] / 255.0,
                alpha: 1.0
            )
        }
        // 232..255 → grayscale 8..238 in steps of 10.
        let gray = CGFloat(8 + (i - 232) * 10) / 255.0
        return UIColor(red: gray, green: gray, blue: gray, alpha: 1.0)
    }

    /// Hand-picked dark palette — black background, light foreground,
    /// the 16-color ANSI slots tuned to roughly match what Ghostty
    /// paints on macOS Sequoia dark mode. Originally the only palette
    /// the Stage 3 renderer knew about (the static `.default` below
    /// still aliases this for back-compat with the SGR color tests).
    static let dark = TerminalPalette(
        defaultForeground: UIColor(red: 0.93, green: 0.93, blue: 0.93, alpha: 1.0),
        defaultBackground: UIColor.black,
        ansi: [
            // Normal (0..7): black, red, green, yellow, blue, magenta, cyan, white
            UIColor(red: 0.00, green: 0.00, blue: 0.00, alpha: 1.0),
            UIColor(red: 0.80, green: 0.20, blue: 0.20, alpha: 1.0),
            UIColor(red: 0.30, green: 0.70, blue: 0.30, alpha: 1.0),
            UIColor(red: 0.80, green: 0.65, blue: 0.20, alpha: 1.0),
            UIColor(red: 0.25, green: 0.45, blue: 0.85, alpha: 1.0),
            UIColor(red: 0.70, green: 0.35, blue: 0.75, alpha: 1.0),
            UIColor(red: 0.25, green: 0.70, blue: 0.75, alpha: 1.0),
            UIColor(red: 0.85, green: 0.85, blue: 0.85, alpha: 1.0),
            // Bright (8..15)
            UIColor(red: 0.45, green: 0.45, blue: 0.45, alpha: 1.0),
            UIColor(red: 0.95, green: 0.40, blue: 0.40, alpha: 1.0),
            UIColor(red: 0.50, green: 0.85, blue: 0.50, alpha: 1.0),
            UIColor(red: 0.95, green: 0.85, blue: 0.40, alpha: 1.0),
            UIColor(red: 0.45, green: 0.65, blue: 0.95, alpha: 1.0),
            UIColor(red: 0.85, green: 0.55, blue: 0.90, alpha: 1.0),
            UIColor(red: 0.45, green: 0.85, blue: 0.90, alpha: 1.0),
            UIColor(red: 1.00, green: 1.00, blue: 1.00, alpha: 1.0),
        ]
    )

    /// Hand-picked light palette — paper-white background, near-black
    /// foreground, the 16 ANSI slots desaturated and darkened so a red
    /// `error:` token still reads as red on a white surface without
    /// blinding the user. Tuned to roughly match the Solarized-Light /
    /// Apple-Terminal "Basic" palette pair.
    static let light = TerminalPalette(
        defaultForeground: UIColor(red: 0.10, green: 0.10, blue: 0.10, alpha: 1.0),
        defaultBackground: UIColor(red: 0.98, green: 0.98, blue: 0.97, alpha: 1.0),
        ansi: [
            // Normal (0..7): black, red, green, yellow, blue, magenta, cyan, white
            UIColor(red: 0.10, green: 0.10, blue: 0.10, alpha: 1.0),
            UIColor(red: 0.70, green: 0.15, blue: 0.15, alpha: 1.0),
            UIColor(red: 0.15, green: 0.55, blue: 0.20, alpha: 1.0),
            UIColor(red: 0.60, green: 0.50, blue: 0.10, alpha: 1.0),
            UIColor(red: 0.15, green: 0.30, blue: 0.70, alpha: 1.0),
            UIColor(red: 0.55, green: 0.20, blue: 0.60, alpha: 1.0),
            UIColor(red: 0.15, green: 0.55, blue: 0.60, alpha: 1.0),
            UIColor(red: 0.55, green: 0.55, blue: 0.55, alpha: 1.0),
            // Bright (8..15)
            UIColor(red: 0.35, green: 0.35, blue: 0.35, alpha: 1.0),
            UIColor(red: 0.85, green: 0.25, blue: 0.25, alpha: 1.0),
            UIColor(red: 0.20, green: 0.70, blue: 0.30, alpha: 1.0),
            UIColor(red: 0.75, green: 0.60, blue: 0.10, alpha: 1.0),
            UIColor(red: 0.25, green: 0.45, blue: 0.85, alpha: 1.0),
            UIColor(red: 0.70, green: 0.30, blue: 0.75, alpha: 1.0),
            UIColor(red: 0.20, green: 0.65, blue: 0.70, alpha: 1.0),
            UIColor(red: 0.20, green: 0.20, blue: 0.20, alpha: 1.0),
        ]
    )

    /// Back-compat alias for the Stage 3 callsite that hard-coded the
    /// dark palette before this PR. Existing tests / call sites that
    /// read `.default` still see the dark variant.
    static let `default` = TerminalPalette.dark

    /// Resolve a theme-aware palette from the user's
    /// [AppearanceStore.ThemeMode]. `.system` reads the supplied
    /// `userInterfaceStyle` (which the caller pulls from the
    /// `traitCollection` of the live view) so the resolution happens
    /// at draw time — toggling the system appearance mid-session
    /// causes the next `setNeedsDisplay` to repaint with the new
    /// palette.
    static func palette(
        for mode: AppearanceStore.ThemeMode,
        systemStyle: UIUserInterfaceStyle
    ) -> TerminalPalette {
        switch mode {
        case .light:
            return .light
        case .dark:
            return .dark
        case .system:
            return systemStyle == .light ? .light : .dark
        }
    }
}
