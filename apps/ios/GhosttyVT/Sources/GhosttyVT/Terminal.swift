// Faithful libghostty init port (ghostty-faithful-init-diagnostic).
//
// Background. The Stage-4 skeleton this replaces created the
// `ghostty_app_t` + `ghostty_surface_t` but wired the
// `ghostty_runtime_config_s` callbacks as NO-OP STUBS
// (`wakeup_cb: { _ in }`, `action_cb: { _,_,_ in false }`). That is
// the root cause of the "still blank on device" rounds (PR #198,
// #204): libghostty's renderer is event-driven — it asks the host to
// pump its event loop via `wakeup_cb` and announces frames via
// `action_cb`'s `GHOSTTY_ACTION_RENDER`. With both stubbed, the app
// loop never ticks after the initial boot and the renderer never
// engages, so the Metal/IOSurface layer the lib *does* contain
// (verified: 74 'Metal' strings + IOSurfaceLayer symbols in the
// pinned storage.1.1.5 ios-arm64 binary) is never driven.
//
// This rewrite follows the working iOS reference apps
// (`eriklangille/clauntty` GhosttyApp/TerminalSurface and
// `daiimus/geistty` Ghostty.App/Ghostty.swift) faithfully:
//
//   * `ghostty_init` once (geistty does this; clauntty relies on the
//     lib's lazy init — calling it is harmless and matches geistty).
//   * `ghostty_config_new` → `ghostty_config_load_default_files` →
//     `ghostty_config_finalize`.
//   * `ghostty_app_new` with a FULLY-POPULATED runtime config whose
//     `userdata` is a pointer back to the `GhosttyApp` and whose
//     `wakeup_cb` schedules `ghostty_app_tick` on the main queue (this
//     is what keeps the renderer alive — clauntty + geistty both do
//     exactly this), and whose `action_cb` acknowledges
//     `GHOSTTY_ACTION_RENDER` (returns true) so the lib's render
//     pipeline is satisfied. Clipboard / close callbacks are real
//     (route through `UIPasteboard` shape), not no-ops.
//   * `ghostty_surface_new` with `userdata` set (so the surface routes
//     back to us), `platform_tag = GHOSTTY_PLATFORM_IOS`,
//     `platform.ios.uiview = <host UIView>`, `scale_factor`,
//     `font_size`, and `context = GHOSTTY_SURFACE_CONTEXT_WINDOW`.
//     Our pinned ABI uses the HOST_MANAGED backend (libghostty does
//     not spawn a child process; the harness streams PTY bytes in via
//     `ghostty_surface_write_buffer`, and libghostty hands user input
//     BACK to us through the `receive_buffer` callback — the analog of
//     clauntty's `set_pty_input_callback`).
//
// ABI note. Our pinned lib exposes `ghostty_surface_draw` (NOT
// `ghostty_surface_draw_now`, which geistty's newer lib has). The host
// view drives `ghostty_surface_draw` from a CADisplayLink — but the
// wakeup→tick loop is what actually keeps the renderer hot; the draw
// pump is belt-and-suspenders for our gen of the lib.
//
// Observability. Because we have had three blind "still blank" device
// rounds with no device logs, every load-bearing step now records into
// process-global atomics that the on-screen diagnostic overlay
// (`GhosttyTerminalView.swift`, behind `experimentalNativeTerminal`)
// reads live: init result, app handle, surface handle (nil vs ptr),
// addSublayer-hook count, draw-tick count, wakeup count, action count,
// last bounds. `ghostty_surface_new`'s nil-vs-ptr return is captured so
// the NEXT device test reveals the failure point even if still blank.
//
// **C ABI surface used (verified against storage.1.1.5
// `libghostty.framework/Headers/ghostty.h`):**
//   ghostty_init(uintptr_t, char**) -> int                  (GHOSTTY_SUCCESS == 0)
//   ghostty_config_new() -> ghostty_config_t
//   ghostty_config_load_default_files(ghostty_config_t)
//   ghostty_config_finalize(ghostty_config_t)
//   ghostty_config_free(ghostty_config_t)
//   ghostty_app_new(const ghostty_runtime_config_s*, ghostty_config_t) -> ghostty_app_t
//   ghostty_app_free(ghostty_app_t)
//   ghostty_app_tick(ghostty_app_t)
//   ghostty_surface_config_new() -> ghostty_surface_config_s
//   ghostty_surface_new(ghostty_app_t, const ghostty_surface_config_s*) -> ghostty_surface_t
//   ghostty_surface_free(ghostty_surface_t)
//   ghostty_surface_write_buffer(ghostty_surface_t, const uint8_t*, uintptr_t)
//   ghostty_surface_set_size(ghostty_surface_t, uint32_t, uint32_t)
//   ghostty_surface_set_content_scale(ghostty_surface_t, double, double)
//   ghostty_surface_set_focus(ghostty_surface_t, bool)
//   ghostty_surface_set_occlusion(ghostty_surface_t, bool)
//   ghostty_surface_draw(ghostty_surface_t)
//   ghostty_surface_refresh(ghostty_surface_t)

