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
    @State private var showInfo: Bool = false
    @State private var showAgentPicker: Bool = false

    var body: some View {
        VStack(spacing: 10) {
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
        .sheet(isPresented: $showInfo) {
            SessionInfoView(session: session)
                .environment(store)
                .presentationDetents([.large])
        }
        .sheet(isPresented: $showAgentPicker) {
            AgentPickerSheet(headerNote: nil).environment(store)
        }
    }

    private var status: SessionStatus? { store.statusBySession[session.id] }
    private var lifecycle: SessionLifecycle? { store.sessionLifecycle[session.id] }

    /// Litter-style header card:
    /// Row 1: centered agent pill (green dot · name · effort · chevron) with
    ///        compact refresh + info icon buttons on the trailing edge.
    /// Row 2: folder path under the pill (mono, muted, middle-truncated).
    /// Row 3: Terminal / Chat / Browser segmented picker (heightened — this
    ///        is the "main idea" per chat window in our app, per the plan).
    private var header: some View {
        VStack(spacing: 8) {
            ZStack {
                agentPill
                HStack(spacing: 8) {
                    Spacer()
                    MemoryButton(tab: $tab, mode: $browserMode)
                    HStack(spacing: 4) {
                        refreshButton
                        infoButton
                    }
                }
            }
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .font(.caption2)
                    .foregroundStyle(SweKittyTheme.textMuted)
                Text(pathLabel)
                    .font(.caption.monospaced())
                    .foregroundStyle(SweKittyTheme.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !subtitle.isEmpty {
                    Text("·")
                        .font(.caption2)
                        .foregroundStyle(SweKittyTheme.textMuted)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(SweKittyTheme.textMuted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
            tabPicker
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .glassRoundedRect()
    }

    private var pathLabel: String {
        // No first-class `cwd` on ProjectSession yet — `name` is the best
        // proxy we have. Stage 3 will surface the real cwd via the
        // SessionInfo screen + Rust core.
        session.name
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

    /// Litter-style centered agent pill: health dot, agent name,
    /// reasoning effort, then a small chevron.down. Tapping opens the
    /// shared AgentPickerSheet (same surface used from Home).
    private var agentPill: some View {
        Button {
            showAgentPicker = true
        } label: {
            HStack(spacing: 6) {
                HealthDot(health: status?.health ?? "unknown", size: 8)
                Text(session.assistant)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(SweKittyTheme.textPrimary)
                Text(reasoningEffort)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(SweKittyTheme.textSecondary)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(SweKittyTheme.textSecondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .glassCapsule(interactive: true, tint: SweKittyTheme.accent(forAgent: session.assistant).opacity(0.32))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Switch agent")
    }

    // TODO: thread reasoning effort from ProjectSession once Rust core
    // surfaces it; hard-coded "medium" so the pill matches Litter today.
    private var reasoningEffort: String { "medium" }

    private var refreshButton: some View {
        Button {
            // Note: SessionStore has no `refresh(sessionID:)` method, so
            // we fall back to `reconnect()` which re-establishes the
            // harness stream and re-emits the session snapshot.
            store.reconnect()
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(SweKittyTheme.accentStrong)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Reconnect")
    }

    private var infoButton: some View {
        Button {
            showInfo = true
        } label: {
            Image(systemName: "info.circle")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(SweKittyTheme.accentStrong)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Session info")
    }

    /// The Terminal / Chat / Browser segmented picker. Plan calls for this
    /// to be visually heightened — it's the per-session "main idea" for
    /// SweKitty (we keep it where litter only has a single chat surface).
    private var tabPicker: some View {
        Picker("View", selection: $tab) {
            ForEach(ProjectTab.allCases) { t in
                Label(t.label, systemImage: t.systemImage).tag(t)
            }
        }
        .pickerStyle(.segmented)
        .controlSize(.large)
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
