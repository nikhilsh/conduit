import SwiftUI

/// Pure-data view-model for `SessionsScreen`. The screen renders a
/// section list grouped by recency with a search bar at top; the model
/// owns the filter + group derivation so `SessionsScreenModelTests` can
/// pin the behaviour without hosting a SwiftUI view.
///
/// Sections are TIME buckets — "Today", "Yesterday", "Previous 7 Days",
/// "Earlier" — derived from each row's `lastSeen`. Only non-empty buckets
/// are emitted, always in that fixed order; rows within a bucket are
/// latest-first. The server identity moves to a per-row chip (so a
/// multi-server history is still readable) rather than being the section.
struct SessionsScreenModel: Equatable {
    /// History filter chip (handoff §A.3): All / Running / claude / codex.
    /// `Running` keys off the persisted lifecycle (`status == .live`); the
    /// two agent chips match `agent` case-insensitively. Pure so
    /// `SessionsScreenModelTests` can pin each predicate.
    enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case running = "Running"
        case claude = "claude"
        case codex = "codex"

        var id: String { rawValue }

        /// Does a row pass this filter? `all` admits everything.
        func matches(_ row: SavedSession) -> Bool {
            switch self {
            case .all:     return true
            case .running: return row.status == .live
            case .claude:  return row.agent.lowercased() == "claude"
            case .codex:   return row.agent.lowercased() == "codex"
            }
        }
    }

    /// A row's at-a-glance result (handoff §A.3). The persisted index only
    /// carries a `SavedSessionStatus` (live / exited / unknown) — there is
    /// NO PR / merged / needs-you signal in `SavedSession`, so we never
    /// fabricate those. A live row reads `running`; everything terminal or
    /// unknown reads the honest neutral `ended`. The richer cases stay in
    /// the enum so the chip vocabulary matches the design and a future
    /// data source (PR state, exit code) can light them up without a
    /// re-skin.
    enum Outcome: Equatable {
        case running
        case pr(Int)
        case merged
        case needsYou
        case ended
        case failed

        /// Derive from the only persisted outcome signal we have today.
        static func from(_ row: SavedSession) -> Outcome {
            switch row.status {
            case .live:    return .running
            case .exited:  return .ended
            case .unknown: return .ended
            }
        }
    }

    /// Recency bucket a row falls into, by `lastSeen` relative to now.
    /// `rawValue` is the section title; `order` fixes the render sequence.
    enum Bucket: String, CaseIterable {
        case today = "Today"
        case yesterday = "Yesterday"
        case previous7Days = "Previous 7 Days"
        case earlier = "Earlier"

        /// Classify a date relative to `now` on `calendar`. Uses a
        /// `now`-relative whole-day distance (not `Calendar.isDateInYesterday`,
        /// which ignores the anchor and compares to the real clock) so the
        /// buckets are deterministic for an injected `now` in tests.
        static func classify(_ date: Date, now: Date, calendar: Calendar) -> Bucket {
            let distance = SessionNaming.dayDistance(from: date, to: now, calendar: calendar) ?? Int.max
            if distance <= 0 { return .today }
            if distance == 1 { return .yesterday }
            // Within the trailing 7 days (but not today/yesterday).
            if distance < 7 { return .previous7Days }
            return .earlier
        }
    }

    /// One time-bucket section, in render order.
    struct Section: Equatable, Identifiable {
        let bucket: Bucket
        let sessions: [SavedSession]

        var title: String { bucket.rawValue }
        var id: String { bucket.rawValue }
    }

    let sections: [Section]
    let totalRows: Int
    let isEmpty: Bool
    /// serverID → friendly server name, for the per-row server chip.
    let serverNames: [String: String]

    /// Friendly name for a row's server (falls back to the raw id).
    func serverName(for row: SavedSession) -> String {
        serverNames[row.serverID] ?? row.serverID
    }

    /// Build a model from the saved store + the saved-server list. The
    /// search filter is applied case-insensitively to the session
    /// summary, id, agent, and cwd. `now`/`calendar` are injectable so
    /// the time-bucket grouping is deterministic in tests.
    static func from(
        sessions: [SavedSession],
        savedServers: [SavedServer],
        query: String,
        filter: Filter = .all,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> SessionsScreenModel {
        // Filter chip first (cheap), then the search predicate.
        let chipped = filter == .all ? sessions : sessions.filter { filter.matches($0) }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered: [SavedSession]
        if trimmed.isEmpty {
            filtered = chipped
        } else {
            let needle = trimmed.lowercased()
            filtered = chipped.filter { row in
                row.summary.lowercased().contains(needle)
                    || row.id.lowercased().contains(needle)
                    || row.agent.lowercased().contains(needle)
                    || (row.cwd ?? "").lowercased().contains(needle)
            }
        }

        // Group by recency bucket. A row whose `lastSeen` doesn't parse
        // sinks into "Earlier" (it's the catch-all oldest bucket). Within
        // each bucket we preserve the already-sorted latest-first order of
        // the input (`SavedSessionsStore.recent` returns latest-first).
        var byBucket: [Bucket: [SavedSession]] = [:]
        for row in filtered {
            let bucket: Bucket
            if let date = SessionNaming.parseTimestamp(row.lastSeen) {
                bucket = Bucket.classify(date, now: now, calendar: calendar)
            } else {
                bucket = .earlier
            }
            byBucket[bucket, default: []].append(row)
        }

        // Emit buckets in fixed order, dropping empties.
        let sections = Bucket.allCases.compactMap { bucket -> Section? in
            guard let rows = byBucket[bucket], !rows.isEmpty else { return nil }
            return Section(bucket: bucket, sessions: rows)
        }

        let nameLookup: [String: String] = Dictionary(
            savedServers.map { ($0.id, $0.name) },
            uniquingKeysWith: { first, _ in first }
        )

        return SessionsScreenModel(
            sections: sections,
            totalRows: filtered.count,
            isEmpty: sessions.isEmpty,
            serverNames: nameLookup
        )
    }
}