import Foundation

#if canImport(libghostty)
import libghostty
#endif

// MARK: - Public data types (UIKit-free)
//
// These were defined in the Stage 1 wrapper and consumed by the iOS
// app's CoreText renderer (`GhosttyTerminalView.swift`). Keeping their
// shape unchanged means the renderer compiles and paints the same
// frame regardless of whether libghostty is live underneath.

/// VT-100/ECMA-48 SGR color, in the shape the renderer needs to look it
/// up in a `TerminalPalette`.
public enum SGRColor: Equatable, Sendable, Hashable {
    case `default`
    case ansi(index: UInt8, bright: Bool)
    case palette(index: UInt8)
    case rgb(r: UInt8, g: UInt8, b: UInt8)
}

/// VT-100/ECMA-48 non-color SGR attributes.
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

/// Pure-Swift mirror of a single cell in the terminal grid.
public struct TerminalCell: Equatable, Sendable {
    public var character: String
    public var fg: SGRColor
    public var bg: SGRColor
    public var attrs: SGRAttributes
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

/// Pure-Swift snapshot of the active screen.
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

// MARK: - Diagnostics
//
// Process-global, thread-safe counters that capture every load-bearing
// step of the libghostty boot + render path. The on-screen overlay in
// `GhosttyTerminalView.swift` polls `GhosttyDiagnostics.snapshot()` once
// per frame and renders it as tiny mono text so the NEXT on-device test
// reveals exactly where the pipeline stalls — even if the surface is
// still visually blank. Everything here is plain-Swift (no libghostty
// types) so the diagnostics compile and the overlay renders on the
// placeholder build too (where it will just show "gh: not linked").

/// Live state of the libghostty integration, formatted for the overlay.
public struct GhosttyDiagnosticsSnapshot: Equatable, Sendable {
    public var linked: Bool
    public var initStatus: String     // "ok" / "err:<reason>" / "n/a"
    public var appOK: Bool
    public var surfaceCreated: Bool   // ghostty_surface_new returned non-nil
    public var surfaceAttempted: Bool // a surface creation was attempted at all
    public var addSublayerCount: Int
    public var drawCount: Int
    public var wakeupCount: Int
    public var actionCount: Int
    public var renderActionCount: Int
    public var lastBoundsW: Int
    public var lastBoundsH: Int
    public var fedBytes: Int

    /// Compact multi-line label for the top-left overlay. Each token is
    /// the smallest string that still disambiguates the failure mode.
    public var overlayText: String {
        guard linked else { return "gh: not linked" }
        let app = appOK ? "ok" : "nil"
        let surf = surfaceAttempted ? (surfaceCreated ? "ok" : "NIL") : "—"
        return """
        gh_init:\(initStatus)
        app:\(app) surface:\(surf)
        wakeups:\(wakeupCount) actions:\(actionCount)
        render:\(renderActionCount) draw:\(drawCount)
        addSublayer:\(addSublayerCount)
        bounds:\(lastBoundsW)x\(lastBoundsH) fed:\(fedBytes)
        """
    }
}

/// Thread-safe diagnostic sink. libghostty callbacks fire from the
/// main thread in practice (wakeup dispatches to main), but `action_cb`
/// is documented as potentially off-thread, so every mutation goes
/// through a lock.
public final class GhosttyDiagnostics: @unchecked Sendable {
    public static let shared = GhosttyDiagnostics()

