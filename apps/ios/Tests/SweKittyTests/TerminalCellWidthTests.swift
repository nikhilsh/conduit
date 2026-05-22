import Testing
import Foundation
@testable import SweKitty
import GhosttyVT

/// Stage 3 cell-width tests. Pure-data over the `terminalCellWidth`
/// helper — no UIView, no libghostty. The helper determines whether a
/// grapheme cluster occupies 1 or 2 cells, which the renderer uses to
/// advance its cursor across the row. Mirrors the test scenarios the
/// Termux + xterm.js implementations pin against, so the iOS path
/// agrees with the other platforms on basic cases (ASCII = 1 cell,
/// CJK = 2 cells, emoji = 2 cells).
@Suite("Terminal cell width (UAX #11 / UAX #51 subset)")
struct TerminalCellWidthTests {

    // MARK: - ASCII / Latin → 1 cell

    @Test func asciiLetterIsSingleCell() {
        #expect(terminalCellWidth(for: "a") == 1)
        #expect(terminalCellWidth(for: "Z") == 1)
        #expect(terminalCellWidth(for: "0") == 1)
        #expect(terminalCellWidth(for: " ") == 1)
        #expect(terminalCellWidth(for: "@") == 1)
    }

    @Test func emptyClusterFallsBackToOneCell() {
        // Defensive: the VT side emits "" for unwritten cells; the
        // helper treats them as narrow so the column math is stable.
        #expect(terminalCellWidth(for: "") == 1)
    }

    @Test func latinSupplementIsSingleCell() {
        #expect(terminalCellWidth(for: "é") == 1)
        #expect(terminalCellWidth(for: "ñ") == 1)
        #expect(terminalCellWidth(for: "ü") == 1)
    }

    @Test func greekAndCyrillicAreSingleCell() {
        #expect(terminalCellWidth(for: "α") == 1)
        #expect(terminalCellWidth(for: "Ω") == 1)
        #expect(terminalCellWidth(for: "д") == 1)
    }

    // MARK: - CJK / fullwidth → 2 cells

    @Test func cjkIdeographsAreDoubleWidth() {
        // CJK Unified Ideographs block (U+4E00..U+9FFF).
        #expect(terminalCellWidth(for: "中") == 2)
        #expect(terminalCellWidth(for: "文") == 2)
        #expect(terminalCellWidth(for: "国") == 2)
    }

    @Test func hiraganaIsDoubleWidth() {
        #expect(terminalCellWidth(for: "あ") == 2)
        #expect(terminalCellWidth(for: "の") == 2)
    }

    @Test func katakanaIsDoubleWidth() {
        #expect(terminalCellWidth(for: "ア") == 2)
        #expect(terminalCellWidth(for: "メ") == 2)
    }

    @Test func hangulSyllablesAreDoubleWidth() {
        // Hangul Syllables U+AC00..U+D7A3.
        #expect(terminalCellWidth(for: "한") == 2)
        #expect(terminalCellWidth(for: "글") == 2)
    }

    @Test func fullwidthLatinIsDoubleWidth() {
        // U+FF21 is fullwidth "A".
        #expect(terminalCellWidth(for: "Ａ") == 2)
        #expect(terminalCellWidth(for: "！") == 2)
    }

    // MARK: - Emoji → 2 cells

    @Test func standalonePictographicEmojiIsDoubleWidth() {
        #expect(terminalCellWidth(for: "😀") == 2)
        #expect(terminalCellWidth(for: "🎉") == 2)
        #expect(terminalCellWidth(for: "🚀") == 2)
    }

    @Test func emojiWithSkinToneModifierIsDoubleWidth() {
        // "👋🏽" — waving hand + medium skin tone modifier.
        #expect(terminalCellWidth(for: "👋🏽") == 2)
    }

    @Test func zwjEmojiSequenceIsDoubleWidth() {
        // Family glyph (multiple codepoints joined by ZWJ U+200D).
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F466}"
        #expect(terminalCellWidth(for: family) == 2)
    }

    @Test func regionalIndicatorFlagPairIsDoubleWidth() {
        // 🇯🇵 = U+1F1EF + U+1F1F5 (regional indicators J + P).
        #expect(terminalCellWidth(for: "🇯🇵") == 2)
        // 🇺🇸 = U+1F1FA + U+1F1F8.
        #expect(terminalCellWidth(for: "🇺🇸") == 2)
    }

    @Test func variationSelector16ForcesEmojiPresentation() {
        // ☎ is U+260E (text presentation by default); with VS-16
        // (U+FE0F) it should render as emoji and take 2 cells.
        let textPhone = "\u{260E}"
        let emojiPhone = "\u{260E}\u{FE0F}"
        #expect(terminalCellWidth(for: textPhone) == 1)
        #expect(terminalCellWidth(for: emojiPhone) == 2)
    }

    // MARK: - TerminalCell width default + constructor

    @Test func terminalCellDefaultsToWidthOne() {
        let cell = TerminalCell(character: "a")
        #expect(cell.width == 1)
        #expect(cell.fg == .default)
        #expect(cell.bg == .default)
        #expect(cell.attrs.isEmpty)
    }

    @Test func terminalCellAcceptsExplicitWideWidth() {
        let cell = TerminalCell(character: "中", width: 2)
        #expect(cell.width == 2)
    }

    @Test func terminalCellPreservesSGRDataThroughInit() {
        let cell = TerminalCell(
            character: "x",
            fg: .ansi(index: 2, bright: false),
            bg: .rgb(r: 10, g: 20, b: 30),
            attrs: [.bold, .underline],
            width: 1
        )
        #expect(cell.fg == .ansi(index: 2, bright: false))
        #expect(cell.bg == .rgb(r: 10, g: 20, b: 30))
        #expect(cell.attrs.contains(.bold))
        #expect(cell.attrs.contains(.underline))
        #expect(!cell.attrs.contains(.italic))
    }
}
