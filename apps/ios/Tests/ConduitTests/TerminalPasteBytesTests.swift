import Testing
import Foundation
@testable import Conduit

/// Stage 5 of the rebuild. Paste wraps the payload in bracketed-paste markers so
/// the receiving TUI treats it as literal input. (Selection itself is
/// libghostty-native — driven by mouse events, verified on-device.)
@Suite("Terminal bracketed paste")
struct TerminalPasteBytesTests {
    @Test func wrapsPayloadInBracketedPasteMarkers() {
        let out = TerminalInputBytes.bracketedPaste("ls")
        #expect(out == Data("\u{1B}[200~ls\u{1B}[201~".utf8))
    }

    @Test func translatesNewlinesInsideTheBrackets() {
        let out = TerminalInputBytes.bracketedPaste("a\nb")
        let expected = Data("\u{1B}[200~".utf8) + Data([0x61, 0x0D, 0x62]) + Data("\u{1B}[201~".utf8)
        #expect(out == expected)
    }

    @Test func startAndEndMarkersAreCorrect() {
        let out = TerminalInputBytes.bracketedPaste("x")
        #expect(out.prefix(6) == Data([0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E])) // ESC [ 2 0 0 ~
        #expect(out.suffix(6) == Data([0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E])) // ESC [ 2 0 1 ~
    }
}