/// Outcome of tapping/resuming a row on the History screen. Read-only is
/// the DEFAULT — we only attach the interactive live session when the row
/// is POSITIVELY confirmed currently-live on the connected broker.
enum ResumeDecision: Equatable {
    /// Open the read-only persisted transcript (`SavedTranscriptView`).
    case readOnlyTranscript
    /// Attach to the genuinely-live session on the broker (interactive).
    case attachLive
}

extension ResumeDecision {
    /// Pure decision for `SessionsScreen.resume(_:)`, hoisted out of the
    /// view so it can be pinned by `SessionsScreenModelTests` without a
    /// live store.
    ///
    /// We attach the interactive session ONLY when ALL hold:
    ///   1. the row is persisted `.live` (a non-`.live` row never resumes
    ///      interactive — exited/unknown always go read-only),
    ///   2. we are connected to the row's server (`connectedToRowServer`),
    ///   3. the session id is present in the live list (`sessionIsListed`),
    ///   4. the store does NOT consider it read-only
    ///      (`storeSaysReadOnly == false`, i.e. confirmed-live).
    ///
    /// Every other case — `.exited`, `.unknown`, a stale `.live` not in the
    /// live list, a `.live` on a different server we'd have to switch to,
    /// or a `.live` the store has positively marked read-only — resolves to
    /// the read-only transcript. The user strongly prefers a read-only open
    /// over a wrong interactive one, so we fail closed.
    static func decide(
        status: SavedSessionStatus,
        connectedToRowServer: Bool,
        sessionIsListed: Bool,
        storeSaysReadOnly: Bool
    ) -> ResumeDecision {
        guard status == .live,
              connectedToRowServer,
              sessionIsListed,
              !storeSaysReadOnly
        else {
            return .readOnlyTranscript
        }
        return .attachLive
    }
}

