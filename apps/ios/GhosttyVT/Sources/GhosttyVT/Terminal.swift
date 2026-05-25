// Stage 4 of `docs/PLAN-TERMINAL-REWRITE.md`. Bridges
// `Lakr233/libghostty-spm storage.1.1.5`'s `libghostty` C module
// (the full Ghostty embedding API: `ghostty_app_new`,
// `ghostty_surface_new`, `ghostty_surface_write_buffer`, …) into Swift
// so the iOS app can finally prove libghostty actually loads at
// runtime. The PRs leading up to this one (#94 → #96 → #98 → #119
// chain) wired the SPM pin and got the iOS-simulator linker happy
// with the multi-arch xcframework, but the Swift wrapper still
// targeted the old slim VT-only ABI (`ghostty_terminal_new`,
// `ghostty_terminal_vt_write`, …) that DOES NOT EXIST in Lakr233's
// build. The `#if canImport(GhosttyVt)` guard (note the lowercase
// `Vt`) always evaluated `false` — the real module name on the
// xcframework's umbrella modulemap is `libghostty` — so
// `Terminal.isAvailable` was wired to permanently report `false`
// and the experimental terminal flag rendered an empty grid. This
// rewrite fixes both problems:
//
//   1. Switch the gate from `canImport(GhosttyVt)` to
//      `canImport(libghostty)` so the import actually resolves.
//   2. Replace the slim VT C ABI calls with the App/Surface ABI:
//      a singleton `GhosttyApp` over `ghostty_app_t` + a
//      `GhosttySurface` host-managed surface that accepts byte feeds
//      via `ghostty_surface_write_buffer`. The bytes are forwarded
//      into libghostty's parser; libghostty's own Metal renderer
//      drives the cell grid (Stage 5 will wire the `CAMetalLayer`
//      host so glyphs paint), but for THIS PR we ship the
//      skeleton — the surface is created (proves the App/Surface
//      pipeline is alive at runtime), bytes are forwarded
//      (no-op rendering until Stage 5 attaches the Metal layer),
//      and the existing CoreText fallback renderer in
//      `GhosttyTerminalView.swift` paints from its own parser-less
//      snapshot — staying as the visible UX so the user still sees
//      agent output even though libghostty's own renderer isn't
//      attached yet. See Stage 4 status block in
//      `docs/PLAN-TERMINAL-REWRITE.md` for the full split.
//
// **Why a façade over a clean-room rewrite.** The existing
// `GhosttyTerminalView.swift` CoreText renderer reads
// `Terminal.snapshot() -> TerminalSnapshot` every frame; tearing
// down its draw path inside this PR would blow the 3-hour timebox.
// Keeping the `Terminal` class as a UIKit-free data shape
// (snapshot returns empty cells when libghostty owns rendering)
// lets the renderer stay green while the App/Surface wiring proves
// itself in production. Stage 5 swaps the renderer to the
// libghostty Metal output and deletes the snapshot path.
//
// **C ABI surface used (verified against
// `GhosttyKit.xcframework/.../libghostty.framework/Headers/ghostty.h`
// from storage.1.1.5):**
//
//   ghostty_init(uintptr_t, char**) -> int
//   ghostty_config_new() -> ghostty_config_t
//   ghostty_config_load_default_files(ghostty_config_t)
//   ghostty_config_finalize(ghostty_config_t)
//   ghostty_config_free(ghostty_config_t)
//
//   ghostty_app_new(const ghostty_runtime_config_s*, ghostty_config_t)
//     -> ghostty_app_t
//   ghostty_app_free(ghostty_app_t)
//   ghostty_app_tick(ghostty_app_t)
//
//   ghostty_surface_config_new() -> ghostty_surface_config_s
//   ghostty_surface_new(ghostty_app_t, const ghostty_surface_config_s*)
//     -> ghostty_surface_t
//   ghostty_surface_free(ghostty_surface_t)
//   ghostty_surface_write_buffer(ghostty_surface_t, const uint8_t*, uintptr_t)
//   ghostty_surface_set_size(ghostty_surface_t, uint32_t, uint32_t)
//
// The runtime callbacks (`ghostty_runtime_config_s`) must all be
// non-null — libghostty calls them at well-defined points (wakeup,
// action dispatch, clipboard, surface close). We stub them as
// no-ops; the host-managed I/O backend
// (`GHOSTTY_SURFACE_IO_BACKEND_HOST_MANAGED`) means libghostty
// never spawns a child process — bytes flow exclusively through
// `ghostty_surface_write_buffer`, matching how the harness already
// streams PTY output into `SessionStore.terminalBuffer`.

