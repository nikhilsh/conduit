import SwiftUI

// MARK: - TabletHome
//
// The design bundle's tablet Home dashboard (tablet-sections.jsx →
// TabletHome): a 2-column grid of active-session cards + a 2-column
// "Boxes" grid, under a section header with a connection chip. Shown in
// the activity bar's Home section (replacing the reused phone HomeView).
//
// Reuses the existing home row model (`LitterUI.HomeViewModel.rows`) so
// the session list matches the phone's data; renders its own card (the
// phone row is a horizontal list row). Outcome chips from the design are
// omitted — the app has no diff/PR/test outcome data to back them.

extension LitterUI {

    struct TabletHome: View {
        /// Open a session in the Sessions section.
        let onOpenSession: (String) -> Void
        @Environment(SessionStore.self) private var store
        @Environment(\.neonTheme) private var neon

        private let columns = [
            GridItem(.flexible(), spacing: 14),
            GridItem(.flexible(), spacing: 14),
        ]

        var body: some View {
            let rows = LitterUI.HomeViewModel.rows(snapshot)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    if rows.isEmpty {
                        emptyState
                    } else {
                        sectionLabel("Active sessions")
                        LazyVGrid(columns: columns, spacing: 14) {
                            ForEach(rows) { row in
                                sessionCard(row)
                            }
                        }
                        .padding(.bottom, 24)
                    }
                    if !store.savedServers.isEmpty {
                        sectionLabel("Boxes")
                        LazyVGrid(columns: columns, spacing: 14) {
                            ForEach(store.savedServers) { server in
                                boxCard(server)
                            }
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
            }
            .scrollIndicators(.hidden)
        }

        // MARK: Header

        private var header: some View {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text("Home")
                    .font(neon.sans(22).weight(.bold))
                    .foregroundStyle(neon.text)
                    .neonTextGlow(neon.textGlow)
                Spacer(minLength: 6)
                connectionChip
            }
            .padding(.bottom, 16)
        }

        private var connectionChip: some View {
            let (label, color): (String, Color) = {
                switch store.harness {
                case .live, .linked:           return (store.endpoint.isComplete ? store.endpoint.displayHost : "online", neon.green)
                case .connecting, .reconnecting: return ("connecting", neon.yellow)
                case .disconnected, .failed:   return ("offline", neon.textFaint)
                }
            }()
            return HStack(spacing: 7) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(label)
                    .font(neon.mono(11.5))
                    .foregroundStyle(color)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .background(
                Capsule().fill(neon.surface)
                    .overlay(Capsule().stroke(neon.border, lineWidth: 1))
            )
        }

