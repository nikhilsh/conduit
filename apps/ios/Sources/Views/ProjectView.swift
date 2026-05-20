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
        VStack(spacing: 8) {
            header
            tabContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .glassRoundedRect()
                .clipShape(RoundedRectangle(cornerRadius: SweKittyTheme.cardCornerRadius, style: .continuous))
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 0)
        .navigationTitle(session.name)
        .navigationBarTitleDisplayMode(.inline)
        .tint(SweKittyTheme.accentStrong)
    }

    private var status: SessionStatus? { store.statusBySession[session.id] }
    private var lifecycle: SessionLifecycle? { store.sessionLifecycle[session.id] }

    private var header: some View {
        VStack(spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                HealthDot(health: status?.health ?? "unknown", size: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(SweKittyTheme.textPrimary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(SweKittyTheme.textMuted)
                        .lineLimit(1)
                }
                Spacer()
                MemoryButton(tab: $tab, mode: $browserMode)
                agentBadge
            }
            tabPicker
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassRoundedRect()
    }

    private var subtitle: String {
        let parts: [String] = [
            session.branch.flatMap { $0.isEmpty ? nil : $0 } ?? "no branch",
            status?.phase ?? "ready",
            lifecycleLabel,
        ].compactMap { $0 }
        return parts.joined(separator: " · ")
    }

    private var lifecycleLabel: String? {
        switch lifecycle {
        case .exited(let c): return "exited(\(c))"
        case .failed(let m): return m
        case .creating, .live, .none: return nil
        }
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
            .foregroundStyle(SweKittyTheme.textPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .glassCapsule(interactive: true, tint: SweKittyTheme.accentStrong.opacity(0.45))
        }
    }

    private var tabPicker: some View {
        Picker("View", selection: $tab) {
            ForEach(ProjectTab.allCases) { t in
                Label(t.label, systemImage: t.systemImage).tag(t)
            }
        }
        .pickerStyle(.segmented)
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
