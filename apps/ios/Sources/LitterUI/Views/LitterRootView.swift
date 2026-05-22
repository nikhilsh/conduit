import SwiftUI

// MARK: - LitterRootView
//
// Top-level shell for the LitterUI tree — the single production root
// after the litter-ui-cutover (PR #119 deleted the legacy `RootView`
// + its dependents).
//
// We branch on `horizontalSizeClass`:
//   - `.compact` (iPhone): the existing iPhone surface
//     (`LitterUI.HomeView`, which owns its own `NavigationStack`
//     + bottom action bar).
//   - `.regular` (iPad / large screen): `NavigationSplitView` with a
//     `LitterUI.SessionsRail` sidebar + `LitterUI.ProjectView`
//     detail. Empty detail when nothing's selected.
//
// Per PLAN-LITTER-UI Decisions row 3: iPad keeps NavigationSplitView,
// the iPhone bottom bar is iPhone-shape only. The rail is the
// sidebar variant of HomeView (no bottom bar; sessions tap drives
// `SessionStore.switchTo(sessionID:)` which the detail observes).

extension LitterUI {

    struct RootView: View {
        @Environment(\.horizontalSizeClass) private var horizontalSizeClass

        var body: some View {
            ZStack {
                LitterUI.Palette.surface.color
                    .ignoresSafeArea()
                if horizontalSizeClass == .regular {
                    SplitView()
                } else {
                    LitterUI.HomeView()
                }
            }
        }
    }

    // MARK: - SplitView (iPad / regular size class)

    fileprivate struct SplitView: View {
        @Environment(SessionStore.self) private var store

        var body: some View {
            @Bindable var store = store

            NavigationSplitView {
                LitterUI.SessionsRail()
                    .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 360)
                    .toolbar(.hidden, for: .navigationBar)
            } detail: {
                if let id = store.selectedSessionID,
                   let session = store.sessions.first(where: { $0.id == id }) {
                    LitterUI.ProjectView(session: session)
                        // Keying on session id forces SwiftUI to
                        // discard the previous detail's `@State`
                        // (e.g. selected tab) when the user picks a
                        // different session — otherwise the new
                        // session inherits the prior one's tab and
                        // header animation state.
                        .id(session.id)
                } else {
                    LitterUI.EmptyDetail()
                }
            }
            .tint(LitterUI.Palette.brand.color)
        }
    }
}