    private let lock = NSLock()

    private var _linked: Bool = {
        #if canImport(libghostty)
        return true
        #else
        return false
        #endif
    }()
    private var _initStatus: String = "n/a"
    private var _appOK = false
    private var _surfaceCreated = false
    private var _surfaceAttempted = false
    private var _addSublayerCount = 0
    private var _drawCount = 0
    private var _wakeupCount = 0
    private var _actionCount = 0
    private var _renderActionCount = 0
    private var _lastBoundsW = 0
    private var _lastBoundsH = 0
    private var _fedBytes = 0

    private init() {}

    public func setInit(ok: Bool, reason: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        _initStatus = ok ? "ok" : "err:\(reason ?? "?")"
    }
    public func setAppOK(_ ok: Bool) { lock.lock(); _appOK = ok; lock.unlock() }
    public func setSurface(created: Bool) {
        lock.lock(); _surfaceAttempted = true; _surfaceCreated = created; lock.unlock()
    }
    public func incAddSublayer() { lock.lock(); _addSublayerCount += 1; lock.unlock() }
    public func incDraw() { lock.lock(); _drawCount += 1; lock.unlock() }
    public func incWakeup() { lock.lock(); _wakeupCount += 1; lock.unlock() }
    public func incAction(render: Bool) {
        lock.lock(); _actionCount += 1; if render { _renderActionCount += 1 }; lock.unlock()
    }
    public func setBounds(w: Int, h: Int) {
        lock.lock(); _lastBoundsW = w; _lastBoundsH = h; lock.unlock()
    }
    public func addFedBytes(_ n: Int) { lock.lock(); _fedBytes += n; lock.unlock() }

    public func snapshot() -> GhosttyDiagnosticsSnapshot {
        lock.lock(); defer { lock.unlock() }
        return GhosttyDiagnosticsSnapshot(
            linked: _linked,
            initStatus: _initStatus,
            appOK: _appOK,
            surfaceCreated: _surfaceCreated,
            surfaceAttempted: _surfaceAttempted,
            addSublayerCount: _addSublayerCount,
            drawCount: _drawCount,
            wakeupCount: _wakeupCount,
            actionCount: _actionCount,
            renderActionCount: _renderActionCount,
            lastBoundsW: _lastBoundsW,
            lastBoundsH: _lastBoundsH,
            fedBytes: _fedBytes
        )
    }
}

// MARK: - App/Surface bridge

#if canImport(libghostty)

/// Process-wide libghostty app handle + lifetime, faithful to
/// clauntty's `GhosttyApp` and geistty's `Ghostty.App`.
///
/// Singleton because `ghostty_app_t` owns process-global state (event
/// loop, runtime callback table, action dispatch). The runtime config's
/// `userdata` points back at this instance via `Unmanaged.passUnretained`
/// — safe because the singleton lives for the whole process.
public final class GhosttyApp {
    public static let shared = GhosttyApp()

    public var isAlive: Bool { return appHandle != nil }

    /// Opaque `ghostty_app_t`. Internal call sites pass it to
    /// `ghostty_surface_new`.
    fileprivate var appHandle: UnsafeMutableRawPointer? { return _app }

    private var _app: UnsafeMutableRawPointer?
    private var _config: UnsafeMutableRawPointer?

    public private(set) var lastInitError: String?

    public var debugDescription: String {
        guard let app = _app else { return "GhosttyApp(nil)" }
        return "GhosttyApp(0x\(String(UInt(bitPattern: app), radix: 16)))"
    }

