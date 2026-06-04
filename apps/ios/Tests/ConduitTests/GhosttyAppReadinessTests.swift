import Testing
import GhosttyVT

/// Stage 1 of the native-terminal rebuild. Building the `GhosttyApp` singleton
/// runs `ghostty_init` + `ghostty_app_new` headlessly (no surface, no window).
/// On the simulator with `libghostty` linked, reaching `.ready` is the proof the
/// App-init lifecycle is wired correctly — real runtime callbacks (wakeup/action/
/// clipboard/close), not the old no-op stubs that shipped a blank terminal.
///
/// Mirrors the `GhosttyAppTests` shape from the geistty / clauntty reference apps.
@Suite("GhosttyApp readiness")
struct GhosttyAppReadinessTests {
    @Test func appInitializesToReady() {
        #expect(GhosttyApp.shared.readiness == .ready)
    }

    @Test func setFocusIsSafeWithoutSurfaces() {
        // Focus toggles drive `ghostty_app_set_focus`; they must be safe to call
        // before any surface exists and must not regress readiness.
        GhosttyApp.shared.setFocus(true)
        GhosttyApp.shared.setFocus(false)
        #expect(GhosttyApp.shared.readiness == .ready)
    }
}
