import SwiftUI

// MARK: - ConduitHomeView
//
// Conduit-faithful home screen. Mirrors upstream's HomeDashboardView in
// structure (top row with chrome icons, server pill row, sessions list,
// bottom action bar with mic/+/search) but uses our own data layer.
//
// Visual decisions:
//   - Top row: 36pt glass-circle icon buttons left/right, centered
//     ConduitMark daemon logo.
//   - Server pill row: horizontal scroll of capsule pills, ending in
//     a "+" pill. Selected pill carries the brand tint.
//   - Sessions list: flat rows (no card chrome), separator-less.
//     A solid status circle replaces the bubble. Title in body
//     weight, subtitle in mono caption.
//   - Bottom action bar: anchored at the bottom-safe-area, three
//     controls (mic / + / search). "+" is the prominent FAB.

extension ConduitUI {

    struct HomeView: View {
        @Environment(SessionStore.self) private var store
        @Environment(AppearanceStore.self) private var appearance
        @Environment(\.colorScheme) private var colorScheme
        @Environment(\.neonTheme) private var neon

        @State private var showSettings = false
        @State private var showAddServer = false
        @State private var showSearch = false
        @State private var showAgentPicker = false
        @State private var showSessionsHistory = false
        /// Voice dictation (bottom mic). On a transcript we stash it here
        /// and open the agent picker seeded with it as the first prompt.
        @State private var showVoiceDictation = false
        @State private var voicePrompt: String?
        @State private var selectedSessionID: String?
        /// Confirmation alert state for the session-row swipe-to-delete.
        /// `.alert(item:)` needs an Identifiable, so we wrap the target
        /// session id (`Identifiable` via the inner struct).
        @State private var pendingDelete: PendingSessionDelete?

        var body: some View {
            @Bindable var store = store

            NavigationStack {
                ZStack {
                    GlassAppBackground()
                    VStack(spacing: 12) {
                        topRow
                        serverPillStrip
                        sessionsList
                        Spacer(minLength: 0)
                        bottomBar
                    }
                    .padding(.top, 8)
                    .navigationDestination(item: $selectedSessionID) { id in
                        if let session = store.sessions.first(where: { $0.id == id }) {
                            ConduitUI.ProjectView(session: session)
                        } else {
                            Color.clear
                        }
                    }
                    .navigationDestination(isPresented: $showSessionsHistory) {
                        // Sessions-history surface is the legacy
                        // `SessionsScreen` (now in `Sources/Shared/`).
                        // A upstream-faithful rebuild is a follow-up;
                        // for now we expose the existing one as a
                        // navigation push so the affordance keeps
                        // working post-cutover.
                        SessionsScreen().environment(store)
                    }
                }
                .sheet(isPresented: $showSettings) {
                    ConduitUI.SettingsView()
                }
                .sheet(isPresented: $showAddServer) {
                    ConduitUI.AddServerSheet()
                }
                .sheet(isPresented: $showAgentPicker, onDismiss: { voicePrompt = nil }) {
                    ConduitUI.AgentPickerSheet(initialPrompt: voicePrompt)
                }
                .sheet(isPresented: $showVoiceDictation, onDismiss: {
                    // Chain into the agent picker (seeded with the transcript)
                    // only if we actually captured something.
                    if voicePrompt?.isEmpty == false { showAgentPicker = true }
                }) {
                    VoiceDictationSheet(onTranscript: { text in
                        voicePrompt = text
                        showVoiceDictation = false
                    })
                }
                .sheet(isPresented: $showSearch) {
                    // Search is a legacy view for now.
                    // Drive navigation through the same local
                    // `selectedSessionID` a home-row tap uses; setting
                    // only `store.selectedSessionID` races the sheet
                    // dismissal and the push never fires on iPhone.
                    SessionSearchView(onSelect: { id in
                        showSearch = false
                        store.selectedSessionID = id
                        selectedSessionID = id
                    })
                    .environment(store)
                }
                .alert(
                    "Archive session?",
                    isPresented: Binding(
                        get: { pendingDelete != nil },
                        set: { if !$0 { pendingDelete = nil } }
                    ),
                    presenting: pendingDelete
                ) { target in
                    Button("Archive") {
                        store.archive(sessionID: target.id)
                        pendingDelete = nil
                    }
                    Button("Cancel", role: .cancel) {
                        pendingDelete = nil
                    }
                } message: { target in
                    Text("Ends \(target.title) on the server and keeps it in History (read-only). Delete it permanently from History.")
                }
                .onChange(of: store.selectedSessionID) { _, new in
                    selectedSessionID = new
                }
                .onAppear {
                    if !store.endpoint.isComplete {
                        showSettings = true
                    } else if store.harness == .disconnected {
                        store.connect()
                    }
                }
                .tint(neon.accent)
            }
        }

