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
                    TabletShell()
                } else {
                    LitterUI.HomeView()
                }
            }
        }
    }

    // MARK: - TabletShell (iPad / regular size class)
    //
    // The design's tablet IDE chrome: a far-left activity bar +
    // section content. Home / Sessions render inline; History / Boxes /
    // Settings present as sheets (reusing the existing sheet views)
    // until they get dedicated tablet layouts. Section choice persists
    // under `nk_tab_section` (matches the prototype key).

    fileprivate struct TabletShell: View {
        @Environment(SessionStore.self) private var store
        @Environment(\.neonTheme) private var neon
        @AppStorage("nk_tab_section") private var sectionRaw =
            LitterUI.TabletSection.sessions.rawValue

        private var section: LitterUI.TabletSection {
            LitterUI.TabletSection(rawValue: sectionRaw) ?? .sessions
        }

        var body: some View {
            HStack(spacing: 0) {
                LitterUI.TabletActivityBar(section: section) { picked in
                    sectionRaw = picked.rawValue
                }
                sectionContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }

        @ViewBuilder private var sectionContent: some View {
            switch section {
            case .home:
                LitterUI.TabletHome { id in
                    store.selectedSessionID = id
                    sectionRaw = LitterUI.TabletSection.sessions.rawValue
                }
            case .settings:
                LitterUI.SettingsView(embedded: true)
            case .boxes:
                LitterUI.DiscoveryView(embedded: true)
            case .history:
                SessionSearchView(
                    onSelect: { id in
                        store.selectedSessionID = id
                        sectionRaw = LitterUI.TabletSection.sessions.rawValue
                    },
                    embedded: true
                )
            default:
                sessionsSplit
            }
        }

        private var sessionsSplit: some View {
            @Bindable var store = store
            return NavigationSplitView {
                LitterUI.SessionsRail()
                    .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 360)
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
                        LitterUI.ProjectView(session: session, chatOnly: true)
                            // Keying on session id forces SwiftUI to
                            // discard the previous detail's `@State`
                            // when the user picks a different session.
                            .id(session.id)
                        Divider().background(neon.border)
                        LitterUI.TabletRightPane(session: session)
                            .frame(width: 392)
                            .id(session.id)
                    }
                } else {
                    LitterUI.EmptyDetail()
                }
            }
            .neonAccentTint()
        }
    }
}
