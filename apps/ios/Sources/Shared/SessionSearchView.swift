import SwiftUI

/// Global "All sessions" overlay opened from the home top-right
/// hamburger and from the bottom-bar magnifying-glass control. Empty
/// query → full session list (matches Litter's "every thread"
/// surface). Typed query → substring filter over server name,
/// session name, assistant, branch, and conversation-content content.
///
/// The actual index + filter live in `SessionSearchIndex` so they can
/// be unit-tested without standing up a SwiftUI host. Mirrors the
/// `ProjectHeaderModel` / `InSessionBottomBarModel` pattern.
struct SessionSearchView: View {
    @Environment(SessionStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.neonTheme) private var neon

    @State private var query: String = ""

    /// Optional navigation hook. When set, a result tap delegates
    /// selection to the presenter (which can drive its local
    /// navigation state) instead of calling `store.switchTo` +
    /// `dismiss` directly, which races sheet dismissal on iPhone and
    /// drops the push.
    var onSelect: ((String) -> Void)? = nil

    var body: some View {
        NavigationStack {
            ZStack {
                SweKittyTheme.backgroundGradient(for: colorScheme)
                    .ignoresSafeArea()

                VStack(spacing: 14) {
                    searchField
                    if results.isEmpty && !query.isEmpty {
                        emptyState
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(results) { result in
                                    resultRow(result)
                                }
                            }
                            .padding(.horizontal, 14)
                        }
                    }
                    Spacer()
                }
                .padding(.vertical, 12)
            }
            .navigationTitle("All Sessions")
            .navigationBarTitleDisplayMode(.inline)
            .neonAccentTint()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .appearanceColorScheme()
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(SweKittyTheme.textMuted)
            TextField("Search sessions, transcripts, paths…", text: $query)
                .textFieldStyle(.plain)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
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

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: query.isEmpty ? "magnifyingglass" : "questionmark.circle")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(SweKittyTheme.textSecondary)
            Text(query.isEmpty ? "Search every session" : "No matches")
                .font(.headline)
                .foregroundStyle(SweKittyTheme.textPrimary)
            Text(query.isEmpty
                ? "Type to scan conversation history across saved servers."
                : "Try a different query — we search session names, agent, branch, and message content.")
                .font(.footnote)
                .foregroundStyle(SweKittyTheme.textMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .padding(.vertical, 32)
    }

    private func resultRow(_ result: SessionSearchResult) -> some View {
        Button {
            if let onSelect {
                onSelect(result.sessionID)
            } else {
                store.switchTo(sessionID: result.sessionID)
                dismiss()
            }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        serverChip(for: result)
                        Text(result.title)
                            .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                            .foregroundStyle(SweKittyTheme.textPrimary)
                            .lineLimit(1)
                    }
                    if let snippet = result.snippet {
                        highlightedSnippet(snippet, needle: result.needle)
                    } else {
                        Text(result.subtitle)
                            .font(.caption)
                            .foregroundStyle(SweKittyTheme.textMuted)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(SweKittyTheme.textMuted)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .glassRoundedRect()
        }
        .buttonStyle(.plain)
    }

    /// Compact server pill — name + status dot — rendered inline with
    /// the session title. Mirrors the home `ServerPill` but trimmed
    /// down so the row stays a single visual line.
    private func serverChip(for result: SessionSearchResult) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(neon.accent.opacity(0.65))
                .frame(width: 6, height: 6)
            Text(result.serverName)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(SweKittyTheme.textSecondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .glassCapsule(tint: neon.accent.opacity(0.18))
        .accessibilityLabel("Server \(result.serverName)")
    }

    /// Render the matched snippet with the matched substring bolded
    /// and accent-tinted so the user's eye lands on it instantly.
    /// Falls back to a plain `Text` when the needle isn't found in
    /// the snippet (e.g. the match came from session-name only).
    private func highlightedSnippet(_ snippet: String, needle: String) -> some View {
        Group {
            if let attributed = SessionSearchIndex.attributedSnippet(snippet: snippet, needle: needle, tint: neon.accent) {
                Text(attributed)
                    .font(.caption)
                    .foregroundStyle(SweKittyTheme.textMuted)
                    .lineLimit(2)
            } else {
                Text(snippet)
                    .font(.caption)
                    .foregroundStyle(SweKittyTheme.textMuted)
                    .lineLimit(2)
            }
        }
    }

    /// Build the search index from the current store state and feed
    /// it the current query. Done lazily on each access so freshly
    /// arriving conversation events surface immediately.
    private var results: [SessionSearchResult] {
        let index = SessionSearchIndex.build(
            sessions: store.sessions,
            displayNames: store.displayNames,
            savedServers: store.savedServers,
            currentEndpoint: store.endpoint,
            conversationLog: store.conversationLog
        )
        return index.filter(query: query)
    }
}

