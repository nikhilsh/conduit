import Foundation
import os.log

#if canImport(UIKit)
import UIKit
#endif

#if canImport(libghostty)
import libghostty
#endif

// Process-wide libghostty application singleton.
//
// Stage 1 of the native-terminal rebuild (see `docs/GHOSTTY-REFERENCES.md`). A
// faithful port of the App-init lifecycle from the working iOS reference apps
// `eriklangille/clauntty` (`GhosttyApp.swift`) and `daiimus/geistty`
// (`Ghostty.App.swift`), pinned to OUR ABI (the `libghostty` module from
// `Lakr233/libghostty-spm` `storage.1.2.2`). Handle typedefs are `void*`, so they
// import as `UnsafeMutableRawPointer?`; our `read_clipboard_cb` returns `bool`.
//
// libghostty is event-driven: it asks the host to pump its loop via `wakeup_cb`
// and emits frames/state via `action_cb`. Wiring these as REAL callbacks (not
// no-op stubs) is what makes the renderer engage — the old Stage-4 skeleton
// stubbed them and shipped a permanently blank terminal.
//
// `GhosttySurface` (Stage 2) holds the per-terminal `ghostty_surface_t`; this
// owns the single `ghostty_app_t` they share. `shared` is created lazily on
// first access (Swift runs a `static let` initializer exactly once — that is our
// single-`ghostty_init` guard), and that first access is the first terminal
// mount, on the main thread.
public final class GhosttyApp {
    public enum Readiness: String {
        case loading, error, ready
    }

    public static let shared = GhosttyApp()

    /// `.ready` once `ghostty_app_new` has returned a live app. Stage 2 refuses
    /// to create a surface unless this is `.ready`.
    public private(set) var readiness: Readiness = .loading

    private static let log = Logger(subsystem: "sh.conduit.ghostty", category: "app")

    #if canImport(libghostty)
    /// Opaque `ghostty_app_t` (`void*` → `UnsafeMutableRawPointer?`). Stage 2's
    /// surface creation reads this via `appHandle`.
    private var app: UnsafeMutableRawPointer?

    /// The live app handle, or nil if init failed. Used by `GhosttySurface`.
    public var appHandle: UnsafeMutableRawPointer? { app }

    private init() {
        Self.log.info("GhosttyApp init: starting libghostty bring-up")

        // libghostty resolves bundled themes / resources relative to this dir.
        // geistty sets it to the app bundle before `ghostty_init`; without it,
        // config theme lookups silently fall back to compiled-in defaults.
        setenv("GHOSTTY_RESOURCES_DIR", Bundle.main.bundlePath, 1)

        // One-time process init (the `static let shared` guarantee makes this
        // run once; the return code is the real gate).
        let initRC = ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv)
        guard initRC == GHOSTTY_SUCCESS else {
            Self.log.error("ghostty_init failed (rc=\(initRC))")
            readiness = .error
            return
        }

        guard let config: UnsafeMutableRawPointer = ghostty_config_new() else {
            Self.log.error("ghostty_config_new failed")
            readiness = .error
            return
        }
        // No iOS-side config files to load (no ~/.config/ghostty on device);
        // surfaces set their own font-size / color-scheme in Stage 2.
        ghostty_config_finalize(config)

        // Real runtime callbacks. C function pointers can't capture context, so
        // each round-trips through `userdata` (this instance) and the static
        // trampolines below. Field order matches `ghostty_runtime_config_s`.
        var runtime = ghostty_runtime_config_s(
            userdata: Unmanaged.passUnretained(self).toOpaque(),
            supports_selection_clipboard: false, // iOS has no selection clipboard
            wakeup_cb: { userdata in GhosttyApp.wakeup(userdata) },
            action_cb: { app, target, action in
                GhosttyApp.action(app, target: target, action: action)
            },
            read_clipboard_cb: { userdata, loc, state in
                GhosttyApp.readClipboard(userdata, location: loc, state: state)
            },
            confirm_read_clipboard_cb: { userdata, str, state, request in
                GhosttyApp.confirmReadClipboard(userdata, string: str, state: state, request: request)
            },
            write_clipboard_cb: { userdata, loc, content, len, confirm in
                GhosttyApp.writeClipboard(userdata, location: loc, content: content, len: len, confirm: confirm)
            },
            close_surface_cb: { userdata, processAlive in
                GhosttyApp.closeSurface(userdata, processAlive: processAlive)
            }
        )