/// "Resume an old thread" — top-level screen pushed from the Home tab's
/// `clock.arrow.circlepath` toolbar button. Shows every session the
/// client has ever seen, grouped by server, with a search bar at top
/// and a swipe-to-resume action that re-establishes the WebSocket if
/// needed and selects the row via `store.switchTo(sessionID:)`.
///
/// Conduit parity audit item A.8. Distinct from `ThreadSwitcherSheet`
/// (#42), which shows live parallel sessions on the *current* server —
/// this is the *historical* surface, across servers, including ones
/// that have already exited.
struct SessionsScreen: View {
    @Environment(SessionStore.self) private var store
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.neonTheme) private var neon
    @Environment(\.dismiss) private var dismiss

    @State private var query: String = ""
    /// Active history filter chip (All / Running / claude / codex).
    @State private var filter: SessionsScreenModel.Filter = .all
    /// Saved-session row pending deletion (drives the confirmation
    /// alert for the swipe-to-delete affordance). Identifiable so the
    /// alert can key its presentation off the pending row.
    @State private var pendingDelete: PendingSavedSessionDelete?
    /// Row whose persisted transcript should open read-only (the default
    /// for history opens — any row not confirmed currently-live). Drives a
    /// `navigationDestination(item:)` push into `SavedTranscriptView`.
    /// Keyed by `compoundID` (not the bare session id, which isn't unique
    /// across servers).
    @State private var transcriptTarget: TranscriptTarget?

    private var savedStore: SavedSessionsStore { SavedSessionsStore.shared }

    var body: some View {
        ZStack {
            GlassAppBackground()

            VStack(spacing: 12) {
                searchField
                filterBar

                let model = SessionsScreenModel.from(
                    sessions: savedStore.recent(limit: 500),
                    savedServers: store.savedServers,
                    query: query,
                    filter: filter
                )

                if model.isEmpty {
                    emptyState
                } else if model.sections.isEmpty {
                    noMatchesState
                } else {
                    sectionList(model)
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 8)
        }
        .navigationTitle("Sessions")
        .navigationBarTitleDisplayMode(.inline)
        .neonAccentTint()
        .navigationDestination(item: $transcriptTarget) { target in
            SavedTranscriptView(session: target.session).environment(store)
        }
        .alert(
            "Delete permanently?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { target in
            Button("Delete", role: .destructive) {
                // History is the ONLY place permanent delete lives (two-tier
                // model): this tombstones the row (`SavedSessionsStore.remove`)
                // so it leaves History forever, and ends it on the broker
                // (idempotent for already-archived/exited rows).
                store.permanentlyDelete(sessionID: target.id)
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDelete = nil
            }
        } message: { target in
            Text("Removes this session from History. This can't be undone.\n\n\(target.title)")
        }
        .appearanceColorScheme()
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(neon.textFaint)
            TextField("Search by name or summary…", text: $query)
                .textFieldStyle(.plain)
                .font(neon.sans(15))
                .foregroundStyle(neon.text)
                .submitLabel(.search)
                .accessibilityIdentifier("SessionsScreen.search")
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(neon.textFaint)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .neonCardSurface(neon, fill: neon.surface, cornerRadius: 18)
        .padding(.horizontal, 14)
    }

    /// Filter chips (handoff §A.3): All / Running / claude / codex. The
    /// active chip fills with the neon accent; the rest are quiet hairline
    /// capsules. A horizontal scroll keeps them on one line on narrow
    /// devices without wrapping.
    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(SessionsScreenModel.Filter.allCases) { chip in
                    filterChip(chip)
                }
            }
            .padding(.horizontal, 14)
        }
    }

    private func filterChip(_ chip: SessionsScreenModel.Filter) -> some View {
        let isActive = filter == chip
        // The agent chips read in their own tint when active, the rest in
        // the palette accent.
        let tint: Color = {
            switch chip {
            case .claude: return neon.agentTint(forAgent: "claude")
            case .codex:  return neon.agentTint(forAgent: "codex")
            default:      return neon.accent
            }
        }()
        return Button {
            withAnimation(.easeOut(duration: 0.16)) { filter = chip }
        } label: {
            Text(chip.rawValue)
                .font(neon.mono(12).weight(.semibold))
                .foregroundStyle(isActive ? neon.accentText : neon.textDim)
                .padding(.horizontal, 13)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(isActive ? tint : neon.surface)
                )
                .overlay(
                    Capsule().stroke(isActive ? Color.clear : neon.border, lineWidth: 1)
                )
                .neonGlowBox(isActive && neon.glow ? neon.glowBox?.tinted(tint) : nil)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    @ViewBuilder
    private func sectionList(_ model: SessionsScreenModel) -> some View {
        // Multi-server histories show a server chip per row; a
        // single-server setup doesn't need the redundant chip.
        let showServerChip = Set(model.sections.flatMap { $0.sessions.map(\.serverID) }).count > 1
        List {
            ForEach(model.sections) { section in
                Section {
                    ForEach(section.sessions, id: \.compoundID) { row in
                        sessionRow(row, serverName: showServerChip ? model.serverName(for: row) : nil)
                            .listRowBackground(Color.clear)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    pendingDelete = PendingSavedSessionDelete(
                                        id: row.id,
                                        title: rowTitle(row)
                                    )
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                        .accessibilityLabel("Delete permanently")
                                }
                                Button {
                                    resume(row)
                                } label: {
                                    Label("Resume", systemImage: "arrow.uturn.forward")
                                }
                                .neonAccentTint()
                            }
                    }
                } header: {
                    sectionHeader(section)
                }
                .listSectionSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func sectionHeader(_ section: SessionsScreenModel.Section) -> some View {
        HStack(spacing: 6) {
            Text(section.title)
                .font(neon.mono(11).weight(.bold))
                .foregroundStyle(neon.accent)
                .textCase(.uppercase)
                .tracking(0.8)
            Spacer()
            Text("\(section.sessions.count) session\(section.sessions.count == 1 ? "" : "s")")
                .font(neon.mono(10.5))
                .foregroundStyle(neon.textDim)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
    }

    private func sessionRow(_ row: SavedSession, serverName: String?) -> some View {
        let tint = neon.agentTint(forAgent: row.agent)
        return Button {
            resume(row)
        } label: {
            HStack(spacing: 12) {
                rowAvatar(tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(rowTitle(row))
                        .font(neon.sans(15).weight(.semibold))
                        .foregroundStyle(neon.text)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(row.agent.lowercased())
                            .font(neon.mono(11).weight(.semibold))
                            .foregroundStyle(tint)
                        Text("·")
                            .font(neon.mono(11))
                            .foregroundStyle(neon.textFaint)
                        Text(relativeTime(row.lastSeen))
                            .font(neon.mono(11))
                            .foregroundStyle(neon.textFaint)
                            .lineLimit(1)
                        if let serverName {
                            Text("·")
                                .font(neon.mono(11))
                                .foregroundStyle(neon.textFaint)
                            HStack(spacing: 3) {
                                Image(systemName: "server.rack")
                                    .font(.system(size: 9, weight: .semibold))
                                Text(serverName)
                                    .font(neon.mono(11))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .foregroundStyle(neon.textFaint)
                        }
                    }
                }
                Spacer(minLength: 8)
                outcomeChip(SessionsScreenModel.Outcome.from(row))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .neonCardSurface(neon, fill: neon.surface, cornerRadius: 14)
        }
        .buttonStyle(.plain)
    }

    /// Agent-tinted rounded avatar with the Conduit mark, mirroring the
    /// Session Info identity tile.
    private func rowAvatar(_ tint: Color) -> some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(tint.opacity(neon.dark ? 0.14 : 0.10))
            .frame(width: 38, height: 38)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(tint.opacity(0.35), lineWidth: 1)
            )
            .overlay(ConduitUI.ConduitMark(size: 21, color: tint, glow: neon.glow))
    }

    /// Outcome chip (handoff §A.3). Color + label come from the persisted
    /// status via `Outcome`; the richer PR/merged cases are honored in the
    /// switch for when a data source lights them up, but `Outcome.from`
    /// only emits `running` / `ended` today.
    @ViewBuilder
    private func outcomeChip(_ outcome: SessionsScreenModel.Outcome) -> some View {
        let (label, color, icon): (String, Color, String?) = {
            switch outcome {
            case .running:    return ("running", neon.green, "dot.radiowaves.left.and.right")
            case .pr(let n):  return ("PR #\(n)", neon.blue, "arrow.triangle.pull")
            case .merged:     return ("merged", neon.purple, "arrow.triangle.merge")
            case .needsYou:   return ("needs you", neon.yellow, "exclamationmark.circle")
            case .ended:      return ("ended", neon.textDim, nil)
            case .failed:     return ("failed", neon.red, "xmark.octagon")
            }
        }()
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
            }
            Text(label)
                .font(neon.mono(10).weight(.semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(color.opacity(0.12)))
        .overlay(Capsule().stroke(color.opacity(0.3), lineWidth: 1))
        .neonGlowBox(outcome == .running && neon.glow ? neon.glowBox?.tinted(color) : nil)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer(minLength: 24)
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(neon.accent)
            Text("No sessions yet")
                .font(neon.sans(17).weight(.semibold))
                .foregroundStyle(neon.text)
            Text("Start one from the Home screen — it'll show up here so you can pick up later.")
                .font(neon.sans(13))
                .foregroundStyle(neon.textDim)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noMatchesState: some View {
        VStack(spacing: 10) {
            Spacer(minLength: 24)
            Image(systemName: "questionmark.circle")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(neon.accent)
            Text("No matches")
                .font(neon.sans(17).weight(.semibold))
                .foregroundStyle(neon.text)
            Text("Try a shorter query or a different filter — we match against the session summary, id, agent, and cwd.")
                .font(neon.sans(13))
                .foregroundStyle(neon.textDim)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Helpers

    /// Open flow (build task #35). READ-ONLY IS THE DEFAULT — opening a
    /// row from history pushes the read-only persisted transcript
    /// (`SavedTranscriptView` → `fetchConversation`) UNLESS the session is
    /// POSITIVELY confirmed currently-live on the connected broker, in
    /// which case we attach the interactive live surface.
    ///
    /// The interactive `attachLiveSession` branch fires only when ALL of:
    ///   1. the row's persisted status is `.live`,
    ///   2. we are already connected to the row's server,
    ///   3. the session id is present in `store.sessions` (the live list),
    ///   4. `!store.isReadOnly(id)` — the store positively considers it
    ///      live/running right now.
    /// See `ResumeDecision.decide` for the pure rule.
    ///
    /// Why this inversion: the persisted `SavedSession.status` lags reality
    /// — a session that died while the app was disconnected, or one the
    /// broker no longer truly runs (removed/ended), keeps a stale `.live`.
    /// The old code fell through to `attachLiveSession` whenever it wasn't
    /// *positively* known dead, so those stale-`.live` rows opened
    /// interactive (the bug). We now require proof of liveness.
    ///
    /// Cross-server: if the row is on a different server we'd have to
    /// switch + reconnect to even learn whether it's live — that's racy and
    /// `connectedToRowServer` is false, so we deliberately open the
    /// read-only transcript rather than blind-attach an unconfirmed
    /// session. A genuinely-live session is still reachable interactively
    /// from the Home list once that server is connected.
    private func resume(_ row: SavedSession) {
        let server = store.savedServers.first(where: { $0.id == row.serverID })
        // No saved server entry → treat as the current server (single-server
        // setups don't have a saved-server row). A mismatched endpoint means
        // the row lives on a different, not-currently-connected server.
        let connectedToRowServer = server.map { store.endpoint == $0.endpoint } ?? true

        let decision = ResumeDecision.decide(
            status: row.status,
            connectedToRowServer: connectedToRowServer,
            sessionIsListed: store.sessions.contains(where: { $0.id == row.id }),
            storeSaysReadOnly: store.isReadOnly(sessionID: row.id)
        )

        switch decision {
        case .readOnlyTranscript:
            transcriptTarget = TranscriptTarget(session: row)
        case .attachLive:
            store.attachLiveSession(sessionID: row.id, assistant: row.agent)
            dismiss()
        }
    }

    /// Friendly history-row title. Mirrors the live `displayName(for:)`
    /// priority on the persisted metadata we carry: the stored `summary`
    /// is the first user message (`SavedSessionsStore.upsert` persists it),
    /// trimmed to a short single line; with no summary we fall back to
    /// `"<agent> · <relative start time>"`. NEVER the raw UUID.
    private func rowTitle(_ row: SavedSession) -> String {
        if let custom = store.displayNames[row.id],
           !SessionNaming.looksLikeRawID(custom, sessionID: row.id) {
            return custom
        }
        if let aiTitle = store.brokerTitles[row.id]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !aiTitle.isEmpty,
           !SessionNaming.looksLikeRawID(aiTitle, sessionID: row.id) {
            return aiTitle
        }
        if let title = SessionNaming.titleFromMessage(row.summary) {
            return title
        }
        return SessionNaming.fallbackName(agent: row.agent, startedAt: row.firstSeen)
    }

    /// Best-effort relative time. The saved store keeps RFC3339 strings;
    /// we render "now" / "Xm" / "Xh" / "Xd" / absolute date.
    private func relativeTime(_ raw: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: raw) else { return raw }
        let now = Date()
        let delta = now.timeIntervalSince(date)
        if delta < 60 { return "now" }
        if delta < 3600 { return "\(Int(delta / 60))m" }
        if delta < 86_400 { return "\(Int(delta / 3600))h" }
        if delta < 86_400 * 14 { return "\(Int(delta / 86_400))d" }
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .none
        return f.string(from: date)
    }
}

/// Carrier for the SessionsScreen swipe-to-delete confirmation alert.
/// Identifiable so `.alert(presenting:)` keys correctly off the
/// pending row and doesn't pick up a stale id between successive
/// swipes.
private struct PendingSavedSessionDelete: Identifiable, Equatable {
    let id: String
    let title: String
}

/// Carrier for the read-only transcript push. Keyed by `compoundID`
/// (server-scoped) so two rows that share a bare session id across
/// paired harnesses don't collide in `navigationDestination(item:)`.
private struct TranscriptTarget: Identifiable, Hashable {
    let session: SavedSession
    var id: String { session.compoundID }
    // `navigationDestination(item:)` requires Hashable; key off the
    // stable compound id rather than relying on SavedSession's
    // synthesized conformances.
    static func == (lhs: TranscriptTarget, rhs: TranscriptTarget) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
