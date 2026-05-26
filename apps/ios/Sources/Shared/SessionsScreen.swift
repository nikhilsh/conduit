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
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> SessionsScreenModel {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered: [SavedSession]
        if trimmed.isEmpty {
            filtered = sessions
        } else {
            let needle = trimmed.lowercased()
            filtered = sessions.filter { row in
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
/// Litter parity audit item A.8. Distinct from `ThreadSwitcherSheet`
/// (#42), which shows live parallel sessions on the *current* server —
/// this is the *historical* surface, across servers, including ones
/// that have already exited.
struct SessionsScreen: View {
    @Environment(SessionStore.self) private var store
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    @State private var query: String = ""
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
            SweKittyTheme.backgroundGradient(for: colorScheme)
                .ignoresSafeArea()

            VStack(spacing: 14) {
                searchField

                let model = SessionsScreenModel.from(
                    sessions: savedStore.recent(limit: 500),
                    savedServers: store.savedServers,
                    query: query
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
        .tint(SweKittyTheme.accentStrong)
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
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(SweKittyTheme.textMuted)
            TextField("Search by name or summary…", text: $query)
                .textFieldStyle(.plain)
                .submitLabel(.search)
                .accessibilityIdentifier("SessionsScreen.search")
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(SweKittyTheme.textMuted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassRoundedRect(cornerRadius: 18)
        .padding(.horizontal, 14)
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
                                .tint(SweKittyTheme.accentStrong)
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
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(SweKittyTheme.textPrimary)
            Text("·")
                .foregroundStyle(SweKittyTheme.textMuted)
            Text("\(section.sessions.count) session\(section.sessions.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(SweKittyTheme.textMuted)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private func sessionRow(_ row: SavedSession, serverName: String?) -> some View {
        Button {
            resume(row)
        } label: {
            HStack(spacing: 12) {
                HealthDot(health: healthLabel(for: row.status), size: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text(rowTitle(row))
                        .font(.system(.body, design: .monospaced).weight(.semibold))
                        .foregroundStyle(SweKittyTheme.textPrimary)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(row.agent)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(SweKittyTheme.textSecondary)
                        Text("·")
                            .font(.caption)
                            .foregroundStyle(SweKittyTheme.textMuted)
                        Text(relativeTime(row.lastSeen))
                            .font(.caption.monospaced())
                            .foregroundStyle(SweKittyTheme.textMuted)
                            .lineLimit(1)
                        if let serverName {
                            Text("·")
                                .font(.caption)
                                .foregroundStyle(SweKittyTheme.textMuted)
                            HStack(spacing: 3) {
                                Image(systemName: "server.rack")
                                    .font(.system(size: 9, weight: .semibold))
                                Text(serverName)
                                    .font(.caption.weight(.medium))
                                    .lineLimit(1)
                            }
                            .foregroundStyle(SweKittyTheme.textMuted)
                        }
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(SweKittyTheme.textMuted)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .glassRect(cornerRadius: SweKittyTheme.smallCornerRadius)
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer(minLength: 24)
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(SweKittyTheme.textSecondary)
            Text("No sessions yet")
                .font(.headline)
                .foregroundStyle(SweKittyTheme.textPrimary)
            Text("Start one from the Home screen — it'll show up here so you can pick up later.")
                .font(.footnote)
                .foregroundStyle(SweKittyTheme.textMuted)
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
                .foregroundStyle(SweKittyTheme.textSecondary)
            Text("No matches")
                .font(.headline)
                .foregroundStyle(SweKittyTheme.textPrimary)
            Text("Try a shorter query — we match against the session summary, id, agent, and cwd.")
                .font(.footnote)
                .foregroundStyle(SweKittyTheme.textMuted)
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

    private func healthLabel(for status: SavedSessionStatus) -> String {
        switch status {
        case .live:    return "green"
        case .exited:  return "red"
        case .unknown: return "unknown"
        }
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
