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

/// VT-100/ECMA-48 SGR color, in the shape the renderer needs to look it
/// up in a `TerminalPalette`. Pure data — the actual `UIColor`
/// resolution happens in the iOS app layer so this module stays
/// UIKit-free (it links into both the app and the test bundle).
///
/// Four flavors, matching what the SGR escape sequences can produce:
///  - `.default` — "use the terminal's default foreground / background"
///    (renderer-dependent; defaults are tracked separately from a
///    palette index because reset SGR doesn't pick palette slot 0/7).
///  - `.ansi(index:bright:)` — the 16-color base + bright table.
///    `index` is 0..7 (black, red, green, yellow, blue, magenta, cyan,
///    white) and `bright` flips the bright variant on. This is the
///    shape SGR 30–37, 40–47, 90–97, 100–107 emits.
///  - `.palette(index:)` — the xterm 256-color palette (SGR 38;5;n /
///    48;5;n). Index 0..15 alias the 16-color base; 16..231 are the
///    6×6×6 RGB cube; 232..255 are the 24-step grayscale ramp.
///  - `.rgb(r:g:b:)` — 24-bit truecolor (SGR 38;2;r;g;b / 48;2;r;g;b).
public enum SGRColor: Equatable, Sendable, Hashable {
    case `default`
    case ansi(index: UInt8, bright: Bool)
    case palette(index: UInt8)
    case rgb(r: UInt8, g: UInt8, b: UInt8)
}

/// VT-100/ECMA-48 SGR attributes that aren't colors. Matches the bit
/// flags Ghostty's `vt/cell.h` exposes — bold + dim are independent so
/// both can be set (and a renderer that doesn't support dim can fall
/// back to "normal weight"); reverse is honored by the renderer
/// swapping `fg`/`bg` before resolving each cell.
public struct SGRAttributes: OptionSet, Equatable, Sendable, Hashable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let bold          = SGRAttributes(rawValue: 1 << 0)
    public static let dim           = SGRAttributes(rawValue: 1 << 1)
    public static let italic        = SGRAttributes(rawValue: 1 << 2)
    public static let underline     = SGRAttributes(rawValue: 1 << 3)
    public static let blink         = SGRAttributes(rawValue: 1 << 4)
    public static let reverse       = SGRAttributes(rawValue: 1 << 5)
    public static let strikethrough = SGRAttributes(rawValue: 1 << 6)
}

/// Pure-Swift mirror of a single cell in the terminal grid. Lives
/// outside the `#if canImport` block so call sites (and tests) can
/// reference `TerminalSnapshot` regardless of whether the binary
/// framework is wired up. Stage 1 only filled `character`; Stage 3
/// adds `fg`/`bg`/`attrs`/`width` so the CoreText renderer can paint
/// colored / wide / styled glyphs. The libghostty bridge in
/// `readCell` still leaves these at their defaults because the
/// current pin's C ABI is unreachable (see `Terminal.isAvailable`);
/// the renderer is exercised via unit tests until that wrapper is
/// rebuilt against the App/Surface API.
public struct TerminalCell: Equatable, Sendable {
    /// The grapheme rendered into this cell. Empty string for cells
    /// that have no text (background-color-only or unwritten cells).
    public var character: String

    /// Foreground SGR color. `.default` for cells the VT side has
    /// reset (the renderer paints the terminal's default foreground).
    public var fg: SGRColor

    /// Background SGR color. `.default` for cells the VT side has
    /// reset (the renderer paints the terminal's default background).
    public var bg: SGRColor

    /// Non-color SGR attributes (bold, italic, underline, …). Empty
    /// option-set when nothing is active.
    public var attrs: SGRAttributes

    /// Visual cell width — 1 for normal characters and 2 for wide
    /// (East Asian / emoji) graphemes. The continuation cell of a
    /// wide pair carries `width == 0` and an empty `character`; the
    /// renderer skips it because the parent already drew the glyph
    /// across the pair. Defaults to 1 so the legacy `init` (which
    /// only set `character`) continues to behave as a single cell.
    public var width: Int

    public init(
        character: String,
        fg: SGRColor = .default,
        bg: SGRColor = .default,
        attrs: SGRAttributes = [],
        width: Int = 1
    ) {
        self.character = character
        self.fg = fg
        self.bg = bg
        self.attrs = attrs
        self.width = width
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
    /// `true` when the slim VT-only `GhosttyVt` C module is linked
    /// and importable. Call sites should fall back to the placeholder
    /// path when this is `false`. This is a compile-time check — at
    /// runtime it always returns the same value for a given build.
    ///
    /// **Currently always `false`.** The PR ghostty-pin-lakr233
    /// swapped the SPM binaryTarget from upstream's `ghostty-vt`
    /// asset (slim VT API) to Lakr233's prebuilt `libghostty` asset
    /// (full App/Surface API). The xcframework now resolves and
    /// links across all required iOS slices, but the C symbols this
    /// wrapper was written against (`ghostty_terminal_new`,
    /// `ghostty_terminal_vt_write`, `ghostty_terminal_grid_ref`, …)
    /// don't exist in the new pin's `ghostty.h`. A follow-up PR
    /// rewrites the wrapper to bridge `ghostty_surface_*`; until
    /// then the `#if canImport(GhosttyVt)` branch below is unreachable
    /// and `Terminal.isAvailable` reports `false`, so all call sites
    /// (and the test bundle) cleanly take the placeholder path.
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
            max_scrollback: Int(maxScrollback)
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
        fatalError("GhosttyVT.Terminal: the `GhosttyVt` C module is not importable. As of the ghostty-pin-lakr233 PR this is the EXPECTED state — the current SPM binaryTarget (Lakr233/libghostty-spm storage.1.1.5, see apps/ios/GhosttyVT/Package.swift) ships the full `libghostty` module with the App/Surface API, not the slim VT-only API this wrapper was written against. The follow-up PR will rewrite this wrapper to bridge the App/Surface surface; until then call sites must flag-gate on `Terminal.isAvailable`. See scripts/fetch-ghostty-kit-xcframework.sh + docs/PLAN-TERMINAL-REWRITE.md → Stage 2 status — Lakr233 pin.")
    }

    public func write(_ bytes: Data) {}
    public func write(_ string: String) {}
    public func resize(cols: UInt, rows: UInt, cellWidthPx: UInt = 0, cellHeightPx: UInt = 0) {}
    public func snapshot() -> TerminalSnapshot {
        TerminalSnapshot(cols: 0, rows: 0, cells: [], cursorRow: 0, cursorCol: 0)
    }
    #endif
}
