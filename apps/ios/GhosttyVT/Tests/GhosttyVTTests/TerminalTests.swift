// Stage 1 smoke test for the `GhosttyVT.Terminal` wrapper. Gated by
// `#if canImport(GhosttyVt)` so the test target builds (as a no-op)
// even when the prebuilt xcframework fails to resolve — same risk-
// mitigation shape as `Terminal.swift`.

import XCTest
@testable import GhosttyVT

final class TerminalTests: XCTestCase {
    #if canImport(GhosttyVt)
    func testInitWriteAndSnapshotRoundTrip() throws {
        XCTAssertTrue(Terminal.isAvailable, "ghostty-vt.xcframework should be linked in this build")

        let terminal = Terminal(cols: 80, rows: 24)
        terminal.write("hello\n")

        let snapshot = terminal.snapshot()
        XCTAssertEqual(snapshot.cols, 80)
        XCTAssertEqual(snapshot.rows, 24)
        XCTAssertEqual(snapshot.cells.count, 80 * 24)

        // "hello" should land on the first row of the active area.
        XCTAssertTrue(
            snapshot.plainText.contains("hello"),
            "expected snapshot to contain 'hello'; got first row: \(snapshot.plainText.split(separator: "\n").first ?? "")"
        )

        // Cursor should have advanced past "hello\n" — i.e. now on
        // row 1, column 0.
        XCTAssertEqual(snapshot.cursorRow, 1)
        XCTAssertEqual(snapshot.cursorCol, 0)
    }

    func testResizeChangesReportedDimensions() {
        let terminal = Terminal(cols: 80, rows: 24)
        terminal.resize(cols: 100, rows: 30)
        let snapshot = terminal.snapshot()
        XCTAssertEqual(snapshot.cols, 100)
        XCTAssertEqual(snapshot.rows, 30)
    }
    #else
    func testFrameworkUnavailable() {
        // When the xcframework isn't linked we still want a green
        // test bundle so CI doesn't fail-stop on resolution issues.
        XCTAssertFalse(Terminal.isAvailable)
    }
    #endif
}