/// One row in the search results table.
struct SessionSearchResult: Identifiable, Equatable {
    let sessionID: String
    let title: String
    let subtitle: String
    let serverName: String
    /// Matched conversation snippet, if the query hit conversation
    /// content. Nil when the match came from the title / branch /
    /// server-name fields alone.
    let snippet: String?
    /// The lowercased query that produced this match. Stored on the
    /// row so the highlight renderer doesn't need a second pass over
    /// the index.
    let needle: String
    /// Recency hint (ISO timestamp) — drives the result ordering.
    /// Nil for sessions that have never emitted a status frame.
    let lastActivityAt: String?

    var id: String { sessionID + ":" + (snippet ?? subtitle) }
}

/// Pure-data search index lifted out of `SessionSearchView` so the
/// substring filter, snippet extraction, case-insensitive matching,
/// and recency ordering can be pinned in unit tests. Same approach as
/// `ProjectHeaderModel` / `InSessionBottomBarModel`.
///
/// **Index shape**: per session we accumulate four searchable strings —
/// `serverName`, `sessionTitle`, `assistantBranch`, and the
/// concatenated `conversationContent` — plus the session's
/// `lastActivityAt` for ordering. The filter does a case-insensitive
/// substring scan against all four fields and falls back to a
/// conversation-content snippet (with ±N chars of context) when the
/// match lands there.
struct SessionSearchIndex: Equatable {
    /// Number of characters of context to include on each side of the
    /// matched needle inside a conversation snippet. Total snippet
    /// width is roughly `2 * snippetContext + needle.count`.
    static let snippetContextBefore = 24
    static let snippetContextAfter = 60

    struct Entry: Equatable {
        let sessionID: String
        let title: String
        let assistant: String
        let branch: String?
        let serverName: String
        let conversationContent: String
        let lastActivityAt: String?
    }

    let entries: [Entry]

    /// Construct an index from the current store state. The server
    /// name is resolved by matching each session's recorded endpoint
    /// against `savedServers`; sessions whose endpoint doesn't match
    /// any saved entry fall back to `currentEndpoint.displayHost`
    /// since the harness today only surfaces one server at a time.
    static func build(
        sessions: [ProjectSession],
        displayNames: [String: String],
        savedServers: [SavedServer],
        currentEndpoint: StoredEndpoint,
        conversationLog: [String: [ConversationItem]]
    ) -> SessionSearchIndex {
        // The harness still surfaces a single active server per
        // SessionStore; the saved-server list is just the available
        // endpoints the user has paired with. Resolve the row label
        // off the active endpoint name, falling back to the host
        // when no saved-server alias exists.
        let activeServerName: String = {
            if let match = savedServers.first(where: { $0.endpoint == currentEndpoint }) {
                return match.name
            }
            if currentEndpoint.isComplete {
                return currentEndpoint.displayHost
            }
            return "local"
        }()

        let entries = sessions.map { session -> Entry in
            let title = displayNames[session.id] ?? session.name
            let log = conversationLog[session.id] ?? []
            let joined = log.map { $0.content }.joined(separator: "\n")
            return Entry(
                sessionID: session.id,
                title: title,
                assistant: session.assistant,
                branch: session.branch,
                serverName: activeServerName,
                conversationContent: joined,
                lastActivityAt: session.lastActivityAt
            )
        }
        return SessionSearchIndex(entries: entries)
    }

