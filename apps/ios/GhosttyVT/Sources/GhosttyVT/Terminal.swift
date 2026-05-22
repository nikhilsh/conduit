// Stage 1 of `docs/PLAN-TERMINAL-REWRITE.md`. A thin Swift wrapper
// over the ghostty-vt C ABI (`ghostty/vt/terminal.h`). The goal is to
// land the integration shape — init/free/write/resize + a snapshot
// readback — without yet wiring it to PTY bytes or a renderer.
//
// Everything that touches a libghostty symbol is gated by
// `#if canImport(GhosttyVt)` so the iOS app continues to build even
// when the SPM binary target fails to resolve (e.g. upstream rotated
// the `tip` asset and the pinned checksum is stale). When that
// happens, `Terminal.isAvailable` reports `false` and any attempt to
// instantiate `Terminal` traps with a clear message; call sites are
// expected to flag-gate on `Terminal.isAvailable` (Stage 1 has no
// real call sites — the only consumer is `GhosttyTerminalView` behind
// `AppearanceStore.experimentalNativeTerminal`).
//
// Notes on the C ABI surface used here:
// - `ghostty_terminal_new` takes an allocator (NULL = default) and a
//   `GhosttyTerminalOptions { cols, rows, max_scrollback }` struct.
// - `ghostty_terminal_vt_write` (NOT `_write`) is the byte-feeding
//   entry point in this release of libghostty-vt.
// - `ghostty_terminal_resize` also wants pixel dims so XTWINOPS size
//   reports work; we pass zero for the pixel dims at Stage 1 because
//   nothing in our pipeline asks for them yet.
// - `snapshot()` walks the active screen via `ghostty_terminal_grid_ref`
//   one cell at a time. The header explicitly warns this path is not
//   built for render-loop framerates — Stage 1 is fine with that
//   because the only Stage 1 consumer is the test ("write hello, read
//   it back"), and the renderer that lands in Stage 2 will move to
//   the render-state API instead.

import Foundation

#if canImport(GhosttyVt)
import GhosttyVt
#endif

/// Pure-Swift mirror of a single cell in the terminal grid. Lives
/// outside the `#if canImport` block so call sites (and tests) can
/// reference `TerminalSnapshot` regardless of whether the binary
/// framework is wired up. Stage 1 only fills `character`; Stage 2
/// will grow style, color, and wide-char fields.
public struct TerminalCell: Equatable, Sendable {
    /// The grapheme rendered into this cell. Empty string for cells
    /// that have no text (background-color-only or unwritten cells).
    public var character: String

    public init(character: String) {
        self.character = character
    }
}

/// Pure-Swift snapshot of the active screen. Returned by
/// `Terminal.snapshot()`. The `cells` array is row-major and exactly
/// `cols * rows` long.
public struct TerminalSnapshot: Equatable, Sendable {
    public var cols: UInt
    public var rows: UInt
    public var cells: [TerminalCell]
    public var cursorRow: UInt
    public var cursorCol: UInt

    public init(cols: UInt, rows: UInt, cells: [TerminalCell], cursorRow: UInt, cursorCol: UInt) {
        self.cols = cols
        self.rows = rows
        self.cells = cells
        self.cursorRow = cursorRow
        self.cursorCol = cursorCol
    }

    /// Convenience: the snapshot rendered as plain text, rows joined
    /// by `\n`. Trailing whitespace is preserved so tests can pin
    /// exact column positions, but the text output mirrors what a
    /// human would see scrolling the buffer.
    public var plainText: String {
        guard cols > 0, rows > 0 else { return "" }
        var out: [String] = []
        out.reserveCapacity(Int(rows))
        for row in 0..<Int(rows) {
            let start = row * Int(cols)
            let end = start + Int(cols)
            let line = cells[start..<end].map { $0.character.isEmpty ? " " : $0.character }.joined()
            out.append(line)
        }
        return out.joined(separator: "\n")
    }
}

