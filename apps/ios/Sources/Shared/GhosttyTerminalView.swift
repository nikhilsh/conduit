import SwiftUI
import UIKit
import QuartzCore
import GhosttyVT

// Native Ghostty (libghostty) terminal — Stage 2 of the clean-slate rebuild.
//
// The previous 1,836-line host crashed with a cascade of CoreAnimation-commit
// use-after-frees. This rewrite keeps ONLY the render lifecycle, faithfully
// following the geistty / clauntty discipline (see `docs/GHOSTTY-REFERENCES.md`):
//   * no `CAMetalLayer` layerClass override — libghostty parents its OWN
//     IOSurfaceLayer via the `@objc(addSublayer:)` message on our plain layer;
//   * that parenting + sizing is DEFERRED off the in-flight CoreAnimation commit
//     (the `apprt.surface.Mailbox.push` UAF the old code chased);
//   * the draw pump is a `CADisplayLink` held by a WEAK proxy (no link↔view
//     retain cycle), driving `ghostty_surface_draw` each vsync;
//   * teardown is EXPLICIT from `dismantleUIView` (a SwiftUI-safe point, not an
//     ARC `deinit` that can fire mid-commit): stop the link, detach every
//     sublayer, then free the surface one runloop turn later.
//
// Stage 2 renders a banner to prove the pipeline end-to-end. Real broker feed +
// resize is Stage 3; keyboard input is Stage 4; selection is Stage 5.

struct GhosttyTerminalTab: View {
    @Environment(SessionStore.self) private var store
    @Environment(AppearanceStore.self) private var appearance
    let session: ProjectSession
    let isActive: Bool

    var body: some View {
        GhosttyTerminalView(
            isActive: isActive,
            theme: appearance.terminalTheme,
            // Reading the observable buffer here establishes the SwiftUI
            // dependency: when the broker appends PTY bytes, the body
            // re-evaluates and `updateUIView` feeds the new tail.
            bufferProvider: { store.terminalBuffer[session.id] ?? Data() },
            bufferRevision: store.terminalBuffer[session.id]?.count ?? 0,
            // Keyboard / accessory-bar / surface-emitted bytes → remote PTY.
            onInput: { bytes in store.sendInput(sessionID: session.id, bytes: bytes) },
            // Resize authority: libghostty owns the grid; the host reads
            // `ghostty_surface_size` after every resize and drives the remote
            // PTY to the SAME cols/rows (else tmux misdraws). `resize` no-ops
            // safely until the session has a connected client.
            onResize: { rows, cols in
                store.resize(sessionID: session.id, rows: UInt16(rows), cols: UInt16(cols))
            }
        )
        .background(Color(
            red: appearance.terminalTheme.backgroundRGB.red,
            green: appearance.terminalTheme.backgroundRGB.green,
            blue: appearance.terminalTheme.backgroundRGB.blue))
        .ignoresSafeArea(.container, edges: .bottom)
    }
}

/// `UIViewRepresentable` host for `GhosttySurfaceView`. `bufferProvider` +
/// `bufferRevision` drive the byte diff (mirrors the old xterm.js contract);
/// `onResize` closes the grid loop back to `SessionStore`.
struct GhosttyTerminalView: UIViewRepresentable {
    let isActive: Bool
    let theme: GhosttyTheme
    let bufferProvider: () -> Data
    let bufferRevision: Int
    let onInput: (Data) -> Void
    let onResize: (_ rows: Int, _ cols: Int) -> Void

    func makeUIView(context: Context) -> GhosttySurfaceView {
        Telemetry.breadcrumb("terminal", "GhosttyTerminalView makeUIView")
        let view = GhosttySurfaceView(frame: .zero)
        view.onInput = onInput
        view.onResize = onResize
        view.configure(theme: theme)
        view.setActive(isActive)
        // Feed whatever the buffer already holds so a tab-switch-back reattach
        // doesn't show an empty grid.
        view.syncBuffer(bufferProvider())
        return view
    }

