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
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Single-line title only — the prior "claude · Remote control"
            // subtitle duplicated the agent pill ("claude medium") that
            // already sits one row below in the header card. Dropping it
            // saves a row of vertical chrome and removes redundant text.
            ToolbarItem(placement: .principal) {
                Text(navTitle)
                    .font(.headline)
                    .foregroundStyle(SweKittyTheme.textPrimary)
                    .lineLimit(1)
            }
        }
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

    /// Friendly first-line title. Prefer the session's display name;
    /// fall back to the agent name (rather than the raw UUID) so the
    /// header reads like a project label, not internal plumbing.
    private var navTitle: String {
        let trimmed = session.name.trimmingCharacters(in: .whitespacesAndNewlines)
        // Sessions created from a fresh dial typically use the UUID as
        // their name — when that's the case, prefer the assistant
        // label so the header carries meaning at a glance.
        if trimmed.isEmpty || trimmed == session.id {
            return "swe-kitty"
        }
        return trimmed
    }

    private var lifecycle: SessionLifecycle? { store.sessionLifecycle[session.id] }

    /// Litter-style header card:
    /// Row 1: centered agent pill (green dot · name · effort · chevron) with
    ///        compact refresh + info icon buttons on the trailing edge.
    /// Row 2: `path · branch · running` one-line muted mono caption.
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
            // One-line caption beneath the agent pill: `path · branch ·
            // running`. Single muted mono line replaces the prior
            // folder-icon + two-segment row so the tab picker sits one
            // row closer to the top of the visible header.
            Text(captionLabel)
                .font(.caption2.monospaced())
                .foregroundStyle(SweKittyTheme.textMuted)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .center)
            tabPicker
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .glassRoundedRect()
    }

    private var pathLabel: String {
        // Real cwd now threads from the harness status frame. Fall back
        // to the session name (typically the workspace folder) when
        // the harness hasn't emitted one yet (older builds).
        if let cwd = session.cwd?.trimmingCharacters(in: .whitespaces), !cwd.isEmpty {
            return cwd
        }
        return session.name
    }

    /// One-line `path · branch · running` caption used directly beneath
    /// the agent pill. Replaces the prior split (icon + path on its own
    /// row, then subtitle on a second row) so the header sheds vertical
    /// chrome and the tab picker climbs closer to the top.
    private var captionLabel: String {
        let parts: [String] = [
            pathLabel,
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

    /// Reasoning effort surfaced by the harness status frame. Falls
    /// back to "medium" when the harness hasn't emitted one (older
    /// builds) so the pill always reads something.
    private var reasoningEffort: String {
        if let raw = session.reasoningEffort?.trimmingCharacters(in: .whitespaces), !raw.isEmpty {
            return raw
        }
        return "medium"
    }

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
        case .terminal: TerminalTabXterm(session: session)
        case .chat:     ChatTab(session: session)
        case .browser:  BrowserTab(session: session, mode: browserMode)
        }
    }
}