        // MARK: Subviews

        private var topRow: some View {
            // Conduit parity (audit §A.1.6) put settings behind a hidden
            // long-press on the brand mark — undiscoverable in practice
            // (user feedback 2026-05-23). Restore a visible gear in the
            // leading slot; the long-press stays as a secondary path so
            // accessibility hints continue to work. Trailing drops the
            // search icon because the bottom action bar already carries
            // a 44pt search button — having both was a duplicate.
            ConduitUI.Header(
                leading: {
                    ConduitUI.HeaderIconButton(systemImage: "gearshape",
                                              accessibilityLabel: "Settings") {
                        showSettings = true
                    }
                },
                center: {
                    // Brand lockup: daemon mark + `>conduit` wordmark
                    // (mono 700, `>` tinted with the accent), per BRAND.md §1
                    // and the design-reference home header.
                    HStack(spacing: 8) {
                        ConduitUI.AnimatedBrandMark(size: 26)
                        (Text(">").foregroundStyle(neon.glow ? neon.accent : neon.textDim)
                            + Text("conduit").foregroundStyle(neon.text))
                            .font(neon.mono(15).weight(.bold))
                            .tracking(1)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Conduit")
                    .accessibilityHint("Press and hold for settings")
                    .onLongPressGesture(minimumDuration: 0.4) {
                        showSettings = true
                    }
                },
                trailing: {
                    ConduitUI.HeaderIconButton(systemImage: "clock.arrow.circlepath",
                                              accessibilityLabel: "Sessions history") {
                        showSessionsHistory = true
                    }
                }
            )
        }

        @ViewBuilder
        private var serverPillStrip: some View {
            // Conduit renders saved servers as a horizontal capsule
            // row. We render the same shape from `store.savedServers`
            // plus a trailing "+" pill that opens the add-server
            // sheet.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(store.savedServers) { server in
                        let isActive = store.endpoint == server.endpoint
                        // device bug #23: the dot used to mean "selected",
                        // so it stayed green even with the broker down. Drive
                        // it from the live connection state for the active
                        // server (green=connected, amber=connecting/retrying,
                        // muted=down/idle).
                        let dotColor: Color = {
                            guard isActive else { return neon.textFaint }
                            switch store.harness {
                            case .live, .linked: return neon.green
                            case .connecting, .reconnecting: return neon.yellow
                            case .disconnected, .failed: return neon.textFaint
                            }
                        }()
                        Button {
                            store.selectSavedServer(server.id, autoConnect: true)
                        } label: {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(dotColor)
                                    .frame(width: 6, height: 6)
                                    .neonGlowBox(isActive && neon.glow ? neon.glowBox?.tinted(dotColor) : nil)
                                Text(server.name)
                                    .font(neon.sans(12).weight(.semibold))
                                    .foregroundStyle(isActive ? neon.accent : neon.text)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(neon.surface))
                            .overlay(Capsule().stroke(isActive ? neon.borderStrong : neon.border, lineWidth: 1))
                            .neonGlowBox(isActive && neon.glow ? neon.glowBox : nil)
                        }
                        .buttonStyle(.plain)
                    }

                    Button {
                        showAddServer = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "plus")
                                .font(.system(size: 11, weight: .bold))
                            Text("server")
                                .font(neon.sans(12).weight(.semibold))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .foregroundStyle(neon.textDim)
                        .background(Capsule().fill(neon.surface))
                        .overlay(Capsule().stroke(neon.border, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
            }
            .frame(height: 36)
        }