    func updateUIView(_ view: GhosttySurfaceView, context: Context) {
        view.onInput = onInput
        view.onResize = onResize
        view.setTheme(theme)
        view.setActive(isActive)
        view.syncBuffer(bufferProvider())
    }

    static func dismantleUIView(_ view: GhosttySurfaceView, coordinator: ()) {
        Telemetry.breadcrumb("terminal", "GhosttyTerminalView dismantle")
        view.prepareForRemoval()
    }
}

/// Pure tail-diff logic for the terminal byte stream — extracted so it's
/// unit-testable without a UIView. The broker buffer only ever grows (append)
/// or is wholesale-replaced by a snapshot (shrink / reset).
enum TerminalFeedDiff: Equatable {
    case none
    case feed(Range<Int>)
    case reset

    static func diff(lastFed: Int, bufferCount: Int) -> TerminalFeedDiff {
        if bufferCount > lastFed { return .feed(lastFed..<bufferCount) }
        if bufferCount < lastFed { return .reset }
        return .none
    }
}

/// Pure keyboard → PTY byte mapping, extracted so it's unit-testable without a
/// UIView. These bytes go straight to the remote PTY (libghostty is render-only
/// for user input — see the rebuild plan's input-model decision).
enum TerminalInputBytes {
    /// Soft-keyboard text. TUIs submit on CR (0x0D); iOS hands us LF (0x0A) from
    /// Return — translate. Everything else passes through as UTF-8.
    static func text(_ s: String) -> Data {
        var data = Data()
        for scalar in s.unicodeScalars {
            if scalar.value == 0x0A {
                data.append(0x0D)
            } else {
                data.append(contentsOf: String(scalar).utf8)
            }
        }
        return data
    }

    static let backspace = Data([0x7F])      // DEL
    static let escape = Data([0x1B])         // ESC
    static let tab = Data([0x09])            // HT
    static let arrowUp = Data([0x1B, 0x5B, 0x41])    // ESC [ A
    static let arrowDown = Data([0x1B, 0x5B, 0x42])  // ESC [ B
    static let arrowLeft = Data([0x1B, 0x5B, 0x44])  // ESC [ D
    static let arrowRight = Data([0x1B, 0x5B, 0x43]) // ESC [ C

    /// Paste payload wrapped in bracketed-paste markers (ESC[200~ … ESC[201~) so
    /// the receiving app treats it as literal input (no vim/emacs auto-indent).
    static func bracketedPaste(_ s: String) -> Data {
        var data = Data("\u{1B}[200~".utf8)
        data.append(text(s))
        data.append(contentsOf: "\u{1B}[201~".utf8)
        return data
    }
}

/// UIView host for one libghostty surface. Plain `CALayer` backing — libghostty
/// attaches its IOSurfaceLayer as a sublayer.
final class GhosttySurfaceView: UIView, UIKeyInput, UIEditMenuInteractionDelegate {
    private var surface: GhosttySurface?
    /// The IOSurfaceLayer libghostty parented on us (held strongly via the
    /// superlayer relationship; this is a tracking reference).
    private var ghosttySublayer: CALayer?
    private var frameDisplayLink: CADisplayLink?
    private var frameDisplayLinkProxy: FrameDisplayLinkProxy?
    private var isActive = false
    private var isAppBackgrounded = false

    /// How much of our bottom is covered by the soft keyboard (incl. its accessory
    /// bar), in points. The libghostty grid is sized to `bounds.height - this` so
    /// the prompt stays visible above the keyboard instead of hiding behind it.
    private var keyboardOverlap: CGFloat = 0
    /// Running translation for the scroll pan.
    private var scrollPanLastY: CGFloat = 0
    /// Downward finger travel (points) that dismisses the keyboard mid-pan — the
    /// iOS scroll-to-dismiss idiom.
    private static let dismissDragThreshold: CGFloat = 36
    /// Extra breathing room below the last row, on top of the home-indicator inset.
    private static let bottomPadding: CGFloat = 8

