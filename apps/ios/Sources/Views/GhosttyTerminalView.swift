import SwiftUI
import UIKit
import CoreText

#if canImport(GhosttyVT)
import GhosttyVT
#endif

/// Stage 2 host for the Ghostty-libghostty terminal view.
///
/// What Stage 2 ships: the flag-on path is no longer a placeholder —
/// PTY bytes from `SessionStore.terminalBuffer[session.id]` are now
/// fed into `GhosttyVT.Terminal.write(_:)`, the resulting grid is
/// rendered through a CoreText-backed `CALayer`, and keyboard input
/// (hardware + soft + the existing `TerminalAccessoryBar`) round-trips
/// back into the harness via `SessionStore.sendInput(...)`. xterm.js
/// is not loaded on this code path — the flag-off branch in
/// `ProjectView.tabContent` keeps `WKTerminalView` reachable as a
/// one-toggle revert per `docs/PLAN-TERMINAL-REWRITE.md` §E.
///
/// What Stage 2 explicitly does NOT ship (deferred to Stage 3+):
/// - Selection / copy / paste (Ghostty exposes `vt/selection.h` but
///   the wrapper does not yet bridge it; tap-and-hold falls back to
///   the system default, which is "nothing").
/// - SGR colors / styles in the renderer — every cell paints with the
///   default foreground; the VT side parses styles correctly, the
///   renderer just doesn't read them yet.
/// - Wide / combining / emoji clusters are rendered per-cell as a
///   single grapheme; double-width cells aren't drawn at 2× width.
/// - Render-state dirty tracking. The current path re-snapshots every
///   frame the buffer grows; fine for chat-shaped TUIs, will need the
///   `vt/render.h` iterator for `cat large.log` smoothness in Stage 3.
///
/// The architectural decision (§E renderer row): a `CAMetalLayer` was
/// the original Stage 2 plan, but `ghostty-vt.xcframework` ships only
/// the parser/state half of libghostty — no Metal renderer surface
/// (per the Stage 1 risk log). Building a Metal pipeline from scratch
/// for "draw a grid of glyphs at default colors" is out of scope for
/// this PR; CoreText into a CALayer is the cheapest path that
/// satisfies the Stage 2 acceptance criterion ("renders agent output
/// end-to-end through Terminal.write(_:), no xterm.js loaded") and
/// keeps the door open for a Metal swap in Stage 3.
struct GhosttyTerminalTab: View {
    @Environment(SessionStore.self) private var store
    let session: ProjectSession

    var body: some View {
        GhosttyTerminalView(
            sessionID: session.id,
            bufferProvider: { store.terminalBuffer[session.id] ?? Data() },
            bufferRevision: store.terminalBuffer[session.id]?.count ?? 0,
            onInput: { bytes in
                store.sendInput(sessionID: session.id, bytes: bytes)
            },
            onResize: { rows, cols in
                store.resize(sessionID: session.id, rows: UInt16(rows), cols: UInt16(cols))
            }
        )
        // Match TerminalTabXterm's scope — extend under the home-indicator
        // inset at rest but yield to the keyboard safe area so the cursor
        // row stays visible while the soft keyboard is up.
        .ignoresSafeArea(.container, edges: .bottom)
    }
}

/// `UIViewRepresentable` host for `GhosttyRenderView`. Mirrors
/// `WKTerminalView`'s contract (bufferProvider + revision counter
/// drive the byte diff; onInput / onResize close the loop with
/// SessionStore) so the swap is a one-line branch in ProjectView.
struct GhosttyTerminalView: UIViewRepresentable {
    let sessionID: String
    let bufferProvider: () -> Data
    let bufferRevision: Int
    let onInput: (Data) -> Void
    let onResize: (Int, Int) -> Void

    func makeUIView(context: Context) -> GhosttyRenderView {
        let view = GhosttyRenderView(frame: .zero)
        view.onInput = onInput
        view.onResize = onResize
        // First update: feed whatever the buffer already holds so a
        // tab-switch-back reattach doesn't show an empty grid.
        view.feed(bufferProvider())
        return view
    }

