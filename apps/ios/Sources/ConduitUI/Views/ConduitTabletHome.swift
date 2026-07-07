import SwiftUI

// MARK: - TabletHome
//
// The design bundle's tablet Home dashboard (tablet-sections.jsx →
// TabletHome): a 2-column grid of active-session cards + a 2-column
// "Boxes" grid, under a section header with a connection chip. Shown in
// the activity bar's Home section (replacing the reused phone HomeView).
//
// Reuses the existing home row model (`ConduitUI.HomeViewModel.rows`) so
// the session list matches the phone's data; renders its own card (the
// phone row is a horizontal list row). Outcome chips from the design are
// omitted — the app has no diff/PR/test outcome data to back them.

extension ConduitUI {

    struct TabletHome: View {
        /// Open a session in the Sessions section.
        let onOpenSession: (String) -> Void
        @Environment(SessionStore.self) private var store
        @Environment(\.neonTheme) private var neon

        // Flows / pipeline affordance (#907, tablet-parity fix for the gap
        // #905 flagged): mirrors ConduitHomeView's FLOWS section -- refresh
        // on appear / box switch only (no polling loop while Home sits
        // idle), gated on the broker's `pipeline` capability.
        @State private var pipelineSummaries: [ConduitUI.PipelineSummary] = []
        @State private var showPipelineList = false
        @State private var showPipelineBuilder = false
        @State private var selectedFlowPipeline: ConduitUI.PipelineSummary?
        @State private var continuingFlowIDs: Set<String> = []

        private var activePipelines: [ConduitUI.PipelineSummary] {
            pipelineSummaries.filter { ConduitUI.PipelineListViewModel.isActiveForHomeAffordance($0.state) }
        }

        private var recentTerminalPipelines: [ConduitUI.PipelineSummary] {
            pipelineSummaries.filter { ConduitUI.PipelineListViewModel.isRecentTerminal($0) }
        }

        private var homeFlows: [ConduitUI.PipelineSummary] {
            ConduitUI.PipelineListViewModel.sorted(activePipelines + recentTerminalPipelines)
        }

        private let columns = [
            GridItem(.flexible(), spacing: 14),
            GridItem(.flexible(), spacing: 14),
        ]

        var body: some View {
            let rows = ConduitUI.HomeViewModel.rows(snapshot)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    // FLOWS: same slot as phone Home -- above "Active
                    // sessions", below the header. Never a fabricated count
                    // -- hidden when no flow qualifies.
                    if !homeFlows.isEmpty {
                        flowsSectionLabel
                        VStack(spacing: 10) {
                            ForEach(homeFlows) { flow in
                                ConduitUI.FlowCard(
                                    summary: flow,
                                    isContinuing: continuingFlowIDs.contains(flow.id),
                                    onOpen: {
                                        Telemetry.breadcrumb("pipeline", "flow card opened",
                                            data: ["id": flow.id, "state": flow.state])
                                        selectedFlowPipeline = flow
                                    },
                                    onContinue: { continueFlow(flow) }
                                )
                            }
                        }
                        .padding(.bottom, 16)
                    }
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
            .task(id: store.endpoint.displayHost) {
                guard store.pipelinesEnabled, store.endpoint.isComplete else { return }
                pipelineSummaries = await store.refreshPipelines()
            }
            .sheet(isPresented: $showPipelineList) {
                ConduitUI.PipelineListView()
                    .environment(store)
                    .presentationDetents([.large])
            }
            .sheet(isPresented: $showPipelineBuilder) {
                ConduitUI.PipelineBuilderView()
                    .environment(store)
                    .presentationDetents([.large])
            }
            .sheet(item: $selectedFlowPipeline) { flow in
                NavigationStack {
                    ConduitUI.PipelineMonitorView(
                        pipelineID: flow.id,
                        pipelineTitle: flow.title.isEmpty ? "Flow" : flow.title
                    )
                    .environment(store)
                }
                .presentationDetents([.large])
            }
        }

        // MARK: Flows

        private var flowsSectionLabel: some View {
            HStack {
                // Own label (not `sectionLabel(_:)`) -- that helper stretches
                // to `maxWidth: .infinity`, which would fight the trailing
                // button for space in this HStack. Accent-tinted per the
                // design handoff ("FLOWS" eyebrow), unlike the textDim
                // "Active sessions"/"Boxes" labels.
                Text("FLOWS")
                    .font(neon.mono(11).weight(.bold))
                    .foregroundStyle(neon.accent)
                    .textCase(.uppercase)
                Spacer(minLength: 8)
                Button {
                    showPipelineBuilder = true
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "plus").font(.system(size: 12, weight: .semibold))
                        Text("New flow").font(neon.sans(12.5).weight(.semibold))
                    }
                    .foregroundStyle(neon.accent)
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 10)
            .padding(.top, 4)
        }

