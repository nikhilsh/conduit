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
    @Environment(AppearanceStore.self) private var appearance
    let session: ProjectSession

    var body: some View {
        GhosttyTerminalView(
            sessionID: session.id,
            bufferProvider: { store.terminalBuffer[session.id] ?? Data() },
            bufferRevision: store.terminalBuffer[session.id]?.count ?? 0,
            themeMode: appearance.themeMode,
            fontFamily: appearance.fontFamily,
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
    /// User-selected theme mode read from `AppearanceStore`. `.system`
    /// resolves at draw time off the live trait collection so a
    /// light/dark system toggle repaints without a re-mount.
    let themeMode: AppearanceStore.ThemeMode
    /// User-selected body font from `AppearanceStore`. The terminal
    /// always uses a monospaced variant (cell-grid renderer can't
    /// tolerate proportional glyph widths) but the user's choice
    /// modulates the system-font fallback path (serif → falls back to
    /// monospaced, system → monospaced system font, monospaced →
    /// explicitly monospaced).
    let fontFamily: AppearanceStore.FontFamily
    let onInput: (Data) -> Void
    let onResize: (Int, Int) -> Void

    func makeUIView(context: Context) -> GhosttyRenderView {
        let view = GhosttyRenderView(frame: .zero)
        view.onInput = onInput
        view.onResize = onResize
        view.applyAppearance(themeMode: themeMode, fontFamily: fontFamily)
        // First update: feed whatever the buffer already holds so a
        // tab-switch-back reattach doesn't show an empty grid.
        view.feed(bufferProvider())
        return view
    }

    func updateUIView(_ view: GhosttyRenderView, context: Context) {
        view.onInput = onInput
        view.onResize = onResize
        // Apply appearance every update so changes in
        // `AppearanceStore.themeMode` / `fontFamily` propagate to the
        // live view without a remount. `applyAppearance` is a no-op
        // when the values didn't actually change, so this is cheap.
        view.applyAppearance(themeMode: themeMode, fontFamily: fontFamily)
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

    /// Base point size before Dynamic Type scaling. Stays at 13pt — the
    /// xterm.js default — so toggling the flag at the same accessibility
    /// setting doesn't shift cell density.
    private static let baseFontSize: CGFloat = 13

    /// Theme + font choice resolved from `AppearanceStore`. Held so the
    /// `traitCollectionDidChange` hook can repaint when the system
    /// flips light↔dark while we're in `.system` mode without re-running
    /// `applyAppearance`. Defaults match the pre-PR behaviour
    /// (monospaced font, dark palette).
    private var themeMode: AppearanceStore.ThemeMode = .system
    private var fontFamily: AppearanceStore.FontFamily = .monospaced

    /// Scaled point size — recomputed every time `applyAppearance` runs
    /// off `UIFontMetrics.default.scaledValue(for:)` so larger Dynamic
    /// Type categories give a larger cell font (better readability for
    /// the Larger Text accessibility setting). The base value is fixed
    /// at 13pt; the scaled value floats per category.
    private var fontSize: CGFloat = baseFontSize

    /// Active glyph font. Recomputed in `applyAppearance`. Always a
    /// monospaced face — the cell-grid renderer can't tolerate
    /// proportional widths — but the underlying descriptor is selected
    /// to match the user's font-family choice so a serif/system reader
    /// gets the closest monospaced variant the system ships.
    private var font: UIFont = UIFont.monospacedSystemFont(
        ofSize: GhosttyRenderView.baseFontSize,
        weight: .regular
    )

    /// Width of a single character in `font`. Recomputed whenever the
    /// font changes (`applyAppearance`); resize math reads the cached
    /// value so a frame doesn't re-measure.
    private var cellWidth: CGFloat = GhosttyRenderView.baseFontSize * 0.6
    private var cellHeight: CGFloat = GhosttyRenderView.baseFontSize

    /// Current grid geometry. Tracked locally because the emulator's
    /// own cols/rows are write-only from our side except via
    /// `resize(_:)`; `cachedSnapshot` carries the read-side truth.
    private var cols: Int = 80
    private var rows: Int = 24

    /// Last grid snapshot read from libghostty. `nil` until the first
    /// `feed(_:)` call lands. Rendered by `draw(_:)`. Internal so unit
    /// tests can verify the snapshot↔selection coupling without
    /// re-implementing it.
    var cachedSnapshot: TerminalSnapshotShim?

    /// Stage 3 selection state. `nil` when nothing is selected; set by
    /// the long-press / double-tap / triple-tap recognisers and
    /// extended by the pan recogniser. Cleared by a single tap or by
    /// `copy(_:)` after the text has been copied. Internal so unit
    /// tests can assert on the state machine without exercising
    /// UIGestureRecognizer.
    var selectionRange: TerminalSelectionRange?

    #if canImport(GhosttyVT)
    private var terminal: Terminal?

    /// Drives libghostty's render loop. libghostty owns the Metal
    /// renderer + the `CAMetalLayer` it created on this view; we just
    /// have to ask it to paint each display refresh. Started/stopped
    /// with window membership so we don't burn cycles off-screen.
    private var displayLink: CADisplayLink?
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
        recomputeTypography()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
        recomputeTypography()
    }

    // MARK: - Appearance plumbing

    /// Called from the UIViewRepresentable on every Compose-style
    /// update with the latest theme + font choice from
    /// `AppearanceStore`. No-op when nothing changed; otherwise
    /// recomputes the cached typography (and triggers a re-layout if
    /// the cell metrics shifted) and a repaint.
    func applyAppearance(
        themeMode: AppearanceStore.ThemeMode,
        fontFamily: AppearanceStore.FontFamily
    ) {
        let themeChanged = themeMode != self.themeMode
        let fontChanged = fontFamily != self.fontFamily
        guard themeChanged || fontChanged else { return }
        self.themeMode = themeMode
        self.fontFamily = fontFamily
        if fontChanged {
            recomputeTypography()
            // Cell geometry may have shifted — re-evaluate the grid
            // and let the harness know about a possible resize.
            recomputeGridFromBounds()
        }
        setNeedsDisplay()
    }

    /// Re-derive `fontSize`, `font`, `cellWidth`, `cellHeight` from
    /// the current `fontFamily` choice and the user's Dynamic Type
    /// category. Stored on the view so `draw(_:)` and the per-cell
    /// layout math read consistent values.
    private func recomputeTypography() {
        // Honour the user's content-size category. `UIFontMetrics.default`
        // scales the base point size against the Larger Text setting so
        // the terminal grid grows for accessibility users instead of
        // staying pinned at 13pt.
        let traits = traitCollection
        fontSize = UIFontMetrics.default.scaledValue(
            for: GhosttyRenderView.baseFontSize,
            compatibleWith: traits
        )
        // Pick a monospaced face that respects the user's family choice.
        // Serif / system both fall back to monospacedSystemFont because
        // a proportional face would break the cell grid; the choice
        // still matters when iOS ships a serif-monospaced variant in a
        // future OS update — feeding the chosen design through here
        // lets that land "for free".
        let design: UIFontDescriptor.SystemDesign
        switch fontFamily {
        case .serif:      design = .serif
        case .system:     design = .default
        case .monospaced: design = .monospaced
        }
        let base = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        if let descriptor = base.fontDescriptor.withDesign(design) {
            // `UIFont(descriptor:size:)` is non-optional in current SDKs —
            // the prior `if let` form here failed compilation under
            // Swift 6 with "initializer for conditional binding must
            // have Optional type, not 'UIFont'". Unwrap only the
            // descriptor and use the plain init for the font.
            font = UIFont(descriptor: descriptor, size: fontSize)
        } else {
            font = base
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        cellWidth = ("M" as NSString).size(withAttributes: attrs).width
        cellHeight = font.lineHeight
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        // Repaint when the system flips appearance under us — `.system`
        // mode reads the live trait collection at draw time, so a
        // light↔dark toggle should change colours immediately. Also
        // catches Dynamic Type changes: if the user bumps Larger Text
        // while the app is running, the cell font grows on the next
        // layout.
        if previousTraitCollection?.preferredContentSizeCategory
            != traitCollection.preferredContentSizeCategory
        {
            recomputeTypography()
            recomputeGridFromBounds()
        }
        if previousTraitCollection?.userInterfaceStyle
            != traitCollection.userInterfaceStyle
        {
            setNeedsDisplay()
        }
    }

    /// Theme-resolved palette for the current draw pass. Re-evaluates
    /// the trait collection every call so `.system` mode picks the
    /// right variant for the live UI style.
    private var resolvedPalette: TerminalPalette {
        TerminalPalette.palette(
            for: themeMode,
            systemStyle: traitCollection.userInterfaceStyle
        )
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
        // Start at dark-palette black so the first frame doesn't flash
        // a UIView-default grey. `draw(_:)` paints the resolved palette
        // background underneath every cell, so this colour only shows
        // through if `cachedSnapshot` is nil during initial layout.
        backgroundColor = TerminalPalette.dark.defaultBackground
        isOpaque = true
        contentMode = .redraw
        layer.contentsScale = UIScreen.main.scale

        // Stage 3 gesture stack. Order matters for `require(toFail:)`
        // — a single tap mustn't fire while a double / triple tap is
        // still in flight, and the long-press anchor mustn't race the
        // selection pan that extends it.

        let triple = UITapGestureRecognizer(target: self, action: #selector(handleTripleTap(_:)))
        triple.numberOfTapsRequired = 3
        addGestureRecognizer(triple)

        let double = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        double.numberOfTapsRequired = 2
        double.require(toFail: triple)
        addGestureRecognizer(double)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.numberOfTapsRequired = 1
        tap.require(toFail: double)
        addGestureRecognizer(tap)

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        addGestureRecognizer(longPress)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleSelectionPan(_:)))
        pan.maximumNumberOfTouches = 1
        // Only extend selection after long-press has anchored it.
        pan.require(toFail: longPress)
        addGestureRecognizer(pan)

        #if canImport(GhosttyVT)
        // Stage 4: with the wrapper rewired to the libghostty
        // App/Surface API, `Terminal.isAvailable` now reads `true`
        // once `GhosttyApp.shared` boots — so we instantiate
        // a real host-managed surface and attach this UIView so
        // libghostty's iOS platform slot (`ghostty_platform_ios_s.uiview`)
        // can target our layer when the Metal renderer lands.
        if Terminal.isAvailable {
            let term = Terminal(cols: UInt(cols), rows: UInt(rows))
            // The host-view attach uses zero pixel dims here; the
            // first `layoutSubviews` pass will call `attach(...)`
            // again with the real bounds once UIKit has measured us.
            term.attach(
                hostView: self,
                pixelWidth: 0,
                pixelHeight: 0,
                scaleFactor: Double(UIScreen.main.scale)
            )
            terminal = term
        }
        #endif
    }

    // MARK: - Selection gestures

    /// Convert a tap point in view coordinates to a (row, col) grid
    /// cell. Clamps to the snapshot bounds so a tap on the
    /// inputAccessoryView edge can't write past the grid.
    private func gridCell(at point: CGPoint) -> (row: Int, col: Int) {
        let col = max(0, min(cols - 1, Int(floor(point.x / cellWidth))))
        let row = max(0, min(rows - 1, Int(floor(point.y / cellHeight))))
        return (row, col)
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        // Single tap: become first responder (summons soft keyboard
        // via UIKeyInput) AND clear any open selection. Hides the
        // edit menu, matching iOS-system behaviour.
        _ = becomeFirstResponder()
        if selectionRange != nil {
            selectionRange = nil
            hideEditMenu()
            setNeedsDisplay()
        }
    }

    @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
        // Long press anchors the selection at the tap point, then a
        // follow-up pan extends `end`. We accept the `.began` state
        // as the anchor — the `.changed` updates flow through the
        // pan handler below.
        let point = recognizer.location(in: self)
        let cell = gridCell(at: point)
        switch recognizer.state {
        case .began:
            _ = becomeFirstResponder()
            selectionRange = TerminalSelectionRange(start: cell, end: cell)
            setNeedsDisplay()
            showEditMenu(at: point)
        case .changed:
            // Long-press-drag (without releasing) also extends. Treat
            // the same as pan.
            guard var range = selectionRange else { return }
            range.end = cell
            selectionRange = range
            setNeedsDisplay()
        case .ended, .cancelled, .failed:
            // Leave the selection in place so the floating Copy menu
            // stays reachable. A single tap clears it.
            if selectionRange != nil {
                showEditMenu(at: point)
            }
        default:
            break
        }
    }

    @objc private func handleSelectionPan(_ recognizer: UIPanGestureRecognizer) {
        guard selectionRange != nil else { return }
        let point = recognizer.location(in: self)
        let cell = gridCell(at: point)
        switch recognizer.state {
        case .began, .changed:
            guard var range = selectionRange else { return }
            range.end = cell
            selectionRange = range
            setNeedsDisplay()
        case .ended:
            if selectionRange != nil {
                showEditMenu(at: point)
            }
        default:
            break
        }
    }

    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        // Word-select. Walk the cell row from the tap point outward
        // until we hit a whitespace boundary. Uses the cached
        // snapshot; if there isn't one, falls through to a single
        // cell.
        let point = recognizer.location(in: self)
        let cell = gridCell(at: point)
        _ = becomeFirstResponder()
        guard let snap = cachedSnapshot,
              snap.rows > 0,
              snap.cols > 0,
              cell.row < snap.cells.count else {
            selectionRange = TerminalSelectionRange(start: cell, end: cell)
            setNeedsDisplay()
            return
        }
        let row = snap.cells[cell.row]
        let isWordChar: (String) -> Bool = { s in
            guard let scalar = s.unicodeScalars.first else { return false }
            // ASCII alphanumeric + underscore = "word". Same heuristic
            // most terminal emulators use for double-click select.
            return CharacterSet.alphanumerics.contains(scalar) || scalar == "_"
        }
        guard cell.col < row.count, isWordChar(row[cell.col]) else {
            selectionRange = TerminalSelectionRange(start: cell, end: cell)
            setNeedsDisplay()
            return
        }
        var lo = cell.col
        var hi = cell.col
        while lo > 0, isWordChar(row[lo - 1]) { lo -= 1 }
        while hi < row.count - 1, isWordChar(row[hi + 1]) { hi += 1 }
        selectionRange = TerminalSelectionRange(start: (cell.row, lo), end: (cell.row, hi))
        setNeedsDisplay()
        showEditMenu(at: point)
    }

    @objc private func handleTripleTap(_ recognizer: UITapGestureRecognizer) {
        // Line-select: full row at the tap point.
        let point = recognizer.location(in: self)
        let cell = gridCell(at: point)
        _ = becomeFirstResponder()
        let lastCol = max(0, (cachedSnapshot?.cols ?? cols) - 1)
        selectionRange = TerminalSelectionRange(
            start: (cell.row, 0),
            end: (cell.row, lastCol)
        )
        setNeedsDisplay()
        showEditMenu(at: point)
    }

    private func showEditMenu(at point: CGPoint) {
        // UIEditMenuInteraction is the iOS 16+ shape, but the simpler
        // UIMenuController API still works and matches what we'd want
        // pre-iOS-26 if we ever back-ported. The menu's `targetRect`
        // anchors at the tap point's row so it doesn't cover the
        // selection itself.
        let menu = UIMenuController.shared
        guard !menu.isMenuVisible else { return }
        let row = max(0, Int(floor(point.y / cellHeight)))
        let anchor = CGRect(
            x: point.x,
            y: CGFloat(row) * cellHeight,
            width: 1,
            height: cellHeight
        )
        menu.showMenu(from: self, rect: anchor)
    }

    private func hideEditMenu() {
        UIMenuController.shared.hideMenu()
    }

    // MARK: - Edit menu (copy / paste)

    /// Surface Copy when there is a selection and Paste when the
    /// pasteboard has a string. Everything else is dropped so the
    /// menu stays terminal-focused — no "Look Up" / "Translate"
    /// noise on a code cell.
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(copy(_:)) {
            return selectionRange != nil
        }
        if action == #selector(paste(_:)) {
            return UIPasteboard.general.hasStrings
        }
        return super.canPerformAction(action, withSender: sender)
    }

    /// Edit-menu integration on iOS 13+ requires the target to be the
    /// view itself rather than a parent controller for the menu to
    /// route copy/paste to our overrides below.
    override func target(forAction action: Selector, withSender sender: Any?) -> Any? {
        if action == #selector(copy(_:)) || action == #selector(paste(_:)) {
            return self
        }
        return super.target(forAction: action, withSender: sender)
    }

    override func copy(_ sender: Any?) {
        guard let range = selectionRange, let snap = cachedSnapshot else { return }
        let text = range.selectedText(from: snap)
        guard !text.isEmpty else { return }
        UIPasteboard.general.string = text
        // Leave the selection visible — iOS terminal apps (Ghostty
        // macOS, iSH, Blink) all keep the highlight after copy so the
        // user can verify what they got.
        hideEditMenu()
    }

    override func paste(_ sender: Any?) {
        guard let text = UIPasteboard.general.string, !text.isEmpty else { return }
        // Forward UTF-8 to the harness — same path as soft-keyboard
        // input (`insertText`). Bracketed paste is the harness's
        // responsibility; we just ship the bytes.
        var data = Data()
        for scalar in text.unicodeScalars {
            // Normalize newlines to CR — TUIs expect line submit as
            // CR, same as `insertText` does for Return.
            if scalar.value == 0x0A {
                data.append(0x0D)
            } else {
                data.append(contentsOf: String(scalar).utf8)
            }
        }
        if !data.isEmpty { onInput(data) }
        hideEditMenu()
    }

    // MARK: - Geometry

    override func layoutSubviews() {
        super.layoutSubviews()
        recomputeGridFromBounds()
        pushPixelSize()
    }

    /// Hand libghostty the *real* backing-store size every layout pass.
    /// `recomputeGridFromBounds` only fires when the cols/rows change,
    /// but libghostty's `CAMetalLayer` must track the exact view size
    /// (and Retina scale) or the surface stays 0×0 and paints nothing —
    /// the Stage-4 blank-screen bug.
    private func pushPixelSize() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        #if canImport(GhosttyVT)
        let scale = contentScaleFactor > 0 ? contentScaleFactor : UIScreen.main.scale
        terminal?.setPixelSize(
            width: UInt32(bounds.width * scale),
            height: UInt32(bounds.height * scale),
            scale: Double(scale)
        )
        #endif
    }

    // MARK: - libghostty render loop

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            #if canImport(GhosttyVT)
            terminal?.setVisible(true)
            terminal?.setFocus(true)
            #endif
            startDisplayLink()
        } else {
            #if canImport(GhosttyVT)
            terminal?.setVisible(false)
            terminal?.setFocus(false)
            #endif
            stopDisplayLink()
        }
    }

    private func startDisplayLink() {
        #if canImport(GhosttyVT)
        guard displayLink == nil, Terminal.isAvailable else { return }
        let link = CADisplayLink(target: self, selector: #selector(renderFrame))
        link.add(to: .main, forMode: .common)
        displayLink = link
        #endif
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func renderFrame() {
        #if canImport(GhosttyVT)
        terminal?.draw()
        #endif
    }

    deinit {
        displayLink?.invalidate()
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
        var styledOut: [[TerminalSnapshotShim.StyledCell]] = []
        rowsOut.reserveCapacity(Int(snap.rows))
        styledOut.reserveCapacity(Int(snap.rows))
        for r in 0..<Int(snap.rows) {
            let start = r * Int(snap.cols)
            let end = start + Int(snap.cols)
            let slice = snap.cells[start..<end]
            rowsOut.append(slice.map { $0.character })
            styledOut.append(slice.map { cell in
                TerminalSnapshotShim.StyledCell(
                    character: cell.character,
                    fg: SGRColorShim(cell.fg),
                    bg: SGRColorShim(cell.bg),
                    attrs: SGRAttributesShim(cell.attrs),
                    width: cell.width
                )
            })
        }
        cachedSnapshot = TerminalSnapshotShim(
            cols: Int(snap.cols),
            rows: Int(snap.rows),
            cells: rowsOut,
            cursorRow: Int(snap.cursorRow),
            cursorCol: Int(snap.cursorCol),
            styledCells: styledOut
        )
        #else
        cachedSnapshot = nil
        #endif
        setNeedsDisplay()
    }

    // MARK: - Drawing

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        // Resolve theme + font here so the draw pass reads the same
        // values the per-cell layout math already used in
        // `recomputeTypography`.
        let palette = resolvedPalette
        ctx.setFillColor(palette.defaultBackground.cgColor)
        ctx.fill(bounds)

        guard let snap = cachedSnapshot, snap.cols > 0, snap.rows > 0 else {
            // No snapshot yet (framework unavailable, or first frame
            // race). Draw a status line so the user isn't staring
            // at a black void if the SPM resolve degraded.
            drawStatus(in: ctx)
            return
        }

        // Stage 3 per-cell background fill. Loop the styled grid and
        // paint each non-default background as a single cell rect.
        // Wide cells (width == 2) extend the fill across two cell
        // widths; the continuation cell (width == 0) is skipped. The
        // reverse attribute swaps fg/bg before the fill so a reversed
        // `.default` row paints the default foreground as background.
        if let styled = snap.styledCells {
            for (r, row) in styled.enumerated() {
                var c = 0
                while c < row.count {
                    let cell = row[c]
                    if cell.width == 0 {
                        c += 1
                        continue
                    }
                    let spanWidth = max(1, cell.width)
                    let effectiveBg = cell.attrs.contains(.reverse) ? cell.fg : cell.bg
                    if effectiveBg != .default {
                        let bgColor = renderColor(effectiveBg, fg: false, palette: palette)
                        let rect = CGRect(
                            x: CGFloat(c) * cellWidth,
                            y: CGFloat(r) * cellHeight,
                            width: CGFloat(spanWidth) * cellWidth,
                            height: cellHeight
                        )
                        ctx.setFillColor(bgColor.cgColor)
                        ctx.fill(rect)
                    }
                    c += spanWidth
                }
            }
        }

        // Selection highlight — paint *after* per-cell background but
        // *before* glyphs so text stays readable. Walks the same
        // normalized rectangle the text extractor reads.
        if let selection = selectionRange {
            let (s, e) = selection.normalized
            let r0 = max(0, min(snap.rows - 1, s.row))
            let r1 = max(0, min(snap.rows - 1, e.row))
            let c0 = max(0, min(snap.cols - 1, s.col))
            let c1 = max(0, min(snap.cols - 1, e.col))
            let highlight = UIColor(SweKittyTheme.warning).withAlphaComponent(0.25).cgColor
            ctx.setFillColor(highlight)
            if r0 == r1 {
                let rect = CGRect(
                    x: CGFloat(c0) * cellWidth,
                    y: CGFloat(r0) * cellHeight,
                    width: CGFloat(c1 - c0 + 1) * cellWidth,
                    height: cellHeight
                )
                ctx.fill(rect)
            } else {
                // First row: c0..lastCol
                let first = CGRect(
                    x: CGFloat(c0) * cellWidth,
                    y: CGFloat(r0) * cellHeight,
                    width: CGFloat(snap.cols - c0) * cellWidth,
                    height: cellHeight
                )
                ctx.fill(first)
                if r1 - r0 > 1 {
                    let mid = CGRect(
                        x: 0,
                        y: CGFloat(r0 + 1) * cellHeight,
                        width: CGFloat(snap.cols) * cellWidth,
                        height: CGFloat(r1 - r0 - 1) * cellHeight
                    )
                    ctx.fill(mid)
                }
                // Last row: 0..c1
                let last = CGRect(
                    x: 0,
                    y: CGFloat(r1) * cellHeight,
                    width: CGFloat(c1 + 1) * cellWidth,
                    height: cellHeight
                )
                ctx.fill(last)
            }
        }

        // CoreText draws with the y-axis flipped (CG default); flip the
        // context once so we can iterate rows top-down with familiar
        // coordinates.
        ctx.saveGState()
        ctx.translateBy(x: 0, y: bounds.height)
        ctx.scaleBy(x: 1, y: -1)

        let regularFont = font
        let boldFont = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .bold)
        let italicDescriptor = regularFont.fontDescriptor.withSymbolicTraits(.traitItalic)
        let italicFont = italicDescriptor.flatMap { UIFont(descriptor: $0, size: fontSize) } ?? regularFont
        let boldItalicDescriptor = boldFont.fontDescriptor.withSymbolicTraits(.traitItalic)
        let boldItalicFont = boldItalicDescriptor.flatMap { UIFont(descriptor: $0, size: fontSize) } ?? boldFont

        // Per-cell glyph paint. We could batch contiguous same-style
        // runs into one `CFAttributedString`, but the snapshot is
        // small (cols * rows ≤ 200 * 100 in practice) and the
        // per-cell path keeps the code inspectable. Stage 3+ moves
        // to run-coalescing when render-state's dirty iterator lands.
        for r in 0..<snap.rows {
            let yFromBottom = bounds.height - CGFloat(r + 1) * cellHeight
            let baseline = yFromBottom + abs(font.descender)
            if let styled = snap.styledCells, r < styled.count {
                let row = styled[r]
                var c = 0
                while c < row.count {
                    let cell = row[c]
                    if cell.width == 0 {
                        c += 1
                        continue
                    }
                    let spanWidth = max(1, cell.width)
                    let glyph = cell.character.isEmpty ? " " : cell.character
                    let effectiveFg = cell.attrs.contains(.reverse) ? cell.bg : cell.fg
                    let fgColor = renderColor(effectiveFg, fg: true, palette: palette)
                    let pickFont: UIFont
                    switch (cell.attrs.contains(.bold), cell.attrs.contains(.italic)) {
                    case (true, true):   pickFont = boldItalicFont
                    case (true, false):  pickFont = boldFont
                    case (false, true):  pickFont = italicFont
                    case (false, false): pickFont = regularFont
                    }
                    var attrs: [NSAttributedString.Key: Any] = [
                        .font: pickFont,
                        .foregroundColor: fgColor,
                    ]
                    if cell.attrs.contains(.underline) {
                        attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
                    }
                    if cell.attrs.contains(.strikethrough) {
                        attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                    }
                    let attr = NSAttributedString(string: glyph, attributes: attrs)
                    ctx.textPosition = CGPoint(x: CGFloat(c) * cellWidth, y: baseline)
                    CTLineDraw(CTLineCreateWithAttributedString(attr), ctx)
                    c += spanWidth
                }
            } else {
                // Fallback: legacy grapheme-only row (no styled data).
                let line = snap.cells[r].map { $0.isEmpty ? " " : $0 }.joined()
                let attr = NSAttributedString(string: line, attributes: [
                    .font: regularFont,
                    .foregroundColor: palette.defaultForeground,
                ])
                ctx.textPosition = CGPoint(x: 0, y: baseline)
                CTLineDraw(CTLineCreateWithAttributedString(attr), ctx)
            }
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
        ctx.setStrokeColor(palette.defaultForeground.cgColor)
        ctx.setLineWidth(1.0)
        ctx.stroke(cursorRect)
    }

    private func drawStatus(in ctx: CGContext) {
        // Stage 4 (ghostty-bridge-app-surface-v3): the status banner
        // surfaces whether libghostty's App/Surface pipeline came up.
        // Before this PR the message was always "module unavailable"
        // because `Terminal.isAvailable` returned `false` (the
        // wrapper's `canImport(GhosttyVt)` gate evaluated false
        // against Lakr233's `libghostty` module name). Now the gate
        // is `canImport(libghostty)` inside the wrapper, so a
        // successful boot reads
        // "libghostty alive — GhosttyApp(0x…)" right on the empty
        // grid — proves libghostty actually loaded at runtime.
        // The CoreText renderer is still the fallback (the Metal
        // renderer lands in Stage 5); the user sees this banner as
        // an empty-grid status until then.
        let text: String
        #if canImport(GhosttyVT)
        text = Terminal.statusDescription()
        #else
        text = "GhosttyVT not linked — see PLAN-TERMINAL-REWRITE Stage 4"
        #endif
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: resolvedPalette.defaultForeground,
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
/// compiles regardless of whether the framework linked. Internal (not
/// private) so `TerminalSelectionRange.selectedText(from:)` can take it
/// as a parameter and the test target can build snapshots directly.
///
/// Stage 3 adds the parallel `styledCells` table — same outer/inner
/// indexing as `cells`, but each entry carries SGR fg/bg/attrs/width.
/// The legacy `cells` array stays so the selection / copy path (which
/// only reads graphemes) doesn't need to learn the richer shape.
struct TerminalSnapshotShim: Equatable {
    var cols: Int
    var rows: Int
    /// Outer = row index, inner = grapheme per cell.
    var cells: [[String]]
    var cursorRow: Int
    var cursorCol: Int
    /// Same shape as `cells` but each entry is a `TerminalCell`
    /// carrying SGR data. Optional in the data model so legacy test
    /// builders (which only fill the grapheme grid) keep compiling.
    /// The renderer falls back to `.default` everywhere when this is
    /// nil — same visual as Stage 2.
    var styledCells: [[StyledCell]]? = nil

    /// Pure-data SGR-bearing cell used by the renderer. Mirrors
    /// `GhosttyVT.TerminalCell` but keeps the renderer compiling
    /// when `GhosttyVT` is not importable (the placeholder build).
    struct StyledCell: Equatable {
        var character: String
        var fg: SGRColorShim
        var bg: SGRColorShim
        var attrs: SGRAttributesShim
        var width: Int
    }
}

/// File-level shadow of `GhosttyVT.SGRColor` so the renderer compiles
/// when the binary framework isn't linked. The conversion to / from
/// the GhosttyVT type lives behind `#if canImport(GhosttyVT)`.
enum SGRColorShim: Equatable {
    case `default`
    case ansi(index: UInt8, bright: Bool)
    case palette(index: UInt8)
    case rgb(r: UInt8, g: UInt8, b: UInt8)
}

struct SGRAttributesShim: OptionSet, Equatable {
    let rawValue: UInt16
    init(rawValue: UInt16) { self.rawValue = rawValue }
    static let bold          = SGRAttributesShim(rawValue: 1 << 0)
    static let dim           = SGRAttributesShim(rawValue: 1 << 1)
    static let italic        = SGRAttributesShim(rawValue: 1 << 2)
    static let underline     = SGRAttributesShim(rawValue: 1 << 3)
    static let blink         = SGRAttributesShim(rawValue: 1 << 4)
    static let reverse       = SGRAttributesShim(rawValue: 1 << 5)
    static let strikethrough = SGRAttributesShim(rawValue: 1 << 6)
}

#if canImport(GhosttyVT)
extension SGRColorShim {
    init(_ source: GhosttyVT.SGRColor) {
        switch source {
        case .default: self = .default
        case .ansi(let index, let bright): self = .ansi(index: index, bright: bright)
        case .palette(let index): self = .palette(index: index)
        case .rgb(let r, let g, let b): self = .rgb(r: r, g: g, b: b)
        }
    }
}

extension SGRAttributesShim {
    init(_ source: GhosttyVT.SGRAttributes) {
        self = SGRAttributesShim(rawValue: source.rawValue)
    }
}
#endif

/// Map a `SGRColorShim` to a `UIColor` via the renderer's palette.
/// Factored out so the renderer and the test target use the same
/// lookup. `fg` flips the meaning of `.default` (foreground vs
/// background) for the reverse-video swap.
func renderColor(_ color: SGRColorShim, fg: Bool, palette: TerminalPalette) -> UIColor {
    switch color {
    case .default:
        return fg ? palette.defaultForeground : palette.defaultBackground
    case .ansi(let index, let bright):
        let slot = Int(index) + (bright ? 8 : 0)
        let safe = max(0, min(palette.ansi.count - 1, slot))
        return palette.ansi[safe]
    case .palette(let index):
        return TerminalPalette.xterm256Color(at: index, palette: palette)
    case .rgb(let r, let g, let b):
        return UIColor(
            red: CGFloat(r) / 255.0,
            green: CGFloat(g) / 255.0,
            blue: CGFloat(b) / 255.0,
            alpha: 1.0
        )
    }
}

/// Pure-data Stage 3 selection rectangle. Two (row, col) anchors plus a
/// `selectedText(from:)` helper that walks a `TerminalSnapshotShim` and
/// returns the substring under the rectangle. Lifted out of the
/// `GhosttyRenderView` UIView so the substring path is unit-testable
/// without standing up a UIKit host — same shape as the Android
/// `TerminalSelectionRange` data class. See
/// `apps/ios/Tests/SweKittyTests/TerminalSelectionRangeTests.swift`.
///
/// The range is **inclusive on both ends** — `start` and `end` both
/// point at cells whose graphemes belong to the selection. A
/// single-cell selection is `start == end`. The view tracks anchors as
/// the user drags them, which means `end` may be "before" `start` in
/// reading order (the user dragged the long-press anchor backwards);
/// the helper normalizes that before reading cells. The view holds the
/// raw anchors so it can paint the same yellow highlight regardless of
/// drag direction.
struct TerminalSelectionRange: Equatable {
    /// Anchor where the long-press / double-tap / triple-tap landed.
    var start: (row: Int, col: Int)
    /// Anchor where the pan / drag last extended to.
    var end: (row: Int, col: Int)

    static func == (lhs: TerminalSelectionRange, rhs: TerminalSelectionRange) -> Bool {
        lhs.start == rhs.start && lhs.end == rhs.end
    }

    /// Returns `(start, end)` reordered so `start` is strictly the
    /// upper-left anchor in reading order (row asc, then col asc).
    /// Pure function so the view's draw path and the text extractor
    /// agree on the rectangle without copy-paste drift.
    var normalized: (start: (row: Int, col: Int), end: (row: Int, col: Int)) {
        let a = start
        let b = end
        if (a.row < b.row) || (a.row == b.row && a.col <= b.col) {
            return (a, b)
        }
        return (b, a)
    }

    /// Walk the snapshot's grid between the (normalized) anchors and
    /// build the selected substring. For multi-row selections, rows
    /// before the last carry a `"\n"` terminator and span from the
    /// first column on row 0 (which is the start.col) through the end
    /// of the row; intermediate rows span the full row width; the
    /// last row spans from col 0 through `end.col`.
    ///
    /// Empty / whitespace-only cells render their literal content (a
    /// single space for an empty grapheme), matching what a user sees
    /// on screen — copying a partially blank line preserves the
    /// visual width.
    func selectedText(from snapshot: TerminalSnapshotShim) -> String {
        guard snapshot.rows > 0, snapshot.cols > 0 else { return "" }
        let (s, e) = normalized
        // Clamp anchors to the snapshot's bounds so a stale selection
        // from a pre-resize geometry never reads out-of-bounds.
        let r0 = max(0, min(snapshot.rows - 1, s.row))
        let r1 = max(0, min(snapshot.rows - 1, e.row))
        let c0 = max(0, min(snapshot.cols - 1, s.col))
        let c1 = max(0, min(snapshot.cols - 1, e.col))

        // Single-row selection: pull cells [c0...c1] off row r0.
        if r0 == r1 {
            return cellsToString(snapshot.cells[r0], from: c0, through: c1)
        }
        var out = ""
        // First row: [c0..lastCol]
        out += cellsToString(snapshot.cells[r0], from: c0, through: snapshot.cols - 1)
        out += "\n"
        // Middle rows: [0..lastCol]
        if r1 - r0 > 1 {
            for r in (r0 + 1)..<r1 {
                out += cellsToString(snapshot.cells[r], from: 0, through: snapshot.cols - 1)
                out += "\n"
            }
        }
        // Last row: [0..c1]
        out += cellsToString(snapshot.cells[r1], from: 0, through: c1)
        return out
    }

    private func cellsToString(_ row: [String], from start: Int, through end: Int) -> String {
        guard !row.isEmpty else { return "" }
        let s = max(0, min(row.count - 1, start))
        let e = max(0, min(row.count - 1, end))
        guard s <= e else { return "" }
        // Empty cells render as a single space — same shape as the
        // renderer's draw path (which substitutes " " for empty
        // graphemes).
        return row[s...e].map { $0.isEmpty ? " " : $0 }.joined()
    }
}
