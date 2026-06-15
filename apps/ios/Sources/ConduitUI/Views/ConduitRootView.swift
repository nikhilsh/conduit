import SwiftUI

// MARK: - ConduitRootView
//
// Top-level shell for the ConduitUI tree — the single production root
// after the upstream-ui-cutover (PR #119 deleted the legacy `RootView`
// + its dependents).
//
// We branch on `horizontalSizeClass`:
//   - `.compact` (iPhone): the existing iPhone surface
//     (`ConduitUI.HomeView`, which owns its own `NavigationStack`
//     + bottom action bar).
//   - `.regular` (iPad / large screen): `NavigationSplitView` with a
//     `ConduitUI.SessionsRail` sidebar + `ConduitUI.ProjectView`
//     detail. Empty detail when nothing's selected.
//
// Per PLAN-CONDUIT-UI Decisions row 3: iPad keeps NavigationSplitView,
// the iPhone bottom bar is iPhone-shape only. The rail is the
// sidebar variant of HomeView (no bottom bar; sessions tap drives
// `SessionStore.switchTo(sessionID:)` which the detail observes).

extension ConduitUI {

    struct RootView: View {
        @Environment(\.horizontalSizeClass) private var horizontalSizeClass
        @Environment(SessionStore.self) private var store
        @Environment(FeatureFlags.self) private var flags

        /// Set true when the user explicitly finishes onboarding, so a paired
        /// session doesn't snap back into the wizard on the same launch.
        @State private var onboardingFinished = false

        /// When true the AnimatedSplashView overlay is still covering the window.
        /// Onboarding is suppressed while the splash is active so the fullScreenCover
        /// doesn't race the splash and appear behind / over it (window-level cover
        /// sits above the zIndex-1 splash overlay). Defaults false so existing
        /// RootView() call sites and previews compile without change.
        var splashActive: Bool = false

        /// Onboarding gate (§5): show the wizard whenever this DEVICE holds no
        /// pairing key for any broker. No accounts / sign-in — trust is the
        /// device↔broker pairing handshake, so `savedServers` (the brokers
        /// this device is paired with) is the only signal. Once one is paired
        /// the route flips to `.none` and the cover dismisses; an unreachable
        /// paired broker is Home + offline banner, never re-onboarding.
        private var needsOnboarding: Bool {
            // Hold off until the splash finishes — a fullScreenCover presented
            // while the splash overlay is still visible appears above/behind it
            // and causes a visible sequencing glitch on fresh install.
            guard !splashActive else { return false }
            guard !onboardingFinished else { return false }
            let route = FeatureFlags.onboardingRoute(
                pairedBrokers: store.savedServers.count,
                brokerReachable: store.harness.canIssueCommands
            )
            return route != .none
        }

        var body: some View {
            ZStack {
                ConduitUI.Palette.surface.color
                    // `.container` (not a bare ignore) so the root canvas never
                    // claims the `.keyboard` region — see GlassAppBackground.
                    .ignoresSafeArea(.container, edges: .all)
                if horizontalSizeClass == .regular {
                    TabletShell()
                } else {
                    ConduitUI.HomeView()
                }
            }
            .fullScreenCover(isPresented: Binding(
                get: { needsOnboarding },
                set: { if !$0 { onboardingFinished = true } }
            )) {
                ConduitUI.OnboardingView(onFinish: { onboardingFinished = true })
                    .environment(store)
                    .environment(flags)
            }
        }
    }

    // MARK: - TabletShell (iPad / regular size class)
    //
    // The design's tablet IDE chrome (tablet.jsx → TabletSessionView):
    // a unified left rail + the session detail. Navigation that used to
    // live in a separate icon "activity bar" (Home / History / Boxes /
    // Settings) now folds into `ConduitUI.SessionsRail` — the shell is
    // just the sessions split. Mirrors the Android `AppRoot` +
    // `NeonTabletRail` rework.

    fileprivate struct TabletShell: View {
        @Environment(SessionStore.self) private var store
        @Environment(\.neonTheme) private var neon

        var body: some View {
            @Bindable var store = store
            return NavigationSplitView {
                ConduitUI.SessionsRail()
                    .navigationSplitViewColumnWidth(min: 256, ideal: 272, max: 320)
                    .toolbar(.hidden, for: .navigationBar)
            } detail: {
                if let id = store.selectedSessionID,
                   let session = store.sessions.first(where: { $0.id == id }) {
                    // Tablet 3-pane (design's TabletSessionView): chat-only
                    // centre + a right pane with Terminal / Browser / Info
                    // tabs. ProjectView(chatOnly:) drops its own tab strip;
                    // the right pane reuses the same terminal/browser/info
                    // surfaces. Phone uses ProjectView's full tabs (chatOnly
                    // defaults false).
                    HStack(spacing: 0) {
                        ConduitUI.ProjectView(session: session, chatOnly: true)
                            // Keying on session id forces SwiftUI to
                            // discard the previous detail's `@State`
                            // when the user picks a different session.
                            .id(session.id)
                        Divider().background(neon.border)
                        ConduitUI.TabletRightPane(session: session)
                            .frame(width: 392)
                            .id(session.id)
                    }
                } else {
                    ConduitUI.EmptyDetail()
                }
            }
            .neonAccentTint()
            // Same navigation-container keyboard opt-out as HomeView's
            // NavigationStack (see the comment there): the split view's
            // hosting layer otherwise shifts the detail — and its right-pane
            // terminal — when the soft keyboard appears. All tablet editors
            // manual-lift or live in sheets, so nothing depends on the
            // implicit avoidance this removes.
            .ignoresSafeArea(.keyboard, edges: .bottom)
        }
    }
}