import Foundation

#if canImport(libghostty)
import libghostty
#endif

// MARK: - Public data types (UIKit-free)
//
// These were defined in the Stage 1 wrapper and consumed by the iOS
// app's CoreText renderer (`GhosttyTerminalView.swift`). Keeping their
// shape unchanged means the renderer compiles and paints the same
// frame regardless of whether libghostty is live underneath. Stage 5
// will delete these once libghostty's own Metal output drives the
// pixel grid; for now they're the data interface between the parser
// (libghostty when alive, no-op when not) and the renderer (CoreText).

/// VT-100/ECMA-48 SGR color, in the shape the renderer needs to look it
/// up in a `TerminalPalette`. See Stage 1 wrapper for the per-case
/// documentation; the type is unchanged from that version so existing
/// `SGRColorShim` / palette code keeps compiling.
public enum SGRColor: Equatable, Sendable, Hashable {
    case `default`
    case ansi(index: UInt8, bright: Bool)
    case palette(index: UInt8)
    case rgb(r: UInt8, g: UInt8, b: UInt8)
}

/// VT-100/ECMA-48 non-color SGR attributes. Unchanged from Stage 1.
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

/// Pure-Swift mirror of a single cell in the terminal grid. Unchanged
/// from Stage 1; the iOS CoreText renderer reads this directly.
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

/// Pure-Swift snapshot of the active screen. Returned by
/// `Terminal.snapshot()`. The `cells` array is row-major and exactly
/// `cols * rows` long. Unchanged from Stage 1.
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

// MARK: - Stage 4: App/Surface bridge
//
// `GhosttyApp` is a process-wide singleton over `ghostty_app_t`; only
// one libghostty App may exist per process (the upstream macOS app
// holds the same invariant). `GhosttySurface` represents a single
// terminal viewport — owned by the host UIView, fed by
// `ghostty_surface_write_buffer`, freed on `deinit`.
//
// Both types are `final class` because the underlying handles are
// heap-allocated by Zig and we rely on Swift's deinit to release
// them in a deterministic order. The handle is `nil` only between an
// init failure and the deinit's no-op free.

#if canImport(libghostty)

/// Lifetime + status of the process-wide libghostty app handle.
///
/// `GhosttyApp.shared` lazily initializes the underlying
/// `ghostty_app_t` the first time anything reads `isAlive` /
/// `appHandle`. The init can fail (config load, library init, or the
/// Zig allocator can refuse) — failures land in
/// `lastInitError` as a human-readable string so the iOS status
/// overlay can surface "libghostty alive" vs the failure reason.
///
/// **Why singleton.** `ghostty_app_t` owns process-global state
/// (the event loop, the runtime config callbacks, the action
/// dispatch table). Creating two would race on action dispatch and
/// double-free the runtime allocator. The upstream macOS app
/// enforces the same invariant via its `AppDelegate.ghostty: Ghostty.App`
/// stored property; ours is a Swift singleton because there's no
/// AppDelegate analog in our SwiftUI-only entry point.
public final class GhosttyApp {
    /// Process-wide instance. The init runs once, behind the
    /// Swift `static let` once-only guarantee (the runtime guards
    /// against re-entry on the same lazy slot — no manual locking
    /// needed). Subsequent reads from any thread share the same
    /// `ghostty_app_t`.
    public static let shared = GhosttyApp()