        private func sectionLabel(_ text: String) -> some View {
            Text(text)
                .font(neon.mono(11).weight(.bold))
                .foregroundStyle(neon.textDim)
                .textCase(.uppercase)
                .padding(.bottom, 10)
                .padding(.top, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
        }

        // MARK: Session card

        private func sessionCard(_ row: LitterUI.HomeRow) -> some View {
            let tint = neon.agentTint(forAgent: row.agent)
            return Button {
                if case .session(let id) = row.kind { onOpenSession(id) }
            } label: {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(row.isRunning ? neon.green : neon.textFaint)
                            .frame(width: 8, height: 8)
                            .neonGlowBox(row.isRunning && neon.glow ? neon.glowBox?.tinted(neon.green) : nil)
                        Text(row.title)
                            .font(neon.sans(15).weight(.semibold))
                            .foregroundStyle(neon.text)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        if !row.relativeTime.isEmpty {
                            Text(row.relativeTime)
                                .font(neon.mono(10))
                                .foregroundStyle(neon.textFaint)
                        }
                    }
                    HStack(spacing: 6) {
                        Text(row.agent)
                            .font(neon.mono(10.5))
                            .foregroundStyle(tint)
                        if !row.statusText.isEmpty {
                            Text("· \(row.statusText)")
                                .font(neon.mono(10.5))
                                .foregroundStyle(neon.textFaint)
                        }
                    }
                    if !row.lastActivityPreview.isEmpty {
                        Text(row.lastActivityPreview)
                            .font(neon.sans(12.5))
                            .foregroundStyle(neon.textDim)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    // OutcomeChips: read the live session's broker-computed
                    // git/PR stats by id (the row view-model doesn't carry
                    // them). Renders nothing when there's no outcome data.
                    if case .session(let id) = row.kind,
                       let session = store.sessions.first(where: { $0.id == id }) {
                        LitterUI.OutcomeChips(
                            linesAdded: session.linesAdded.map(Int.init),
                            linesRemoved: session.linesRemoved.map(Int.init),
                            commits: session.commits.map(Int.init),
                            prNumber: session.prNumber.map(Int.init),
                            prState: session.prState
                        )
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .neonCardSurface(neon, fill: neon.surface, cornerRadius: neon.radius - 2)
            }
            .buttonStyle(.plain)
        }

        // MARK: Box card

        private func boxCard(_ server: SavedServer) -> some View {
            let isActive = store.endpoint == server.endpoint
            let color: Color = {
                guard isActive else { return neon.textFaint }
                switch store.harness {
                case .live, .linked:             return neon.green
                case .connecting, .reconnecting: return neon.yellow
                case .disconnected, .failed:     return neon.textFaint
                }
            }()
            return Button {
                store.selectSavedServer(server.id, autoConnect: true)
            } label: {
                HStack(spacing: 13) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(color.opacity(0.11))
                            .overlay(
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .strokeBorder(color.opacity(0.22), lineWidth: 1)
                            )
                        Image(systemName: "server.rack")
                            .font(.system(size: 18))
                            .foregroundStyle(color)
                    }
                    .frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(server.name)
                            .font(neon.sans(14.5).weight(.semibold))
                            .foregroundStyle(neon.text)
                            .lineLimit(1)
                        Text(server.endpoint.displayHost)
                            .font(neon.mono(10.5))
                            .foregroundStyle(neon.textFaint)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Text(isActive ? "active" : "tap")
                        .font(neon.mono(11))
                        .foregroundStyle(color)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 15)
                .frame(maxWidth: .infinity, alignment: .leading)
                .neonCardSurface(neon, fill: neon.surface, cornerRadius: neon.radius - 4)
            }
            .buttonStyle(.plain)
        }

        private var emptyState: some View {
            VStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 38, weight: .light))
                    .foregroundStyle(neon.accent)
                    .neonTextGlow(neon.textGlow)
                Text("No sessions yet")
                    .font(neon.sans(17).weight(.semibold))
                    .foregroundStyle(neon.text)
                Text("Start one from the Sessions tab.")
                    .font(neon.sans(13))
                    .foregroundStyle(neon.textDim)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 60)
        }

        // MARK: Snapshot (mirrors LitterHomeView.snapshot; read-only mapping)

        private var snapshot: LitterUI.HomeSnapshot {
            let endpointHost = store.endpoint.isComplete ? store.endpoint.displayHost : nil
            let harness: LitterUI.HomeSnapshotHarness = {
                switch store.harness {
                case .disconnected:  return .disconnected
                case .connecting:    return .connecting
                case .linked, .live: return .live
                case .reconnecting:  return .reconnecting
                case .failed(let reason): return .failed(reason)
                }
            }()
            let sessions = store.sessions.map { s -> LitterUI.HomeSnapshotSession in
                let status = store.statusBySession[s.id]
                let lastActivity = status?.lastActivityAt ?? s.lastActivityAt ?? status?.startedAt ?? s.startedAt
                let cwd = status?.cwd ?? s.cwd
                return LitterUI.HomeSnapshotSession(
                    id: s.id,
                    displayName: store.displayName(for: s),
                    assistant: s.assistant,
                    phase: status?.phase,
                    lastActivityAt: lastActivity,
                    workingDir: SessionNaming.meaningfulWorkingDir(cwd),
                    lastActivityPreview: activityPreview(for: s.id)
                )
            }
            return LitterUI.HomeSnapshot(
                harness: harness,
                sessions: sessions,
                placeholders: [],
                selectedSessionID: store.selectedSessionID,
                endpointDisplayHost: endpointHost
            )
        }

        private func activityPreview(for sessionID: String) -> String? {
            guard let log = store.conversationLog[sessionID], !log.isEmpty else { return nil }
            guard let latest = log.last(where: { $0.role.lowercased() != "user" }) else { return nil }
            return LitterUI.HomeViewModel.activityPreview(
                role: latest.role,
                kind: latest.kind,
                toolName: latest.toolName,
                command: latest.command,
                content: latest.content
            )
        }
    }
}