    /// Case-insensitive substring filter. Empty query returns every
    /// entry sorted by recency (newest `lastActivityAt` first); the
    /// view doubles as the "all threads" list when no query is set.
    func filter(query: String) -> [SessionSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let ordered = entries.sorted { lhs, rhs in
            // Newest first by ISO timestamp. nil < anything-non-nil
            // so sessions with no recorded activity sink to the
            // bottom (they typically just spawned and haven't emitted
            // status yet).
            switch (lhs.lastActivityAt, rhs.lastActivityAt) {
            case let (l?, r?): return l > r
            case (_?, nil):    return true
            case (nil, _?):    return false
            case (nil, nil):   return lhs.title < rhs.title
            }
        }

        if trimmed.isEmpty {
            return ordered.map { entry in
                SessionSearchResult(
                    sessionID: entry.sessionID,
                    title: entry.title,
                    subtitle: "\(entry.assistant) · \(entry.branch ?? "no branch")",
                    serverName: entry.serverName,
                    snippet: nil,
                    needle: "",
                    lastActivityAt: entry.lastActivityAt
                )
            }
        }

        let needle = trimmed.lowercased()
        var hits: [SessionSearchResult] = []
        for entry in ordered {
            let titleHit = entry.title.lowercased().contains(needle)
            let agentHit = entry.assistant.lowercased().contains(needle)
            let branchHit = (entry.branch ?? "").lowercased().contains(needle)
            let serverHit = entry.serverName.lowercased().contains(needle)
            let snippet = Self.matchSnippet(in: entry.conversationContent, needle: needle)
            if titleHit || agentHit || branchHit || serverHit || snippet != nil {
                hits.append(
                    SessionSearchResult(
                        sessionID: entry.sessionID,
                        title: entry.title,
                        subtitle: "\(entry.assistant) · \(entry.branch ?? "no branch")",
                        serverName: entry.serverName,
                        snippet: snippet,
                        needle: needle,
                        lastActivityAt: entry.lastActivityAt
                    )
                )
            }
        }
        return hits
    }

    /// Extract a ±context snippet around the first occurrence of
    /// `needle` (case-insensitive) inside `haystack`. Returns nil
    /// when the needle isn't present.
    static func matchSnippet(in haystack: String, needle: String) -> String? {
        guard !needle.isEmpty else { return nil }
        let lower = haystack.lowercased()
        guard let range = lower.range(of: needle) else { return nil }
        let start = lower.index(range.lowerBound, offsetBy: -snippetContextBefore, limitedBy: lower.startIndex) ?? lower.startIndex
        let end = lower.index(range.upperBound, offsetBy: snippetContextAfter, limitedBy: lower.endIndex) ?? lower.endIndex
        return String(haystack[start..<end])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Render the snippet with the matched substring bolded and
    /// accent-tinted using `AttributedString`. Returns nil when the
    /// needle isn't found in the snippet (caller falls back to a
    /// plain `Text`).
    static func attributedSnippet(snippet: String, needle: String, tint: Color) -> AttributedString? {
        guard !needle.isEmpty else { return nil }
        let lower = snippet.lowercased()
        guard let range = lower.range(of: needle) else { return nil }
        var attributed = AttributedString(snippet)
        // AttributedString uses its own index space — map String.Index
        // back through UTF-16 offsets to find the corresponding range.
        let nsStart = lower.distance(from: lower.startIndex, to: range.lowerBound)
        let nsEnd = lower.distance(from: lower.startIndex, to: range.upperBound)
        let start = attributed.index(attributed.startIndex, offsetByCharacters: nsStart)
        let end = attributed.index(attributed.startIndex, offsetByCharacters: nsEnd)
        attributed[start..<end].foregroundColor = tint
        attributed[start..<end].font = .caption.weight(.semibold)
        return attributed
    }
}