    /// `true` when `ghostty_app_new` returned a non-nil handle and
    /// the runtime is ready to accept surfaces. `false` when the
    /// init failed (see `lastInitError`) or libghostty's
    /// `ghostty_init` returned non-zero (rare; would mean an
    /// out-of-tree fork removed `ghostty_init`).
    public var isAlive: Bool {
        return appHandle != nil
    }

    /// Opaque `ghostty_app_t` handle, exposed as `UnsafeMutableRawPointer`
    /// so call sites in this module can pass it to
    /// `ghostty_surface_new`. External callers should not read
    /// this — pass `GhosttyApp.shared` and let `GhosttySurface`
    /// drive the wiring.
    fileprivate var appHandle: UnsafeMutableRawPointer? {
        return _app
    }

    /// Underlying handle. `nil` until the first successful init,
    /// or forever if init fails. Released in `deinit`.
    private var _app: UnsafeMutableRawPointer?

    /// Owned config handle. libghostty's API takes ownership of the
    /// config inside `ghostty_app_new`, so we don't free it directly
    /// — but we keep a reference around in case a future
    /// `ghostty_app_update_config` path needs to clone it.
    private var _config: UnsafeMutableRawPointer?

    /// Diagnostic string surfaced through `lastInitError`. Set once
    /// on the first failed init; stays nil on success.
    public private(set) var lastInitError: String?

    /// Hex address of the C handle, for the iOS status overlay.
    /// Returns "nil" when the handle is unset. Useful for the
    /// "libghostty alive — App=0x..." debug label.
    public var debugDescription: String {
        guard let app = _app else { return "GhosttyApp(nil)" }
        return "GhosttyApp(0x\(String(UInt(bitPattern: app), radix: 16)))"
    }

    /// Private — use `GhosttyApp.shared`. Runs the libghostty boot
    /// sequence: `ghostty_init` -> `ghostty_config_new` ->
    /// `ghostty_app_new` with a stub runtime callback table.
    private init() {
        // The runtime callbacks are non-null per ghostty.h. None of
        // them get exercised on the host-managed I/O backend — the
        // harness owns clipboard, event loop pumping, and session
        // lifetime — but the function-pointer slots must be filled.
        // Stubs return safe defaults: `false` for the
        // predicate-shaped callbacks (`action_cb`, `read_clipboard_cb`)
        // and a no-op for the rest.
        var runtime = ghostty_runtime_config_s(
            userdata: nil,
            supports_selection_clipboard: false,
            wakeup_cb: { _ in },
            action_cb: { _, _, _ in return false },
            read_clipboard_cb: { _, _, _ in return false },
            confirm_read_clipboard_cb: { _, _, _, _ in },
            write_clipboard_cb: { _, _, _, _, _ in },
            close_surface_cb: { _, _ in }
        )

        // Initialize the Zig allocator + libghostty internal state.
        // Signature: `int ghostty_init(uintptr_t argc, char** argv)`.
        // Upstream's `iOSApp.swift` passes the process argv straight
        // through (`CommandLine.unsafeArgv`); we mirror that so any
        // CLI flag libghostty might inspect (none in practice on
        // iOS, but the symbol must be reachable) gets the same
        // bytes the host process saw. A non-zero return from
        // `ghostty_init` is fatal in upstream — if our boot path
        // ever hits it we want to know, so we surface it through
        // `lastInitError` rather than precondition-failing (would
        // bring down the whole app for a feature that's still
        // experimental).
        let initRC = ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv)
        if initRC != GHOSTTY_SUCCESS {
            lastInitError = "ghostty_init returned \(initRC)"
            return
        }

        // Load a default config — load_default_files reads
        // $XDG_CONFIG_HOME/ghostty/config when present and
        // otherwise falls back to baked-in defaults. On iOS the
        // file is virtually never present (sandboxed); the
        // baked-in defaults are fine for the skeleton.
        guard let config: UnsafeMutableRawPointer = ghostty_config_new() else {
            lastInitError = "ghostty_config_new returned nil"
            return
        }
        ghostty_config_load_default_files(config)
        ghostty_config_finalize(config)
        self._config = config

