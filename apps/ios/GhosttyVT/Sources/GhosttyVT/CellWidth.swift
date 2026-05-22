// Stage 3 of `docs/PLAN-TERMINAL-REWRITE.md`. Pure-data helpers for
// computing the visual cell width of a grapheme cluster, used by both
// the iOS CoreText renderer (to advance two cell widths for a wide
// glyph) and the unit tests (which build snapshots from string literals
// without standing up libghostty).
//
// Lives in `GhosttyVT` rather than the app target so the data path
// stays UIKit-free — the renderer reads `TerminalCell.width` directly
// off the snapshot; this file exposes `terminalCellWidth(for:)` so test
// builds that construct cells without going through libghostty agree
// with the renderer on which clusters are double-width.
//
// The width rules implemented here are a simplified subset of UAX #11
// "East Asian Width" and UAX #51 "Unicode Emoji":
//
//  - Emoji presentation (Extended_Pictographic + variation selector
//    `U+FE0F`, ZWJ sequences, regional indicators, keycaps, ASCII
//    digits/emoji shouldn't promote → 1) → width 2.
//  - East Asian Wide / Fullwidth (CJK ideographs U+4E00..U+9FFF,
//    hiragana U+3040..U+309F, katakana U+30A0..U+30FF, hangul
//    U+AC00..U+D7AF, fullwidth Latin U+FF00..U+FF60, …) → width 2.
//  - Combining marks attached to a base codepoint don't change the
//    width — a Swift `Character` already groups them with their base,
//    so the helper just inspects the leading scalar's Unicode category.
//  - Everything else → 1.
//
// The C ABI we'll eventually bridge (`ghostty_cell_get` with the wide
// cell flag) is the production source of truth. The helper here is a
// best-effort approximation for the unit-test / placeholder path —
// good enough for emoji + CJK + grapheme clusters built from literal
// strings, which is all the tests need to pin the renderer's two-cell
// advance behavior.

import Foundation

/// Compute the visual cell width for a grapheme cluster.
///
/// Returns 2 for clusters that should occupy two terminal cells:
///  - Extended_Pictographic emoji (single-codepoint or ZWJ chains).
///  - Emoji modifier sequences (skin tones, hair-styles).
///  - Keycap sequences (`*️⃣`, `#️⃣`, `0️⃣` – `9️⃣`).
///  - Regional Indicator pairs (flags).
///  - East Asian Wide / Fullwidth codepoints (CJK / fullwidth Latin).
///
/// Returns 1 for everything else, including:
///  - ASCII letters / digits / punctuation.
///  - Latin-1 supplement, Greek, Cyrillic.
///  - Hangul Jamo (which present narrow), unless composed into Hangul
///    Syllables (`U+AC00..U+D7AF`, fullwidth).
///  - Empty / control characters (caller should typically not pass
///    these; the helper conservatively returns 1).
///
/// Combining marks at the start of a cluster are highly unusual (the
/// VT half doesn't emit them as standalone cells) — they fall through
/// to 1 since the cluster has no visible "base" to widen.
public func terminalCellWidth(for grapheme: String) -> Int {
    guard let first = grapheme.unicodeScalars.first else { return 1 }

    // Multi-scalar cluster: regional-indicator flags (two RI scalars)
    // and any cluster containing Variation Selector-16 (U+FE0F) or a
    // Zero-Width Joiner (U+200D) are emoji presentation → 2 cells.
    if grapheme.unicodeScalars.count > 1 {
        let scalars = Array(grapheme.unicodeScalars)
        if scalars[0].properties.isEmoji
            && scalars[0].properties.isEmojiPresentation {
            return 2
        }
        for scalar in scalars {
            // Variation Selector-16 forces emoji presentation on the
            // base, taking it to 2 cells. Same logic the macOS Cocoa
            // text engine uses for layout.
            if scalar.value == 0xFE0F { return 2 }
            // ZWJ joiner — any cluster that includes a joiner is a
            // multi-codepoint emoji sequence (e.g. family glyph).
            if scalar.value == 0x200D { return 2 }
            // Regional Indicator (U+1F1E6..U+1F1FF). Flags pair two
            // of these; finding even one in a cluster means the
            // cluster is a flag (or a partial flag, which we still
            // render as wide so the column math doesn't go off).
            if (0x1F1E6...0x1F1FF).contains(scalar.value) { return 2 }
        }
    }

    // Single-scalar — check Emoji_Presentation directly. Codepoints
    // like ☎ (U+260E) are Emoji but *not* Emoji_Presentation; they
    // render as text (1 cell) absent a VS-16 selector, which we
    // already handled in the multi-scalar branch.
    if first.properties.isEmojiPresentation {
        return 2
    }

    let v = first.value
    // East Asian Wide ranges (UAX #11 condensed — only the blocks the
    // tests pin against; matches what `terminal-emulator` ships).
    let wideRanges: [ClosedRange<UInt32>] = [
        0x1100...0x115F,   // Hangul Jamo
        0x2E80...0x303E,   // CJK Radicals + Kangxi + CJK Symbols
        0x3041...0x33FF,   // Hiragana, Katakana, Bopomofo, CJK Strokes
        0x3400...0x4DBF,   // CJK Unified Ideographs Ext A
        0x4E00...0x9FFF,   // CJK Unified Ideographs
        0xA000...0xA4CF,   // Yi Syllables
        0xAC00...0xD7A3,   // Hangul Syllables
        0xF900...0xFAFF,   // CJK Compatibility Ideographs
        0xFE30...0xFE4F,   // CJK Compatibility Forms
        0xFF00...0xFF60,   // Fullwidth Forms
        0xFFE0...0xFFE6,   // Fullwidth signs
        0x1F300...0x1F64F, // Misc Symbols and Pictographs + Emoticons
        0x1F680...0x1F6FF, // Transport and Map Symbols
        0x1F900...0x1F9FF, // Supplemental Symbols and Pictographs
        0x20000...0x2FFFD, // CJK Ext B–F (SIP)
        0x30000...0x3FFFD, // CJK Ext G+ (TIP)
    ]
    for range in wideRanges where range.contains(v) {
        return 2
    }
    return 1
}