    func updateUIView(_ view: GhosttyRenderView, context: Context) {
        view.onInput = onInput
        view.onResize = onResize
        let buf = bufferProvider()
        let last = view.lastFedByteCount
        if buf.count > last {
            view.feed(buf[last..<buf.count])
            view.lastFedByteCount = buf.count
        } else if buf.count < last {
            // Buffer shrank (snapshot replacement). Reset the emulator
            // and re-feed from scratch — same shape as
            // `WKTerminalView.resetAndFeed`. Stage 1's `Terminal`
            // wrapper doesn't expose `reset()` directly, so we
            // recreate the terminal handle.
            view.resetAndFeed(buf)
            view.lastFedByteCount = buf.count
        }
    }
}

/// Native iOS UIView that renders the Ghostty terminal grid via
/// CoreText, hosts the soft-keyboard accessory bar, and forwards
/// keystrokes back to the harness. Lives at the file level (not nested
/// inside the representable) so it can be exercised from a snapshot
/// test without standing up a SwiftUI host.
final class GhosttyRenderView: UIView, UIKeyInput {
    var onInput: (Data) -> Void = { _ in }
    var onResize: (Int, Int) -> Void = { _, _ in }
    /// Mirrors WKTerminalView.Coordinator.lastFedByteCount — index
    /// into the SessionStore buffer of the last byte we forwarded
    /// into the emulator. The representable's `updateUIView` reads
    /// this on every refresh so we only ever ship the new tail.
    var lastFedByteCount: Int = 0

    /// Cell typography — picked to roughly match xterm.js defaults so
    /// switching the flag mid-session doesn't shock the eye. Stage 3
    /// will read these from `AppearanceStore`.
    private let fontSize: CGFloat = 13
    private lazy var font: UIFont = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
    /// Width of a single character in `font`. Memoized at first layout
    /// so resize math doesn't re-measure on every frame.
    private lazy var cellWidth: CGFloat = {
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        // 'M' is the canonical monospace measurement glyph.
        return ("M" as NSString).size(withAttributes: attrs).width
    }()
    private lazy var cellHeight: CGFloat = font.lineHeight

    /// Current grid geometry. Tracked locally because the emulator's
    /// own cols/rows are write-only from our side except via
    /// `resize(_:)`; `cachedSnapshot` carries the read-side truth.
    private var cols: Int = 80
    private var rows: Int = 24

    /// Last grid snapshot read from libghostty. `nil` until the first
    /// `feed(_:)` call lands. Rendered by `draw(_:)`.
    private var cachedSnapshot: TerminalSnapshotShim?

    #if canImport(GhosttyVT)
    private var terminal: Terminal?
    #endif