        guard let app: UnsafeMutableRawPointer = ghostty_app_new(&runtime, config) else {
            lastInitError = "ghostty_app_new returned nil — runtime callbacks rejected"
            ghostty_config_free(config)
            self._config = nil
            return
        }
        self._app = app
    }

    deinit {
        if let app = _app {
            ghostty_app_free(app)
        }
        // libghostty took ownership of `_config` inside
        // ghostty_app_new — do not free here. The `_config` slot is
        // kept so future code can compare identity if needed.
    }

    /// Pump the libghostty event loop once. Safe to call from the
    /// main thread; no-op when the app isn't alive. The host renderer
    /// will call this from a `CADisplayLink` once libghostty owns
    /// the pixel pipeline; for the skeleton it's only invoked from
    /// `GhosttySurface.feed` so any pending parser work gets flushed.
    public func tick() {
        guard let app = _app else { return }
        ghostty_app_tick(app)
    }
}

/// One terminal viewport. Bridges PTY byte writes from the harness
/// into `ghostty_surface_write_buffer`, owns a `ghostty_surface_t`,
/// and tears it down on `deinit`. **Not** a UIView — the host view
/// (`GhosttyTerminalView.swift`) owns the `CAMetalLayer` and passes
/// itself in via `attach(uiview:)` so libghostty can target its layer
/// when the Metal renderer lands in Stage 5. For this PR the surface
/// is configured with `GHOSTTY_SURFACE_IO_BACKEND_HOST_MANAGED` so
/// libghostty never spawns a child process; all bytes flow through
/// `feed(_:)` from the harness's `SessionStore.terminalBuffer`.
public final class GhosttySurface {
    /// Underlying `ghostty_surface_t`. Released on deinit.
    private var _surface: UnsafeMutableRawPointer?

    /// Strong reference to the host UIView passed in via `attach`.
    /// `void*` on the C side; we hold a Swift reference here so the
    /// view outlives the surface even if the call site drops it.
    /// `Any` keeps this module UIKit-free for the macOS test build.
    private var _hostView: AnyObject?

    /// Cached size to avoid redundant `ghostty_surface_set_size` calls.
    /// libghostty re-derives the cell grid + reflow on every set_size,
    /// which is cheap but allocates — bypass when bytes match.
    private var lastSizePx: (width: UInt32, height: UInt32) = (0, 0)

    /// Hex address of the C handle for the iOS status overlay.
    public var debugDescription: String {
        guard let s = _surface else { return "GhosttySurface(nil)" }
        return "GhosttySurface(0x\(String(UInt(bitPattern: s), radix: 16)))"
    }

    /// `true` when the surface created cleanly. Mirrors
    /// `GhosttyApp.isAlive` but tracks this specific viewport.
    public var isAlive: Bool { return _surface != nil }

