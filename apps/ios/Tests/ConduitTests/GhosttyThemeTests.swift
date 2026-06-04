import Testing
import Foundation
@testable import Conduit
@testable import GhosttyVT

/// Terminal color themes (restored after the rebuild) + their persistence.
@Suite("Ghostty theme")
struct GhosttyThemeTests {
    @Test func backgroundRGBParsesTheHex() {
        let c = GhosttyTheme.ghosttyDark.backgroundRGB // #1d1f21
        #expect(abs(c.red - 0x1d / 255.0) < 0.001)
        #expect(abs(c.green - 0x1f / 255.0) < 0.001)
        #expect(abs(c.blue - 0x21 / 255.0) < 0.001)
    }

    @Test func everyThemeHasA16ColorPalette() {
        for theme in GhosttyTheme.allCases {
            #expect(theme.palette.count == 16)
        }
    }

    @Test func configBodyCarriesThemeFontAndScrollback() {
        let body = GhosttyTheme.dracula.configBody(fontSize: 12, font: .jetBrainsMono)
        #expect(body.contains("font-size = 12"))
        #expect(body.contains("font-thicken = true"))
        #expect(body.contains("scrollback-limit = 10000000"))
        #expect(body.contains("background = #282a36"))
        #expect(body.contains("font-family = JetBrains Mono"))
        #expect(body.contains("palette = 0="))
    }

    @Test func systemFontOmitsFontFamily() {
        let body = GhosttyTheme.ghosttyDark.configBody(fontSize: 10, font: .system)
        #expect(!body.contains("font-family"))
    }

    @Test func appearanceStoreTerminalThemeAndFontPersist() {
        let defaults = UserDefaults(suiteName: "ghostty-theme-test-\(UUID().uuidString)")!
        let fresh = AppearanceStore(defaults: defaults)
        #expect(fresh.terminalTheme == .ghosttyDark)
        #expect(fresh.terminalFont == .jetBrainsMono)

        let first = AppearanceStore(defaults: defaults)
        first.terminalTheme = .nord
        first.terminalFont = .hack
        let second = AppearanceStore(defaults: defaults)
        #expect(second.terminalTheme == .nord)
        #expect(second.terminalFont == .hack)
    }
}
