import SwiftUI

/// Pure-data view-model for `SessionsScreen`. The screen renders a
/// section list grouped by server with a search bar at top; the model
/// owns the filter + group derivation so `SessionsScreenModelTests` can
/// pin the behaviour without hosting a SwiftUI view.
///
/// Section ordering is "latest-active server first" — derived from the
/// max `lastSeen` across each server's rows. That makes the active
/// server's bucket float to the top so the user lands on the right
/// section without scrolling.
struct SessionsScreenModel: Equatable {
    /// One section per known server, in render order.
    struct Section: Equatable, Identifiable {
        let serverID: String
        let serverName: String
        let sessions: [SavedSession]

        var id: String { serverID }
    }

    let sections: [Section]
    let totalRows: Int
    let isEmpty: Bool

    /// Build a model from the saved store + the saved-server list. The
    /// search filter is applied case-insensitively to the session
    /// summary AND name (display name overrides the harness name on
    /// iOS today; on the saved screen we only have the saved metadata
    /// so we match against `summary` and the `id` substring).
    static func from(
        sessions: [SavedSession],
        savedServers: [SavedServer],
        query: String
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

        // Group by serverID preserving the already-sorted (latest-first)
        // order of `sessions`. We can't use `Dictionary(grouping:)` because
        // it doesn't preserve insertion order; build the lookup manually.
        var orderedServerIDs: [String] = []
        var byServer: [String: [SavedSession]] = [:]
        for row in filtered {
            if byServer[row.serverID] == nil {
                orderedServerIDs.append(row.serverID)
                byServer[row.serverID] = []
            }
            byServer[row.serverID]?.append(row)
        }

        let nameLookup: [String: String] = Dictionary(
            uniqueKeysWithValues: savedServers.map { ($0.id, $0.name) }
        )

        let sections = orderedServerIDs.map { serverID -> Section in
            Section(
                serverID: serverID,
                serverName: nameLookup[serverID] ?? serverID,
                sessions: byServer[serverID] ?? []
            )
        }

        return SessionsScreenModel(
            sections: sections,
            totalRows: filtered.count,
            isEmpty: sessions.isEmpty
        )
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
        List {
            ForEach(model.sections) { section in
                Section {
                    ForEach(section.sessions, id: \.compoundID) { row in
                        sessionRow(row)
                            .listRowBackground(Color.clear)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
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
            Circle()
                .fill(SweKittyTheme.accentStrong.opacity(0.75))
                .frame(width: 6, height: 6)
            Text(section.serverName)
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

    private func sessionRow(_ row: SavedSession) -> some View {
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

    /// Resume flow. If the row belongs to the active endpoint and the
    /// session is still in the live store, we just call `switchTo`. If
    /// the row is on a different saved server, we switch endpoints
    /// (which auto-reconnects); the underlying session may not exist on
    /// the harness anymore — that's fine, the user lands in the home
    /// view scoped to the right server and can pick from live sessions
    /// there. (Forking the historical row into a fresh session is a
    /// follow-up; A.8 is just the "list + jump" surface for v1.)
    private func resume(_ row: SavedSession) {
        if let server = store.savedServers.first(where: { $0.id == row.serverID }),
           store.endpoint != server.endpoint {
            store.selectSavedServer(server.id, autoConnect: true)
        }
        if store.sessions.contains(where: { $0.id == row.id }) {
            store.switchTo(sessionID: row.id)
        }
        dismiss()
    }

    private func rowTitle(_ row: SavedSession) -> String {
        if !row.summary.isEmpty { return row.summary }
        return row.id
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