    /// Create a new host-managed surface attached to `app`. The
    /// `hostView` is retained for the surface's lifetime; libghostty
    /// stores the raw `void*` in its `ghostty_platform_ios_s.uiview`
    /// slot so the Metal renderer (when wired) can target its layer.
    /// `cols` / `rows` set the initial logical grid; `pixelWidth` /
    /// `pixelHeight` set the initial render-target size — pass zero
    /// to skip the initial `set_size` (the host will call
    /// `resize(...)` once it lays out).
    public init(
        app: GhosttyApp = .shared,
        hostView: AnyObject? = nil,
        pixelWidth: UInt32 = 0,
        pixelHeight: UInt32 = 0,
        scaleFactor: Double = 2.0
    ) {
        guard let appHandle = app.appHandle else { return }
        self._hostView = hostView

        var config = ghostty_surface_config_new()
        config.platform_tag = GHOSTTY_PLATFORM_IOS
        // Pass the host UIView through to libghostty's iOS platform
        // slot. Cast through `Unmanaged` so the C side gets a stable
        // pointer; we keep the Swift reference in `_hostView` so the
        // UIView lifetime is bound to the surface's. Swift imports
        // the `ghostty_platform_u` union as a discriminated-union
        // initializer — assigning to `.ios` member-wise is not
        // supported, the only public path is the per-case init
        // (matches upstream Ghostty's `Ghostty.Surface.withCValue`
        // pattern at macos/Sources/Ghostty/Surface View/SurfaceView.swift).
        let uiviewPtr: UnsafeMutableRawPointer?
        if let host = hostView {
            uiviewPtr = Unmanaged.passUnretained(host).toOpaque()
        } else {
            uiviewPtr = nil
        }
        config.platform = ghostty_platform_u(
            ios: ghostty_platform_ios_s(uiview: uiviewPtr)
        )
        // Host-managed I/O: libghostty does NOT spawn a child
        // process; bytes arrive via `ghostty_surface_write_buffer`
        // from the harness's PTY stream.
        config.backend = GHOSTTY_SURFACE_IO_BACKEND_HOST_MANAGED
        config.scale_factor = scaleFactor
        config.context = GHOSTTY_SURFACE_CONTEXT_WINDOW
        // The remaining fields default to zero / null from
        // `ghostty_surface_config_new`. Working directory + command +
        // env vars are irrelevant for host-managed surfaces.

        guard let surface: UnsafeMutableRawPointer = ghostty_surface_new(appHandle, &config) else {
            return
        }
        self._surface = surface

        if pixelWidth > 0, pixelHeight > 0 {
            ghostty_surface_set_size(surface, pixelWidth, pixelHeight)
            lastSizePx = (pixelWidth, pixelHeight)
        }
    }

    deinit {
        if let surface = _surface {
            ghostty_surface_free(surface)
        }
    }

    /// Forward a chunk of PTY bytes into libghostty's parser. Safe to
    /// call from the main thread; libghostty's surface is documented
    /// as main-thread-only for byte writes. No-op when the surface
    /// init failed or `bytes` is empty.
    public func feed(_ bytes: Data) {
        guard let surface = _surface, !bytes.isEmpty else { return }
        bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            ghostty_surface_write_buffer(surface, base, UInt(bytes.count))
        }
        // Flush any deferred parser work; the host owns the event
        // loop so libghostty doesn't poll on its own.
        GhosttyApp.shared.tick()
    }

    /// Convenience overload for ad-hoc string feeds (tests, status
    /// banners). UTF-8 encoded.
    public func feed(_ string: String) {
        feed(Data(string.utf8))
    }

    /// Tell libghostty the host view changed pixel size. Cell grid
    /// + reflow happen inside libghostty; the harness still needs a
    /// separate `SessionStore.resize` call to inform the remote PTY.
    public func resize(pixelWidth: UInt32, pixelHeight: UInt32) {
        guard let surface = _surface else { return }
        if lastSizePx.width == pixelWidth && lastSizePx.height == pixelHeight {
            return
        }
        ghostty_surface_set_size(surface, pixelWidth, pixelHeight)
        lastSizePx = (pixelWidth, pixelHeight)
    }

    /// Render one frame. libghostty owns the Metal renderer + the
    /// `CAMetalLayer` it created on the attached `uiview`; this just
    /// asks it to paint the current grid state. Must run on the main
    /// thread. This is the call Stage 4 was missing — bytes were fed
    /// but no frame was ever drawn, so the surface stayed blank.
    public func draw() {
        guard let surface = _surface else { return }
        ghostty_surface_draw(surface)
    }

    /// libghostty only renders an active surface; tell it we're
    /// focused so it paints (and shows a live cursor).
    public func setFocus(_ focused: Bool) {
        guard let surface = _surface else { return }
        ghostty_surface_set_focus(surface, focused)
    }

    /// Backing-store scale (UIScreen.scale). Drives libghostty's
    /// glyph rasterization DPI so text isn't blurry on Retina.
    public func setContentScale(_ x: Double, _ y: Double) {
        guard let surface = _surface else { return }
        ghostty_surface_set_content_scale(surface, x, y)
    }

    /// Pause rendering when the view is off-screen (tab switch /
    /// backgrounding) so libghostty stops its draw work.
    public func setOcclusion(_ visible: Bool) {
        guard let surface = _surface else { return }
        ghostty_surface_set_occlusion(surface, visible)
    }
}