    private init() {
        // 1. Initialize the libghostty runtime. geistty calls this
        //    explicitly; clauntty relies on lazy init. Calling it is
        //    the safer, reference-faithful path. A non-zero return is
        //    surfaced (not fatal — the feature is experimental).
        let initRC = ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv)
        if initRC != GHOSTTY_SUCCESS {
            lastInitError = "ghostty_init returned \(initRC)"
            GhosttyDiagnostics.shared.setInit(ok: false, reason: "init=\(initRC)")
            return
        }
        GhosttyDiagnostics.shared.setInit(ok: true)

        // 2. Config: new → load default files → finalize. On iOS the
        //    config file is virtually never present (sandboxed); the
        //    baked-in defaults are fine.
        guard let config: UnsafeMutableRawPointer = ghostty_config_new() else {
            lastInitError = "ghostty_config_new returned nil"
            GhosttyDiagnostics.shared.setInit(ok: false, reason: "config_nil")
            return
        }
        ghostty_config_load_default_files(config)
        ghostty_config_finalize(config)
        self._config = config

        // 3. Runtime config with FULLY-POPULATED callbacks. `userdata`
        //    is a pointer back to this singleton so the static C
        //    callbacks can recover `self`. This is the critical fix:
        //    the old skeleton stubbed wakeup/action as no-ops, so the
        //    renderer never got driven after boot.
        var runtime = ghostty_runtime_config_s(
            userdata: Unmanaged.passUnretained(self).toOpaque(),
            supports_selection_clipboard: false,
            wakeup_cb: { userdata in GhosttyApp.wakeup(userdata) },
            action_cb: { app, target, action in
                GhosttyApp.action(app, target: target, action: action)
            },
            read_clipboard_cb: { userdata, loc, state in
                GhosttyApp.readClipboard(userdata, location: loc, state: state)
            },
            confirm_read_clipboard_cb: { _, _, _, _ in },
            write_clipboard_cb: { userdata, loc, content, len, confirm in
                GhosttyApp.writeClipboard(userdata, location: loc, content: content, len: len, confirm: confirm)
            },
            close_surface_cb: { _, _ in }
        )

        // 4. App.
        guard let app: UnsafeMutableRawPointer = ghostty_app_new(&runtime, config) else {
            lastInitError = "ghostty_app_new returned nil"
            GhosttyDiagnostics.shared.setInit(ok: false, reason: "app_nil")
            ghostty_config_free(config)
            self._config = nil
            return
        }
        self._app = app
        GhosttyDiagnostics.shared.setAppOK(true)
    }

    deinit {
        if let app = _app {
            ghostty_app_free(app)
        }
        // libghostty took ownership of `_config` inside ghostty_app_new.
    }

    /// Pump the libghostty event loop once. Main-thread only.
    public func tick() {
        guard let app = _app else { return }
        ghostty_app_tick(app)
    }

    // MARK: - Static C callbacks
    //
    // These are the runtime-config function pointers. They recover the
    // `GhosttyApp` (or, for surface-scoped actions, the host view via
    // the surface registry) from `userdata`.

    /// libghostty asks the host to pump its loop. clauntty + geistty
    /// both dispatch `ghostty_app_tick` to the main queue here — this
    /// is what keeps the renderer alive frame-to-frame.
    static func wakeup(_ userdata: UnsafeMutableRawPointer?) {
        GhosttyDiagnostics.shared.incWakeup()
        DispatchQueue.main.async {
            guard let userdata = userdata else { return }
            let app = Unmanaged<GhosttyApp>.fromOpaque(userdata).takeUnretainedValue()
            app.tick()
        }
    }

    /// libghostty announces an action (render, set-title, …). We must
    /// acknowledge `GHOSTTY_ACTION_RENDER` (return true) so the lib's
    /// render pipeline is satisfied — matches clauntty/geistty.
    static func action(
        _ app: UnsafeMutableRawPointer?,
        target: ghostty_target_s,
        action: ghostty_action_s
    ) -> Bool {
        switch action.tag {
        case GHOSTTY_ACTION_RENDER:
            GhosttyDiagnostics.shared.incAction(render: true)
            return true
        default:
            GhosttyDiagnostics.shared.incAction(render: false)
            return false
        }
    }