        /// Inline "Continue" (gate approval) from a tablet `FlowCard` --
        /// same endpoint + approve-as-is semantics as the phone Home /
        /// monitor Continue (`ConduitPipelineMonitorView.continuePipeline`).
        private func continueFlow(_ flow: ConduitUI.PipelineSummary) {
            guard !continuingFlowIDs.contains(flow.id) else { return }
            let endpoint = store.endpoint
            guard endpoint.isComplete, let base = endpoint.httpBaseURL else { return }
            var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
            components?.path = "/api/pipeline/\(flow.id)/continue"
            guard let url = components?.url else { return }

            continuingFlowIDs.insert(flow.id)
            Telemetry.breadcrumb("pipeline", "flow card continue tapped", data: ["id": flow.id])
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.timeoutInterval = 15
            req.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = Data("{}".utf8)

            Task { @MainActor in
                defer { continuingFlowIDs.remove(flow.id) }
                do {
                    let (_, resp) = try await URLSession.shared.data(for: req)
                    guard let http = resp as? HTTPURLResponse else { return }
                    if http.statusCode >= 200 && http.statusCode < 300 {
                        Telemetry.breadcrumb("pipeline", "flow card continue ok", data: ["id": flow.id])
                        pipelineSummaries = await store.refreshPipelines()
                    } else {
                        Telemetry.capture(
                            error: NSError(domain: "ios.pipeline", code: 12,
                                userInfo: [NSLocalizedDescriptionKey: "flow card continue failed"]),
                            message: "flow card continue failed",
                            tags: ["surface": "ios", "phase": "pipeline"],
                            extras: ["id": flow.id, "status": "\(http.statusCode)"]
                        )
                    }
                } catch {
                    Telemetry.capture(
                        error: error,
                        message: "flow card continue network error",
                        tags: ["surface": "ios", "phase": "pipeline"],
                        extras: ["id": flow.id]
                    )
                }
            }
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
                // Use visibleHarness: suppresses "reconnecting" during grace window (Change 4).
                switch store.visibleHarness {
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

        private func sessionCard(_ row: ConduitUI.HomeRow) -> some View {
            let tint = neon.agentTint(forAgent: row.agent)
            return Button {
                if case .session(let id) = row.kind { onOpenSession(id) }
            } label: {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(row.isRunning ? neon.green : (row.isStarting ? neon.yellow : neon.textFaint))
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
                        ConduitUI.OutcomeChips(
                            linesAdded: session.linesAdded.map(Int.init),
                            linesRemoved: session.linesRemoved.map(Int.init),
                            commits: session.commits.map(Int.init),
                            prNumber: session.prNumber.map(Int.init),
                            prState: session.prState,
                            prUrl: session.prUrl
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
                // Use visibleHarness: suppresses reconnecting color during grace window (Change 4).
                switch store.visibleHarness {
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

        // MARK: Snapshot (mirrors ConduitHomeView.snapshot; read-only mapping)

        private var snapshot: ConduitUI.HomeSnapshot {
            let endpointHost = store.endpoint.isComplete ? store.endpoint.displayHost : nil
            let harness: ConduitUI.HomeSnapshotHarness = {
                // Use visibleHarness so snapshot suppresses reconnecting during grace window (Change 4).
                switch store.visibleHarness {
                case .disconnected:  return .disconnected
                case .connecting:    return .connecting
                case .linked, .live: return .live
                case .reconnecting:  return .reconnecting
                case .failed(let reason): return .failed(reason)
                }
            }()
            let sessions = store.sessions.map { s -> ConduitUI.HomeSnapshotSession in
                let status = store.statusBySession[s.id]
                // Last-MESSAGE time (real activity) first, then the session's
                // own metadata; the reconnect-set status timestamp is only a
                // last resort (on cold-boot it's the CONNECTION time). Mirrors
                // the phone home (`ConduitHomeView.snapshot`).
                let lastActivity = lastMessageTimestamp(for: s.id)
                    ?? s.lastActivityAt
                    ?? s.startedAt
                    ?? status?.lastActivityAt
                    ?? status?.startedAt
                let cwd = status?.cwd ?? s.cwd
                return ConduitUI.HomeSnapshotSession(
                    id: s.id,
                    displayName: store.displayName(for: s),
                    assistant: s.assistant,
                    phase: status?.phase,
                    lastActivityAt: lastActivity,
                    workingDir: SessionNaming.meaningfulWorkingDir(cwd),
                    lastActivityPreview: activityPreview(for: s.id),
                    isConfirmedLive: store.isConfirmedLive(sessionID: s.id)
                )
            }
            let placeholders = store.visibleSessions.compactMap { v -> ConduitUI.HomeSnapshotPlaceholder? in
                guard case .creating(let id) = v else { return nil }
                return ConduitUI.HomeSnapshotPlaceholder(id: id, label: "Starting session...")
            }
            return ConduitUI.HomeSnapshot(
                harness: harness,
                sessions: sessions,
                placeholders: placeholders,
                selectedSessionID: store.selectedSessionID,
                endpointDisplayHost: endpointHost
            )
        }

        /// Broker `ts` of the freshest live conversation-log item — the real
        /// last-message time — or nil when the log is empty.
        private func lastMessageTimestamp(for sessionID: String) -> String? {
            guard let last = store.conversationLog[sessionID]?.last else { return nil }
            return last.ts.isEmpty ? nil : last.ts
        }

        private func activityPreview(for sessionID: String) -> String? {
            guard let log = store.conversationLog[sessionID], !log.isEmpty else { return nil }
            guard let latest = log.last(where: { $0.role.lowercased() != "user" }) else { return nil }
            return ConduitUI.HomeViewModel.activityPreview(
                role: latest.role,
                kind: latest.kind,
                toolName: latest.toolName,
                command: latest.command,
                content: latest.content
            )
        }
    }
}
