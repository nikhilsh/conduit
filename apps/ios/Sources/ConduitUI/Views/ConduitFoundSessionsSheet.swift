import SwiftUI

// MARK: - ConduitFoundSessionsSheet
//
// The browse-and-pick surface for sessions started outside Conduit.
// Screens 02 (discovery), 03 (branch), 04 (view transcript),
// 05 (overflow), 06 (resume progress), 07 (errors), 08 (empty/offline).
//
// Entry: present via .sheet(isPresented:) from ConduitBoxHealthView.
// Capability gate: only shown when features?.sessionDiscovery == true.

// MARK: - FoundSessionsSheet

extension ConduitUI {

    struct FoundSessionsSheet: View {
        @Environment(SessionStore.self) private var store
        @Environment(\.neonTheme) private var neon
        @Environment(\.dismiss) private var dismiss

        let server: SavedServer

        /// Called after a successful resume or branch so the whole sheet
        /// stack (found-sessions + box-health) can be dismissed, landing
        /// the user directly on the newly adopted chat. Defaults to a
        /// no-op so standalone presentations work without a closure.
        var onOpenedSession: () -> Void = {}

        @State private var snapshot: FoundSessionsSnapshot
        @State private var features: SessionStore.BoxFeatures?

        init(server: SavedServer, initialSnapshot: FoundSessionsSnapshot = .empty,
             onOpenedSession: @escaping () -> Void = {}) {
            self.server = server
            self.onOpenedSession = onOpenedSession
            _snapshot = State(initialValue: initialSnapshot)
        }

        // Navigation into sub-sheets
        @State private var selectedForBranch: FoundSessionRow?
        @State private var selectedForView: FoundSessionRow?
        @State private var selectedForResume: FoundSessionRow?
        @State private var selectedForWatch: FoundSessionRow?
        @State private var errorState: FoundSessionsErrorKind?

        // Overflow
        @State private var overflowSession: FoundSessionRow?
        @State private var showOverflow = false
        @State private var pendingHideRow: FoundSessionRow?
        @State private var showHideUndo = false

        // Search
        @State private var searchQuery = ""
        @State private var filter: FoundSessionsFilter = .recent

        // Whether we are connected to this box
        private var isActive: Bool { store.endpoint == server.endpoint }
        private var connected: Bool { isActive && store.harness.canIssueCommands }

        var body: some View {
            NavigationStack {
                ZStack {
                    GlassAppBackground()
                    mainContent
                }
                .navigationTitle("Found on \(server.name)")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
                .tint(neon.accent)
            }
            .appearanceColorScheme()
            .task(id: server.id) { await load() }
            .sheet(item: $selectedForBranch) { row in
                FoundBranchSheet(server: server, row: row, features: features,
                                 onError: { kind in errorState = kind },
                                 onDismiss: { selectedForBranch = nil },
                                 onSuccess: {
                                     selectedForBranch = nil
                                     Telemetry.breadcrumb("found_sessions", "branch adopt: dismissing sheet chain")
                                     dismiss()
                                     onOpenedSession()
                                 })
            }
            .sheet(item: $selectedForView) { row in
                FoundTranscriptView(server: server, row: row,
                                    features: features,
                                    onResume: { r in
                                        selectedForView = nil
                                        selectedForResume = r
                                    },
                                    onBranch: { r in
                                        selectedForView = nil
                                        selectedForBranch = r
                                    })
            }
            .sheet(item: $selectedForResume) { row in
                FoundResumeProgressView(
                    server: server,
                    row: row,
                    onError: { kind in
                        errorState = kind
                        selectedForResume = nil
                    },
                    onSuccess: {
                        selectedForResume = nil
                        Telemetry.breadcrumb("found_sessions", "resume adopt: dismissing sheet chain")
                        dismiss()
                        onOpenedSession()
                    }
                )
            }
            .sheet(item: $errorState) { kind in
                FoundErrorSheet(
                    kind: kind,
                    onRetry: {
                        errorState = nil
                        if kind == .sessionVanished {
                            Task { await load() }
                        }
                    },
                    onViewTranscript: {
                        errorState = nil
                    },
                    onDismiss: { errorState = nil }
                )
            }
            .sheet(item: $selectedForWatch) { row in
                FoundWatchView(
                    server: server,
                    row: row,
                    features: features,
                    onBranch: { r in
                        selectedForWatch = nil
                        selectedForBranch = r
                    }
                )
            }
            .overlay(undoOverlay, alignment: .bottom)
        }

        // MARK: - Main content

        @ViewBuilder
        private var mainContent: some View {
            switch snapshot.discoveryState {
            case .offline:
                offlineState
            case .empty where searchQuery.isEmpty:
                emptyState
            case .scanning where snapshot.sessions.isEmpty:
                scanningState
            default:
                discoveryList
            }
        }

        // MARK: - Discovery list (screen 02)