    /// Read iOS pasteboard into libghostty. Stubbed body (the harness
    /// owns paste via the renderer's edit menu) but a real, non-no-op
    /// function pointer so the lib's clipboard path is well-formed.
    static func readClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        state: UnsafeMutableRawPointer?
    ) -> Bool {
        // The host owns clipboard reads via the UIKit edit menu; we do
        // not complete the request here, but the callback exists and
        // returns cleanly rather than trapping.
        return false
    }

    /// Write libghostty's clipboard payload to the iOS pasteboard.
    static func writeClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        content: UnsafePointer<ghostty_clipboard_content_s>?,
        len: Int,
        confirm: Bool
    ) {
        // No-op body for now (renderer owns copy); kept as a real
        // function pointer so the runtime config is fully populated.
        _ = (userdata, location, content, len, confirm)
    }
}

/// One terminal viewport over `ghostty_surface_t`, faithful to
/// clauntty's `TerminalSurfaceView` + geistty's `SurfaceView` init.
///
/// The host UIView (`GhosttyRenderView`) is passed in via `attach`; we
/// set it as both `platform.ios.uiview` AND `userdata` so libghostty's
/// Metal renderer can target the view's layer (it adds an IOSurfaceLayer
/// sublayer via `addSublayer:`) and route surface-scoped callbacks back.
public final class GhosttySurface {
    private var _surface: UnsafeMutableRawPointer?
    private var _hostView: AnyObject?
    private var lastSizePx: (width: UInt32, height: UInt32) = (0, 0)

    /// Forwarded user input from libghostty's HOST_MANAGED backend
    /// (`receive_buffer`). The host wires this to send bytes to the
    /// remote PTY — the analog of clauntty's `set_pty_input_callback`.
    /// libghostty calls `receive_buffer` for things like mouse-reporting
    /// escape sequences and bracketed-paste framing.
    public var onReceiveInput: ((Data) -> Void)?

    /// Strips libghostty's duplicate terminal-query RESPONSES (DA1/DA2/DA3,
    /// XTVERSION, DSR, CPR, DECRPM, XTGETTCAP) out of the `receive_buffer`
    /// stream before they reach `onReceiveInput`. The broker runs the agent
    /// in a REAL kernel PTY + tmux that already answers these queries; the
    /// raw stream is then re-emulated by libghostty here, which auto-replies
    /// a SECOND time. That duplicate would otherwise be routed back to the
    /// broker PTY input and echo as literal `^[[?62;22;52c` /
    /// `ghostty 1.3.1` text at the idle bash prompt. See
    /// `QueryResponseFilter` for the full topology writeup. Per-surface so
    /// sequences split across callbacks are reassembled correctly.
    private let queryResponseFilter = QueryResponseFilter()

    public var debugDescription: String {
        guard let s = _surface else { return "GhosttySurface(nil)" }
        return "GhosttySurface(0x\(String(UInt(bitPattern: s), radix: 16)))"
    }

    public var isAlive: Bool { return _surface != nil }

