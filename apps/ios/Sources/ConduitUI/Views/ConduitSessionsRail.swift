import Foundation
import SwiftUI

// MARK: - ConduitSessionsRail
//
// The unified tablet left rail (tablet.jsx → TabletRail), mirroring the
// Android `NeonTabletRail`. It folds in the navigation that used to live
// in the separate icon "activity bar": brand + connected-server chip +
// an overflow menu (Settings / Boxes), a Search button (covers History
// via the search sheet), the sessions list, and a pinned "New session"
// button. Tapping a row drives selection via
// `SessionStore.switchTo(sessionID:)`.
//
// The pure-data layout decisions live in `ConduitSessionsRailModel`
// so the test layer can pin row count + active-session highlight
// without standing up a view tree.

extension ConduitUI {

    struct SessionsRail: View {
        @Environment(SessionStore.self) private var store
        @Environment(AppearanceStore.self) private var appearance
        @Environment(\.neonTheme) private var neon

        @State private var showSettings = false
        @State private var showAddServer = false
        @State private var showBoxes = false
        @State private var showSearch = false
        @State private var showAgentPicker = false
        @State private var showOnboarding = false
        /// Fan-out surface, reachable from the "+" long-press menu (mirrors
        /// ConduitHomeView's bottom-bar FAB menu).
        @State private var showFanOut = false
        /// Pipeline builder, reachable from the "+" long-press menu.
        @State private var showPipelineBuilder = false

        var body: some View {
            @Bindable var store = store

            ZStack {
                ConduitUI.Palette.surface.color.ignoresSafeArea()
                VStack(spacing: 12) {
                    header
                    searchButton
                    sessionsList
                    Spacer(minLength: 0)
                    newSessionButton
                }
                .padding(.top, 8)
            }
            .sheet(isPresented: $showSettings) {
                ConduitUI.SettingsView(onOpenOnboarding: {
                    showSettings = false
                    showOnboarding = true
                })
                .presentationDetents([.medium, .large])
            }
            .fullScreenCover(isPresented: $showOnboarding) {
                ConduitUI.OnboardingView(onFinish: { showOnboarding = false })
                    .environment(store)
            }
            .sheet(isPresented: $showAddServer) {
                ConduitUI.AddServerSheet()
                    .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showBoxes) {
                ConduitUI.DiscoveryView()
                    .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showSearch) {
                SessionSearchView(
                    onSelect: { id in store.switchTo(sessionID: id) },
                    embedded: false
                )
            }
            .sheet(isPresented: $showAgentPicker) {
                ConduitUI.AgentPickerSheet(initialPrompt: nil)
            }
            .sheet(isPresented: $showFanOut) {
                ConduitUI.FanOutView(
                    onLaunch: { task, branches in
                        for branch in branches {
                            store.createSession(assistant: "claude", branch: branch, initialPrompt: task)
                        }
                    }
                )
                .environment(store)
                .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showPipelineBuilder) {
                ConduitUI.PipelineBuilderView()
                    .environment(store)
                    .presentationDetents([.large])
            }
            .neonAccentTint()
        }

        /// Long-press quick-action menu shared by both "+" affordances
        /// (header circle + pinned bottom button). Plain tap is unchanged.
        @ViewBuilder
        private var plusButtonMenu: some View {
            Button {
                if store.harness.canIssueCommands {
                    showAgentPicker = true
                } else {
                    showAddServer = true
                }
            } label: {
                Label("New session", systemImage: "plus.square")
            }
            if store.pipelinesEnabled {
                Button {
                    showPipelineBuilder = true
                } label: {
                    Label("New flow", systemImage: "arrow.triangle.merge")
                }
            }
            Button {
                showFanOut = true
            } label: {
                Label("Fan out", systemImage: "square.grid.2x2")
            }
        }

        // MARK: Header (brand + server chip + overflow)

        private var header: some View {
            HStack(spacing: 9) {
                ConduitUI.ConduitMark(size: 24)
                    .accessibilityLabel("Conduit")
                wordmark
                Spacer(minLength: 6)
                serverChip
                newButton
                overflowMenu
            }
            .padding(.horizontal, 14)
        }