    /// Custom accessory bar shared shape with `WKTerminalView`. Held
    /// strong so `inputAccessoryView` doesn't return a dangling ref.
    private lazy var accessoryBar: TerminalAccessoryBar = {
        let bar = TerminalAccessoryBar()
        bar.onSend = { [weak self] bytes in self?.onInput(bytes) }
        return bar
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    // MARK: - First responder / accessory bar

    /// `UIKeyInput` needs the view to be first-responder for hardware
    /// keyboard events to fire and the soft keyboard to appear.
    override var canBecomeFirstResponder: Bool { true }

    override var inputAccessoryView: UIView? { accessoryBar }

    // MARK: - UIKeyInput

    var hasText: Bool { false }

    func insertText(_ text: String) {
        // Soft-keyboard character entry. Forward UTF-8 bytes straight
        // through to the harness — matches WKTerminalView's "input"
        // postMessage path. CR vs LF: TUIs submit on CR (0x0D); iOS
        // hands us LF (0x0A) from Return — translate.
        var data = Data()
        for scalar in text.unicodeScalars {
            if scalar.value == 0x0A {
                data.append(0x0D)
            } else {
                data.append(contentsOf: String(scalar).utf8)
            }
        }
        if !data.isEmpty { onInput(data) }
    }

    func deleteBackward() {
        // VT backspace is BS (0x08); the harness emits a wrap-aware
        // sequence on the way back. Same byte WKTerminalView uses.
        onInput(Data([0x7F]))
    }

    /// Hardware-keyboard arrows / Esc / Tab. Captured before iOS'
    /// own UIKeyCommand resolution so they land on the PTY rather
    /// than navigating SwiftUI.
    override var keyCommands: [UIKeyCommand]? {
        let mods: UIKeyModifierFlags = []
        return [
            UIKeyCommand(input: UIKeyCommand.inputUpArrow,    modifierFlags: mods, action: #selector(handleArrow(_:))),
            UIKeyCommand(input: UIKeyCommand.inputDownArrow,  modifierFlags: mods, action: #selector(handleArrow(_:))),
            UIKeyCommand(input: UIKeyCommand.inputLeftArrow,  modifierFlags: mods, action: #selector(handleArrow(_:))),
            UIKeyCommand(input: UIKeyCommand.inputRightArrow, modifierFlags: mods, action: #selector(handleArrow(_:))),
            UIKeyCommand(input: UIKeyCommand.inputEscape,     modifierFlags: mods, action: #selector(handleEsc)),
            UIKeyCommand(input: "\t",                          modifierFlags: mods, action: #selector(handleTab)),
        ]
    }

    @objc private func handleArrow(_ cmd: UIKeyCommand) {
        switch cmd.input {
        case UIKeyCommand.inputUpArrow:    onInput(Data([0x1B, 0x5B, 0x41]))
        case UIKeyCommand.inputDownArrow:  onInput(Data([0x1B, 0x5B, 0x42]))
        case UIKeyCommand.inputLeftArrow:  onInput(Data([0x1B, 0x5B, 0x44]))
        case UIKeyCommand.inputRightArrow: onInput(Data([0x1B, 0x5B, 0x43]))
        default: break
        }
    }

    @objc private func handleEsc() { onInput(Data([0x1B])) }
    @objc private func handleTab() { onInput(Data([0x09])) }

    // MARK: - Setup

    private func configure() {
        backgroundColor = .black
        isOpaque = true
        contentMode = .redraw
        layer.contentsScale = UIScreen.main.scale

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        addGestureRecognizer(tap)

        #if canImport(GhosttyVT)
        if Terminal.isAvailable {
            terminal = Terminal(cols: UInt(cols), rows: UInt(rows))
        }
        #endif
    }

    @objc private func handleTap() {
        _ = becomeFirstResponder()
    }

    // MARK: - Geometry

    override func layoutSubviews() {
        super.layoutSubviews()
        recomputeGridFromBounds()
    }

    private func recomputeGridFromBounds() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let newCols = max(1, Int(floor(bounds.width / cellWidth)))
        let newRows = max(1, Int(floor(bounds.height / cellHeight)))
        guard newCols != cols || newRows != rows else { return }
        cols = newCols
        rows = newRows
        #if canImport(GhosttyVT)
        terminal?.resize(cols: UInt(cols), rows: UInt(rows))
        #endif
        // Inform the harness so the remote PTY matches. Same call
        // WKTerminalView makes when xterm.js's fit addon resizes.
        onResize(rows, cols)
        refreshSnapshot()
    }

    // MARK: - PTY feed

    func feed(_ bytes: Data) {
        guard !bytes.isEmpty else { return }
        #if canImport(GhosttyVT)
        terminal?.write(bytes)
        #endif
        refreshSnapshot()
    }

    func resetAndFeed(_ bytes: Data) {
        #if canImport(GhosttyVT)
        // No `reset()` on the Stage 1 wrapper — recreate the handle.
        if Terminal.isAvailable {
            terminal = Terminal(cols: UInt(cols), rows: UInt(rows))
            terminal?.write(bytes)
        }
        #endif
        refreshSnapshot()
    }

    private func refreshSnapshot() {
        #if canImport(GhosttyVT)
        guard let terminal else {
            cachedSnapshot = nil
            setNeedsDisplay()
            return
        }
        let snap = terminal.snapshot()
        var rowsOut: [[String]] = []
        rowsOut.reserveCapacity(Int(snap.rows))
        for r in 0..<Int(snap.rows) {
            let start = r * Int(snap.cols)
            let end = start + Int(snap.cols)
            rowsOut.append(snap.cells[start..<end].map { $0.character })
        }
        cachedSnapshot = TerminalSnapshotShim(
            cols: Int(snap.cols),
            rows: Int(snap.rows),
            cells: rowsOut,
            cursorRow: Int(snap.cursorRow),
            cursorCol: Int(snap.cursorCol)
        )
        #else
        cachedSnapshot = nil
        #endif
        setNeedsDisplay()
    }

    // MARK: - Drawing

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.setFillColor(UIColor.black.cgColor)
        ctx.fill(bounds)

        guard let snap = cachedSnapshot, snap.cols > 0, snap.rows > 0 else {
            // No snapshot yet (framework unavailable, or first frame
            // race). Draw a status line so the user isn't staring
            // at a black void if the SPM resolve degraded.
            drawStatus(in: ctx)
            return
        }

        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.white,
        ]

        // CoreText draws with the y-axis flipped (CG default); flip the
        // context once so we can iterate rows top-down with familiar
        // coordinates.
        ctx.saveGState()
        ctx.translateBy(x: 0, y: bounds.height)
        ctx.scaleBy(x: 1, y: -1)

        for r in 0..<snap.rows {
            let line = snap.cells[r].map { $0.isEmpty ? " " : $0 }.joined()
            let attr = NSAttributedString(string: line, attributes: textAttrs)
            let yFromBottom = bounds.height - CGFloat(r + 1) * cellHeight
            // CoreText baselines from the bottom of the line; offset
            // by the font descender so glyphs sit on the cell row.
            let baseline = yFromBottom + abs(font.descender)
            ctx.textPosition = CGPoint(x: 0, y: baseline)
            let line2 = CTLineCreateWithAttributedString(attr)
            CTLineDraw(line2, ctx)
        }
        ctx.restoreGState()

        // Cursor — block style at the current row/col. White
        // background under whatever glyph already drew so the
        // contrast inverts the way a real terminal does. Stage 3
        // will read DECSCUSR style + blink state from
        // `vt/render.h`'s cursor field.
        let cursorRect = CGRect(
            x: CGFloat(snap.cursorCol) * cellWidth,
            y: CGFloat(snap.cursorRow) * cellHeight,
            width: cellWidth,
            height: cellHeight
        )
        ctx.setStrokeColor(UIColor.white.cgColor)
        ctx.setLineWidth(1.0)
        ctx.stroke(cursorRect)
    }

    private func drawStatus(in ctx: CGContext) {
        let text: String
        #if canImport(GhosttyVT)
        text = Terminal.isAvailable
            ? "GhosttyVT initializing — see PLAN-TERMINAL-REWRITE Stage 2"
            : "GhosttyVT module unavailable — flip off the experimental flag"
        #else
        text = "GhosttyVT not linked — see PLAN-TERMINAL-REWRITE Stage 2"
        #endif
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.white,
        ]
        let attr = NSAttributedString(string: text, attributes: attrs)
        let size = attr.size()
        let origin = CGPoint(
            x: (bounds.width - size.width) / 2,
            y: (bounds.height - size.height) / 2
        )
        attr.draw(at: origin)
        _ = ctx // silence unused-var warning when canImport branch elided
    }
}

/// Pure-Swift mirror of `TerminalSnapshot` shaped for the renderer's
/// draw path — rows pre-split into String arrays so `draw(_:)` doesn't
/// re-index a flat array per cell. Lives at the file level so it
/// compiles regardless of whether the framework linked.
private struct TerminalSnapshotShim: Equatable {
    var cols: Int
    var rows: Int
    /// Outer = row index, inner = grapheme per cell.
    var cells: [[String]]
    var cursorRow: Int
    var cursorCol: Int
}
