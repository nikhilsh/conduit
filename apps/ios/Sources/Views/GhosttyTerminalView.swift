import SwiftUI
import UIKit

#if canImport(GhosttyVT)
import GhosttyVT
#endif

/// Stage 1 host for the future Ghostty-libghostty terminal view.
/// Mounted only when `AppearanceStore.experimentalNativeTerminal` is
/// on. See `docs/PLAN-TERMINAL-REWRITE.md` for the staging plan.
///
/// At Stage 1 we lock in the call-site shape and the SPM wiring: the
/// app imports `GhosttyVT`, instantiates a `Terminal` (`80x24`), and
/// renders a status surface that confirms the framework loaded. There
/// is still no PTY wiring, no input routing, and no glyph rendering —
/// the xterm.js path (`TerminalTabXterm`) remains the production view
/// and toggling the experimental flag off restores it.
///
/// The terminal object is held by `GhosttyPlaceholderView` so its
/// lifetime tracks the UIView; it is only constructed when
/// `Terminal.isAvailable` is true, so a stale-checksum SPM resolve
/// failure degrades to the same plain status label Stage 0 shipped.
struct GhosttyTerminalTab: View {
    // SessionStore is intentionally NOT bound yet. Stage 2 will add
    // `@Environment(SessionStore.self) private var store` here to
    // wire PTY bytes through `store.terminalBuffer[session.id]` and
    // `store.sendInput`, mirroring `TerminalTabXterm`'s shape. Stage
    // 1 only needs to prove the SPM binary target loads and the
    // wrapper API is callable.
    let session: ProjectSession

    var body: some View {
        GhosttyTerminalView(sessionID: session.id)
            // Match TerminalTabXterm's behavior: full-bleed under the
            // home-indicator inset, but the keyboard safe area still
            // pushes the surface up so the status message stays
            // visible while the toggle is being explored on-device.
            .ignoresSafeArea(.container, edges: .bottom)
    }
}

/// `UIViewRepresentable` wrapping a plain `UIView` that hosts the
/// Ghostty surface. As of Stage 1 the surface is still a placeholder
/// `UILabel`, but the underlying `GhosttyPlaceholderView` now holds
/// a live `GhosttyVT.Terminal` so the SPM binary target is exercised
/// at runtime. Stage 2 will replace the label with a real renderer
/// and forward keystrokes + PTY bytes through the held terminal.
struct GhosttyTerminalView: UIViewRepresentable {
    /// Forwarded so Stage 1 can hook up SessionStore by session ID
    /// without churn at the call site.
    let sessionID: String

    func makeUIView(context: Context) -> UIView {
        let container = GhosttyPlaceholderView(frame: .zero)
        container.backgroundColor = .black
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // No-op until Stage 1 wires PTY bytes through. The placeholder
        // label is static — there is nothing to refresh.
    }
}

/// Minimal placeholder body. Lives outside `GhosttyTerminalView` so
/// snapshot testing can instantiate it without standing up a SwiftUI
/// host. Renders a centered status line on a black background — the
/// same visual idiom Ghostty's macOS shell uses for the
/// `Ghostty.App.readiness` waiting state.
final class GhosttyPlaceholderView: UIView {
    private let label = UILabel()

    /// Stage 1 demonstrates integration by holding a live
    /// `GhosttyVT.Terminal` instance. The view does not yet render
    /// the terminal's grid (Stage 2 owns the renderer) — the only
    /// purpose of the live instance here is to prove the SPM wiring
    /// loaded and the C ABI is callable. The terminal is created
    /// only when the framework actually linked.
    #if canImport(GhosttyVT)
    private var terminal: Terminal?
    #endif

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    /// First responder so the iOS keyboard appears when the user taps
    /// the surface — Stage 1 still drops keystrokes on the floor;
    /// Stage 2 wires them through to `terminal?.write(...)`.
    override var canBecomeFirstResponder: Bool { true }

    /// Placeholder accessory bar slot. Stage 2 will replace this
    /// with `TerminalAccessoryBar()` shared with `WKTerminalView`.
    override var inputAccessoryView: UIView? { nil }

    private func configure() {
        backgroundColor = .black
        label.translatesAutoresizingMaskIntoConstraints = false

        let statusText: String
        #if canImport(GhosttyVT)
        if Terminal.isAvailable {
            // Construct the terminal so the SPM binary target is
            // actually exercised at runtime (not just at link time).
            // The instance is intentionally unused beyond this point
            // — Stage 1 is about proving the wiring compiles and
            // loads, not about rendering anything.
            let term = Terminal(cols: 80, rows: 24)
            term.write("ghostty-vt linked\n")
            self.terminal = term
            statusText = "GhosttyVT linked — see PLAN-TERMINAL-REWRITE Stage 1"
        } else {
            statusText = "GhosttyVT module unavailable — see PLAN-TERMINAL-REWRITE Stage 1"
        }
        #else
        statusText = "GhosttyVT not yet integrated — see PLAN-TERMINAL-REWRITE Stage 1"
        #endif

        label.text = statusText
        label.textColor = .white
        label.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        label.numberOfLines = 0
        label.textAlignment = .center
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
        ])

        // One-tap-to-focus, matches xterm.js view's keyboard summoning
        // (xterm.js calls focus() on tap; here we route through
        // becomeFirstResponder).
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        addGestureRecognizer(tap)
    }

    @objc private func handleTap() {
        _ = becomeFirstResponder()
    }
}