        private var discoveryList: some View {
            let rows = FoundSessionsModel.rows(snapshot)
            let grouped = filter == .byFolder ? FoundSessionsModel.grouped(rows) : []
            return VStack(spacing: 0) {
                // Provenance banner (always visible)
                provenanceBanner

                // Search + filter
                VStack(spacing: 10) {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 13))
                            .foregroundStyle(neon.textFaint)
                        TextField("Search title, repo or branch...", text: $searchQuery)
                            .font(neon.sans(14))
                            .foregroundStyle(neon.text)
                            .autocorrectionDisabled()
                            .onChange(of: searchQuery) { _, q in
                                snapshot.query = q
                            }
                        if !searchQuery.isEmpty {
                            Button {
                                searchQuery = ""
                                snapshot.query = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(neon.textFaint)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .neonCardSurface(neon, fill: neon.surface, cornerRadius: 10, border: neon.border)
                    .padding(.horizontal, 16)

                    Picker("Filter", selection: $filter) {
                        Text("Recent").tag(FoundSessionsFilter.recent)
                        Text("By folder").tag(FoundSessionsFilter.byFolder)
                        Text("All \(snapshot.totalOnDisk)").tag(FoundSessionsFilter.all)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)
                    .onChange(of: filter) { _, f in snapshot.filter = f }
                }
                .padding(.top, 12)
                .padding(.bottom, 8)

                if rows.isEmpty && !searchQuery.isEmpty {
                    noSearchResults
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                            if filter == .byFolder {
                                ForEach(grouped, id: \.cwd) { group in
                                    Section {
                                        ForEach(group.rows) { row in
                                            rowView(row)
                                        }
                                    } header: {
                                        folderHeader(group.cwd)
                                    }
                                }
                            } else {
                                ForEach(rows) { row in
                                    rowView(row)
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 16)

                        // Footer
                        let footer = FoundSessionsModel.footerText(
                            recentCount: snapshot.recentCount,
                            totalOnDisk: snapshot.totalOnDisk
                        )
                        Text(footer)
                            .font(neon.mono(11))
                            .foregroundStyle(neon.textFaint)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                            .padding(.bottom, 24)
                    }
                }
            }
        }

        // MARK: - Provenance banner

        private var provenanceBanner: some View {
            HStack(spacing: 10) {
                Image(systemName: "terminal")
                    .font(.system(size: 13))
                    .foregroundStyle(neon.textFaint)
                Text("Started by hand in your terminal \u{2014} not in Conduit")
                    .font(neon.sans(12))
                    .foregroundStyle(neon.textFaint)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(neon.surface.opacity(0.5))
        }

        // MARK: - Folder header

        private func folderHeader(_ cwd: String) -> some View {
            HStack {
                Text(shortCwd(cwd))
                    .font(neon.mono(11).weight(.bold))
                    .foregroundStyle(neon.textDim)
                    .textCase(.uppercase)
                    .tracking(0.8)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 8)
            .background(GlassAppBackground())
        }

        private func shortCwd(_ cwd: String) -> String {
            let parts = cwd.split(separator: "/")
            if cwd.hasPrefix("/root/") || cwd.hasPrefix("/home/") {
                return "~/" + parts.dropFirst(2).joined(separator: "/")
            }
            return cwd
        }

        // MARK: - Session row

        private func rowView(_ row: FoundSessionRow) -> some View {
            let dimmed = row.state == .adopted || row.isHidden
            return VStack(spacing: 0) {
                HStack(spacing: 10) {
                    // Agent glyph
                    agentAvatar(row.agent)

                    // Main content
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(row.title)
                                .font(neon.sans(13).weight(.semibold))
                                .foregroundStyle(dimmed ? neon.textFaint : neon.text)
                                .lineLimit(1)
                            stateBadge(row.state)
                        }
                        Text(metaLine(row))
                            .font(neon.mono(10.5))
                            .foregroundStyle(neon.textFaint)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 6)

                    // Overflow button
                    Button {
                        overflowSession = row
                        showOverflow = true
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 14))
                            .foregroundStyle(neon.textFaint)
                            .padding(8)
                    }
                    .buttonStyle(.plain)
                }

                // Action buttons for non-adopted rows
                if row.state != .adopted && !row.isHidden {
                    HStack(spacing: 8) {
                        switch row.state {
                        case .idle:
                            actionButton("Resume", systemImage: "play.fill", tint: neon.accent) {
                                selectedForResume = row
                                Telemetry.breadcrumb("found_sessions", "resume tapped",
                                    data: ["id": row.externalID])
                            }
                            actionButton("View", systemImage: "eye", tint: neon.textDim) {
                                selectedForView = row
                            }
                        case .running:
                            actionButton("Branch a copy", systemImage: "arrow.branch", tint: neon.yellow) {
                                selectedForBranch = row
                                Telemetry.breadcrumb("found_sessions", "branch tapped",
                                    data: ["id": row.externalID])
                            }
                            if features?.sessionWatch == true {
                                actionButton("Watch", systemImage: "eye.circle", tint: neon.accent) {
                                    selectedForWatch = row
                                    Telemetry.breadcrumb("found_sessions", "watch tapped",
                                        data: ["id": row.externalID])
                                }
                            }
                            actionButton("View", systemImage: "eye", tint: neon.textDim) {
                                selectedForView = row
                            }
                        case .adopted:
                            EmptyView()
                        }
                    }
                    .padding(.top, 8)
                } else if row.state == .adopted {
                    HStack {
                        actionButton("Open in Conduit", systemImage: "arrow.right.circle", tint: neon.accent) {
                            dismiss()
                        }
                        Spacer()
                    }
                    .padding(.top, 8)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .neonCardSurface(
                neon,
                fill: dimmed ? neon.surface.opacity(0.4) : neon.surface,
                cornerRadius: 12,
                border: dimmed ? neon.border.opacity(0.4) : neon.border
            )
            .padding(.vertical, 4)
            .opacity(dimmed ? 0.55 : 1.0)
            .confirmationDialog(
                overflowSession?.title ?? "",
                isPresented: $showOverflow,
                titleVisibility: .visible
            ) {
                overflowActions
            }
        }

