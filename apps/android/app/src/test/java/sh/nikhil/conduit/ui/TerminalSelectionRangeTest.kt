package sh.nikhil.conduit.ui

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Pure-data Stage 3 selection-extraction test. Mirrors the iOS
 * `TerminalSelectionRangeTests` so both platforms share a contract.
 *
 * Termux's `TerminalView` ships the live selection UI on Android, so
 * this type is not (yet) on the hot path — but we still lock the
 * row/col → substring helper now so a future Stage 3.1 "Send selection
 * to chat" button can reuse the same shape iOS uses today.
 *
 * Covered cases (mirror the Swift suite):
 *  - Forward / reverse / single-cell single-row.
 *  - Multi-row with first-partial / middle-full / last-partial spans.
 *  - Empty grid cells render as spaces (what-you-see-is-what-you-copy).
 *  - Out-of-bounds anchors clamp.
 *  - `normalized()` swap for drag-backwards.
 */
class TerminalSelectionRangeTest {

    // Build a (rows, cols) cell grid from a list of row strings.
    private fun gridFromRows(vararg rows: String): List<List<String>> =
        rows.map { row -> row.map { it.toString() } }

    // --- single row ---------------------------------------------------

    @Test
    fun `forward single-row range pulls substring`() {
        val grid = gridFromRows("hello", "world", "!!!!!")
        val range = TerminalSelectionRange(
            start = TerminalSelectionAnchor(row = 0, col = 1),
            end = TerminalSelectionAnchor(row = 0, col = 3),
        )
        assertEquals("ell", range.selectedText(grid))
    }

    @Test
    fun `reverse single-row range returns same text as forward`() {
        val grid = gridFromRows("hello", "world", "!!!!!")
        // User dragged from col 3 back to col 1 — normalization must
        // produce the same substring as the forward case above.
        val reversed = TerminalSelectionRange(
            start = TerminalSelectionAnchor(row = 0, col = 3),
            end = TerminalSelectionAnchor(row = 0, col = 1),
        )
        assertEquals("ell", reversed.selectedText(grid))
    }

    @Test
    fun `single-cell selection returns one grapheme`() {
        val grid = gridFromRows("hello", "world", "!!!!!")
        val range = TerminalSelectionRange(
            start = TerminalSelectionAnchor(row = 1, col = 2),
            end = TerminalSelectionAnchor(row = 1, col = 2),
        )
        assertEquals("r", range.selectedText(grid))
    }

    // --- multi-row ----------------------------------------------------

    @Test
    fun `multi-row selection walks rows with newline separators`() {
        val grid = gridFromRows("hello", "world", "!!!!!")
        // Row 0 cols 2..end + "\n" + full row 1 + "\n" + row 2 cols 0..1.
        val range = TerminalSelectionRange(
            start = TerminalSelectionAnchor(row = 0, col = 2),
            end = TerminalSelectionAnchor(row = 2, col = 1),
        )
        assertEquals("llo\nworld\n!!", range.selectedText(grid))
    }

    @Test
    fun `reverse multi-row selection matches forward`() {
        val grid = gridFromRows("hello", "world", "!!!!!")
        // User dragged from (2, 1) upward to (0, 2). Same substring.
        val reversed = TerminalSelectionRange(
            start = TerminalSelectionAnchor(row = 2, col = 1),
            end = TerminalSelectionAnchor(row = 0, col = 2),
        )
        assertEquals("llo\nworld\n!!", reversed.selectedText(grid))
    }

    @Test
    fun `two-row selection has no middle span`() {
        val grid = gridFromRows("hello", "world", "!!!!!")
        val range = TerminalSelectionRange(
            start = TerminalSelectionAnchor(row = 0, col = 3),
            end = TerminalSelectionAnchor(row = 1, col = 2),
        )
        assertEquals("lo\nwor", range.selectedText(grid))
    }

    // --- empty cells render visibly ----------------------------------

    @Test
    fun `empty cells render as space so selection preserves visual width`() {
        val grid = listOf(
            listOf("a", "", "b"),
            listOf("", "", ""),
        )
        val row = TerminalSelectionRange(
            start = TerminalSelectionAnchor(row = 0, col = 0),
            end = TerminalSelectionAnchor(row = 0, col = 2),
        )
        assertEquals("a b", row.selectedText(grid))

        val blank = TerminalSelectionRange(
            start = TerminalSelectionAnchor(row = 1, col = 0),
            end = TerminalSelectionAnchor(row = 1, col = 2),
        )
        assertEquals("   ", blank.selectedText(grid))
    }

    // --- bounds clamping ---------------------------------------------

    @Test
    fun `out-of-bounds anchors clamp to grid size`() {
        val grid = gridFromRows("hello", "world", "!!!!!")
        val range = TerminalSelectionRange(
            start = TerminalSelectionAnchor(row = 0, col = 0),
            end = TerminalSelectionAnchor(row = 99, col = 99),
        )
        assertEquals("hello\nworld\n!!!!!", range.selectedText(grid))
    }

    @Test
    fun `empty grid returns empty string`() {
        val range = TerminalSelectionRange(
            start = TerminalSelectionAnchor(row = 0, col = 0),
            end = TerminalSelectionAnchor(row = 0, col = 0),
        )
        assertEquals("", range.selectedText(emptyList()))
    }

    // --- normalized() ------------------------------------------------

    @Test
    fun `normalized swaps anchors when end is before start`() {
        val r = TerminalSelectionRange(
            start = TerminalSelectionAnchor(row = 3, col = 5),
            end = TerminalSelectionAnchor(row = 1, col = 2),
        )
        val n = r.normalized()
        assertEquals(TerminalSelectionAnchor(row = 1, col = 2), n.start)
        assertEquals(TerminalSelectionAnchor(row = 3, col = 5), n.end)
    }

    @Test
    fun `normalized leaves already-ordered anchors alone`() {
        val r = TerminalSelectionRange(
            start = TerminalSelectionAnchor(row = 1, col = 2),
            end = TerminalSelectionAnchor(row = 3, col = 5),
        )
        val n = r.normalized()
        assertEquals(TerminalSelectionAnchor(row = 1, col = 2), n.start)
        assertEquals(TerminalSelectionAnchor(row = 3, col = 5), n.end)
    }

    @Test
    fun `normalized handles same row end before start`() {
        val r = TerminalSelectionRange(
            start = TerminalSelectionAnchor(row = 2, col = 7),
            end = TerminalSelectionAnchor(row = 2, col = 3),
        )
        val n = r.normalized()
        assertEquals(TerminalSelectionAnchor(row = 2, col = 3), n.start)
        assertEquals(TerminalSelectionAnchor(row = 2, col = 7), n.end)
    }
}
