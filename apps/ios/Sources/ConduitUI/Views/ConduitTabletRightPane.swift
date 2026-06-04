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

extension ConduitUI {

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
        @Environment(\.neonTheme) private var neon
        @State private var tab: RightPaneTab = .terminal
        // Lazy-mount gate for the native terminal (same fix as phone
        // ConduitProjectView). The right pane defaults to the Terminal tab, so
        // an eager mount builds libghostty's surface inside the session-create
        // CA commit → terminal-mount EXC_BAD_ACCESS. We mount it one runloop
        // AFTER the pane appears (`.task` below) so the create commit settles
        // first; it then stays mounted (opacity) per #294.
        @State private var terminalActivated = false

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
            // Defer the native-terminal mount to the next runloop, off the
            // session-create CA commit (see terminalActivated).
            .task { terminalActivated = true }
        }

        // Keep Terminal + Browser MOUNTED across the right-pane tab switches
        // (same reopen-crash fix as the phone ProjectView): rebuilding the
        // native GhosttyTerminalView on every Terminal↔Info↔Browser switch
        // tore down + recreated libghostty's surface, and a CA commit mid-
        // teardown crashed (APPLE-IOS-S / -P / -Q). `isActive` stands the
        // hidden terminal's renderer down. Info is cheap, so it stays a
        // plain switch overlaid on top when selected.
        @ViewBuilder private var content: some View {
            ZStack {
                if terminalActivated {
                    terminalContent
                        .opacity(tab == .terminal ? 1 : 0)
                        .allowsHitTesting(tab == .terminal)
                        .accessibilityHidden(tab != .terminal)
                        .zIndex(tab == .terminal ? 1 : 0)
                }

                BrowserTab(session: session, mode: .preview)
                    .opacity(tab == .browser ? 1 : 0)
                    .allowsHitTesting(tab == .browser)
                    .accessibilityHidden(tab != .browser)
                    .zIndex(tab == .browser ? 1 : 0)

                if tab == .info {
                    ConduitUI.SessionInfoView(session: session, embedded: true)
                        .zIndex(2)
                }
            }
        }

        @ViewBuilder private var terminalContent: some View {
            GhosttyTerminalTab(session: session, isActive: tab == .terminal)
        }
    }
}
