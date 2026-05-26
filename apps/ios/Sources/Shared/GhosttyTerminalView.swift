import SwiftUI
import UIKit
import QuartzCore

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
            ghosttyFontSize: appearance.ghosttyFontSize,
            ghosttyTheme: appearance.ghosttyTerminalTheme,
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
    /// Native-terminal font size from `AppearanceStore`. Drives
    /// libghostty's `font-size` config key. A change re-applies the
    /// config to the live surface and re-syncs the broker PTY grid (a
    /// font-size change shifts libghostty's cell px → grid).
    let ghosttyFontSize: Double
    /// Native-terminal color theme from `AppearanceStore`. Drives
    /// libghostty's foreground/background/cursor/palette config keys.
    let ghosttyTheme: AppearanceStore.GhosttyTerminalTheme
    let onInput: (Data) -> Void
    let onResize: (Int, Int) -> Void

    func makeUIView(context: Context) -> GhosttyRenderView {
        let view = GhosttyRenderView(frame: .zero)
        view.onInput = onInput
        view.onResize = onResize
        // Seed the libghostty font size + theme BEFORE the surface is
        // built so the first frame paints at the right size/palette.
        view.configureGhosttyAppearance(fontSize: ghosttyFontSize, theme: ghosttyTheme)
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
        // Same for the libghostty font size + theme — `configureGhosttyAppearance`
        // is a no-op when nothing changed; otherwise it rebuilds the
        // surface config and re-syncs the PTY grid.
        view.configureGhosttyAppearance(fontSize: ghosttyFontSize, theme: ghosttyTheme)
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

    /// libghostty font size + color theme chosen by the user
    /// (`AppearanceStore.ghosttyFontSize` / `.ghosttyTerminalTheme`).
    /// These drive libghostty's OWN renderer (config keys `font-size`,
    /// `foreground`, `background`, `cursor-color`, `palette`) — distinct
    /// from `fontSize`/`fontFamily` above, which fed the old CoreText
    /// fallback path. Seeded before the surface is created so the first
    /// frame is correct; updated live via `configureGhosttyAppearance`.
    private var ghosttyFontSize: Double = AppearanceStore.defaultGhosttyFontSize
    private var ghosttyTheme: AppearanceStore.GhosttyTerminalTheme = .ghosttyDark

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
    /// `feed(_:)` call lands. No longer painted (libghostty's metal
    /// renderer owns the pixels); retained only so the selection / copy
    /// path can extract text. Internal so unit tests can verify the
    /// snapshot↔selection coupling without re-implementing it.
    var cachedSnapshot: TerminalSnapshotShim?

    /// Stage 3 selection state. `nil` when nothing is selected; set by
    /// the long-press / double-tap / triple-tap recognisers and
    /// extended by the pan recogniser. Cleared by a single tap or by
    /// `copy(_:)` after the text has been copied. Internal so unit
    /// tests can assert on the state machine without exercising
    /// UIGestureRecognizer.
    var selectionRange: TerminalSelectionRange?

    /// Whether the in-flight one-finger pan is scrolling scrollback (vs
    /// extending a selection). Decided at the pan's `.began` from whether a
    /// selection was already anchored; latched for the gesture's lifetime
    /// so a mid-drag selection clear can't flip it into selection mode.
    private var panIsScrolling = false

    /// Accumulated pan translation (points) consumed by the scroll handler,
    /// so each `.changed` callback feeds libghostty only the INCREMENTAL
    /// delta since the last callback.
    private var scrollPanLastY: CGFloat = 0

    /// Points-of-finger-travel → pixel-precise scroll-delta multiplier.
    /// 1.0 = content-following (the surface scrolls with the finger), the
    /// natural iOS feel; libghostty divides the pixel delta by its cell
    /// height to land on rows. Tunable if device testing wants it
    /// faster/slower.
    private static let scrollSensitivity: Double = 1.0

    #if canImport(GhosttyVT)
    private var terminal: Terminal?

    #endif

    /// IMPORTANT: we deliberately do NOT override `layerClass`. The host
    /// view must be backed by a plain `CALayer`. Both working references
    /// confirm this:
    ///   * clauntty (`TerminalSurfaceView`): *"We do NOT override
    ///     layerClass to CAMetalLayer because Ghostty adds its own
    ///     IOSurfaceLayer as a sublayer. Using default CALayer."*
    ///   * geistty (`SurfaceView`): no `layerClass` override at all — its
    ///     `metalLayer` accessor is dead code; every real use is a
    ///     `layer as? CAMetalLayer` that simply no-ops on the plain layer,
    ///     and its resize path iterates `layer.sublayers` to size the
    ///     IOSurfaceLayer libghostty parents there.
    ///
    /// The prior `CAMetalLayer` `layerClass` (PR #205) was the bug behind
    /// the blank screen: libghostty's iOS renderer builds its OWN
    /// `IOSurfaceLayer` (a Metal-backed layer, verified via the pinned
    /// binary's `IOSurfaceLayer` / `CAIOSurfaceLayer` symbols) and attaches
    /// it to the host view via the `addSublayer:` selector (the view-level
    /// `@objc(addSublayer:)` hook below intercepts it and re-parents it onto
    /// our layer). It never renders into a host-supplied `CAMetalLayer`. A
    /// `CAMetalLayer`-backed host view violated that assumption, so the
    /// renderer never attached its layer (`addSublayer:0`, `render:0` on the
    /// device readout) and nothing painted.

    /// libghostty's render layer: the `IOSurfaceLayer` its Metal renderer
    /// builds and hands us through `addSublayer(_:)`. We hold the ref so
    /// `sizeGhosttyLayer()` can keep its frame + `contentsScale` synced to
    /// our bounds (libghostty attaches it at a zero frame, so it paints
    /// nothing until we size it). nil until libghostty attaches one.
    private var ghosttySublayer: CALayer?

    /// On-screen diagnostic overlay (top-left, tiny mono text). Surfaces
    /// the live `GhosttyDiagnostics` state — init result, app/surface
    /// handles (nil vs ptr), addSublayer-hook count, draw-tick count,
    /// wakeup/action counts, bounds, fed bytes — so a device tester can
    /// read off exactly where the libghostty pipeline stalls even if the
    /// surface is still visually blank. Behind `experimentalNativeTerminal`
    /// (this whole view only mounts on the flag-on path), so default
    /// users never see it. A `CADisplayLink`-driven label refresh keeps
    /// it live. Set `showDiagnosticOverlay = false` to compile it out of
    /// the layout entirely (kept on by default while we chase the blank
    /// screen).
    static var showDiagnosticOverlay = true
    private lazy var diagnosticLabel: UILabel = {
        let label = UILabel()
        label.numberOfLines = 0
        label.font = UIFont.monospacedSystemFont(ofSize: 9, weight: .regular)
        label.textColor = UIColor.green
        label.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        label.layer.zPosition = 10_000  // above libghostty's sublayer
        label.isUserInteractionEnabled = false
        label.lineBreakMode = .byClipping
        return label
    }()

    /// Frame pacing. A `CADisplayLink` drives `Terminal.draw()` (→
    /// `ghostty_surface_draw`) once per frame while the view is on a
    /// window. geistty pumps the renderer the same way (its
    /// `FrameDisplayLinkProxy` → `ghostty_surface_draw_now`); our pinned
    /// 1.1.5 lib exposes `ghostty_surface_draw`, not `draw_now`, so we
    /// call that. Started in `didMoveToWindow`, stopped when we leave the
    /// window. The proxy is a weak indirection because `CADisplayLink`
    /// strongly retains its target — pointing it at `self` directly would
    /// leak the view (self → link → self).
    private var frameDisplayLink: CADisplayLink?
    private var frameDisplayLinkProxy: FrameDisplayLinkProxy?

    /// Weak-target indirection for `frameDisplayLink`. Mirrors geistty's
    /// `FrameDisplayLinkProxy`: the link retains this proxy, the proxy
    /// holds the view weakly, so the view can deallocate and the proxy's
    /// tick self-invalidates the link.
    private final class FrameDisplayLinkProxy {
        weak var view: GhosttyRenderView?
        init(_ view: GhosttyRenderView) { self.view = view }
        @objc func tick(_ link: CADisplayLink) {
            guard let view = view else {
                link.invalidate()
                return
            }
            #if canImport(GhosttyVT)
            view.terminal?.draw()
            // libghostty recomputes its grid on its own tick, so the grid
            // read immediately after `set_size` in `sizeGhosttyLayer` can
            // lag one frame. Re-poll here (cheap; only fires `onResize` when
            // the grid actually changes) so the broker PTY converges to
            // libghostty's settled grid even when layout fired before the
            // recompute landed.
            view.syncPtyToGhosttyGrid()
            #endif
            view.refreshDiagnosticOverlay()
        }
    }

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

    /// Apply the user's libghostty font size + color theme. Called from
    /// the representable before the surface is built (seed) and on every
    /// update (live re-apply). No-op when nothing changed.
    ///
    /// On a real change we push a fresh config to the live surface
    /// (`Terminal.applyConfig` → `ghostty_surface_update_config`). Because
    /// a font-size change shifts libghostty's cell pixel dimensions — and
    /// therefore the grid (cols/rows) for our fixed bounds — we then
    /// re-push the pixel size and re-read `ghostty_surface_size` so the
    /// broker PTY converges to libghostty's NEW grid. Treating a font-size
    /// change like a bounds change is mandatory (see Terminal.swift /
    /// PLAN-TERMINAL-REWRITE): otherwise the broker PTY grid and
    /// libghostty's render grid disagree (oversized/duplicated tmux bars,
    /// gaps, stray echo). `sizeGhosttyLayer` already does both steps, so
    /// we just call it.
    func configureGhosttyAppearance(
        fontSize: Double,
        theme: AppearanceStore.GhosttyTerminalTheme
    ) {
        let fontChanged = fontSize != ghosttyFontSize
        let changed = fontChanged || theme != ghosttyTheme
        ghosttyFontSize = fontSize
        ghosttyTheme = theme
        guard changed else { return }
        #if canImport(GhosttyVT)
        terminal?.applyConfig(
            fontSize: Float(fontSize),
            theme: Self.mapTheme(theme)
        )
        // A font-size change rebuilds the surface (update_config does not
        // re-rasterize the glyph atlas on the pinned ABI). The new surface
        // boots occluded/unfocused, so re-assert visibility + focus and
        // ask for a full refresh — same wake recipe `didMoveToWindow`
        // uses — otherwise the freshly-attached IOSurfaceLayer can stay
        // blank until the next PTY byte.
        if fontChanged, window != nil {
            terminal?.setVisible(true)
            terminal?.setFocus(false)
            terminal?.setFocus(true)
            terminal?.refresh()
        }
        // Re-drive the grid: a font change re-derives libghostty's cell px,
        // so the surface must reflow at the current bounds and the broker
        // PTY must be re-sized to the new grid. `sizeGhosttyLayer` re-pushes
        // the pixel size and runs `syncPtyToGhosttyGrid`.
        sizeGhosttyLayer()
        #endif
    }

    #if canImport(GhosttyVT)
    /// Bridge `AppearanceStore.GhosttyTerminalTheme` → `GhosttyVT.GhosttyTheme`.
    /// The two enums share rawValues by construction (the model enum is a
    /// deliberate mirror so the model layer needn't link libghostty), so
    /// this is a total `init(rawValue:)` with a safe fallback.
    static func mapTheme(_ theme: AppearanceStore.GhosttyTerminalTheme) -> GhosttyVT.GhosttyTheme {
        GhosttyVT.GhosttyTheme(rawValue: theme.rawValue) ?? .ghosttyDark
    }
    #endif

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
        // Plain-`CALayer` setup (NO `CAMetalLayer` layerClass — see the
        // note on `ghosttySublayer`). Configure the layer opaque + black so
        // libghostty's first frame doesn't flash a white/grey curtain.
        // Wrap in a no-implicit-animation CATransaction exactly like
        // geistty's + clauntty's `init` — without `setDisableActions` the
        // colour change animates and flashes on attach. libghostty builds
        // and owns its own IOSurface/Metal pipeline once the surface is
        // created; we only set the host background colour.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        isOpaque = true
        backgroundColor = .black
        layer.isOpaque = true
        layer.backgroundColor = UIColor.black.cgColor
        layer.contentsScale = UIScreen.main.scale
        CATransaction.commit()

        // libghostty's iOS renderer reads the host view's bounds + scale at
        // surface-creation time; if we're created at `.zero` (the
        // representable's `makeUIView` passes `frame: .zero`) the renderer
        // can fail to attach its layer. geistty sidesteps this by
        // initializing its `SurfaceView` at a fixed 800x600 "so layer
        // bounds are non-zero" *before* `ghostty_surface_new`. Mirror that:
        // give ourselves a non-zero frame here so the surface init below
        // sees real bounds. UIKit overwrites this on the first real
        // `layoutSubviews`, which then pushes the true pixel size through
        // `sizeGhosttyLayer`.
        if bounds.width <= 0 || bounds.height <= 0 {
            frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        }

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

        // Single one-finger pan with a dual role (standard mobile-terminal
        // model): with NO active selection it SCROLLS libghostty's
        // scrollback; with a selection already anchored (by long-press /
        // double- / triple-tap) it EXTENDS that selection. It requires the
        // long-press to fail first, so a hold-then-drag goes to the
        // long-press's own `.changed` selection path and a quick drag
        // (long-press never fires) becomes the pan. The scroll-vs-select
        // branch is decided at `.began` from `selectionRange`.
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.require(toFail: longPress)
        addGestureRecognizer(pan)

        // Diagnostic overlay (top-left). Added unconditionally on the
        // flag-on path so it still reports "gh: not linked" on the
        // placeholder build. It sits above libghostty's sublayer via
        // its high zPosition; `layoutSubviews` keeps it pinned top-left.
        if GhosttyRenderView.showDiagnosticOverlay {
            addSubview(diagnosticLabel)
            refreshDiagnosticOverlay()
        }

        #if canImport(GhosttyVT)
        // Faithful init: with `GhosttyApp.shared` booted (real
        // wakeup/action callbacks), instantiate the surface WITH this
        // host UIView so libghostty's iOS platform slot
        // (`ghostty_platform_ios_s.uiview`) targets our layer and its
        // renderer attaches its IOSurface sublayer here.
        if Terminal.isAvailable {
            let term = Terminal(
                cols: UInt(cols),
                rows: UInt(rows),
                fontSize: Float(ghosttyFontSize),
                theme: Self.mapTheme(ghosttyTheme)
            )
            // Forward user input libghostty emits from its HOST_MANAGED
            // backend (mouse-reporting, bracketed-paste framing) to the
            // harness PTY — analog of clauntty's set_pty_input_callback.
            term.onReceiveInput = { [weak self] bytes in self?.onInput(bytes) }
            // Attach with the real (now non-zero) pixel size so the
            // renderer initializes against a sized view. `sizeGhosttyLayer`
            // re-pushes the true size on every `layoutSubviews`. Use the
            // view's own `contentScaleFactor` (geistty passes
            // `view.contentScaleFactor` as `scale_factor`); it's the backing
            // scale UIKit will actually render at and matches what libghostty
            // reads off the view at attach time.
            let scale = contentScaleFactor > 0 ? contentScaleFactor : UIScreen.main.scale
            term.attach(
                hostView: self,
                pixelWidth: UInt32(bounds.width * scale),
                pixelHeight: UInt32(bounds.height * scale),
                scaleFactor: Double(scale)
            )
            terminal = term
        }
        #endif
    }

    /// Pull the latest `GhosttyDiagnostics` snapshot and repaint the
    /// overlay label. Cheap (string format + frame set); called once per
    /// frame from the display-link proxy and on layout. No-op when the
    /// overlay is compiled out.
    func refreshDiagnosticOverlay() {
        guard GhosttyRenderView.showDiagnosticOverlay else { return }
        #if canImport(GhosttyVT)
        let snap = GhosttyDiagnostics.shared.snapshot()
        diagnosticLabel.text = snap.overlayText
        #else
        diagnosticLabel.text = "gh: not linked (flag-on, no lib)"
        #endif
        diagnosticLabel.sizeToFit()
        let pad: CGFloat = 4
        let size = diagnosticLabel.intrinsicContentSize
        let topInset = safeAreaInsets.top
        let maxWidth = max(0, bounds.width - pad * 2)
        diagnosticLabel.frame = CGRect(
            x: pad,
            y: topInset + pad,
            width: min(size.width + pad * 2, maxWidth),
            height: size.height + pad
        )
        bringSubviewToFront(diagnosticLabel)
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

    /// One-finger pan with a dual role. At `.began` we latch the mode from
    /// whether a selection is already anchored: a selection means EXTEND
    /// it (drag-to-select), no selection means SCROLL libghostty's
    /// scrollback. Scrolling never starts a selection, so a plain drag on
    /// fresh output just walks history — the standard mobile-terminal feel.
    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
        case .began:
            // Latch the role once: selection extend vs scroll.
            panIsScrolling = (selectionRange == nil)
            scrollPanLastY = 0
            if panIsScrolling {
                handleScrollPan(recognizer)
            } else {
                handleSelectionPan(recognizer)
            }
        case .changed:
            if panIsScrolling {
                handleScrollPan(recognizer)
            } else {
                handleSelectionPan(recognizer)
            }
        case .ended, .cancelled, .failed:
            if panIsScrolling {
                handleScrollPan(recognizer)
            } else {
                handleSelectionPan(recognizer)
            }
            panIsScrolling = false
            scrollPanLastY = 0
        default:
            break
        }
    }

    /// Convert the pan's vertical translation into pixel-precise scroll
    /// deltas for libghostty's scrollback. We track the consumed
    /// translation so each callback feeds only the incremental movement.
    /// Sign: a finger dragging DOWN (positive translation.y) should reveal
    /// OLDER content above, so we negate before handing off — `Terminal.scroll`
    /// treats positive `deltaY` as "scroll up into history".
    private func handleScrollPan(_ recognizer: UIPanGestureRecognizer) {
        #if canImport(GhosttyVT)
        switch recognizer.state {
        case .began:
            // Dragging the terminal dismisses any open edit menu + soft
            // keyboard focus is irrelevant to scrolling; leave it alone.
            scrollPanLastY = 0
        case .changed:
            let translationY = recognizer.translation(in: self).y
            let deltaPoints = translationY - scrollPanLastY
            scrollPanLastY = translationY
            guard deltaPoints != 0 else { return }
            // Negate: finger DOWN → reveal history ABOVE (scroll up).
            let scrollDelta = -Double(deltaPoints) * Self.scrollSensitivity
            terminal?.scroll(deltaY: scrollDelta)
        default:
            break
        }
        #else
        _ = recognizer
        #endif
    }

    private func handleSelectionPan(_ recognizer: UIPanGestureRecognizer) {
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
        sizeGhosttyLayer()
        refreshDiagnosticOverlay()
    }

    /// libghostty's iOS renderer builds its own `IOSurfaceLayer` and parents
    /// it on the host by sending `addSublayer:` to the `uiview` pointer from
    /// the surface config. `UIView` does NOT implement that selector
    /// natively (it's a `CALayer` method), so without this `@objc` hook the
    /// message is unhandled and the layer is never parented — exactly the
    /// failure both clauntty (`TerminalSurfaceView.addSublayer`) and geistty
    /// guard against. We capture the layer, parent it on our (plain
    /// `CALayer`) root, and size it immediately — libghostty hands it over at
    /// a zero frame. The per-frame `CADisplayLink` then pumps
    /// `ghostty_surface_draw` and the IOSurfaceLayer presents.
    @objc(addSublayer:)
    func addSublayer(_ sublayer: CALayer) {
        #if canImport(GhosttyVT)
        GhosttyDiagnostics.shared.incAddSublayer()
        #endif
        // A font-size change rebuilds the surface, which hands us a fresh
        // IOSurfaceLayer. Detach the previous one so we don't stack stale
        // (now-orphaned) render layers on top of each other.
        if let old = ghosttySublayer, old !== sublayer {
            old.removeFromSuperlayer()
        }
        ghosttySublayer = sublayer
        layer.addSublayer(sublayer)
        sizeGhosttyLayer()
        refreshDiagnosticOverlay()
    }

    /// Keep libghostty's render target sized to our bounds at the real
    /// backing scale, and push the pixel size into the surface. libghostty
    /// attaches its IOSurfaceLayer at a zero frame, so it paints nothing
    /// until we size it — geistty + clauntty both resize the attached
    /// sublayer to `bounds` on every layout. We size the captured
    /// `ghosttySublayer` directly; as a belt-and-suspenders we also size any
    /// other sublayer libghostty parented straight on our root layer (it can
    /// attach via `[[uiview layer] addSublayer:]` instead of the view-level
    /// hook), matching geistty's `layer.sublayers` resize loop.
    private func sizeGhosttyLayer() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        #if canImport(GhosttyVT)
        GhosttyDiagnostics.shared.setBounds(w: Int(bounds.width), h: Int(bounds.height))
        #endif
        let scale = contentScaleFactor > 0 ? contentScaleFactor : UIScreen.main.scale
        // No implicit animation on the resize — terminals must snap.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let sub = ghosttySublayer {
            sub.frame = bounds
            sub.contentsScale = scale
        }
        // Catch any IOSurfaceLayer libghostty parented directly on our root
        // layer (not via the view-level hook). Skip the diagnostic overlay's
        // backing layer — it's a UIView subview positioned in layoutSubviews.
        if let sublayers = layer.sublayers {
            let overlayLayer = diagnosticLabel.layer
            for sub in sublayers where sub !== overlayLayer && sub !== ghosttySublayer {
                sub.frame = bounds
                sub.contentsScale = scale
            }
        }
        CATransaction.commit()
        #if canImport(GhosttyVT)
        terminal?.setPixelSize(
            width: UInt32(bounds.width * scale),
            height: UInt32(bounds.height * scale),
            scale: Double(scale)
        )
        // Drive the remote PTY from libghostty's OWN grid, not a
        // client-side CoreText estimate. libghostty re-derives cols/rows
        // from the pixel size we just pushed using its own font metrics;
        // if we resize the broker PTY (tmux) to a different grid the two
        // disagree on the coordinate space and tmux misdraws (oversized /
        // duplicated status bars, gaps, a stray DA-response echo). clauntty
        // reads `ghostty_surface_size` after every `set_size` and sends
        // exactly that to its SSH winsize — mirror that here.
        syncPtyToGhosttyGrid()
        #endif
    }

    #if canImport(GhosttyVT)
    /// Read libghostty's authoritative grid (`ghostty_surface_size`) and,
    /// if it changed, push it to the local gesture grid + the remote PTY.
    /// Called after every surface `set_size` (layout / rotation / attach)
    /// so the broker PTY rows/cols always match what libghostty renders.
    private func syncPtyToGhosttyGrid() {
        guard let grid = terminal?.gridSize() else { return }
        let newCols = Int(grid.cols)
        let newRows = Int(grid.rows)
        // Keep the local gesture grid + cell metrics in sync so tap→cell
        // mapping (selection) lands on the same cells libghostty paints.
        if grid.cellWidthPx > 0, grid.cellHeightPx > 0 {
            let scale = contentScaleFactor > 0 ? contentScaleFactor : UIScreen.main.scale
            cellWidth = CGFloat(grid.cellWidthPx) / scale
            cellHeight = CGFloat(grid.cellHeightPx) / scale
        }
        guard newCols != cols || newRows != rows else { return }
        cols = newCols
        rows = newRows
        // Tell the harness so the remote PTY matches libghostty's grid —
        // same call WKTerminalView makes when xterm.js's fit addon resizes.
        onResize(rows, cols)
        refreshSnapshot()
    }
    #endif

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // Toggle visibility/focus so libghostty paints (and shows a live
        // cursor), and start/stop the per-frame draw pump. Unlike PR #198
        // (which assumed libghostty self-drives once its layer is
        // parented), we explicitly drive `ghostty_surface_draw` from a
        // CADisplayLink — geistty pumps `ghostty_surface_draw_now` the
        // same way, and that working app is what we're matching.
        let visible = window != nil
        #if canImport(GhosttyVT)
        terminal?.setVisible(visible)
        if visible {
            // clauntty toggles focus false→true to wake the renderer
            // thread when a surface becomes visible; mirror that, then
            // ask for a full refresh so a reattach doesn't show stale
            // (or blank) layer content.
            terminal?.setFocus(false)
            terminal?.setFocus(true)
            terminal?.refresh()
        } else {
            terminal?.setFocus(false)
        }
        #endif
        if visible {
            startFrameDisplayLink()
        } else {
            stopFrameDisplayLink()
        }
        refreshDiagnosticOverlay()
    }

    /// Start the per-frame draw pump. The link drives `Terminal.draw()`
    /// (→ `ghostty_surface_draw`) each vsync; ProMotion devices run up to
    /// 120Hz. Weak-proxy target avoids the link↔view retain cycle.
    private func startFrameDisplayLink() {
        guard frameDisplayLink == nil else { return }
        let proxy = FrameDisplayLinkProxy(self)
        frameDisplayLinkProxy = proxy
        let link = CADisplayLink(target: proxy, selector: #selector(FrameDisplayLinkProxy.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        frameDisplayLink = link
    }

    /// Stop + tear down the per-frame draw pump (off-window / dealloc).
    private func stopFrameDisplayLink() {
        frameDisplayLink?.invalidate()
        frameDisplayLink = nil
        frameDisplayLinkProxy = nil
    }

    deinit {
        frameDisplayLink?.invalidate()
    }

    /// Fallback grid estimate from CoreText cell metrics. ONLY authoritative
    /// when libghostty isn't live (the flag-on placeholder build with no
    /// linked lib). When libghostty IS live it derives the real grid from the
    /// pixel size in `sizeGhosttyLayer` → `syncPtyToGhosttyGrid`, and THAT
    /// drives both the surface and the remote PTY; pushing a divergent
    /// CoreText estimate here would fight it (the old bug: this resized the
    /// broker PTY to `bounds/cellWidth` while libghostty rendered at its own
    /// grid, so tmux misdrew). So on the live path we do nothing — the grid
    /// is owned by libghostty.
    private func recomputeGridFromBounds() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        #if canImport(GhosttyVT)
        // libghostty live → its grid wins; `syncPtyToGhosttyGrid` drives the
        // PTY off `ghostty_surface_size`. Skip the CoreText estimate entirely.
        if terminal != nil { return }
        #endif
        let newCols = max(1, Int(floor(bounds.width / cellWidth)))
        let newRows = max(1, Int(floor(bounds.height / cellHeight)))
        guard newCols != cols || newRows != rows else { return }
        cols = newCols
        rows = newRows
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
        // No `reset()` on the wrapper — recreate the handle AND
        // re-attach this host view + re-wire input. The old skeleton
        // recreated the Terminal without re-attaching, leaving the new
        // surface with no host view (guaranteed blank). Mirror the
        // `configure()` attach so the renderer keeps a layer to paint
        // into across a buffer-shrink reset.
        if Terminal.isAvailable {
            let term = Terminal(
                cols: UInt(cols),
                rows: UInt(rows),
                fontSize: Float(ghosttyFontSize),
                theme: Self.mapTheme(ghosttyTheme)
            )
            term.onReceiveInput = { [weak self] inBytes in self?.onInput(inBytes) }
            let scale = contentScaleFactor > 0 ? contentScaleFactor : UIScreen.main.scale
            term.attach(
                hostView: self,
                pixelWidth: UInt32(bounds.width * scale),
                pixelHeight: UInt32(bounds.height * scale),
                scaleFactor: Double(scale)
            )
            term.write(bytes)
            terminal = term
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

    // No `draw(_:)` / CoreText path. libghostty's renderer owns the pixels:
    // it builds its own `IOSurfaceLayer` and parents it on our (plain
    // `CALayer`) root view via `addSublayer:`, then presents into it; the
    // per-frame `CADisplayLink` -> `Terminal.draw()` pumps `ghostty_surface_draw`.
    // We must NOT also paint through `drawRect`/CoreText — it would fight
    // libghostty's sublayer for the same on-screen region. The old CoreText
    // snapshot/cursor/status fallback was only there for the pre-libghostty
    // builds, so it's removed. `cachedSnapshot` / `selectionRange` are still
    // maintained for the copy/selection text path (`copy(_:)` reads the
    // snapshot); they just aren't repainted here.
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
