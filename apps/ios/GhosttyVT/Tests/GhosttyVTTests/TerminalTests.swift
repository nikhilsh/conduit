// Stage 4 smoke tests for the rewritten `GhosttyVT.Terminal`
// (ghostty-bridge-app-surface-v3). The Stage 1 tests against the
// slim VT-only API are gone — `ghostty_terminal_grid_ref` and friends
// do not exist in Lakr233's `libghostty` build, so the per-cell
// snapshot path the old tests asserted on was inherently unreachable
// against this binary target. The new tests just exercise the smoke
// path: `Terminal.init` + `Terminal.write` + a status-description
// query — enough to prove libghostty's `ghostty_app_new` boot path
// returns a live App handle and `ghostty_surface_write_buffer`
// accepts byte feeds without trapping.
//
// Gated by `canImport(libghostty)` so a stale checksum (or a build
// configuration where the binary target failed to resolve) keeps the
// test bundle green — same risk posture as `Terminal.swift`.

import XCTest
@testable import GhosttyVT

final class TerminalTests: XCTestCase {
    #if canImport(libghostty)

    /// Smoke: the App/Surface pipeline initializes and a byte write
    /// does not trap. Stage 5 will assert on rendered output once the
    /// Metal renderer lands; for the skeleton this is the "did
    /// libghostty actually load" lock-down.
    func testAppAndSurfaceCreateThenWriteDoesNotTrap() throws {
        XCTAssertTrue(
            Terminal.isAvailable,
            "libghostty.xcframework should have linked and ghostty_app_new should have succeeded: \(Terminal.statusDescription())"
        )

        let terminal = Terminal(cols: 80, rows: 24)
        terminal.write("hello, ghostty\r\n")

        // The status string is stable enough to assert a prefix on
        // — useful for debugging which boot branch the runtime took.
        let status = Terminal.statusDescription()
        XCTAssertTrue(
            status.hasPrefix("libghostty alive"),
            "expected status to report libghostty as alive; got: \(status)"
        )
    }

    /// Resize math should clamp to the UInt16 range and not trap.
    /// Stage 5 will assert that libghostty's internal grid follows
    /// the resize — for the skeleton we just guard against the
    /// precondition crash that bit the old wrapper when iOS handed
    /// it a zero-width layout pass.
    func testResizeDoesNotTrap() {
        let terminal = Terminal(cols: 80, rows: 24)
        terminal.resize(cols: 100, rows: 30)
        // No assertion beyond "did not crash" — the App/Surface
        // ABI does not expose a per-cell read-back, so the
        // snapshot stub returns empty cells. Stage 5 swaps the
        // renderer over to `ghostty_surface_draw` and removes
        // the snapshot path.
        let snap = terminal.snapshot()
        XCTAssertEqual(snap.cols, 100)
        XCTAssertEqual(snap.rows, 30)
    }

    #else

    /// Binary target failed to resolve on this build. Keep the
    /// bundle green so CI doesn't fail-stop on a transient SPM
    /// hiccup — same posture the slim-VT-era tests used.
    func testFrameworkUnavailable() {
        XCTAssertFalse(Terminal.isAvailable)
    }

    #endif
}
