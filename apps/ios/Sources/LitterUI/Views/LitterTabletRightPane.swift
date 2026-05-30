import SwiftUI

// MARK: - TabletRightPane
//
// The design bundle's tablet Sessions right pane (tablet.jsx →
// TabletRightPane): a Terminal / Browser / Info tab strip over the
// matching surface. Sits beside the chat-only `ProjectView(chatOnly:)`
// in the Sessions section so chat + terminal/browser/info are visible
// side-by-side (the full 3-pane). Reuses the exact same surfaces the
// phone uses as ProjectView tabs — `TerminalTabXterm` /
// `GhosttyTerminalTab`, `BrowserTab`, and the inline `SessionInfoView` —
// so there's no second renderer to maintain.

extension LitterUI {

    enum RightPaneTab: String, CaseIterable, Identifiable {
        case terminal
        case browser
        case info

        var id: String { rawValue }
        var label: String {
            switch self {
            case .terminal: return "Terminal"
            case .browser:  return "Browser"
            case .info:     return "Info"
            }
        }
        var systemImage: String {
            switch self {
            case .terminal: return "terminal"
            case .browser:  return "globe"
            case .info:     return "info.circle"
            }
        }
    }

    struct TabletRightPane: View {
        let session: ProjectSession
        @Environment(AppearanceStore.self) private var appearance
        @Environment(\.neonTheme) private var neon
        @State private var tab: RightPaneTab = .terminal

        var body: some View {
            VStack(spacing: 0) {
                HStack {
                    NeonSegmentedPill(
                        segments: RightPaneTab.allCases.map {
                            NeonSegmentedPill<RightPaneTab>.Segment(
                                id: $0, label: $0.label, systemImage: $0.systemImage
                            )
                        },
                        selection: $tab
                    )
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 8)

                Divider().background(neon.border)

                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(GlassAppBackground().ignoresSafeArea(.container, edges: .all))
        }

        @ViewBuilder private var content: some View {
            switch tab {
            case .terminal:
                if appearance.experimentalNativeTerminal {
                    GhosttyTerminalTab(session: session)
                } else {
                    TerminalTabXterm(session: session)
                }
            case .browser:
                BrowserTab(session: session, mode: .preview)
            case .info:
                LitterUI.SessionInfoView(session: session, embedded: true)
            }
        }
    }
}