        /// Header "＋ new" (handoff §6) — the primary new-session affordance
        /// on tablet, alongside the pinned bottom button.
        private var newButton: some View {
            Button {
                if store.harness.canIssueCommands {
                    showAgentPicker = true
                } else {
                    showAddServer = true
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(neon.accentText)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(neon.accent))
                    .neonGlowBox(neon.glow ? neon.glowBox?.tinted(neon.accent) : nil)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("New session")
            .contextMenu {
                plusButtonMenu
            }
        }

        private var wordmark: some View {
            (Text(">").foregroundStyle(neon.accent)
                + Text("conduit").foregroundStyle(neon.text))
                .font(.system(size: 15, weight: .bold, design: .monospaced))
                .accessibilityHidden(true)
        }

        /// Single connected-server chip — reuses `TabletHome.connectionChip`
        /// styling (host + status dot: green live/linked, yellow
        /// connecting/reconnecting, muted offline).
        private var serverChip: some View {
            let (label, color): (String, Color) = {
                // Use visibleHarness: suppresses "reconnecting" during grace window (Change 4).
                switch store.visibleHarness {
                case .live, .linked:
                    return (store.endpoint.isComplete ? store.endpoint.displayHost : "online", neon.green)
                case .connecting, .reconnecting:
                    return ("connecting", neon.yellow)
                case .disconnected, .failed:
                    return ("offline", neon.textFaint)
                }
            }()
            return HStack(spacing: 6) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(label)
                    .font(neon.mono(11))
                    .foregroundStyle(color)
                    .lineLimit(1)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(neon.surface)
                    .overlay(Capsule().stroke(neon.border, lineWidth: 1))
            )
        }

        private var overflowMenu: some View {
            Menu {
                Button {
                    showSettings = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                Button {
                    showBoxes = true
                } label: {
                    Label("Boxes", systemImage: "externaldrive")
                }
            } label: {
                // A gear, not a `•••`: the dim ellipsis was undiscoverable as
                // the route to Settings on tablet — a user on the 3-pane layout
                // couldn't find Settings at all (device feedback 2026-06-01).
                // Settings is the primary item, so the trigger reads as a gear;
                // Boxes stays as the menu's secondary entry.
                Image(systemName: "gearshape")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(neon.textDim)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Settings and more")
        }

        // MARK: Search (covers History)

        private var searchButton: some View {
            Button {
                showSearch = true
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(neon.accent)
                    Text("Search…")
                        .font(neon.sans(12.5))
                        .foregroundStyle(neon.textFaint)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(neon.surface)
                        .overlay(
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .stroke(neon.border, lineWidth: 1)
                        )
                )
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
        }

        // MARK: New session (pinned bottom)

        private var newSessionButton: some View {
            Button {
                if store.harness.canIssueCommands {
                    showAgentPicker = true
                } else {
                    showAddServer = true
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .bold))
                    Text("New session")
                        .font(neon.sans(13.5).weight(.bold))
                }
                .foregroundStyle(neon.accentText)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(neon.accent)
                )
            }
            .buttonStyle(.plain)
            .contextMenu {
                plusButtonMenu
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }

        private var snapshot: ConduitUI.HomeSnapshot {
            let endpointHost = store.endpoint.isComplete ? store.endpoint.displayHost : nil
            let harness: ConduitUI.HomeSnapshotHarness = {
                // Use visibleHarness so snapshot suppresses reconnecting during grace window (Change 4).
                switch store.visibleHarness {
                case .disconnected: return .disconnected
                case .connecting:   return .connecting
                case .linked, .live: return .live
                case .reconnecting: return .reconnecting
                case .failed(let reason): return .failed(reason)
                }
            }()
            let sessions = store.sessions.map { s -> ConduitUI.HomeSnapshotSession in
                let status = store.statusBySession[s.id]
                let cwd = status?.cwd ?? s.cwd
                // Live git branch from the status frame; falls back to the
                // session's static create-time branch when the broker hasn't
                // yet emitted a status frame with git_branch.
                let liveBranch = status?.gitBranch ?? s.gitBranch
                return ConduitUI.HomeSnapshotSession(
                    id: s.id,
                    displayName: store.displayName(for: s),
                    assistant: s.assistant,
                    phase: status?.phase,
                    // Sort / group key — broker-stamped activity time that
                    // survives reboot (the live last-message ts is HomeView's
                    // richer source; the rail uses the durable session stamp).
                    lastActivityAt: s.lastActivityAt ?? s.startedAt ?? status?.lastActivityAt,
                    workingDir: SessionNaming.meaningfulWorkingDir(cwd),
                    lastActivityPreview: railActivityPreview(for: s.id),
                    isConfirmedLive: store.isConfirmedLive(sessionID: s.id),
                    gitBranch: liveBranch?.isEmpty == false ? liveBranch : nil,
                    gitDirty: status?.gitDirty ?? s.gitDirty
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

        /// One-line preview of the latest non-user activity for a session
        /// (mirrors HomeView) — the 2-line preview in the redesigned rail row.
        private func railActivityPreview(for sessionID: String) -> String? {
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

        @ViewBuilder
        private var sessionsList: some View {
            let snap = snapshot
            let sections = ConduitUI.SessionsRailModel.sections(snap)
            let rows = ConduitUI.SessionsRailModel.rows(snap)
            if rows.isEmpty {
                VStack(spacing: 8) {
                    Spacer(minLength: 24)
                    Image(systemName: ConduitUI.HomeViewModel.emptySymbol(snap))
                        .font(.system(size: 32, weight: .light))
                        .foregroundStyle(ConduitUI.Palette.textSecondary.color)
                    Text(ConduitUI.HomeViewModel.emptyTitle(snap))
                        .font(.subheadline)
                        .foregroundStyle(ConduitUI.Palette.textPrimary.color)
                    Text(ConduitUI.HomeViewModel.emptyBody(snap))
                        .font(.caption)
                        .foregroundStyle(ConduitUI.Palette.textMuted.color)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(sections) { section in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(section.title.uppercased())
                                    .font(neon.mono(10).weight(.bold))
                                    .tracking(1.4)
                                    .foregroundStyle(neon.textFaint)
                                    .padding(.horizontal, 10)
                                    .padding(.bottom, 3)
                                ForEach(section.rows) { row in
                                    RailRowView(row: row)
                                        .onTapGesture {
                                            if case .session(let id) = row.kind {
                                                store.switchTo(sessionID: id)
                                            }
                                        }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 16)
                }
            }
        }
    }
}

// MARK: - Row view

private struct RailRowView: View {
    let row: ConduitUI.HomeRow
    @Environment(\.neonTheme) private var neon

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            indicator
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(neon.sans(14).weight(.semibold))
                    .foregroundStyle(neon.text)
                    .lineLimit(1)
                Text(subtitle)
                    .font(neon.mono(10.5))
                    .foregroundStyle(neon.textDim)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if case .session = row.kind, !row.lastActivityPreview.isEmpty {
                    Text(row.lastActivityPreview)
                        .font(neon.sans(11.5))
                        .foregroundStyle(neon.textFaint)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(row.isSelected ? neon.accent.opacity(0.16) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(row.isSelected ? neon.accent.opacity(0.4) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
    }

    /// `agent · branch[●N] · dir` (or status) mono subline — what the row runs.
    private var subtitle: String {
        switch row.kind {
        case .creatingPlaceholder:
            return row.statusText
        case .session:
            var parts: [String] = []
            if !row.agent.isEmpty { parts.append(row.agent) }
            if let branch = row.gitBranch, !branch.isEmpty {
                // Show branch + dirty indicator (● count when > 0).
                if let dirty = row.gitDirty, dirty > 0 {
                    parts.append("\(branch) ●\(dirty)")
                } else {
                    parts.append(branch)
                }
            } else if let dir = row.workingDir, !dir.isEmpty {
                parts.append(shortDir(dir))
            } else {
                parts.append(row.statusText)
            }
            if !row.relativeTime.isEmpty { parts.append(row.relativeTime) }
            return parts.joined(separator: " · ")
        }
    }

    /// Trim a cwd to its last path component for the compact subline.
    private func shortDir(_ dir: String) -> String {
        let trimmed = dir.hasSuffix("/") ? String(dir.dropLast()) : dir
        return trimmed.split(separator: "/").last.map(String.init) ?? trimmed
    }

    /// Status dot color (handoff §6): live = green, starting/paused = amber,
    /// done/exited = cyan, idle/archived = faint. Running rows pulse.
    @ViewBuilder
    private var indicator: some View {
        switch row.kind {
        case .creatingPlaceholder:
            ProgressView().controlSize(.small)
        case .session:
            let color = dotColor
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .neonGlowBox(row.isRunning && neon.glow ? neon.glowBox?.tinted(color) : nil)
        }
    }

    private var dotColor: Color {
        if row.isRunning { return neon.green }
        if row.isStarting { return neon.yellow }
        if row.statusText.lowercased().contains("exit") { return neon.codex }
        return neon.textFaint
    }
}

// MARK: - Pure-data model
//
// Mirrors `ConduitUI.HomeViewModel.rows` but exposed under a dedicated
// namespace so the rail's contract (row count + active highlight) is
// the thing tests pin. Today the body forwards to the home model —
// keeping the indirection makes the rail safe to evolve (e.g. recent-
// session truncation, pinned sessions) without dragging the home
// screen's row contract along.

extension ConduitUI {

    enum SessionsRailModel {
        static func rows(_ snap: HomeSnapshot) -> [HomeRow] {
            HomeViewModel.rows(snap)
        }

        /// A titled group of rows in the redesigned tablet sidebar
        /// (handoff §6 — Today / Yesterday / This week / Earlier).
        struct RailSection: Identifiable, Equatable {
            let id: String
            let title: String
            let rows: [HomeRow]
        }

        /// Group the rail rows by recency. The order from `rows(_:)` is
        /// preserved within each bucket (it's already recency-sorted). Rows
        /// without a parseable timestamp — and creating placeholders — fall
        /// into Today (they're the freshest, in-flight work). Empty buckets
        /// are dropped. Pure + testable.
        static func sections(_ snap: HomeSnapshot, now: Date = Date()) -> [RailSection] {
            let rows = HomeViewModel.rows(snap)
            guard !rows.isEmpty else { return [] }

            // session id → its last-activity Date (when parseable).
            var dateByID: [String: Date] = [:]
            for s in snap.sessions {
                if let iso = s.lastActivityAt, let d = parseTimestamp(iso) {
                    dateByID[s.id] = d
                }
            }

            let cal = Calendar.current
            // Bucket relative to the injected `now` (NOT the system clock):
            // `Calendar.isDateInToday/Yesterday` ignore `now`, so we compare
            // calendar-day offsets from `now`'s start-of-day instead. Keeps
            // production correct (now = Date()) and tests deterministic.
            let nowDay = cal.startOfDay(for: now)
            func bucket(_ row: HomeRow) -> Int {
                guard case .session(let id) = row.kind, let date = dateByID[id] else {
                    return 0   // placeholders / unknown → Today
                }
                let dayOffset = cal.dateComponents([.day], from: cal.startOfDay(for: date), to: nowDay).day ?? 0
                switch dayOffset {
                case ..<1:  return 0   // today (or future-stamped) → Today
                case 1:     return 1   // Yesterday
                case 2..<7: return 2   // This week
                default:    return 3   // Earlier
                }
            }

            let titles = ["Today", "Yesterday", "This week", "Earlier"]
            var grouped: [[HomeRow]] = [[], [], [], []]
            for row in rows { grouped[bucket(row)].append(row) }
            return zip(titles, grouped).compactMap { title, rows in
                rows.isEmpty ? nil : RailSection(id: title, title: title, rows: rows)
            }
        }

        /// Parse a broker timestamp — RFC3339 with or without fractional
        /// seconds (the broker emits both shapes).
        private static func parseTimestamp(_ s: String) -> Date? {
            let withFraction = ISO8601DateFormatter()
            withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = withFraction.date(from: s) { return d }
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            return plain.date(from: s)
        }
    }
}
