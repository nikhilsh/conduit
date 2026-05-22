// Stage 2 render-path tests for `GhosttyVT.Terminal`. The goal here
// is to lock down the snapshot contract the iOS renderer reads on
// every frame:
//
// - Multi-row writes (LF + content) land on the right rows.
// - The cursor coordinate matches the visual write position so the
//   block-cursor overlay in `GhosttyRenderView.draw(_:)` paints in
//   the right cell.
// - Resize triggers a snapshot with the new dimensions and existing
//   content reflows rather than truncating to invalid indices.
//
// Gated by `#if canImport(GhosttyVt)` so a stale `tip` checksum
// doesn't fail-stop the test bundle — same risk-mitigation shape as
// `TerminalTests.swift` + `Terminal.swift`. When the binary target
// fails to resolve, the bundle has a single "framework unavailable"
// assertion so CI stays green either way.

import XCTest
@testable import GhosttyVT

final class TerminalRenderTests: XCTestCase {
    #if canImport(GhosttyVt)

    /// A short, hand-written VT stream lands on consecutive rows and
    /// the cursor stops at the column after the last character of the
    /// last line. This mirrors the per-cell read pattern
    /// `GhosttyRenderView.refreshSnapshot()` runs every frame.
    func testMultiRowWriteAndCursorAdvance() throws {
        let terminal = Terminal(cols: 20, rows: 6)
        terminal.write("alpha\r\nbeta\r\ngamma")

        let snapshot = terminal.snapshot()
        XCTAssertEqual(snapshot.cols, 20)
        XCTAssertEqual(snapshot.rows, 6)

        // Snapshot row 0 should start with "alpha".
        let row0 = rowText(snapshot: snapshot, row: 0)
        XCTAssertTrue(row0.hasPrefix("alpha"), "row0='\(row0)'")
        let row1 = rowText(snapshot: snapshot, row: 1)
        XCTAssertTrue(row1.hasPrefix("beta"), "row1='\(row1)'")
        let row2 = rowText(snapshot: snapshot, row: 2)
        XCTAssertTrue(row2.hasPrefix("gamma"), "row2='\(row2)'")

        // Cursor: "gamma" is 5 chars on row 2 (no trailing newline) so
        // the cursor sits at column 5, row 2.
        XCTAssertEqual(snapshot.cursorRow, 2, "expected cursor row 2 after multi-line write")
        XCTAssertEqual(snapshot.cursorCol, 5, "expected cursor col 5 after 'gamma'")
    }

    /// Resize after a write resizes the visible grid; the previous
    /// content stays addressable for the renderer (no out-of-bounds
    /// from a stale row count). Mirrors what happens when the iOS
    /// keyboard shows up and `recomputeGridFromBounds()` fires.
    func testResizeReflectsInSnapshot() {
        let terminal = Terminal(cols: 80, rows: 24)
        terminal.write("preflight\r\n")
        terminal.resize(cols: 60, rows: 20)
        let snapshot = terminal.snapshot()
        XCTAssertEqual(snapshot.cols, 60)
        XCTAssertEqual(snapshot.rows, 20)
        XCTAssertEqual(snapshot.cells.count, 60 * 20)
        // After reflow the "preflight" line should still be addressable
        // somewhere in the active area.
        XCTAssertTrue(
            snapshot.plainText.contains("preflight"),
            "expected 'preflight' to survive reflow"
        )
    }

    /// ANSI cursor-positioning sequences from agent output (e.g. a
    /// fullscreen TUI redraw) leave the cursor at the addressed cell.
    /// This is the regression iOS users see if `Terminal.write(_:)`
    /// silently drops escapes — the renderer would paint the cursor
    /// at (0,0) instead of where the agent expects it.
    func testCursorPositionEscape() {
        let terminal = Terminal(cols: 40, rows: 10)
        // CUP: ESC [ 5 ; 12 H — row 5, col 12, both 1-indexed in VT.
        terminal.write("\u{1B}[5;12H")
        let snapshot = terminal.snapshot()
        XCTAssertEqual(snapshot.cursorRow, 4, "VT row is 1-indexed; snapshot is 0-indexed")
        XCTAssertEqual(snapshot.cursorCol, 11)
    }

    // MARK: - Helpers

    /// Pull a single row out of the flat cells array as a String for
    /// readable assertions. Mirrors the row-split the iOS renderer
    /// runs in `refreshSnapshot()` — keeps the test in sync with the
    /// actual render-path data shape.
    private func rowText(snapshot: TerminalSnapshot, row: Int) -> String {
        let start = row * Int(snapshot.cols)
        let end = start + Int(snapshot.cols)
        return snapshot.cells[start..<end]
            .map { $0.character.isEmpty ? " " : $0.character }
            .joined()
    }

    #else
    func testFrameworkUnavailableForRenderTests() {
        // SPM didn't resolve the binary target on this machine — keep
        // the bundle green so CI doesn't fail-stop on a moving-tip
        // checksum issue. Same posture as TerminalTests.
        XCTAssertFalse(Terminal.isAvailable)
    }
    #endif
}
