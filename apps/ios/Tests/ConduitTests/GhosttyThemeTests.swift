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

    @Test func configBodyCarriesThemeKeysAndScrollback() {
        let body = GhosttyTheme.dracula.configBody(fontSize: 12)
        #expect(body.contains("font-size = 12"))
        #expect(body.contains("scrollback-limit = 10000000"))
        #expect(body.contains("background = #282a36"))
        #expect(body.contains("palette = 0="))
    }

    @Test func appearanceStoreDefaultsToGhosttyDarkAndPersists() {
        let defaults = UserDefaults(suiteName: "ghostty-theme-test-\(UUID().uuidString)")!
        #expect(AppearanceStore(defaults: defaults).terminalTheme == .ghosttyDark)

        let first = AppearanceStore(defaults: defaults)
        first.terminalTheme = .nord
        #expect(AppearanceStore(defaults: defaults).terminalTheme == .nord)
    }
}