        // libghostty takes ownership of `config` inside `ghostty_app_new` — do
        // NOT free it ourselves (the old wrapper documented this; freeing it
        // again is a double-free).
        guard let app: UnsafeMutableRawPointer = ghostty_app_new(&runtime, config) else {
            Self.log.error("ghostty_app_new failed")
            ghostty_config_free(config) // app_new didn't take it on the nil path
            readiness = .error
            return
        }
        self.app = app

        // App-level scheme is a default; each surface sets its own in Stage 2.
        // Kept off main-only UIKit APIs (UITraitCollection) so the unit test can
        // build the singleton without tripping the Main Thread Checker.
        ghostty_app_set_color_scheme(app, GHOSTTY_COLOR_SCHEME_DARK)

        readiness = .ready
        Self.log.info("GhosttyApp init: ready")
    }

    deinit {
        // Singleton lives for the whole process; this is a backstop. libghostty
        // owns `config`, so only the app is freed.
        if let app { ghostty_app_free(app) }
    }

    /// Drive one turn of libghostty's event loop. Called from `wakeup`, always
    /// on the main thread.
    func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
    }

    /// Reflect app foreground/background to libghostty.
    public func setFocus(_ focused: Bool) {
        guard let app else { return }
        ghostty_app_set_focus(app, focused)
    }

    // MARK: - Static C trampolines

    /// libghostty (renderer thread) asks the host to pump its loop. Hop to main
    /// and tick — `ghostty_app_tick` must run on the thread that owns the app.
    private static func wakeup(_ userdata: UnsafeMutableRawPointer?) {
        DispatchQueue.main.async {
            guard let userdata else { return }
            let app = Unmanaged<GhosttyApp>.fromOpaque(userdata).takeUnretainedValue()
            app.tick()
        }
    }

    /// libghostty emits state changes (render, title, bell, …) here. Stage 1 has
    /// no surfaces, so surface-targeted actions are logged and declined; Stage 2
    /// routes them to the owning `GhosttySurface` via a pointer registry.
    private static func action(
        _ app: UnsafeMutableRawPointer?,
        target: ghostty_target_s,
        action: ghostty_action_s
    ) -> Bool {
        switch action.tag {
        case GHOSTTY_ACTION_RENDER:
            // Rendering is pulled by the CADisplayLink draw pump (Stage 2);
            // nothing to do here, but acknowledge it.
            return true
        default:
            log.debug("unhandled ghostty action tag=\(action.tag.rawValue)")
            return false
        }
    }

    /// Paste request from a TUI app. Our ABI's `read_clipboard_cb` returns `bool`.
    /// Completing a paste needs the requesting surface (Stage 2 wires
    /// `ghostty_surface_complete_clipboard_request`); decline for now.
    private static func readClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        state: UnsafeMutableRawPointer?
    ) -> Bool {
        return false
    }

    private static func confirmReadClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        string: UnsafePointer<CChar>?,
        state: UnsafeMutableRawPointer?,
        request: ghostty_clipboard_request_e
    ) {
        // iOS auto-confirms; no security prompt.
    }

    /// OSC 52 / copy from a TUI app → iOS pasteboard. Needs no surface, so it
    /// works already in Stage 1.
    private static func writeClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        content: UnsafePointer<ghostty_clipboard_content_s>?,
        len: Int,
        confirm: Bool
    ) {
        guard let content, len > 0 else { return }
        #if canImport(UIKit)
        for i in 0..<len {
            let item = content[i]
            guard let mime = item.mime, String(cString: mime) == "text/plain",
                  let data = item.data else { continue }
            UIPasteboard.general.string = String(cString: data)
            break
        }
        #endif
    }

    private static func closeSurface(_ userdata: UnsafeMutableRawPointer?, processAlive: Bool) {
        log.debug("close_surface (processAlive=\(processAlive))")
    }

    #else
    // libghostty unavailable (non-iOS toolchain). The type still exists so the
    // app/tests compile; readiness is `.error`.
    private init() {
        readiness = .error
        Self.log.error("libghostty not available — GhosttyApp is inert")
    }
    public func setFocus(_ focused: Bool) {}
    #endif
}
