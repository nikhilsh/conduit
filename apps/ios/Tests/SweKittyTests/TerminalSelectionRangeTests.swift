import Testing
import Foundation
@testable import SweKitty

/// Stage 3 selection-extraction tests. Pure data over a
/// `TerminalSnapshotShim` — no UIView, no gesture recognizer. Mirrors
/// the Kotlin `TerminalSelectionRangeTest` shape so both platforms
/// share a contract.
///
/// What's exercised:
///  - Forward range (start above-left of end) over a single row.
///  - Reverse range (user dragged the long-press anchor backwards) —
///    `selectedText` must normalize the anchors and produce the same
///    substring as the forward case.
///  - Single-cell selection (start == end) — one grapheme out.
///  - Multi-row extraction — first row from `start.col` to row end,
///    middle rows full-width, last row from 0 to `end.col`, with
///    `\n` row separators between them.
///  - Empty / whitespace cells render as a single space (matches
///    what the renderer paints on screen so what-you-see-is-what-you-copy).
///  - Out-of-bounds anchors clamp to the snapshot, not crash.
@Suite("TerminalSelectionRange — pure-data text extraction")
struct TerminalSelectionRangeTests {

    // Helper: build a 5x3 snapshot from a list of row strings.
    private func snapshot(_ rows: [String]) -> TerminalSnapshotShim {
        let cols = rows.first?.count ?? 0
        let cells: [[String]] = rows.map { row in
            row.map { String($0) }
        }
        return TerminalSnapshotShim(
            cols: cols,
            rows: rows.count,
            cells: cells,
            cursorRow: 0,
            cursorCol: 0
        )
    }

    // MARK: - Single-row cases

    @Test func forwardSingleRowRangeReturnsSubstring() {
        let snap = snapshot(["hello", "world", "!!!!!"])
        // Start at (0, 1) end at (0, 3) — pulls "ell".
        let range = TerminalSelectionRange(start: (0, 1), end: (0, 3))
        #expect(range.selectedText(from: snap) == "ell")
    }

    @Test func reverseSingleRowRangeReturnsSameAsForward() {
        let snap = snapshot(["hello", "world", "!!!!!"])
        // User long-pressed at (0, 3) and dragged back to (0, 1).
        // Normalized rectangle is identical to the forward case.
        let reversed = TerminalSelectionRange(start: (0, 3), end: (0, 1))
        #expect(reversed.selectedText(from: snap) == "ell")
    }

    @Test func singleCellSelectionReturnsOneGrapheme() {
        let snap = snapshot(["hello", "world", "!!!!!"])
        let range = TerminalSelectionRange(start: (1, 2), end: (1, 2))
        // Cell (1, 2) on "world" is "r".
        #expect(range.selectedText(from: snap) == "r")
    }

    // MARK: - Multi-row case

    @Test func multiRowSelectionWalksRowsWithNewlineSeparators() {
        let snap = snapshot(["hello", "world", "!!!!!"])
        // Start mid-row 0 (col 2), end mid-row 2 (col 1).
        // Expected:
        //   "llo"     -- row 0 from col 2 to last col (4)
        //   "\n"
        //   "world"   -- row 1 full width
        //   "\n"
        //   "!!"      -- row 2 from col 0 through col 1
        let range = TerminalSelectionRange(start: (0, 2), end: (2, 1))
        #expect(range.selectedText(from: snap) == "llo\nworld\n!!")
    }

    @Test func reverseMultiRowSelectionMatchesForward() {
        let snap = snapshot(["hello", "world", "!!!!!"])
        // User dragged from (2, 1) UP to (0, 2). Normalization should
        // produce the same substring as the forward case above.
        let reversed = TerminalSelectionRange(start: (2, 1), end: (0, 2))
        #expect(reversed.selectedText(from: snap) == "llo\nworld\n!!")
    }

    @Test func twoRowSelectionHasNoMiddleSpan() {
        let snap = snapshot(["hello", "world", "!!!!!"])
        // Adjacent rows: row 0 from col 3, row 1 through col 2.
        // No middle rows — just first + "\n" + last.
        let range = TerminalSelectionRange(start: (0, 3), end: (1, 2))
        #expect(range.selectedText(from: snap) == "lo\nwor")
    }

    // MARK: - Padding cells render visibly

    @Test func emptyCellsRenderAsSpaceSoSelectionPreservesVisualWidth() {
        // Cells from a fresh grid are "" — the renderer paints them
        // as spaces, and `selectedText` mirrors that so a copied
        // selection contains the same visible whitespace.
        let cells: [[String]] = [
            ["a", "",  "b"],
            ["",  "",  ""],
        ]
        let snap = TerminalSnapshotShim(
            cols: 3,
            rows: 2,
            cells: cells,
            cursorRow: 0,
            cursorCol: 0
        )
        let row = TerminalSelectionRange(start: (0, 0), end: (0, 2))
        #expect(row.selectedText(from: snap) == "a b")

        let blank = TerminalSelectionRange(start: (1, 0), end: (1, 2))
        #expect(blank.selectedText(from: snap) == "   ")
    }

    // MARK: - Bounds clamping

    @Test func outOfBoundsAnchorsClampToSnapshot() {
        let snap = snapshot(["hello", "world", "!!!!!"])
        // Anchor end at (99, 99). Should clamp to the bottom-right
        // and return the rest of the grid from (0, 0).
        let range = TerminalSelectionRange(start: (0, 0), end: (99, 99))
        #expect(range.selectedText(from: snap) == "hello\nworld\n!!!!!")
    }

    @Test func emptySnapshotReturnsEmptyString() {
        let snap = TerminalSnapshotShim(
            cols: 0,
            rows: 0,
            cells: [],
            cursorRow: 0,
            cursorCol: 0
        )
        let range = TerminalSelectionRange(start: (0, 0), end: (0, 0))
        #expect(range.selectedText(from: snap) == "")
    }

    // MARK: - normalized()

    @Test func normalizedSwapsAnchorsWhenEndIsBeforeStart() {
        let r = TerminalSelectionRange(start: (3, 5), end: (1, 2))
        let n = r.normalized
        #expect(n.start == (1, 2))
        #expect(n.end == (3, 5))
    }

    @Test func normalizedLeavesAlreadyOrderedAnchorsAlone() {
        let r = TerminalSelectionRange(start: (1, 2), end: (3, 5))
        let n = r.normalized
        #expect(n.start == (1, 2))
        #expect(n.end == (3, 5))
    }

    @Test func normalizedHandlesSameRowEndBeforeStart() {
        let r = TerminalSelectionRange(start: (2, 7), end: (2, 3))
        let n = r.normalized
        #expect(n.start == (2, 3))
        #expect(n.end == (2, 7))
    }
}
