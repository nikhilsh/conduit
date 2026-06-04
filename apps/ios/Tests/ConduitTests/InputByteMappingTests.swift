import Testing
import Foundation
@testable import Conduit

/// Stage 4 of the rebuild. Keyboard → PTY byte mapping. User input goes straight
/// to the remote PTY (libghostty is render-only for input), so these bytes must
/// match what a real terminal sends.
@Suite("Terminal input byte mapping")
struct InputByteMappingTests {
    @Test func plainTextPassesThroughAsUTF8() {
        #expect(TerminalInputBytes.text("a") == Data([0x61]))
        #expect(TerminalInputBytes.text("ls -la") == Data("ls -la".utf8))
    }

    @Test func returnTranslatesLFtoCR() {
        // TUIs submit on CR; iOS Return is LF.
        #expect(TerminalInputBytes.text("\n") == Data([0x0D]))
        #expect(TerminalInputBytes.text("a\nb") == Data([0x61, 0x0D, 0x62]))
    }

    @Test func unicodePassesThrough() {
        #expect(TerminalInputBytes.text("é") == Data("é".utf8))
        #expect(TerminalInputBytes.text("→") == Data("→".utf8))
    }

    @Test func controlBytes() {
        #expect(TerminalInputBytes.backspace == Data([0x7F]))
        #expect(TerminalInputBytes.escape == Data([0x1B]))
        #expect(TerminalInputBytes.tab == Data([0x09]))
    }

    @Test func arrowsAreCSICursorKeys() {
        #expect(TerminalInputBytes.arrowUp == Data([0x1B, 0x5B, 0x41]))
        #expect(TerminalInputBytes.arrowDown == Data([0x1B, 0x5B, 0x42]))
        #expect(TerminalInputBytes.arrowLeft == Data([0x1B, 0x5B, 0x44]))
        #expect(TerminalInputBytes.arrowRight == Data([0x1B, 0x5B, 0x43]))
    }
}