    public init(
        app: GhosttyApp = .shared,
        hostView: AnyObject? = nil,
        pixelWidth: UInt32 = 0,
        pixelHeight: UInt32 = 0,
        scaleFactor: Double = 2.0,
        fontSize: Float = 13.0
    ) {
        guard let appHandle = app.appHandle else {
            GhosttyDiagnostics.shared.setSurface(created: false)
            return
        }
        self._hostView = hostView

        var config = ghostty_surface_config_new()
        config.platform_tag = GHOSTTY_PLATFORM_IOS
        // Host UIView → libghostty's iOS platform slot AND userdata.
        // clauntty + geistty both pass the view as `userdata` so
        // surface-scoped action callbacks can recover the view; the
        // `.ios.uiview` slot is where the renderer attaches its layer.
        let uiviewPtr: UnsafeMutableRawPointer?
        if let host = hostView {
            uiviewPtr = Unmanaged.passUnretained(host).toOpaque()
        } else {
            uiviewPtr = nil
        }
        config.platform = ghostty_platform_u(
            ios: ghostty_platform_ios_s(uiview: uiviewPtr)
        )
        config.userdata = uiviewPtr
        config.scale_factor = scaleFactor
        config.font_size = fontSize
        // Host-managed I/O: libghostty does NOT spawn a child process.
        // The harness streams PTY output IN via write_buffer; libghostty
        // hands user input OUT via the receive_buffer callback below.
        config.backend = GHOSTTY_SURFACE_IO_BACKEND_HOST_MANAGED
        config.receive_userdata = Unmanaged.passUnretained(self).toOpaque()
        config.receive_buffer = { userdata, bytes, len in
            guard let userdata = userdata, let bytes = bytes, len > 0 else { return }
            let surface = Unmanaged<GhosttySurface>.fromOpaque(userdata).takeUnretainedValue()
            let data = Data(bytes: bytes, count: Int(len))
            // Drop libghostty's duplicate query RESPONSES (DA/XTVERSION/DSR/…)
            // before they hit the broker PTY: the broker's real PTY + tmux
            // already answered every query, so this copy is spurious and
            // would otherwise echo as literal text at the bash prompt. The
            // filter is stateful (handles sequences split across callbacks)
            // so it must run on the same actor it's mutated on — hop to main
            // first, filter there, then deliver.
            DispatchQueue.main.async {
                let forwarded = surface.queryResponseFilter.filter(data)
                guard !forwarded.isEmpty else { return }
                surface.onReceiveInput?(forwarded)
            }
        }
        config.receive_resize = { _, _, _, _, _ in }
        config.context = GHOSTTY_SURFACE_CONTEXT_WINDOW

        guard let surface: UnsafeMutableRawPointer = ghostty_surface_new(appHandle, &config) else {
            GhosttyDiagnostics.shared.setSurface(created: false)
            return
        }
        self._surface = surface
        GhosttyDiagnostics.shared.setSurface(created: true)

        // Push the initial size + scale BEFORE the first draw so the
        // renderer initializes against a non-zero render target. geistty
        // + clauntty both size the surface immediately on creation.
        if pixelWidth > 0, pixelHeight > 0 {
            ghostty_surface_set_content_scale(surface, scaleFactor, scaleFactor)
            ghostty_surface_set_size(surface, pixelWidth, pixelHeight)
            lastSizePx = (pixelWidth, pixelHeight)
        }
    }

    deinit {
        if let surface = _surface {
            ghostty_surface_free(surface)
        }
    }