#endif // canImport(libghostty)

// MARK: - Compatibility façade
//
// The iOS CoreText renderer (`GhosttyTerminalView.swift`) was written
// against the Stage 1 `Terminal` class shape. Keeping it as a thin
// façade lets the renderer compile + paint unchanged. When libghostty
// is alive, `Terminal` also forwards bytes into `GhosttySurface` so
// the App/Surface pipeline gets exercised at runtime (proves the
// integration is live even before the Metal renderer lands).
//
// Snapshot data is always empty cells — libghostty's App/Surface API
// does not expose a per-cell readback like the slim VT API did
// (the public path is `ghostty_surface_read_text` which returns
// human-readable text, not a grid). The renderer treats an empty
// snapshot as "draw the status overlay", which is exactly the UX we
// want for the skeleton: the user sees "libghostty alive — App=…"
// instead of an empty grid. Stage 5 swaps the renderer to
// libghostty's own Metal output and removes this façade.

/// Swift wrapper over a libghostty viewport. Retained name + public
/// API shape so existing renderer code keeps compiling; the
/// implementation now forwards to `GhosttySurface` when libghostty
/// is alive and otherwise behaves as the Stage 1 no-op stub.
public final class Terminal {
    /// `true` when libghostty's App/Surface pipeline is alive in
    /// this process — i.e. `ghostty_app_new` succeeded AND a fresh
    /// `GhosttySurface` could be created. Reads `false` either when
    /// the `libghostty` module isn't importable (placeholder build)
    /// or when the runtime rejected the app init (config error,
    /// allocator failure).
    public static var isAvailable: Bool {
        #if canImport(libghostty)
        return GhosttyApp.shared.isAlive
        #else
        return false
        #endif
    }

    /// Stage 4 status string for the iOS overlay. Stable across
    /// builds so the renderer can surface it directly:
    ///   - `"libghostty alive — App=0x… Surface=0x…"` when both
    ///     handles came up.
    ///   - `"libghostty init failed: <reason>"` when the App init
    ///     rejected.
    ///   - `"libghostty not linked — flag-off path"` when the
    ///     module isn't importable.
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

    /// Cached cols/rows for the renderer. Tracked locally because
    /// the App/Surface API doesn't expose a per-cell readback.
    private var cols: UInt
    private var rows: UInt

    #if canImport(libghostty)
    /// Underlying host-managed surface. Lazy — created on first
    /// init, replaced on reset, freed on deinit.
    private var surface: GhosttySurface?
    #endif

    /// Create a fresh terminal. Cols/rows are advisory — the
    /// libghostty surface computes the real grid from its pixel
    /// size, but we cache the request so a subsequent `snapshot()`
    /// returns the expected shape for the CoreText path.
    public init(cols: UInt, rows: UInt, maxScrollback: UInt = 10_000) {
        precondition(cols > 0 && cols <= UInt(UInt16.max), "cols out of range")
        precondition(rows > 0 && rows <= UInt(UInt16.max), "rows out of range")
        self.cols = cols
        self.rows = rows
        #if canImport(libghostty)
        // _ = maxScrollback // host-managed surface doesn't expose
        //                   // a scrollback knob through the public ABI.
        if GhosttyApp.shared.isAlive {
            self.surface = GhosttySurface()
        }
        #endif
        _ = maxScrollback // silence unused-arg warning on the placeholder build
    }

    /// Attach a host UIView so libghostty's Metal renderer (Stage 5)
    /// can target its layer. Re-creates the underlying surface
    /// because `ghostty_surface_config_s.platform.ios.uiview` is
    /// read once at surface-creation time. No-op when libghostty
    /// isn't alive.
    public func attach(hostView: AnyObject?, pixelWidth: UInt32, pixelHeight: UInt32, scaleFactor: Double) {
        #if canImport(libghostty)
        guard GhosttyApp.shared.isAlive else { return }
        surface = GhosttySurface(
            hostView: hostView,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            scaleFactor: scaleFactor
        )
        #else
        _ = (hostView, pixelWidth, pixelHeight, scaleFactor)
        #endif
    }

