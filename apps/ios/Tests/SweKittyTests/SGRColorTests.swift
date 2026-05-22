import Testing
import UIKit
import Foundation
@testable import SweKitty
import GhosttyVT

/// Stage 3 SGR-color tests. Pure-data over `TerminalPalette` and the
/// pure-Swift `renderColor` lookup — no UIView, no CGContext. Mirrors
/// the shape `GhosttyTerminalView.draw(_:)` uses so the in-flight code
/// path is exercised even though the production renderer paints
/// nothing today (libghostty's C ABI is unreachable at the moment;
/// see `Terminal.isAvailable`).
@Suite("SGR color + attribute resolution")
struct SGRColorTests {

    // MARK: - Default fg / bg

    @Test func defaultColorMapsToPaletteForegroundWhenFg() {
        let palette = TerminalPalette.default
        let color = renderColor(.default, fg: true, palette: palette)
        #expect(color == palette.defaultForeground)
    }

    @Test func defaultColorMapsToPaletteBackgroundWhenBg() {
        let palette = TerminalPalette.default
        let color = renderColor(.default, fg: false, palette: palette)
        #expect(color == palette.defaultBackground)
    }

    // MARK: - 16-color ANSI base

    @Test func ansiNormalIndexZeroPicksFirstPaletteSlot() {
        let palette = TerminalPalette.default
        let color = renderColor(.ansi(index: 0, bright: false), fg: true, palette: palette)
        #expect(color == palette.ansi[0])
    }

    @Test func ansiBrightIndexZeroPicksEighthPaletteSlot() {
        let palette = TerminalPalette.default
        let color = renderColor(.ansi(index: 0, bright: true), fg: true, palette: palette)
        #expect(color == palette.ansi[8])
    }

    @Test func ansiNormalIndexSevenPicksSeventhSlot() {
        let palette = TerminalPalette.default
        let color = renderColor(.ansi(index: 7, bright: false), fg: true, palette: palette)
        #expect(color == palette.ansi[7])
    }

    @Test func ansiBrightIndexSevenPicksFifteenthSlot() {
        let palette = TerminalPalette.default
        let color = renderColor(.ansi(index: 7, bright: true), fg: true, palette: palette)
        #expect(color == palette.ansi[15])
    }

    // MARK: - 256-color xterm palette

    @Test func paletteIndexInFirstSixteenAliasesAnsiSlots() {
        let palette = TerminalPalette.default
        for i in 0..<16 {
            let color = renderColor(.palette(index: UInt8(i)), fg: true, palette: palette)
            #expect(color == palette.ansi[i], "palette(\(i)) should equal ansi[\(i)]")
        }
    }

    @Test func paletteIndexSixteenIsXtermCubeOrigin() {
        // Index 16 = cube origin (0, 0, 0) → black.
        let palette = TerminalPalette.default
        let color = renderColor(.palette(index: 16), fg: true, palette: palette)
        // RGB(0, 0, 0).
        var r: CGFloat = -1, g: CGFloat = -1, b: CGFloat = -1, a: CGFloat = -1
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        #expect(r == 0 && g == 0 && b == 0)
    }

    @Test func paletteIndexTwoThirtyOneIsXtermCubeWhite() {
        // Index 231 = cube (5, 5, 5) → 255,255,255.
        let palette = TerminalPalette.default
        let color = renderColor(.palette(index: 231), fg: true, palette: palette)
        var r: CGFloat = -1, g: CGFloat = -1, b: CGFloat = -1, a: CGFloat = -1
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        #expect(r == 1 && g == 1 && b == 1)
    }

    @Test func paletteIndexInCubeUsesCanonicalLevels() {
        // Index 17 = cube (0, 0, 1) → blue = 95.
        let palette = TerminalPalette.default
        let color = renderColor(.palette(index: 17), fg: true, palette: palette)
        var r: CGFloat = -1, g: CGFloat = -1, b: CGFloat = -1, a: CGFloat = -1
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        #expect(r == 0 && g == 0)
        #expect(abs(b - 95.0 / 255.0) < 0.001)
    }

    @Test func paletteIndexTwoThirtyTwoStartsGrayscaleRamp() {
        // 232 → gray 8/255.
        let palette = TerminalPalette.default
        let color = renderColor(.palette(index: 232), fg: true, palette: palette)
        var r: CGFloat = -1, g: CGFloat = -1, b: CGFloat = -1, a: CGFloat = -1
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        #expect(abs(r - 8.0 / 255.0) < 0.001)
        #expect(r == g && g == b)
    }