        @ViewBuilder
        private var overflowActions: some View {
            if let row = overflowSession {
                Button("View transcript") {
                    selectedForView = row
                    showOverflow = false
                }
                Button("Copy resume command") {
                    let cmd = "conduit resume \(row.agent)://\(row.cwd.split(separator: "/").last ?? "")"
                    UIPasteboard.general.string = cmd
                    showOverflow = false
                }
                Button("Hide from this list", role: .destructive) {
                    pendingHideRow = row
                    store.hide(foundSessionID: row.externalID, onBox: server.id)
                    showHideUndo = true
                    showOverflow = false
                    // Refresh snapshot to reflect the hide
                    snapshot.hiddenIDs.insert(row.externalID)
                    // 4s undo window
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                        pendingHideRow = nil
                        showHideUndo = false
                    }
                }
                Button("Cancel", role: .cancel) { showOverflow = false }
            }
        }

        // MARK: - State badge

        private func stateBadge(_ state: FoundSessionState) -> some View {
            Group {
                switch state {
                case .idle:
                    Text("IDLE")
                        .font(neon.mono(9).weight(.bold))
                        .foregroundStyle(neon.textFaint)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(neon.surface2))
                        .overlay(Capsule().stroke(neon.border, lineWidth: 1))
                case .running:
                    HStack(spacing: 4) {
                        Circle()
                            .fill(neon.yellow)
                            .frame(width: 6, height: 6)
                        Text("RUNNING")
                            .font(neon.mono(9).weight(.bold))
                            .foregroundStyle(neon.yellow)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(neon.yellow.opacity(0.12)))
                    .overlay(Capsule().stroke(neon.yellow.opacity(0.3), lineWidth: 1))
                case .adopted:
                    HStack(spacing: 4) {
                        Circle()
                            .fill(neon.accent)
                            .frame(width: 6, height: 6)
                        Text("IN CONDUIT")
                            .font(neon.mono(9).weight(.bold))
                            .foregroundStyle(neon.accent)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(neon.accent.opacity(0.12)))
                    .overlay(Capsule().stroke(neon.accent.opacity(0.3), lineWidth: 1))
                }
            }
        }

        // MARK: - Agent avatar

        private func agentAvatar(_ agent: String) -> some View {
            let tint = neon.agentTint(forAgent: agent)
            return RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(tint.opacity(0.14))
                .frame(width: 34, height: 34)
                .overlay(
                    Image(systemName: agent == "codex" ? "cpu" : "terminal")
                        .font(.system(size: 15))
                        .foregroundStyle(tint)
                )
        }

        private func metaLine(_ row: FoundSessionRow) -> String {
            var parts: [String] = []
            if let branch = row.gitBranch { parts.append(branch) }
            parts.append(row.relativeTime)
            parts.append("\(row.turnCount) turns")
            return parts.joined(separator: " \u{00B7} ")
        }

        // MARK: - Action button

        private func actionButton(_ label: String, systemImage: String, tint: Color, action: @escaping () -> Void) -> some View {
            Button(action: action) {
                HStack(spacing: 5) {
                    Image(systemName: systemImage)
                        .font(.system(size: 11, weight: .semibold))
                    Text(label)
                        .font(neon.sans(12).weight(.semibold))
                }
                .foregroundStyle(tint)
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .neonCardSurface(neon, fill: tint.opacity(0.1), cornerRadius: 8, border: tint.opacity(0.3))
            }
            .buttonStyle(.plain)
        }

        // MARK: - No search results

        private var noSearchResults: some View {
            VStack(spacing: 12) {
                Spacer()
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 32))
                    .foregroundStyle(neon.textFaint)
                Text("No sessions match \"\(searchQuery)\"")
                    .font(neon.sans(15).weight(.semibold))
                    .foregroundStyle(neon.text)
                Button {
                    searchQuery = ""
                    snapshot.query = ""
                } label: {
                    Text("Clear search")
                        .font(neon.sans(13).weight(.semibold))
                        .foregroundStyle(neon.accent)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }

        // MARK: - Empty state (screen 08 - nothing found)

        private var emptyState: some View {
            VStack(spacing: 16) {
                Spacer()
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(neon.surface)
                    .frame(width: 64, height: 64)
                    .overlay(
                        Image(systemName: "greaterthan.square")
                            .font(.system(size: 26))
                            .foregroundStyle(neon.textFaint)
                    )
                VStack(spacing: 8) {
                    Text("Nothing to pick up")
                        .font(neon.sans(18).weight(.bold))
                        .foregroundStyle(neon.text)
                    Text("No Claude or Codex sessions started outside Conduit on this box. Anything you run by hand in your terminal will show up here.")
                        .font(neon.sans(13))
                        .foregroundStyle(neon.textFaint)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                HStack {
                    Image(systemName: "clock")
                        .font(.system(size: 11))
                        .foregroundStyle(neon.textFaint)
                    Text("last scanned just now")
                        .font(neon.mono(11))
                        .foregroundStyle(neon.textFaint)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .neonCardSurface(neon, fill: neon.surface, cornerRadius: 8)

                Button {
                    Task { await load() }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Scan again")
                            .font(neon.sans(14).weight(.semibold))
                    }
                    .foregroundStyle(neon.accent)
                    .frame(maxWidth: 200)
                    .padding(.vertical, 12)
                    .neonCardSurface(neon, fill: neon.surface, cornerRadius: 10, border: neon.borderStrong)
                }
                .buttonStyle(.plain)
                Spacer()
            }
            .padding(.horizontal, 24)
        }

        // MARK: - Offline state (screen 08 - offline)

        private var offlineState: some View {
            VStack(spacing: 16) {
                Spacer()
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(neon.yellow.opacity(0.12))
                    .frame(width: 64, height: 64)
                    .overlay(
                        Image(systemName: "wifi.slash")
                            .font(.system(size: 26))
                            .foregroundStyle(neon.yellow)
                    )
                VStack(spacing: 8) {
                    Text("\(server.name) is offline")
                        .font(neon.sans(18).weight(.bold))
                        .foregroundStyle(neon.text)
                    Text("Conduit can only discover sessions while it's connected to the box. Reconnect to scan for sessions you started in your terminal.")
                        .font(neon.sans(13))
                        .foregroundStyle(neon.textFaint)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                HStack(spacing: 10) {
                    Image(systemName: "server.rack")
                        .font(.system(size: 12))
                        .foregroundStyle(neon.textFaint)
                    VStack(alignment: .leading, spacing: 1) {
                        if let ssh = server.ssh {
                            Text("\(ssh.host):\(ssh.port)")
                                .font(neon.mono(12).weight(.semibold))
                                .foregroundStyle(neon.text)
                        } else {
                            Text(server.endpoint.displayHost)
                                .font(neon.mono(12).weight(.semibold))
                                .foregroundStyle(neon.text)
                        }
                        Text("last seen 0 last seen ago")
                            .font(neon.mono(10))
                            .foregroundStyle(neon.textFaint)
                    }
                    Spacer(minLength: 0)
                }
                .padding(12)
                .neonCardSurface(neon, fill: neon.surface, cornerRadius: 10)
                .padding(.horizontal, 24)

                Button {
                    store.selectSavedServer(server.id, autoConnect: true)
                    dismiss()
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "link")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Reconnect")
                            .font(neon.sans(14).weight(.semibold))
                    }
                    .foregroundStyle(neon.bg)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(neon.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 24)
                Spacer()
            }
        }

        // MARK: - Scanning state (cold open, no sessions yet)

        private var scanningState: some View {
            VStack(spacing: 16) {
                Spacer()
                ProgressView()
                    .tint(neon.accent)
                    .scaleEffect(1.4)
                Text("Scanning sessions on \(server.name)...")
                    .font(neon.mono(13))
                    .foregroundStyle(neon.textFaint)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }

        // MARK: - Undo overlay

        @ViewBuilder
        private var undoOverlay: some View {
            if showHideUndo, let row = pendingHideRow {
                HStack {
                    Text("Hidden: \(row.title)")
                        .font(neon.sans(13))
                        .foregroundStyle(neon.text)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Button {
                        store.unhide(foundSessionID: row.externalID, onBox: server.id)
                        snapshot.hiddenIDs.remove(row.externalID)
                        pendingHideRow = nil
                        showHideUndo = false
                    } label: {
                        Text("Undo")
                            .font(neon.sans(13).weight(.semibold))
                            .foregroundStyle(neon.accent)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .neonCardSurface(neon, fill: neon.surface, cornerRadius: 12, border: neon.border)
                .padding(.horizontal, 16)
                .padding(.bottom, 20)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(.easeInOut(duration: 0.25), value: showHideUndo)
            }
        }

        // MARK: - Load

        @MainActor
        private func load() async {
            Telemetry.breadcrumb("found_sessions", "load start",
                data: ["host": server.endpoint.displayHost])

            guard connected else {
                snapshot.discoveryState = .offline
                return
            }

            if snapshot.sessions.isEmpty { snapshot.discoveryState = .scanning }
            snapshot.boxID = server.id
            snapshot.boxName = server.name

            // Adopt-dedupe: match Conduit-native sessions' externalIDs
            let liveIDs = Set(store.sessions.compactMap { $0.id })
            snapshot.adoptedExternalIDs = liveIDs
            snapshot.hiddenIDs = store.hiddenFoundSessions[server.id] ?? []

            let result = await store.fetchDiscoveredSessions(endpoint: server.endpoint)
            guard let result else {
                Telemetry.breadcrumb("found_sessions", "load error",
                    data: ["host": server.endpoint.displayHost])
                snapshot.discoveryState = .error("Could not reach the box")
                return
            }

            snapshot.sessions = result.sessions
            snapshot.totalOnDisk = result.totalOnDisk
            snapshot.discoveryState = result.sessions.isEmpty ? .empty : .loaded

            Telemetry.breadcrumb("found_sessions", "load done",
                data: ["host": server.endpoint.displayHost,
                       "count": "\(result.sessions.count)"])
        }
    }
}

// MARK: - FoundBranchSheet (screen 03)

extension ConduitUI {

    struct FoundBranchSheet: View {
        @Environment(SessionStore.self) private var store
        @Environment(\.neonTheme) private var neon
        @Environment(\.dismiss) private var dismiss

        let server: SavedServer
        let row: FoundSessionRow
        let features: SessionStore.BoxFeatures?
        let onError: (FoundSessionsErrorKind) -> Void
        let onDismiss: () -> Void
        /// Called on a successful branch-adopt so the whole sheet chain
        /// (branch + found-sessions + box-health) dismisses atomically.
        var onSuccess: () -> Void = {}

        // MARK: - Fork probe tri-state
        //
        // Distinguishes three outcomes that `features?.sessionFork` alone cannot:
        //   .checking  - probe in flight (show spinner, not the "not available" copy)
        //   .failed    - probe returned nil (transient / unreachable / 401) - offer Retry
        //   .ready(f)  - probe returned a BoxFeatures struct (f.sessionFork may be true/false)
        //
        // This prevents a transient probe failure from looking like an old broker.
        private enum ForkProbe {
            case checking
            case failed
            case ready(SessionStore.BoxFeatures)
        }

        @State private var isBranching = false
        @State private var forkProbe: ForkProbe = .checking

        var body: some View {
            NavigationStack {
                ZStack {
                    GlassAppBackground()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            sessionHeader
                            amberHonestyCard
                            forkDiagram
                            copyStartsWith
                            Spacer(minLength: 24)
                            branchCTA
                            Text("Nothing on your box is changed or deleted.")
                                .font(neon.mono(11))
                                .foregroundStyle(neon.textFaint)
                                .frame(maxWidth: .infinity)
                                .multilineTextAlignment(.center)
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 20)
                    }
                }
                .navigationTitle("Branch a copy")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
                .tint(neon.accent)
            }
            .appearanceColorScheme()
            .task(id: server.id) { await probeFork() }
        }

        @MainActor
        private func probeFork() async {
            forkProbe = .checking
            Telemetry.breadcrumb("found_sessions", "branch gate probe",
                data: ["host": server.endpoint.displayHost])
            if let f = await store.fetchBoxFeatures(endpoint: server.endpoint) {
                forkProbe = .ready(f)
                Telemetry.breadcrumb("found_sessions", "branch gate ready",
                    data: ["host": server.endpoint.displayHost,
                           "fork": f.sessionFork ? "true" : "false"])
            } else {
                forkProbe = .failed
                Telemetry.breadcrumb("found_sessions", "branch gate probe failed",
                    data: ["host": server.endpoint.displayHost])
            }
        }

        private var sessionHeader: some View {
            let tint = neon.agentTint(forAgent: row.agent)
            return HStack(spacing: 11) {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(tint.opacity(0.14))
                    .frame(width: 38, height: 38)
                    .overlay(
                        Image(systemName: row.agent == "codex" ? "cpu" : "terminal")
                            .font(.system(size: 16))
                            .foregroundStyle(tint)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title)
                        .font(neon.sans(15).weight(.bold))
                        .foregroundStyle(neon.text)
                        .lineLimit(1)
                    Text([row.cwd, row.gitBranch, "\(row.turnCount) turns"]
                            .compactMap { $0 }.joined(separator: " \u{00B7} "))
                        .font(neon.mono(11))
                        .foregroundStyle(neon.textFaint)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                HStack(spacing: 4) {
                    Circle().fill(neon.yellow).frame(width: 7, height: 7)
                    Text("RUNNING")
                        .font(neon.mono(9).weight(.bold))
                        .foregroundStyle(neon.yellow)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(Capsule().fill(neon.yellow.opacity(0.12)))
                .overlay(Capsule().stroke(neon.yellow.opacity(0.3), lineWidth: 1))
            }
            .padding(12)
            .neonCardSurface(neon, fill: neon.surface, cornerRadius: 12)
        }

        private var amberHonestyCard: some View {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(neon.yellow)
                VStack(alignment: .leading, spacing: 5) {
                    Text("This session is live in your terminal")
                        .font(neon.sans(14).weight(.bold))
                        .foregroundStyle(neon.yellow)
                    Text("Conduit can't drive a running session \u{2014} that would leave two copies diverging. Instead it **branches a copy** from the latest saved point. Your terminal session keeps running, untouched.")
                        .font(neon.sans(12))
                        .foregroundStyle(neon.text)
                }
            }
            .padding(14)
            .neonCardSurface(neon, fill: neon.yellow.opacity(0.08), cornerRadius: 12,
                             border: neon.yellow.opacity(0.3))
        }

        private var forkDiagram: some View {
            VStack(spacing: 12) {
                HStack(spacing: 0) {
                    Label("terminal", systemImage: "terminal")
                        .font(neon.mono(11))
                        .foregroundStyle(neon.textFaint)
                    Spacer()
                    Text("keeps running")
                        .font(neon.mono(10))
                        .foregroundStyle(neon.textFaint)
                }
                HStack(spacing: 0) {
                    Label("conduit copy", systemImage: "arrow.branch")
                        .font(neon.mono(11))
                        .foregroundStyle(neon.accent)
                    Spacer()
                    Text("you drive")
                        .font(neon.mono(10))
                        .foregroundStyle(neon.accent)
                }
            }
            .padding(14)
            .neonCardSurface(neon, fill: neon.surface, cornerRadius: 12)
        }

        private var copyStartsWith: some View {
            VStack(alignment: .leading, spacing: 0) {
                Text("THE COPY STARTS WITH")
                    .font(neon.mono(10).weight(.bold))
                    .foregroundStyle(neon.textDim)
                    .tracking(1.0)
                    .padding(.bottom, 10)
                ForEach([
                    ("checkmark.circle.fill", "Full transcript",
                     "\(row.turnCount) turns of context, restored"),
                    ("folder.fill", "Working directory",
                     "\(row.cwd) on a new worktree"),
                    ("gearshape.fill", "Model & settings",
                     "same as the original"),
                ], id: \.0) { (icon, label, detail) in
                    HStack(spacing: 12) {
                        Image(systemName: icon)
                            .font(.system(size: 14))
                            .foregroundStyle(neon.accent)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(label)
                                .font(neon.sans(13).weight(.semibold))
                                .foregroundStyle(neon.text)
                            Text(detail)
                                .font(neon.mono(10.5))
                                .foregroundStyle(neon.textFaint)
                        }
                    }
                    .padding(.vertical, 9)
                    if icon != "gearshape.fill" {
                        Divider().background(neon.border)
                    }
                }
            }
            .padding(14)
            .neonCardSurface(neon, fill: neon.surface, cornerRadius: 12)
        }

        private var branchCTA: some View {
            Group {
                switch forkProbe {
                case .checking:
                    // State 1: probe in flight -- spinner, not the "not available" copy
                    HStack(spacing: 8) {
                        ProgressView()
                            .tint(neon.textFaint)
                            .controlSize(.small)
                        Text("Checking this box...")
                            .font(neon.sans(14).weight(.semibold))
                            .foregroundStyle(neon.textFaint)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(neon.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(neon.border, lineWidth: 1)
                    )

                case .failed:
                    // State 2: transient failure (unreachable/401/decode) -- offer Retry
                    // Do NOT say "not available yet" which wrongly implies old broker.
                    VStack(spacing: 10) {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.branch")
                                .font(.system(size: 14, weight: .semibold))
                            Text("Branch a copy & open")
                                .font(neon.sans(14).weight(.semibold))
                        }
                        .foregroundStyle(neon.textFaint)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(neon.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(neon.border, lineWidth: 1)
                        )

                        HStack(spacing: 6) {
                            Text("Couldn't check this box \u{2014}")
                                .font(neon.mono(11))
                                .foregroundStyle(neon.textFaint)
                            Button {
                                Task { await probeFork() }
                            } label: {
                                Text("Retry")
                                    .font(neon.mono(11).weight(.bold))
                                    .foregroundStyle(neon.accent)
                            }
                            .buttonStyle(.plain)
                        }
                        .multilineTextAlignment(.center)
                    }

                case .ready(let f) where f.sessionFork:
                    // State 4: broker supports fork -- enabled button (unchanged behavior)
                    Button {
                        guard !isBranching else { return }
                        isBranching = true
                        Telemetry.breadcrumb("found_sessions", "branch start",
                            data: ["id": row.externalID])
                        Task {
                            let result = await store.adoptFound(
                                endpoint: server.endpoint,
                                agent: row.agent,
                                externalID: row.externalID,
                                cwd: row.cwd,
                                mode: "fork"
                            )
                            await MainActor.run {
                                isBranching = false
                                if result != nil {
                                    Telemetry.breadcrumb("found_sessions", "branch success",
                                        data: ["id": row.externalID])
                                    onSuccess()
                                } else {
                                    Telemetry.breadcrumb("found_sessions", "branch failed",
                                        data: ["id": row.externalID])
                                    onError(.branchFailed(row))
                                    dismiss()
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 8) {
                            if isBranching {
                                ProgressView()
                                    .tint(neon.bg)
                                    .controlSize(.small)
                                Text("Forking \(row.turnCount) turns into a Conduit copy...")
                                    .font(neon.sans(14).weight(.semibold))
                                    .foregroundStyle(neon.bg)
                            } else {
                                Image(systemName: "arrow.branch")
                                    .font(.system(size: 14, weight: .semibold))
                                Text("Branch a copy & open")
                                    .font(neon.sans(14).weight(.semibold))
                            }
                        }
                        .foregroundStyle(neon.bg)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(isBranching ? neon.accent.opacity(0.7) : neon.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(isBranching)

                default:
                    // State 3: probe succeeded but session_fork == false -- honest old-broker copy
                    VStack(spacing: 10) {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.branch")
                                .font(.system(size: 14, weight: .semibold))
                            Text("Branch a copy & open")
                                .font(neon.sans(14).weight(.semibold))
                        }
                        .foregroundStyle(neon.textFaint)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(neon.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(neon.border, lineWidth: 1)
                        )

                        Text("Branching needs a newer broker on this box. Update it to enable.")
                            .font(neon.mono(11))
                            .foregroundStyle(neon.textFaint)
                            .multilineTextAlignment(.center)
                    }
                }
            }
        }
    }
}

// MARK: - FoundTranscriptView (screen 04)

extension ConduitUI {

    struct FoundTranscriptView: View {
        @Environment(SessionStore.self) private var store
        @Environment(\.neonTheme) private var neon
        @Environment(\.dismiss) private var dismiss

        let server: SavedServer
        let row: FoundSessionRow
        let features: SessionStore.BoxFeatures?
        let onResume: (FoundSessionRow) -> Void
        let onBranch: (FoundSessionRow) -> Void

        enum LoadState {
            case loading
            case loaded([ConversationItem])
            case failed
        }
        @State private var loadState: LoadState = .loading

        var body: some View {
            NavigationStack {
                ZStack(alignment: .bottom) {
                    GlassAppBackground()
                    content
                    bottomCTA
                }
                .navigationTitle(row.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        VStack(spacing: 1) {
                            Text(row.title)
                                .font(neon.sans(14).weight(.semibold))
                                .foregroundStyle(neon.text)
                                .lineLimit(1)
                            HStack(spacing: 5) {
                                Image(systemName: "lock")
                                    .font(.system(size: 9))
                                Text("READ-ONLY \u{00B7} NOT RESUMED")
                                    .font(neon.mono(9).weight(.bold))
                            }
                            .foregroundStyle(neon.textFaint)
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
                .tint(neon.accent)
            }
            .appearanceColorScheme()
            .task { await load() }
        }

        @ViewBuilder
        private var content: some View {
            switch loadState {
            case .loading:
                ProgressView()
                    .tint(neon.accent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded(let items):
                // Find a matching ProjectSession for ChatView (or synthesize one)
                let synthSession = ProjectSession(
                    id: "found-view-\(row.externalID)",
                    name: row.title,
                    assistant: row.agent,
                    branch: row.gitBranch,
                    preview: nil,
                    reasoningEffort: nil,
                    cwd: row.cwd,
                    startedAt: nil,
                    lastActivityAt: nil,
                    displayName: row.title
                )
                ChatView(session: synthSession, readOnlyItems: items)
                    .padding(.bottom, 80) // room for pinned CTA
            case .failed:
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.circle")
                        .font(.system(size: 32))
                        .foregroundStyle(neon.red)
                    Text("Could not load transcript")
                        .font(neon.sans(15).weight(.semibold))
                        .foregroundStyle(neon.text)
                    Text("The box may be unreachable.")
                        .font(neon.sans(13))
                        .foregroundStyle(neon.textFaint)
                    Button {
                        Task { await load() }
                    } label: {
                        Text("Try again")
                            .font(neon.sans(13).weight(.semibold))
                            .foregroundStyle(neon.accent)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }

        private var bottomCTA: some View {
            VStack(spacing: 0) {
                Divider().background(neon.border)
                HStack(spacing: 12) {
                    switch row.state {
                    case .idle:
                        Button {
                            dismiss()
                            onResume(row)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "play.fill")
                                Text("Resume in Conduit")
                                    .font(neon.sans(13).weight(.semibold))
                            }
                            .foregroundStyle(neon.bg)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(neon.accent)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    case .running:
                        Button {
                            let forkOk = features?.sessionFork == true
                            if forkOk {
                                dismiss()
                                onBranch(row)
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.branch")
                                Text(features?.sessionFork == true
                                     ? "Branch a copy"
                                     : "Branch (unavailable on this box)")
                                    .font(neon.sans(13).weight(.semibold))
                            }
                            .foregroundStyle(features?.sessionFork == true ? neon.bg : neon.textFaint)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(features?.sessionFork == true ? neon.yellow : neon.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .disabled(features?.sessionFork != true)
                    case .adopted:
                        EmptyView()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial)
            }
        }

        private func load() async {
            Telemetry.breadcrumb("found_sessions", "view transcript",
                data: ["id": row.externalID])
            let items = await store.fetchDiscoveredTranscript(
                endpoint: server.endpoint,
                agent: row.agent,
                externalID: row.externalID
            )
            await MainActor.run {
                if let items {
                    loadState = .loaded(items)
                } else {
                    loadState = .failed
                }
            }
        }
    }
}

// MARK: - FoundResumeProgressView (screen 06)

extension ConduitUI {

    struct FoundResumeProgressView: View {
        @Environment(SessionStore.self) private var store
        @Environment(\.neonTheme) private var neon
        @Environment(\.dismiss) private var dismiss

        let server: SavedServer
        let row: FoundSessionRow
        let onError: (FoundSessionsErrorKind) -> Void
        let onSuccess: () -> Void

        enum Step: Int, CaseIterable {
            case reading = 0
            case ingesting
            case restoring
            case handoff

            var label: String {
                switch self {
                case .reading: return "Reading saved transcript"
                case .ingesting: return "Re-ingesting turns of context"
                case .restoring: return "Restoring working tree"
                case .handoff: return "Handing off to agent"
                }
            }
        }

        @State private var currentStep: Step = .reading
        @State private var progress: Double = 0.0
        @State private var isCancelled = false

        var body: some View {
            NavigationStack {
                ZStack {
                    GlassAppBackground()
                    VStack(spacing: 24) {
                        sessionHeader

                        // Progress ring
                        ZStack {
                            Circle()
                                .stroke(neon.border, lineWidth: 10)
                                .frame(width: 100, height: 100)
                            Circle()
                                .trim(from: 0, to: progress)
                                .stroke(neon.accent,
                                        style: StrokeStyle(lineWidth: 10, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                                .frame(width: 100, height: 100)
                                .animation(.easeInOut(duration: 0.4), value: progress)
                            Text("\(Int(progress * 100))%")
                                .font(neon.mono(18).weight(.bold))
                                .foregroundStyle(neon.text)
                        }

                        VStack(spacing: 4) {
                            Text("Restoring full context")
                                .font(neon.sans(16).weight(.bold))
                                .foregroundStyle(neon.text)
                            Text("Large transcripts take a moment \u{2014} the agent picks up exactly where you left off")
                                .font(neon.sans(12))
                                .foregroundStyle(neon.textFaint)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 20)
                        }

                        // Checklist
                        VStack(spacing: 0) {
                            ForEach(Step.allCases, id: \.rawValue) { step in
                                stepRow(step)
                                if step != .handoff {
                                    Divider().background(neon.border)
                                }
                            }
                        }
                        .neonCardSurface(neon, fill: neon.surface, cornerRadius: 12)
                        .padding(.horizontal, 20)

                        Button {
                            isCancelled = true
                            dismiss()
                        } label: {
                            Text("Cancel")
                                .font(neon.sans(13).weight(.semibold))
                                .foregroundStyle(neon.textDim)
                                .frame(maxWidth: 200)
                                .padding(.vertical, 10)
                                .neonCardSurface(neon, fill: neon.surface, cornerRadius: 10)
                        }
                        .buttonStyle(.plain)

                        Spacer()
                    }
                    .padding(.top, 20)
                }
                .navigationTitle("Resuming session")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Cancel") { isCancelled = true; dismiss() }
                    }
                }
                .tint(neon.accent)
            }
            .appearanceColorScheme()
            .task { await doResume() }
        }

        private var sessionHeader: some View {
            let tint = neon.agentTint(forAgent: row.agent)
            return HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(tint.opacity(0.14))
                    .frame(width: 34, height: 34)
                    .overlay(
                        Image(systemName: row.agent == "codex" ? "cpu" : "terminal")
                            .font(.system(size: 14))
                            .foregroundStyle(tint)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title)
                        .font(neon.sans(13).weight(.semibold))
                        .foregroundStyle(neon.text)
                        .lineLimit(1)
                    Text("\(row.cwd) \u{00B7} \(row.gitBranch ?? "") \u{00B7} \(row.turnCount) turns")
                        .font(neon.mono(10))
                        .foregroundStyle(neon.textFaint)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
        }

        private func stepRow(_ step: Step) -> some View {
            let isDone = step.rawValue < currentStep.rawValue
            let isActive = step == currentStep
            return HStack(spacing: 12) {
                Group {
                    if isDone {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(neon.accent)
                    } else if isActive {
                        ProgressView()
                            .tint(neon.accent)
                            .controlSize(.small)
                    } else {
                        Circle()
                            .stroke(neon.border, lineWidth: 1.5)
                            .frame(width: 16, height: 16)
                    }
                }
                .font(.system(size: 16))
                .frame(width: 18)

                Text(step == .ingesting
                     ? "Re-ingesting \(row.turnCount) turns of context"
                     : (step == .restoring && row.gitBranch != nil
                        ? "Restoring working tree \u{00B7} \(row.gitBranch!)"
                        : (step == .handoff
                           ? "Handing off to \(row.agent)"
                           : step.label)))
                    .font(neon.sans(13))
                    .foregroundStyle(isDone ? neon.text : (isActive ? neon.text : neon.textFaint))

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }

        @MainActor
        private func doResume() async {
            guard !isCancelled else { return }

            // Approximate stepped progress off adopt call + connect milestones.
            // No special broker events -- we simulate the steps.
            let steps: [(Step, Double, UInt64)] = [
                (.reading,   0.25, 500),
                (.ingesting, 0.60, 800),
                (.restoring, 0.85, 400),
                (.handoff,   1.0,  200),
            ]

            Telemetry.breadcrumb("found_sessions", "resume start",
                data: ["id": row.externalID])

            // Kick off the actual adopt call
            let adoptTask = Task<String?, Never> {
                await store.adoptFound(
                    endpoint: server.endpoint,
                    agent: row.agent,
                    externalID: row.externalID,
                    cwd: row.cwd,
                    mode: "resume"
                )
            }

            for (step, prog, delay) in steps {
                guard !isCancelled else { return }
                withAnimation { currentStep = step; progress = prog }
                try? await Task.sleep(nanoseconds: delay * 1_000_000)
            }

            let result = await adoptTask.value
            guard !isCancelled else { return }

            if result != nil {
                Telemetry.breadcrumb("found_sessions", "resume success",
                    data: ["id": row.externalID])
                onSuccess()
            } else {
                Telemetry.breadcrumb("found_sessions", "resume error",
                    data: ["id": row.externalID])
                onError(.resumeFailed(row))
            }
        }
    }
}

// MARK: - FoundSessionsErrorKind + FoundErrorSheet (screen 07)

extension ConduitUI {

    enum FoundSessionsErrorKind: Identifiable, Equatable {
        case resumeFailed(FoundSessionRow)
        case branchFailed(FoundSessionRow)
        case sessionVanished

        var id: String {
            switch self {
            case .resumeFailed(let r): return "resume-\(r.externalID)"
            case .branchFailed(let r): return "branch-\(r.externalID)"
            case .sessionVanished: return "vanished"
            }
        }
    }

    struct FoundErrorSheet: View {
        @Environment(\.neonTheme) private var neon
        @Environment(\.dismiss) private var dismiss

        let kind: FoundSessionsErrorKind
        let onRetry: () -> Void
        let onViewTranscript: () -> Void
        let onDismiss: () -> Void

        private var icon: String {
            switch kind {
            case .resumeFailed: return "exclamationmark.triangle.fill"
            case .branchFailed: return "arrow.branch"
            case .sessionVanished: return "magnifyingglass"
            }
        }
        private var iconTint: Color {
            switch kind {
            case .resumeFailed: return neon.red
            case .branchFailed: return neon.red
            case .sessionVanished: return neon.yellow
            }
        }
        private var title: String {
            switch kind {
            case .resumeFailed: return "Couldn't restore the session"
            case .branchFailed: return "Couldn't branch a copy"
            case .sessionVanished: return "This session is no longer here"
            }
        }
        private var message: String {
            switch kind {
            case .resumeFailed:
                return "The box dropped while re-ingesting the transcript. Your session on disk is untouched \u{2014} try again."
            case .branchFailed:
                return "Conduit couldn't create a new worktree \u{2014} the branch may be checked out elsewhere. Your terminal session keeps running, untouched."
            case .sessionVanished:
                return "It was removed on the box, or resumed by hand in your terminal since we last scanned. Nothing was lost on your end."
            }
        }
        private var reassurance: String {
            switch kind {
            case .resumeFailed: return "Your session on disk is untouched."
            case .branchFailed: return "Your terminal session keeps running, untouched."
            case .sessionVanished: return "Nothing was lost on your end."
            }
        }

        var body: some View {
            NavigationStack {
                ZStack {
                    GlassAppBackground()
                    VStack(spacing: 24) {
                        Spacer()
                        // Error icon
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(iconTint.opacity(0.12))
                            .frame(width: 72, height: 72)
                            .overlay(
                                Image(systemName: icon)
                                    .font(.system(size: 28))
                                    .foregroundStyle(iconTint)
                            )

                        VStack(spacing: 8) {
                            Text(title)
                                .font(neon.sans(18).weight(.bold))
                                .foregroundStyle(neon.text)
                                .multilineTextAlignment(.center)
                            Text(message)
                                .font(neon.sans(13))
                                .foregroundStyle(neon.textFaint)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 16)
                        }

                        // Context chip
                        if case .resumeFailed(let row) = kind {
                            HStack(spacing: 6) {
                                Image(systemName: "folder")
                                    .font(.system(size: 11))
                                    .foregroundStyle(neon.textFaint)
                                Text("\(row.gitBranch ?? row.cwd) \u{00B7} re-ingest failed")
                                    .font(neon.mono(10))
                                    .foregroundStyle(neon.textFaint)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .neonCardSurface(neon, fill: neon.surface, cornerRadius: 8)
                        } else if case .branchFailed(let row) = kind {
                            HStack(spacing: 6) {
                                Image(systemName: "folder")
                                    .font(.system(size: 11))
                                    .foregroundStyle(neon.textFaint)
                                Text("\(row.cwd) \u{00B7} worktree conflict")
                                    .font(neon.mono(10))
                                    .foregroundStyle(neon.textFaint)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .neonCardSurface(neon, fill: neon.surface, cornerRadius: 8)
                        }

                        // CTAs
                        VStack(spacing: 10) {
                            Button {
                                if case .sessionVanished = kind {
                                    onRetry()
                                } else {
                                    onRetry()
                                }
                            } label: {
                                HStack(spacing: 7) {
                                    Image(systemName: "arrow.clockwise")
                                        .font(.system(size: 13, weight: .semibold))
                                    Text(kind == .sessionVanished ? "Rescan box" : "Retry")
                                        .font(neon.sans(14).weight(.semibold))
                                }
                                .foregroundStyle(neon.bg)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(neon.accent)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 24)

                            if kind != .sessionVanished {
                                Button {
                                    onViewTranscript()
                                } label: {
                                    Text("View transcript instead")
                                        .font(neon.sans(13))
                                        .foregroundStyle(neon.textDim)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 12)
                                }
                                .buttonStyle(.plain)
                            } else {
                                Button {
                                    onDismiss()
                                } label: {
                                    Text("Dismiss")
                                        .font(neon.sans(13))
                                        .foregroundStyle(neon.textDim)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 12)
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        Spacer()
                    }
                }
                .navigationTitle(kind == .sessionVanished ? "Resume session" : "Resume session")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Dismiss") { onDismiss() }
                    }
                }
                .tint(neon.accent)
            }
            .appearanceColorScheme()
        }
    }
}