    /// Long-press selection: where it began, and whether it has turned into a
    /// drag (which switches from word-select to a char-precise multi-line drag).
    private var longPressStart: CGPoint = .zero
    private var longPressDragging = false

    /// A dark terminal keyboard (the translucent keyboard otherwise samples the
    /// black surface behind the lifted grid and reads as pure black).
    var keyboardAppearance: UIKeyboardAppearance = .dark

    /// Current terminal theme — drives the surface palette and the host view's
    /// background color (so the keyboard-revealed band + any sliver around the
    /// grid match the terminal rather than being pure black).
    private var currentTheme: GhosttyTheme = .ghosttyDark

    private func themeBackgroundColor() -> UIColor {
        let c = currentTheme.backgroundRGB
        return UIColor(red: CGFloat(c.red), green: CGFloat(c.green), blue: CGFloat(c.blue), alpha: 1)
    }

    private func applyThemeBackground() {
        let color = themeBackgroundColor()
        backgroundColor = color
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.backgroundColor = color.cgColor
        CATransaction.commit()
    }

    /// Tail-diff cursor: how many bytes of the broker buffer we've fed so far.
    private var lastFedByteCount = 0
    /// Last grid reported to the broker, so `onResize` only fires on a change.
    private var lastGrid: (cols: UInt16, rows: UInt16)?
    /// Drives the remote PTY to libghostty's own grid (set by the representable).
    var onResize: ((_ rows: Int, _ cols: Int) -> Void)?

    /// Keyboard / accessory-bar / surface-emitted bytes → remote PTY (set by the
    /// representable). Surface-generated bytes arrive via the surface's
    /// `onReceiveInput` (already query-response-filtered) and are forwarded here.
    var onInput: (Data) -> Void = { _ in }

    /// Held strong so `inputAccessoryView` never returns a dangling reference.
    private lazy var accessoryBar: TerminalAccessoryBar = {
        let bar = TerminalAccessoryBar()
        bar.onSend = { [weak self] bytes in self?.onInput(bytes) }
        bar.onDismiss = { [weak self] in _ = self?.resignFirstResponder() }
        return bar
    }()

    private lazy var editMenuInteraction = UIEditMenuInteraction(delegate: self)