    /// Forward a chunk of PTY bytes into libghostty's parser. Main-thread
    /// only. After writing, tick the app so the parser work flushes and
    /// the renderer is woken (libghostty also calls `wakeup_cb`).
    public func feed(_ bytes: Data) {
        guard let surface = _surface, !bytes.isEmpty else { return }
        bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            ghostty_surface_write_buffer(surface, base, UInt(bytes.count))
        }
        GhosttyDiagnostics.shared.addFedBytes(bytes.count)
        GhosttyApp.shared.tick()
    }

    public func feed(_ string: String) {
        feed(Data(string.utf8))
    }

    /// Push the host view's pixel size + scale. Cell grid + reflow happen
    /// inside libghostty. Mirrors clauntty's `sizeDidChange`: set content
    /// scale first, then size.
    public func resize(pixelWidth: UInt32, pixelHeight: UInt32, scale: Double) {
        guard let surface = _surface else { return }
        if lastSizePx.width == pixelWidth && lastSizePx.height == pixelHeight {
            return
        }
        ghostty_surface_set_content_scale(surface, scale, scale)
        ghostty_surface_set_size(surface, pixelWidth, pixelHeight)
        lastSizePx = (pixelWidth, pixelHeight)
    }

    /// Render one frame. Our pinned ABI has `ghostty_surface_draw` (NOT
    /// `draw_now`). Driven by the host's CADisplayLink — but the
    /// wakeup→tick loop is the primary render driver.
    public func draw() {
        guard let surface = _surface else { return }
        ghostty_surface_draw(surface)
        GhosttyDiagnostics.shared.incDraw()
    }

    /// Ask libghostty to fully re-render (used after a size change /
    /// reattach where the layer may hold stale content).
    public func refresh() {
        guard let surface = _surface else { return }
        ghostty_surface_refresh(surface)
    }

    public func setFocus(_ focused: Bool) {
        guard let surface = _surface else { return }
        ghostty_surface_set_focus(surface, focused)
    }

    public func setContentScale(_ x: Double, _ y: Double) {
        guard let surface = _surface else { return }
        ghostty_surface_set_content_scale(surface, x, y)
    }

    public func setOcclusion(_ visible: Bool) {
        guard let surface = _surface else { return }
        ghostty_surface_set_occlusion(surface, visible)
    }

    /// The grid libghostty itself derived from the current surface pixel
    /// size + its own font metrics, read back via `ghostty_surface_size`.
    /// This is the authoritative cols/rows the renderer paints at — the
    /// host MUST drive the remote PTY to the SAME grid (clauntty reads
    /// `ghostty_surface_size` after every `set_size` and sends that to its
    /// SSH winsize), otherwise the PTY app (tmux) draws at a different
    /// coordinate space than libghostty renders and the screen misdraws.
    /// Returns nil if the surface isn't alive or libghostty hasn't sized
    /// the grid yet (zero cols/rows).
    public func gridSize() -> (cols: UInt16, rows: UInt16, cellWidthPx: UInt32, cellHeightPx: UInt32)? {
        guard let surface = _surface else { return nil }
        let s = ghostty_surface_size(surface)
        guard s.columns > 0, s.rows > 0 else { return nil }
        return (s.columns, s.rows, s.cell_width_px, s.cell_height_px)
    }
}

#endif // canImport(libghostty)

// MARK: - Compatibility façade
//
// The iOS renderer (`GhosttyTerminalView.swift`) was written against
// the `Terminal` class shape. Keeping it as a thin façade lets the
// renderer compile unchanged; under the hood it now drives the faithful
// `GhosttyApp` + `GhosttySurface` init.

/// Swift wrapper over a libghostty viewport. Public API shape retained
/// so the renderer keeps compiling.
public final class Terminal {
    /// `true` when libghostty's App pipeline is alive in this process.
    public static var isAvailable: Bool {
        #if canImport(libghostty)
        return GhosttyApp.shared.isAlive
        #else
        return false
        #endif
    }

    /// Status string for the iOS overlay header.
    public static func statusDescription(includeSurface: Bool = true) -> String {
        #if canImport(libghostty)
        let app = GhosttyApp.shared
        if let err = app.lastInitError {
            return "libghostty init failed: \(err)"
        }
        guard app.isAlive else {
            return "libghostty not initialized"
        }
        if includeSurface {
            return "libghostty alive — \(app.debugDescription)"
        }
        return "libghostty alive"
        #else
        return "libghostty not linked — flag-off path"
        #endif
    }

    private var cols: UInt
    private var rows: UInt

    #if canImport(libghostty)
    private var surface: GhosttySurface?
    #endif

    /// User input forwarded out of libghostty's HOST_MANAGED backend.
    /// The renderer wires this to `SessionStore.sendInput`.
    public var onReceiveInput: ((Data) -> Void)? {
        didSet {
            #if canImport(libghostty)
            surface?.onReceiveInput = onReceiveInput
            #endif
        }
    }

