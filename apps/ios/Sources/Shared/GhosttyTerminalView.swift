import SwiftUI

// Stage 0 placeholder for the native Ghostty (libghostty) terminal.
//
// The previous 1,836-line implementation was torn down in the clean-slate
// rebuild (see `docs/GHOSTTY-REFERENCES.md` and the rebuild plan): it crashed
// with a cascade of CoreAnimation-commit use-after-frees and carried a
// double-emulator query-response echo. This stub keeps the app compiling and
// the Terminal tab resolvable while the new App-singleton + surface lifecycle
// are built up in Stages 1–5, faithfully ported from the geistty / clauntty
// reference apps.
//
// `GhosttyTerminalTab` is the only symbol the rest of the app depends on
// (mounted by `ConduitProjectView` / `ConduitTabletRightPane`). It is rewritten
// into a real `UIViewRepresentable` + `GhosttySurfaceView` host in Stage 2.
struct GhosttyTerminalTab: View {
    let session: ProjectSession
    let isActive: Bool

    var body: some View {
        // Opaque black surface — the rebuilt libghostty renderer paints here
        // starting in Stage 2.
        Color.black
            .ignoresSafeArea()
            .accessibilityIdentifier("ghostty-terminal-placeholder")
    }
}