/// Swift wrapper over a `GhosttyTerminal` C handle. Reference type
/// because the underlying handle is heap-allocated and must outlive
/// any borrowed string returns; Swift's value-type story makes the
/// lifetime contract harder to read.
public final class Terminal {
    /// `true` when the prebuilt `ghostty-vt.xcframework` is linked
    /// and importable. Call sites should fall back to the placeholder
    /// path when this is `false`. This is a compile-time check — at
    /// runtime it always returns the same value for a given build.
    public static var isAvailable: Bool {
        #if canImport(GhosttyVt)
        return true
        #else
        return false
        #endif
    }

    #if canImport(GhosttyVt)
    /// Opaque C handle. `nil` only between `init` failure and `deinit`,
    /// which shouldn't be observable from outside.
    private var handle: GhosttyTerminal?

    /// Create a fresh terminal. Traps on allocation failure — this
    /// matches Swift convention for `init` (no `throws` on the
    /// happy-path Stage 1 API; we'll add a throwing variant when
    /// real call sites need to recover).
    public init(cols: UInt, rows: UInt, maxScrollback: UInt = 10_000) {
        precondition(cols > 0 && cols <= UInt(UInt16.max), "cols out of range")
        precondition(rows > 0 && rows <= UInt(UInt16.max), "rows out of range")
        var options = GhosttyTerminalOptions(
            cols: UInt16(cols),
            rows: UInt16(rows),
            max_scrollback: maxScrollback
        )
        var handle: GhosttyTerminal? = nil
        let result = ghostty_terminal_new(nil, &handle, options)
        precondition(result == GHOSTTY_SUCCESS, "ghostty_terminal_new failed: \(result.rawValue)")
        self.handle = handle
    }

    deinit {
        if let handle {
            ghostty_terminal_free(handle)
        }
    }