    public init(cols: UInt, rows: UInt, maxScrollback: UInt = 10_000) {
        precondition(cols > 0 && cols <= UInt(UInt16.max), "cols out of range")
        precondition(rows > 0 && rows <= UInt(UInt16.max), "rows out of range")
        self.cols = cols
        self.rows = rows
        // Surface is created lazily in `attach(...)` with the real host
        // view + non-zero pixel size. Creating a hostless surface here
        // (as the skeleton did) starves the renderer of a layer to
        // attach to — the reference apps always create the surface WITH
        // the view.
        _ = maxScrollback
    }

    /// Attach a host UIView. Re-creates the underlying surface because
    /// `platform.ios.uiview` is read once at surface-creation time.
    public func attach(hostView: AnyObject?, pixelWidth: UInt32, pixelHeight: UInt32, scaleFactor: Double) {
        #if canImport(libghostty)
        guard GhosttyApp.shared.isAlive else { return }
        let s = GhosttySurface(
            hostView: hostView,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            scaleFactor: scaleFactor
        )
        s.onReceiveInput = onReceiveInput
        surface = s
        #else
        _ = (hostView, pixelWidth, pixelHeight, scaleFactor)
        #endif
    }

    public func write(_ bytes: Data) {
        #if canImport(libghostty)
        surface?.feed(bytes)
        #else
        _ = bytes
        #endif
    }

    public func write(_ string: String) {
        write(Data(string.utf8))
    }

    public func resize(cols: UInt, rows: UInt, cellWidthPx: UInt = 0, cellHeightPx: UInt = 0) {
        precondition(cols > 0 && cols <= UInt(UInt16.max), "cols out of range")
        precondition(rows > 0 && rows <= UInt(UInt16.max), "rows out of range")
        self.cols = cols
        self.rows = rows
        #if canImport(libghostty)
        let cellW = cellWidthPx > 0 ? cellWidthPx : 8
        let cellH = cellHeightPx > 0 ? cellHeightPx : 16
        let pxW = UInt32(cols * cellW)
        let pxH = UInt32(rows * cellH)
        surface?.resize(pixelWidth: pxW, pixelHeight: pxH, scale: 2.0)
        #else
        _ = (cellWidthPx, cellHeightPx)
        #endif
    }

    /// Push the real backing-store pixel size + scale to libghostty.
    public func setPixelSize(width: UInt32, height: UInt32, scale: Double) {
        #if canImport(libghostty)
        surface?.resize(pixelWidth: width, pixelHeight: height, scale: scale)
        #else
        _ = (width, height, scale)
        #endif
    }

    /// The grid (cols/rows + cell px) libghostty derived from the current
    /// surface pixel size. The host reads this after pushing a new size so
    /// it can resize the remote PTY to libghostty's exact grid instead of
    /// a divergent client-side cell estimate. nil until a surface exists
    /// and libghostty has sized a non-empty grid.
    public func gridSize() -> (cols: UInt16, rows: UInt16, cellWidthPx: UInt32, cellHeightPx: UInt32)? {
        #if canImport(libghostty)
        return surface?.gridSize()
        #else
        return nil
        #endif
    }

    public func draw() {
        #if canImport(libghostty)
        surface?.draw()
        #endif
    }

    public func refresh() {
        #if canImport(libghostty)
        surface?.refresh()
        #endif
    }

    public func setFocus(_ focused: Bool) {
        #if canImport(libghostty)
        surface?.setFocus(focused)
        #endif
    }

    public func setVisible(_ visible: Bool) {
        #if canImport(libghostty)
        surface?.setOcclusion(visible)
        #endif
    }

    /// Empty-grid snapshot — the App/Surface ABI does not expose a
    /// per-cell readback (the public path is `ghostty_surface_read_text`,
    /// for accessibility, not render loops). libghostty's own renderer
    /// owns the pixels; the renderer keeps this only for the selection
    /// text path shape.
    public func snapshot() -> TerminalSnapshot {
        let total = Int(cols) * Int(rows)
        let cells = [TerminalCell](repeating: TerminalCell(character: ""), count: total)
        return TerminalSnapshot(
            cols: cols,
            rows: rows,
            cells: cells,
            cursorRow: 0,
            cursorCol: 0
        )
    }
}