        private var snapshot: ConduitUI.HomeSnapshot {
            let endpointHost = store.endpoint.isComplete ? store.endpoint.displayHost : nil
            let harness: ConduitUI.HomeSnapshotHarness = {
                switch store.harness {
                case .disconnected: return .disconnected
                case .connecting:   return .connecting
                case .linked, .live: return .live
                case .reconnecting: return .reconnecting
                case .failed(let reason): return .failed(reason)
                }
            }()
            let sessions = store.sessions.map { s in
                let status = store.statusBySession[s.id]
                // Prefer the freshest activity timestamp the store carries
                // for the relative "last active" stamp.
                let lastActivity = status?.lastActivityAt
                    ?? s.lastActivityAt
                    ?? status?.startedAt
                    ?? s.startedAt
                let cwd = status?.cwd ?? s.cwd
                return ConduitUI.HomeSnapshotSession(
                    id: s.id,
                    displayName: store.displayName(for: s),
                    assistant: s.assistant,
                    phase: status?.phase,
                    lastActivityAt: lastActivity,
                    // Drop the ephemeral per-session work dir; only a real
                    // user-picked cwd surfaces in the row.
                    workingDir: SessionNaming.meaningfulWorkingDir(cwd),
                    lastActivityPreview: latestActivityPreview(for: s.id)
                )
            }
            return ConduitUI.HomeSnapshot(
                harness: harness,
                sessions: sessions,
                placeholders: [],
                selectedSessionID: store.selectedSessionID,
                endpointDisplayHost: endpointHost
            )
        }

