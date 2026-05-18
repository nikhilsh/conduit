import SwiftUI

enum ProjectTab: String, CaseIterable, Identifiable {
    case terminal, chat, browser
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var systemImage: String {
        switch self {
        case .terminal: return "terminal"
        case .chat:     return "bubble.left.and.bubble.right"
        case .browser:  return "safari"
        }
    }
}

struct ProjectView: View {
    @Environment(SessionStore.self) private var store
    let session: ProjectSession

    @State private var tab: ProjectTab = .terminal
    @State private var browserMode: BrowserMode = .preview

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            tabContent
        }
        .navigationTitle(session.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var header: some View {
        HStack {
            HealthDot(health: store.statusBySession[session.id]?.health ?? "unknown")
            Text(session.name).font(.headline)
            Spacer()
            MemoryButton(tab: $tab, mode: $browserMode)
            agentBadge
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) {
            Picker("View", selection: $tab) {
                ForEach(ProjectTab.allCases) { t in
                    Label(t.label, systemImage: t.systemImage).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.bottom, 4)
            .offset(y: 40)
        }
        .padding(.bottom, 44)
    }

    private var agentBadge: some View {
        Menu {
            Button("Switch to Claude") { store.switchAgent(sessionID: session.id, to: "claude") }
                .disabled(session.assistant == "claude")
            Button("Switch to Codex") { store.switchAgent(sessionID: session.id, to: "codex") }
                .disabled(session.assistant == "codex")
            Divider()
            Button("End session", role: .destructive) {
                store.exit(sessionID: session.id)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "cpu")
                Text(session.assistant)
                Image(systemName: "chevron.down")
            }
            .font(.caption.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.accentColor.opacity(0.15))
            .clipShape(Capsule())
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch tab {
        case .terminal: TerminalTab(session: session)
        case .chat:     ChatTab(session: session)
        case .browser:  BrowserTab(session: session, mode: browserMode)
        }
    }
}