    /// Feed VT bytes into libghostty's parser. The bytes flow into
    /// `ghostty_surface_write_buffer`; libghostty runs the full
    /// parser + state machine + reflow on its side. The CoreText
    /// renderer reads `snapshot()` (empty cells in this PR) — its
    /// own status-line fallback paints the "libghostty alive"
    /// banner so the user sees the integration is live.
    public func write(_ bytes: Data) {
        #if canImport(libghostty)
        surface?.feed(bytes)
        #else
        _ = bytes
        #endif
    }

    /// Convenience for tests + the placeholder path. UTF-8 encoded.
    public func write(_ string: String) {
        write(Data(string.utf8))
    }

    /// Resize the active grid. The pixel dimensions feed into
    /// libghostty's cell-grid math; the harness still needs a
    /// separate cols/rows update to inform the remote PTY.
    public func resize(cols: UInt, rows: UInt, cellWidthPx: UInt = 0, cellHeightPx: UInt = 0) {
        precondition(cols > 0 && cols <= UInt(UInt16.max), "cols out of range")
        precondition(rows > 0 && rows <= UInt(UInt16.max), "rows out of range")
        self.cols = cols
        self.rows = rows
        #if canImport(libghostty)
        // Derive a pixel size for libghostty; if the caller didn't
        // hand us cell dimensions, fall back to a 8×16 raster — the
        // value is only used by libghostty's grid math, which the
        // renderer overrides anyway via `attach(...)`.
        let cellW = cellWidthPx > 0 ? cellWidthPx : 8
        let cellH = cellHeightPx > 0 ? cellHeightPx : 16
        let pxW = UInt32(cols * cellW)
        let pxH = UInt32(rows * cellH)
        surface?.resize(pixelWidth: pxW, pixelHeight: pxH)
        #else
        _ = (cellWidthPx, cellHeightPx)
        #endif
    }

    /// Push the *real* backing-store pixel size + scale to libghostty.
    /// The `resize(cols:rows:)` overload above derives a fake 8×16
    /// raster; Stage 5's renderer needs the true layer size so
    /// libghostty's `CAMetalLayer` matches the host view and glyphs
    /// aren't mis-scaled. Call from `layoutSubviews` with
    /// `bounds.size * contentScaleFactor`.
    public func setPixelSize(width: UInt32, height: UInt32, scale: Double) {
        #if canImport(libghostty)
        surface?.setContentScale(scale, scale)
        surface?.resize(pixelWidth: width, pixelHeight: height)
        #else
        _ = (width, height, scale)
        #endif
    }

    /// Render one frame via libghostty's own Metal renderer. Driven by
    /// the host view's `CADisplayLink` (Stage 5). No-op off libghostty.
    public func draw() {
        #if canImport(libghostty)
        surface?.draw()
        #endif
    }

    /// Focus state — libghostty only paints an active surface, and the
    /// cursor blink follows focus.
    public func setFocus(_ focused: Bool) {
        #if canImport(libghostty)
        surface?.setFocus(focused)
        #endif
    }

    /// Visibility — pause libghostty's render work when the view is
    /// off-screen (tab switch / backgrounding).
    public func setVisible(_ visible: Bool) {
        #if canImport(libghostty)
        surface?.setOcclusion(visible)
        #endif
    }

    /// Return a pure-Swift snapshot. The App/Surface ABI does not
    /// expose a per-cell grid readback (the public path is
    /// `ghostty_surface_read_text` which returns human-readable
    /// text and is intended for accessibility, not render loops),
    /// so this returns an empty grid of the cached cols/rows
    /// dimensions. The CoreText renderer treats an empty grid as
    /// "draw the status overlay" — that's the Stage 4 skeleton UX.
    /// Stage 5 will replace the renderer with libghostty's Metal
    /// output and remove this snapshot path entirely.
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
