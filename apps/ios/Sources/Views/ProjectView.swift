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
        VStack(spacing: 12) {
            header
            tabContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: SweKittyTheme.cardCornerRadius, style: .continuous)
                        .fill(.ultraThinMaterial)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: SweKittyTheme.cardCornerRadius, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: SweKittyTheme.cardCornerRadius, style: .continuous))
        }
        .padding(12)
        .navigationTitle(session.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var status: SessionStatus? { store.statusBySession[session.id] }
    private var lifecycle: SessionLifecycle? { store.sessionLifecycle[session.id] }

    private var header: some View {
        VStack(spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                HealthDot(health: status?.health ?? "unknown", size: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.name)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(SweKittyTheme.mutedFG)
                        .lineLimit(1)
                }
                Spacer()
                MemoryButton(tab: $tab, mode: $browserMode)
                agentBadge
            }
            tabPicker
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: SweKittyTheme.cardCornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: SweKittyTheme.cardCornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
        )
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
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(SweKittyTheme.accent.opacity(0.25))
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(SweKittyTheme.accent.opacity(0.45), lineWidth: 1))
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
