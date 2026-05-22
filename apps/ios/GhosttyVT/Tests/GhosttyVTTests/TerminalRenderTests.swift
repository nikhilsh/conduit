// Stage 4 render-path tests for `GhosttyVT.Terminal`
// (ghostty-bridge-app-surface-v3). The Stage 2 tests that asserted
// per-cell snapshot data (e.g. "row 0 starts with 'alpha'") are gone
// — libghostty's App/Surface ABI does not expose a per-cell readback,
// so those assertions were inherently incompatible with the new pin.
// What remains is the boundary check the iOS renderer actually
// depends on: `snapshot()` returns a stable shape (cols × rows
// cells) so the CoreText fallback doesn't crash on an out-of-bounds
// read while the App/Surface skeleton waits for the Stage 5 Metal
// renderer to take over the visible pixel pipeline.
//
// Gated by `canImport(libghostty)` so a stale checksum keeps the
// bundle green — same risk posture as `Terminal.swift`.

import XCTest
@testable import GhosttyVT

final class TerminalRenderTests: XCTestCase {
    #if canImport(libghostty)

    /// The snapshot shape stays in sync with the cached cols/rows
    /// even when libghostty owns the actual grid. This matters
    /// because the CoreText renderer reads `snap.cells[row*cols+col]`
    /// every frame; a mis-sized cells array would crash on the
    /// first paint.
    func testSnapshotShapeMatchesRequestedGrid() throws {
        let terminal = Terminal(cols: 20, rows: 6)
        terminal.write("alpha\r\nbeta\r\ngamma")

        let snapshot = terminal.snapshot()
        XCTAssertEqual(snapshot.cols, 20)
        XCTAssertEqual(snapshot.rows, 6)
        XCTAssertEqual(snapshot.cells.count, 20 * 6)
    }

    /// A resize after a write resizes the snapshot grid. Stage 5
    /// will assert that the resize propagates through libghostty's
    /// own grid; for the skeleton we just lock down the cached
    /// shape so the renderer's grid-cell math doesn't go stale.
    func testResizeReflectsInSnapshot() {
        let terminal = Terminal(cols: 80, rows: 24)
        terminal.write("preflight\r\n")
        terminal.resize(cols: 60, rows: 20)
        let snapshot = terminal.snapshot()
        XCTAssertEqual(snapshot.cols, 60)
        XCTAssertEqual(snapshot.rows, 20)
        XCTAssertEqual(snapshot.cells.count, 60 * 20)
    }

    #else

    func testFrameworkUnavailableForRenderTests() {
        XCTAssertFalse(Terminal.isAvailable)
    }

    #endif
}