    /// Weak indirection so the `CADisplayLink` (retained by the main runloop)
    /// does not retain the view.
    private final class FrameDisplayLinkProxy {
        weak var view: GhosttySurfaceView?
        init(_ view: GhosttySurfaceView) { self.view = view }
        @objc func tick(_ link: CADisplayLink) {
            guard let view = view else { link.invalidate(); return }
            view.surface?.draw()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = themeBackgroundColor()
        isOpaque = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidBackground),
            name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(appWillForeground),
            name: UIApplication.willEnterForegroundNotification, object: nil)
        // Lift the grid above the keyboard so the prompt stays visible.
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardFrameWillChange(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardWillHide(_:)),
            name: UIResponder.keyboardWillHideNotification, object: nil)
        // Tap to focus → show the soft keyboard + give libghostty key focus.
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        addGestureRecognizer(tap)
        // Long-press → drag to select text (forwarded to libghostty as mouse
        // events); release presents the copy/paste menu.
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        addGestureRecognizer(longPress)
        // One-finger pan → scroll libghostty's scrollback (or, while the keyboard
        // is up, drag-down dismisses it). Waits for the long-press to fail so a
        // press-and-hold selects instead of scrolling.
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.require(toFail: longPress)
        addGestureRecognizer(pan)
        addInteraction(editMenuInteraction)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Create the surface with this view pinned as libghostty's host. The
    /// representable hands us a `.zero` frame, so seed a non-zero pixel size;
    /// `layoutSubviews` pushes the real bounds once we're laid out.
    func configure(theme: GhosttyTheme) {
        currentTheme = theme
        applyThemeBackground()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contentsScale = traitCollection.displayScale
        CATransaction.commit()

        let scale = Double(contentScaleFactor > 0 ? contentScaleFactor : traitCollection.displayScale)
        let (pw, ph) = pixelSize(scale: scale)
        surface = GhosttySurface(hostView: self, pixelWidth: pw, pixelHeight: ph, scaleFactor: scale, theme: theme)
        surface?.onReceiveInput = { [weak self] bytes in self?.onInput(bytes) }
        Telemetry.breadcrumb("terminal", "GhosttySurface attached", data: ["px": "\(pw)x\(ph)"])
    }

    /// Live theme change from the representable (Settings picker).
    func setTheme(_ theme: GhosttyTheme) {
        guard theme != currentTheme else { return }
        currentTheme = theme
        surface?.setTheme(theme)
        applyThemeBackground()
    }

    /// Feed the broker buffer to libghostty by tail diff. The buffer grows on
    /// streaming output (feed the new tail) or is wholesale-replaced by a
    /// snapshot on reconnect (shrink → rebuild the surface and re-feed).
    func syncBuffer(_ full: Data) {
        switch TerminalFeedDiff.diff(lastFed: lastFedByteCount, bufferCount: full.count) {
        case .none:
            break
        case .feed(let range):
            surface?.feed(full.subdata(in: range))
            lastFedByteCount = full.count
        case .reset:
            rebuildSurface()
            surface?.feed(full)
            lastFedByteCount = full.count
        }
    }

    /// Snapshot replacement (buffer shrank): our ABI has no surface `reset`, so
    /// tear the surface down and build a fresh one on the same host view. The
    /// teardown defers the free a runloop turn (CA-commit safety); the new
    /// surface's IOSurfaceLayer re-parents via `addSublayer` as usual.
    private func rebuildSurface() {
        if let s = surface {
            surface = nil
            ghosttySublayer = nil
            layer.sublayers?.forEach { $0.removeFromSuperlayer() }
            DispatchQueue.main.async { s.teardown() }
        }
        let scale = Double(contentScaleFactor > 0 ? contentScaleFactor : traitCollection.displayScale)
        let (pw, ph) = pixelSize(scale: scale)
        surface = GhosttySurface(hostView: self, pixelWidth: pw, pixelHeight: ph, scaleFactor: scale, theme: currentTheme)
        surface?.onReceiveInput = { [weak self] bytes in self?.onInput(bytes) }
        lastFedByteCount = 0
        lastGrid = nil
    }

    private func pixelSize(scale: Double) -> (UInt32, UInt32) {
        // geistty seeds 800×600 to avoid a 0×0 surface before first layout.
        let w = bounds.width > 0 ? bounds.width : 800
        let h = bounds.height > 0 ? bounds.height : 600
        return (UInt32(w * CGFloat(scale)), UInt32(h * CGFloat(scale)))
    }

    // MARK: - Layer parenting

    /// libghostty's iOS renderer builds its own IOSurfaceLayer and parents it by
    /// sending `addSublayer:` to the `uiview` pointer. `UIView` doesn't implement
    /// that selector, so without this hook the layer is never parented (the
    /// failure clauntty + geistty both guard against).
    @objc(addSublayer:)
    func addSublayer(_ sublayer: CALayer) {
        Telemetry.breadcrumb("terminal", "addSublayer (libghostty IOSurfaceLayer)")
        if let old = ghosttySublayer, old !== sublayer { old.removeFromSuperlayer() }
        ghosttySublayer = sublayer
        // Defer BOTH parenting AND sizing off the in-flight CA commit:
        // `addSublayer:` fires synchronously from inside `ghostty_surface_new`
        // while the surface is still half-built. Putting the IOSurfaceLayer into
        // the live tree mid-construction drives the mount commit into the
        // surface's mailbox (`apprt.surface.Mailbox.push`) → EXC_BAD_ACCESS. One
        // runloop turn lets `ghostty_surface_new` return first.
        DispatchQueue.main.async { [weak self] in
            guard let self, let sub = self.ghosttySublayer, sub === sublayer else { return }
            self.layer.addSublayer(sub)
            self.sizeLayer()
        }
    }

    /// Keep libghostty's render target sized to our bounds at the backing scale,
    /// and push the pixel size into the surface (libghostty attaches the layer at
    /// a zero frame and paints nothing until sized).
    private func sizeLayer() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let scale = contentScaleFactor > 0 ? contentScaleFactor : traitCollection.displayScale
        // Reserve the keyboard overlap (when up) or the bottom safe-area inset +
        // a little breathing room (when down) so the last row clears the home
        // indicator instead of sitting flush against the bottom edge. The
        // reserved band shows the terminal background, so it reads as padding.
        let safeBottom = max(safeAreaInsets.bottom, window?.safeAreaInsets.bottom ?? 0)
        let bottomReserve = max(keyboardOverlap, safeBottom + Self.bottomPadding)
        let effectiveHeight = max(1, bounds.height - bottomReserve)
        let rect = CGRect(x: 0, y: 0, width: bounds.width, height: effectiveHeight)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let sub = ghosttySublayer {
            sub.frame = rect
            sub.contentsScale = scale
        }
        // Belt-and-suspenders: size any layer libghostty parented directly on our
        // root layer (it can attach via `[[uiview layer] addSublayer:]`).
        if let subs = layer.sublayers {
            for s in subs where s !== ghosttySublayer {
                s.frame = rect
                s.contentsScale = scale
            }
        }
        CATransaction.commit()
        surface?.resize(
            pixelWidth: UInt32(bounds.width * scale),
            pixelHeight: UInt32(effectiveHeight * scale),
            scale: Double(scale))
        syncGridToBroker()
    }

    /// Read libghostty's own derived grid and drive the remote PTY to it, only
    /// when it changed. libghostty owns the grid (it re-derives cols/rows from
    /// the pixel size + its font metrics); pushing a client-side estimate would
    /// fight it and make tmux misdraw.
    private func syncGridToBroker() {
        guard let grid = surface?.gridSize() else { return }
        if lastGrid?.cols != grid.cols || lastGrid?.rows != grid.rows {
            lastGrid = (grid.cols, grid.rows)
            onResize?(Int(grid.rows), Int(grid.cols))
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        sizeLayer()
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        sizeLayer()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            sizeLayer()
            // Wake recipe (deferred off the mount commit): toggle focus + refresh
            // so the surface repaints rather than showing stale/blank pixels.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.surface?.setFocus(false)
                self.surface?.setFocus(true)
                self.surface?.refresh()
            }
        }
        updateDisplayLinkRunning()
    }

    // MARK: - Visibility / draw pump

    /// Tab visibility, pushed from the representable. The view stays MOUNTED
    /// across tab switches (so the surface is never torn down + recreated
    /// mid-use); this stands the renderer down/up.
    func setActive(_ active: Bool) {
        isActive = active
        let visible = isActive && window != nil && !isAppBackgrounded
        surface?.setOcclusion(visible)
        if visible {
            surface?.setFocus(false)
            surface?.setFocus(true)
            surface?.refresh()
        } else {
            // Resign the UIKit first responder (not just libghostty focus) so the
            // soft keyboard doesn't linger over another tab's content after a
            // Terminal→Chat switch.
            _ = resignFirstResponder()
        }
        updateDisplayLinkRunning()
    }

    @objc private func appDidBackground() {
        isAppBackgrounded = true
        updateDisplayLinkRunning()
    }

    @objc private func appWillForeground() {
        isAppBackgrounded = false
        updateDisplayLinkRunning()
    }

    /// Run the draw pump only while the surface is actually visible.
    private func updateDisplayLinkRunning() {
        let shouldRun = window != nil && !isAppBackgrounded && isActive
        if shouldRun { startDisplayLink() } else { stopDisplayLink() }
    }

    private func startDisplayLink() {
        guard frameDisplayLink == nil else { return }
        let proxy = FrameDisplayLinkProxy(self)
        frameDisplayLinkProxy = proxy
        let link = CADisplayLink(target: proxy, selector: #selector(FrameDisplayLinkProxy.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        frameDisplayLink = link
    }

    private func stopDisplayLink() {
        frameDisplayLink?.invalidate()
        frameDisplayLink = nil
        frameDisplayLinkProxy = nil
    }

    // MARK: - Input (keyboard + accessory bar)

    /// `UIKeyInput` needs the view to be first responder for hardware key events
    /// to fire and the soft keyboard to appear.
    override var canBecomeFirstResponder: Bool { true }

    override var inputAccessoryView: UIView? { accessoryBar }

    @objc private func handleTap() {
        _ = becomeFirstResponder()
    }

    @discardableResult
    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { surface?.setFocus(true) }
        return became
    }

    @discardableResult
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { surface?.setFocus(false) }
        return resigned
    }

    var hasText: Bool { false }

    func insertText(_ text: String) {
        let data = TerminalInputBytes.text(text)
        if !data.isEmpty { onInput(data) }
    }

    func deleteBackward() {
        onInput(TerminalInputBytes.backspace)
    }

    /// Hardware-keyboard arrows / Esc / Tab → escape sequences on the PTY,
    /// captured before iOS' own UIKeyCommand resolution navigates SwiftUI.
    override var keyCommands: [UIKeyCommand]? {
        let mods: UIKeyModifierFlags = []
        return [
            UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: mods, action: #selector(handleArrow(_:))),
            UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: mods, action: #selector(handleArrow(_:))),
            UIKeyCommand(input: UIKeyCommand.inputLeftArrow, modifierFlags: mods, action: #selector(handleArrow(_:))),
            UIKeyCommand(input: UIKeyCommand.inputRightArrow, modifierFlags: mods, action: #selector(handleArrow(_:))),
            UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: mods, action: #selector(handleEsc)),
            UIKeyCommand(input: "\t", modifierFlags: mods, action: #selector(handleTab)),
        ]
    }

    @objc private func handleArrow(_ cmd: UIKeyCommand) {
        switch cmd.input {
        case UIKeyCommand.inputUpArrow:    onInput(TerminalInputBytes.arrowUp)
        case UIKeyCommand.inputDownArrow:  onInput(TerminalInputBytes.arrowDown)
        case UIKeyCommand.inputLeftArrow:  onInput(TerminalInputBytes.arrowLeft)
        case UIKeyCommand.inputRightArrow: onInput(TerminalInputBytes.arrowRight)
        default: break
        }
    }

    @objc private func handleEsc() { onInput(TerminalInputBytes.escape) }
    @objc private func handleTab() { onInput(TerminalInputBytes.tab) }

    // MARK: - Selection / copy / paste

    /// Selection. A stationary long-press selects the WORD under the finger
    /// (libghostty double-click). If the finger then drags, it becomes a
    /// char-precise drag-selection from the press point to the finger — which
    /// extends across lines (multi-line). Release presents the copy/paste menu
    /// (also reachable for Paste with no selection).
    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        let p = gesture.location(in: self)
        switch gesture.state {
        case .began:
            longPressStart = p
            longPressDragging = false
            surface?.selectWord(x: Double(p.x), y: Double(p.y))
        case .changed:
            let moved = hypot(p.x - longPressStart.x, p.y - longPressStart.y)
            guard moved > 10 else { return }
            if !longPressDragging {
                // Switch to a held-button drag from the original press point so
                // the selection grows char-by-char (and across lines) as the
                // finger moves — `selectWord` left the button up.
                longPressDragging = true
                surface?.selectionBegin(x: Double(longPressStart.x), y: Double(longPressStart.y))
            }
            surface?.selectionExtend(x: Double(p.x), y: Double(p.y))
        case .ended, .cancelled, .failed:
            if longPressDragging {
                surface?.selectionEnd(x: Double(p.x), y: Double(p.y))
            }
            let selected = surface?.hasSelection ?? false
            Telemetry.breadcrumb("terminal", "long-press selection",
                                 data: ["hasSelection": "\(selected)", "dragged": "\(longPressDragging)"])
            presentEditMenu(at: p)
        default:
            break
        }
    }

    private func presentEditMenu(at point: CGPoint) {
        let config = UIEditMenuConfiguration(identifier: nil, sourcePoint: point)
        editMenuInteraction.presentEditMenu(with: config)
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        switch action {
        case #selector(copy(_:)):
            return surface?.hasSelection == true
        case #selector(paste(_:)):
            return UIPasteboard.general.hasStrings
        default:
            return super.canPerformAction(action, withSender: sender)
        }
    }

    override func copy(_ sender: Any?) {
        guard let text = surface?.readSelection(), !text.isEmpty else { return }
        UIPasteboard.general.string = text
    }

    override func paste(_ sender: Any?) {
        guard let text = UIPasteboard.general.string else { return }
        onInput(TerminalInputBytes.bracketedPaste(text))
    }

    /// Return nil so UIKit builds the menu from the suggested system actions
    /// (filtered by `canPerformAction`). Returning a custom menu here is what
    /// triggered the old `-[__NSCFNumber bounds]` crash.
    func editMenuInteraction(
        _ interaction: UIEditMenuInteraction,
        menuFor configuration: UIEditMenuConfiguration,
        suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        nil
    }

    // MARK: - Scroll + keyboard avoidance

    /// One-finger pan → scroll libghostty's scrollback; while the keyboard is up,
    /// a downward drag past the threshold dismisses it first.
    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            scrollPanLastY = 0
        case .changed:
            let ty = gesture.translation(in: self).y
            let delta = ty - scrollPanLastY
            scrollPanLastY = ty
            guard delta != 0 else { return }
            if isFirstResponder, ty > Self.dismissDragThreshold {
                _ = resignFirstResponder()
                return
            }
            // Points → pixels via the backing scale; a finger dragging DOWN reveals
            // older history (positive delta, no negation).
            let scale = contentScaleFactor > 0 ? contentScaleFactor : traitCollection.displayScale
            surface?.scroll(deltaY: Double(delta) * Double(scale))
        default:
            break
        }
    }

    /// Keyboard shown / moved → lift the grid so the prompt clears it.
    @objc private func keyboardFrameWillChange(_ note: Notification) {
        // Only the visible terminal lifts — otherwise the Chat tab's keyboard
        // would needlessly resize this (hidden) terminal's remote PTY.
        guard isActive,
              let end = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue,
              let window else { return }
        // Keyboard frame is in screen coords; convert into our space and measure
        // how much it covers our bottom (this includes the accessory bar).
        let inWindow = window.convert(end, from: nil)
        let inView = convert(inWindow, from: window)
        let overlap = max(0, bounds.maxY - inView.minY)
        guard abs(overlap - keyboardOverlap) > 0.5 else { return }
        keyboardOverlap = overlap
        sizeLayer()
    }

    @objc private func keyboardWillHide(_ note: Notification) {
        guard keyboardOverlap != 0 else { return }
        keyboardOverlap = 0
        sizeLayer()
    }

    // MARK: - Teardown

    /// Deterministic teardown from `dismantleUIView` (SwiftUI removal — a
    /// known-safe point, not inside a CA commit). Order matters so we never rely
    /// on ARC release ordering between the CADisplayLink, the IOSurfaceLayer(s),
    /// and the surface (the `apprt.surface.Mailbox.push` UAF). Idempotent.
    func prepareForRemoval() {
        stopDisplayLink()
        // Detach EVERY layer libghostty parented — any stray one left attached
        // would be committed by the next CATransaction flush INTO the surface
        // we're about to free.
        ghosttySublayer = nil
        layer.sublayers?.forEach { $0.removeFromSuperlayer() }
        // Free the surface on the NEXT runloop turn, never synchronously: this
        // can run inside a CoreAnimation commit, and freeing mid-commit is the
        // exact UAF. Layers are already detached, so a turn later is safe.
        if let s = surface {
            surface = nil
            DispatchQueue.main.async { s.teardown() }
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        prepareForRemoval()
    }
}
