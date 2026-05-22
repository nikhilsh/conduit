import SwiftUI

// MARK: - LitterProjectView
//
// Session detail in the LitterUI tree. Litter's reference has a single
// chat surface per session; we keep our Terminal / Chat / Browser
// trio (per the user's direction in the brief) but collapse the tab
// strip into a slim segmented control directly under the title so it
// reads as sub-nav rather than chrome.
//
// Header layout (litter-faithful):
//   row 1: ← back · ● claude medium ▼ · ↻ refresh · ⓘ info
//   row 2: path subtitle (truncated middle, mono)
//   row 3: Terminal | Chat | Browser segmented picker
// Below: tab content (LitterChatView for the chat tab, legacy
// TerminalTabXterm + BrowserTab for the others — the LitterUI rebuild
// scope was the conversation + nav, not the terminal/browser
// renderers).

extension LitterUI {

    enum ProjectTab: String, CaseIterable, Identifiable {
        case terminal
        case chat
        case browser

        var id: String { rawValue }
        var label: String {
            switch self {
            case .terminal: return "Terminal"
            case .chat:     return "Chat"
            case .browser:  return "Browser"
            }
        }
        var systemImage: String {
            switch self {
            case .terminal: return "terminal"
            case .chat:     return "bubble.left.and.bubble.right"
            case .browser:  return "globe"
            }
        }
    }

    struct ProjectView: View {
        @Environment(SessionStore.self) private var store
        @Environment(AppearanceStore.self) private var appearance
        @Environment(\.dismiss) private var dismiss

        let session: ProjectSession

        @State private var tab: ProjectTab = .chat
        @State private var showInfo = false

        var body: some View {
            VStack(spacing: 0) {
                header
                tabStrip
                Divider().background(LitterUI.Palette.separator.color)
                content
            }
            .background(LitterUI.Palette.surface.color.ignoresSafeArea())
            .navigationBarBackButtonHidden(true)
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showInfo) {
                LitterUI.SessionInfoView(session: session)
            }
        }

        // MARK: Header rows

        private var header: some View {
            VStack(alignment: .leading, spacing: 8) {
                row1
                row2
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)
        }

        private var row1: some View {
            HStack(spacing: 10) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(LitterUI.Palette.textPrimary.color)
                        .frame(width: 32, height: 32)
                        .litterGlassCircle(tint: LitterUI.Palette.surfaceLight.color, config: .floating)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")

                HStack(spacing: 6) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                    Text(store.displayName(for: session))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(LitterUI.Palette.textPrimary.color)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    LitterUI.Chip(label: session.assistant, tint: agentTint)
                    if let effort = session.reasoningEffort {
                        LitterUI.Chip(label: effort)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    store.reconnect()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(LitterUI.Palette.textSecondary.color)
                        .frame(width: 32, height: 32)
                        .litterGlassCircle(tint: LitterUI.Palette.surfaceLight.color, config: .floating)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Refresh")

                Button {
                    showInfo = true
                } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(LitterUI.Palette.textSecondary.color)
                        .frame(width: 32, height: 32)
                        .litterGlassCircle(tint: LitterUI.Palette.surfaceLight.color, config: .floating)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Session info")
            }
        }

        private var row2: some View {
            HStack {
                Text(session.cwd ?? "—")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(LitterUI.Palette.textMuted.color)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }

        private var statusColor: Color {
            let phase = store.statusBySession[session.id]?.phase ?? ""
            switch phase.lowercased() {
            case "working", "thinking": return LitterUI.Palette.warning.color
            case "ready", "idle":       return LitterUI.Palette.success.color
            default:                     return LitterUI.Palette.textMuted.color
            }
        }

        private var agentTint: Color {
            SweKittyTheme.accent(forAgent: session.assistant)
        }

        // MARK: Tab strip — slim segmented control

        private var tabStrip: some View {
            HStack(spacing: 4) {
                ForEach(ProjectTab.allCases) { t in
                    Button {
                        withAnimation(.easeOut(duration: 0.18)) { tab = t }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: t.systemImage)
                                .font(.system(size: 10, weight: .semibold))
                            Text(t.label)
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .foregroundStyle(tab == t ? LitterUI.Palette.textOnAccent.color : LitterUI.Palette.textSecondary.color)
                        .litterGlassCapsule(tint: tab == t ? LitterUI.Palette.brand.color : nil, config: .pill)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 8)
        }

        @ViewBuilder
        private var content: some View {
            switch tab {
            case .chat:
                LitterUI.ChatView(session: session)
            case .terminal:
                // Reuse the existing terminal renderer — LitterUI's
                // rebuild scope was the chat / nav surfaces, not the
                // terminal engine. The chrome around it (our header
                // + tab strip) still lives in the new style.
                if appearance.experimentalNativeTerminal {
                    GhosttyTerminalTab(session: session)
                } else {
                    TerminalTabXterm(session: session)
                }
            case .browser:
                BrowserTab(session: session, mode: .preview)
            }
        }
    }
}