        /// One-line preview of the latest activity in a session for the
        /// home card. Pulls the most recent NON-user transcript item from
        /// `store.conversationLog` (assistant reply or tool action) — the
        /// first user message is already the card title, so this surfaces
        /// "what's happening" instead. Returns nil when the log carries
        /// nothing but the user's prompts (or is empty), so the card simply
        /// drops the line. Condensing lives in the pure view-model so it's
        /// unit-testable.
        private func latestActivityPreview(for sessionID: String) -> String? {
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
            let rows = ConduitUI.HomeViewModel.rows(snap)
            if rows.isEmpty {
                VStack(spacing: 10) {
                    Spacer(minLength: 24)
                    Image(systemName: ConduitUI.HomeViewModel.emptySymbol(snap))
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(neon.accent)
                        .neonTextGlow(neon.textGlow)
                    Text(ConduitUI.HomeViewModel.emptyTitle(snap))
                        .font(neon.sans(17).weight(.semibold))
                        .foregroundStyle(neon.text)
                    Text(ConduitUI.HomeViewModel.emptyBody(snap))
                        .font(neon.sans(13))
                        .foregroundStyle(neon.textDim)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 36)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Promoted from ScrollView+VStack to a `List` so each row
                // can carry `.swipeActions` for the delete affordance —
                // SwiftUI only honours swipe gestures on List/Form rows.
                // `listStyle(.plain)` + clear backgrounds preserve the
                // upstream-faithful flat look from the prior layout.
                List {
                    ForEach(rows) { row in
                        HomeRowView(row: row)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(
                                top: HomeRowMetrics.interRowSpacing / 2,
                                leading: 14,
                                bottom: HomeRowMetrics.interRowSpacing / 2,
                                trailing: 14
                            ))
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if case .session(let id) = row.kind {
                                    store.selectedSessionID = id
                                    selectedSessionID = id
                                }
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                if case .session(let id) = row.kind {
                                    // Swipe = ARCHIVE (two-tier delete model):
                                    // ends the live session on the broker but
                                    // keeps it in History as a read-only
                                    // transcript. Permanent delete lives in
                                    // History. Non-destructive tint so it reads
                                    // as a light, recoverable action.
                                    Button {
                                        pendingDelete = PendingSessionDelete(id: id, title: row.title)
                                    } label: {
                                        Label("Archive", systemImage: "archivebox")
                                    }
                                    .tint(neon.textDim)
                                }
                            }
                            .contextMenu {
                                if case .session(let id) = row.kind {
                                    Button {
                                        pendingDelete = PendingSessionDelete(id: id, title: row.title)
                                    } label: {
                                        Label("Archive", systemImage: "archivebox")
                                    }
                                }
                            }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }

        private var bottomBar: some View {
            // PLAN-CONDUIT-VISUAL-PARITY PR 3, audit §A.1.5: upstream wraps
            // the bottom bar in TWO `GlassMorphContainer`s so the `+`
            // can morph into a composer without the surrounding
            // mic / search merging into the same glass blob. All three
            // controls drop to a single 44pt — the prior 56pt copper-
            // outlined plus was over-built relative to upstream.
            HStack(spacing: 14) {
                ConduitUI.GlassMorphContainer(spacing: 14) {
                    ConduitUI.PillButton(systemImage: "mic.fill", size: 44, tint: neon.accent) {
                        showVoiceDictation = true
                    }
                }
                Spacer()
                ConduitUI.GlassMorphContainer(spacing: 14) {
                    ConduitUI.PillButton(
                        systemImage: "plus",
                        size: 44,
                        tint: neon.accent,
                        isProminent: true
                    ) {
                        if store.harness.canIssueCommands {
                            showAgentPicker = true
                        } else {
                            showAddServer = true
                        }
                    }
                }
                Spacer()
                ConduitUI.GlassMorphContainer(spacing: 14) {
                    ConduitUI.PillButton(systemImage: "magnifyingglass", size: 44, tint: neon.accent) {
                        showSearch = true
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 4)
        }
    }
}

/// Carrier for the alert-driven delete confirmation on the home
/// sessions list. `Identifiable` so the `.alert(presenting:)` overload
/// can key the presentation off the pending target, ensuring a stale
/// id from a previous swipe doesn't survive into the next prompt.
private struct PendingSessionDelete: Identifiable, Equatable {
    let id: String
    let title: String
}

/// Row metrics extracted as named constants so `ConduitHomeRowGeometry
/// Tests` can pin them. Changing any of these silently re-grows / re-
/// shrinks the home list, which is exactly the drift the rebuild PR
/// is trying to stop. Typography (title/subtitle) stays upstream-faithful
/// (audit §A.1.1); the row chrome is a contained glass card (styling
/// polish — the prior flat row left the status dot floating outside the
/// row's content to the left and read as tall/empty).
enum HomeRowMetrics {
    static let titlePointSize: CGFloat = 13
    static let subtitlePointSize: CGFloat = 11
    static let indicatorSize: CGFloat = 7
    /// Leading daemon-avatar (ConduitMark tinted per agent) box size.
    static let avatarSize: CGFloat = 38
    /// The selected row gets a brand-tinted card; an unselected row keeps
    /// the neutral glass surface. Both share `cardCornerRadius`.
    static let cardCornerRadius: CGFloat = 12
    /// Internal card padding — the status dot + text live INSIDE this, so
    /// nothing floats against the screen gutter.
    static let cardHorizontalPadding: CGFloat = 12
    static let cardVerticalPadding: CGFloat = 9
    /// Gap between the leading status dot and the text column.
    static let dotTextSpacing: CGFloat = 10
    /// Vertical gap between stacked cards in the list.
    static let interRowSpacing: CGFloat = 6
    /// Brand tint opacity on the selected card.
    static let selectedTintOpacity: Double = 0.22
}

private struct HomeRowView: View {
    let row: ConduitUI.HomeRow
    @Environment(\.neonTheme) private var neon

    /// Agent-tinted leading rail / glow for the row.
    private var agentTint: Color { neon.agentTint(forAgent: row.agent) }

    var body: some View {
        HStack(alignment: .top, spacing: HomeRowMetrics.dotTextSpacing) {
            // Per-design (screens.jsx SessionRow): the leading element is a
            // daemon avatar — the ConduitMark tinted with the agent color —
            // in a soft tinted rounded-square, with a small run-state dot.
            avatar
            VStack(alignment: .leading, spacing: 3) {
                // Prominent friendly name. 13pt semibold per audit §A.1.1
                // (upstream-faithful density); single line, truncating.
                Text(row.title)
                    .font(neon.sans(HomeRowMetrics.titlePointSize).weight(.semibold))
                    .foregroundStyle(neon.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                secondaryLine
                activityPreviewLine
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, HomeRowMetrics.cardHorizontalPadding)
        .padding(.vertical, HomeRowMetrics.cardVerticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .neonCardSurface(
            neon,
            fill: row.isSelected ? agentTint.opacity(neon.dark ? 0.18 : 0.12) : neon.surface,
            cornerRadius: HomeRowMetrics.cardCornerRadius,
            border: row.isSelected ? agentTint.opacity(0.55) : neon.borderStrong,
            glowTint: row.isSelected ? agentTint : nil
        )
        .contentShape(RoundedRectangle(cornerRadius: HomeRowMetrics.cardCornerRadius, style: .continuous))
    }

    /// Secondary line: agent chip · status (tinted by run state) ·
    /// relative time, with an optional real cwd. Caption2-sized (11pt)
    /// per audit §A.1.1. Replaces the old `"agent · phase · host"` mono
    /// string — the host wasn't useful and the row never carried a
    /// meaningful path.
    @ViewBuilder
    private var secondaryLine: some View {
        switch row.kind {
        case .creatingPlaceholder:
            Text(row.statusText)
                .font(neon.mono(HomeRowMetrics.subtitlePointSize))
                .foregroundStyle(neon.textFaint)
                .lineLimit(1)
        case .session:
            HStack(spacing: 5) {
                if !row.agent.isEmpty {
                    Text(row.agent)
                        .font(neon.mono(HomeRowMetrics.subtitlePointSize).weight(.semibold))
                        .foregroundStyle(agentTint)
                }
                statusDot
                    .frame(width: 5, height: 5)
                Text(row.statusText)
                    .font(neon.sans(HomeRowMetrics.subtitlePointSize))
                    .foregroundStyle(statusColor)
                if !row.relativeTime.isEmpty {
                    Text("·")
                        .font(neon.sans(HomeRowMetrics.subtitlePointSize))
                        .foregroundStyle(neon.textFaint)
                    Text(row.relativeTime)
                        .font(neon.mono(HomeRowMetrics.subtitlePointSize))
                        .foregroundStyle(neon.textFaint)
                }
                if let dir = row.workingDir {
                    Text("·")
                        .font(neon.sans(HomeRowMetrics.subtitlePointSize))
                        .foregroundStyle(neon.textFaint)
                    Text(dirLeaf(dir))
                        .font(neon.mono(HomeRowMetrics.subtitlePointSize))
                        .foregroundStyle(neon.textFaint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .lineLimit(1)
        }
    }

    /// Third line: a one-line preview of the latest activity (most recent
    /// assistant reply / tool action) so the user can tell active sessions
    /// apart and see "what's happening" at a glance. The title is the
    /// FIRST user message; this complements it. Muted, single-line,
    /// truncating; renders nothing when there's no preview (placeholder
    /// rows, or a transcript with only the user's prompt).
    @ViewBuilder
    private var activityPreviewLine: some View {
        if case .session = row.kind, !row.lastActivityPreview.isEmpty {
            Text(row.lastActivityPreview)
                .font(neon.sans(HomeRowMetrics.subtitlePointSize))
                .foregroundStyle(neon.textDim)
                .lineLimit(2)
                .truncationMode(.tail)
        }
    }

    /// Final path component of a cwd, for the compact dir label.
    private func dirLeaf(_ path: String) -> String {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        return trimmed.split(separator: "/").last.map(String.init) ?? trimmed
    }

    /// Run-state tint shared by the status word and its inline dot.
    private var statusColor: Color {
        row.isRunning ? neon.green : neon.textFaint
    }

    private var statusDot: some View {
        Circle().fill(statusColor)
    }

    /// Daemon avatar: the ConduitMark tinted with the agent color in a soft
    /// tinted rounded-square, with a small bottom-trailing run-state dot.
    /// Matches the design-reference SessionRow leading element.
    @ViewBuilder
    private var avatar: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(agentTint.opacity(neon.dark ? 0.14 : 0.10))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(agentTint.opacity(0.35), lineWidth: 1)
            )
            .frame(width: HomeRowMetrics.avatarSize, height: HomeRowMetrics.avatarSize)
            .overlay {
                switch row.kind {
                case .creatingPlaceholder:
                    ProgressView().controlSize(.small).tint(agentTint)
                case .session:
                    ConduitUI.ConduitMark(size: HomeRowMetrics.avatarSize - 14, color: agentTint, glow: neon.glow)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if case .session = row.kind {
                    Circle()
                        .fill(row.isRunning ? neon.green : neon.textFaint.opacity(0.5))
                        .frame(width: 8, height: 8)
                        .overlay(Circle().stroke(neon.surface, lineWidth: 1.5))
                        .offset(x: 3, y: 3)
                }
            }
    }

    @ViewBuilder
    private var indicator: some View {
        switch row.kind {
        case .creatingPlaceholder:
            // ProgressView is bigger than 7pt natively; clip into the
            // indicator frame so the row vertical rhythm doesn't break.
            ProgressView()
                .controlSize(.mini)
                .tint(neon.accent)
        case .session:
            // 7pt filled circle per audit §A.1.7 — green when the agent
            // is running (with a neon glow), muted once it has exited.
            // Driven by run state, not selection (device bug #9): every
            // running session shows green, not just the attached one.
            // Selection is conveyed by the row's background fill.
            Circle()
                .fill(row.isRunning ? neon.green : neon.textFaint.opacity(0.5))
                .neonGlowBox(row.isRunning && neon.glow ? neon.glowBox?.tinted(neon.green) : nil)
        }
    }
}