    /// Feed VT bytes into the terminal's stream parser. Mirrors
    /// `ghostty_terminal_vt_write`; the C entry never fails (it logs
    /// internally on bad input) so this returns `Void`.
    public func write(_ bytes: Data) {
        guard let handle, !bytes.isEmpty else { return }
        bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            ghostty_terminal_vt_write(handle, base, bytes.count)
        }
    }

    /// Convenience for tests + the placeholder path. UTF-8 encoded.
    public func write(_ string: String) {
        write(Data(string.utf8))
    }

    /// Resize the active grid. Pixel dimensions are required by the
    /// C ABI for XTWINOPS reports; Stage 1 leaves them at zero
    /// because no Stage 1 consumer reads the pixel side. Stage 2's
    /// renderer will pass the real measurements.
    public func resize(cols: UInt, rows: UInt, cellWidthPx: UInt = 0, cellHeightPx: UInt = 0) {
        guard let handle else { return }
        precondition(cols > 0 && cols <= UInt(UInt16.max), "cols out of range")
        precondition(rows > 0 && rows <= UInt(UInt16.max), "rows out of range")
        _ = ghostty_terminal_resize(
            handle,
            UInt16(cols),
            UInt16(rows),
            UInt32(cellWidthPx),
            UInt32(cellHeightPx)
        )
    }

    /// Walk the active screen and return a pure-Swift snapshot. The
    /// header documents this path as "not meant to be used as the
    /// core of render loop" — fine for Stage 1, which only needs the
    /// readback for tests + ad-hoc inspection. Stage 2 will swap
    /// over to the render-state iterator API.
    public func snapshot() -> TerminalSnapshot {
        guard let handle else {
            return TerminalSnapshot(cols: 0, rows: 0, cells: [], cursorRow: 0, cursorCol: 0)
        }

        var cols: UInt16 = 0
        var rows: UInt16 = 0
        var cursorX: UInt16 = 0
        var cursorY: UInt16 = 0
        _ = ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_COLS, &cols)
        _ = ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_ROWS, &rows)
        _ = ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_CURSOR_X, &cursorX)
        _ = ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_CURSOR_Y, &cursorY)

        var cells: [TerminalCell] = []
        cells.reserveCapacity(Int(cols) * Int(rows))

        for y in 0..<rows {
            for x in 0..<cols {
                let cell = readCell(handle: handle, x: x, y: y)
                cells.append(cell)
            }
        }

        return TerminalSnapshot(
            cols: UInt(cols),
            rows: UInt(rows),
            cells: cells,
            cursorRow: UInt(cursorY),
            cursorCol: UInt(cursorX)
        )
    }

    private func readCell(handle: GhosttyTerminal, x: UInt16, y: UInt16) -> TerminalCell {
        // Build a GhosttyPoint in active coordinates pointing at (x, y).
        // Swift's C-union importer exposes `GhosttyPointValue` with a
        // no-arg init (zero-initialized bytes); we then set the
        // `coordinate` variant. The `_padding` variant exists only
        // for ABI-growth headroom and is not touched.
        var pointValue = GhosttyPointValue()
        pointValue.coordinate = GhosttyPointCoordinate(x: x, y: UInt32(y))
        let point = GhosttyPoint(tag: GHOSTTY_POINT_TAG_ACTIVE, value: pointValue)

        // GhosttyGridRef is a sized struct; the C side reads `size`
        // first to detect ABI version. Zero-init then patch `size`.
        var ref = GhosttyGridRef()
        ref.size = MemoryLayout<GhosttyGridRef>.size
        let refResult = ghostty_terminal_grid_ref(handle, point, &ref)
        guard refResult == GHOSTTY_SUCCESS, ref.node != nil else {
            return TerminalCell(character: "")
        }

        var cell: GhosttyCell = 0
        let cellResult = ghostty_grid_ref_cell(&ref, &cell)
        guard cellResult == GHOSTTY_SUCCESS else {
            return TerminalCell(character: "")
        }

        var hasText = false
        _ = ghostty_cell_get(cell, GHOSTTY_CELL_DATA_HAS_TEXT, &hasText)
        guard hasText else { return TerminalCell(character: "") }

        // Pull the full grapheme cluster (one or more codepoints).
        // 8 codepoints covers >99.9% of cells we'll ever see; allocate
        // larger only on the rare retry path.
        var buf = [UInt32](repeating: 0, count: 8)
        var outLen: size_t = 0
        var graphemeResult = buf.withUnsafeMutableBufferPointer { ptr in
            ghostty_grid_ref_graphemes(&ref, ptr.baseAddress, ptr.count, &outLen)
        }
        if graphemeResult == GHOSTTY_OUT_OF_SPACE {
            buf = [UInt32](repeating: 0, count: outLen)
            graphemeResult = buf.withUnsafeMutableBufferPointer { ptr in
                ghostty_grid_ref_graphemes(&ref, ptr.baseAddress, ptr.count, &outLen)
            }
        }
        guard graphemeResult == GHOSTTY_SUCCESS, outLen > 0 else {
            return TerminalCell(character: "")
        }

        var scalars: [Unicode.Scalar] = []
        scalars.reserveCapacity(Int(outLen))
        for i in 0..<Int(outLen) {
            if let scalar = Unicode.Scalar(buf[i]) {
                scalars.append(scalar)
            }
        }
        var character = ""
        for scalar in scalars {
            character.unicodeScalars.append(scalar)
        }
        return TerminalCell(character: character)
    }

    #else
    /// Unavailable build — calls trap to surface mis-wired call sites.
    public init(cols: UInt, rows: UInt, maxScrollback: UInt = 10_000) {
        fatalError("GhosttyVT.Terminal requires the ghostty-vt.xcframework to be linked. Check that the SPM binary target resolved (see scripts/fetch-ghostty-vt-xcframework.sh).")
    }

    public func write(_ bytes: Data) {}
    public func write(_ string: String) {}
    public func resize(cols: UInt, rows: UInt, cellWidthPx: UInt = 0, cellHeightPx: UInt = 0) {}
    public func snapshot() -> TerminalSnapshot {
        TerminalSnapshot(cols: 0, rows: 0, cells: [], cursorRow: 0, cursorCol: 0)
    }
    #endif
}