    @Test func paletteIndexTwoFiftyFiveEndsGrayscaleRamp() {
        // 255 → gray 238/255.
        let palette = TerminalPalette.default
        let color = renderColor(.palette(index: 255), fg: true, palette: palette)
        var r: CGFloat = -1, g: CGFloat = -1, b: CGFloat = -1, a: CGFloat = -1
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        #expect(abs(r - 238.0 / 255.0) < 0.001)
        #expect(r == g && g == b)
    }

    // MARK: - Truecolor

    @Test func rgbColorIsPassedThroughComponentForComponent() {
        let palette = TerminalPalette.default
        let color = renderColor(.rgb(r: 200, g: 100, b: 50), fg: true, palette: palette)
        var r: CGFloat = -1, g: CGFloat = -1, b: CGFloat = -1, a: CGFloat = -1
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        #expect(abs(r - 200.0 / 255.0) < 0.001)
        #expect(abs(g - 100.0 / 255.0) < 0.001)
        #expect(abs(b - 50.0 / 255.0) < 0.001)
        #expect(a == 1.0)
    }

    @Test func rgbBlackAndWhiteHitChannelExtremes() {
        let palette = TerminalPalette.default
        let black = renderColor(.rgb(r: 0, g: 0, b: 0), fg: true, palette: palette)
        let white = renderColor(.rgb(r: 255, g: 255, b: 255), fg: true, palette: palette)
        var r: CGFloat = -1, g: CGFloat = -1, b: CGFloat = -1, a: CGFloat = -1
        black.getRed(&r, green: &g, blue: &b, alpha: &a)
        #expect(r == 0 && g == 0 && b == 0)
        white.getRed(&r, green: &g, blue: &b, alpha: &a)
        #expect(r == 1 && g == 1 && b == 1)
    }

    // MARK: - SGRColor enum equality (data path the renderer reads)

    @Test func sgrColorEnumsCompareByCase() {
        #expect(SGRColor.default == SGRColor.default)
        #expect(SGRColor.ansi(index: 1, bright: false) == SGRColor.ansi(index: 1, bright: false))
        #expect(SGRColor.ansi(index: 1, bright: false) != SGRColor.ansi(index: 1, bright: true))
        #expect(SGRColor.rgb(r: 1, g: 2, b: 3) != SGRColor.rgb(r: 3, g: 2, b: 1))
    }

    // MARK: - SGRAttributes option set

    @Test func sgrAttributesBoldAndItalicCoexist() {
        var attrs: SGRAttributes = []
        attrs.insert(.bold)
        attrs.insert(.italic)
        #expect(attrs.contains(.bold))
        #expect(attrs.contains(.italic))
        #expect(!attrs.contains(.underline))
    }

    @Test func sgrAttributesAllSevenFlagsAreIndependent() {
        // Smoke: each flag toggles its own bit and doesn't collide.
        let all: [SGRAttributes] = [
            .bold, .dim, .italic, .underline, .blink, .reverse, .strikethrough,
        ]
        for (i, a) in all.enumerated() {
            for (j, b) in all.enumerated() where i != j {
                #expect(a.rawValue & b.rawValue == 0, "flags \(i) and \(j) share a bit")
            }
        }
    }

    @Test func sgrAttributesShimBridgesFromGhosttyVTValue() {
        var src: SGRAttributes = []
        src.insert(.bold)
        src.insert(.underline)
        let shim = SGRAttributesShim(src)
        #expect(shim.contains(.bold))
        #expect(shim.contains(.underline))
        #expect(!shim.contains(.italic))
    }

    // MARK: - SGRColorShim ↔ SGRColor bridge

    @Test func sgrColorShimBridgesAllFourCases() {
        let cases: [(GhosttyVT.SGRColor, SGRColorShim)] = [
            (.default, .default),
            (.ansi(index: 3, bright: false), .ansi(index: 3, bright: false)),
            (.ansi(index: 4, bright: true), .ansi(index: 4, bright: true)),
            (.palette(index: 42), .palette(index: 42)),
            (.rgb(r: 11, g: 22, b: 33), .rgb(r: 11, g: 22, b: 33)),
        ]
        for (source, expected) in cases {
            #expect(SGRColorShim(source) == expected)
        }
    }
}
