import SwiftUI

/// Global "All sessions" overlay opened from the home top-right
/// hamburger. Empty query → full session list (matches Litter's "every
/// thread" surface). Typed query → substring filter over name, agent,
/// branch, and message content. Multi-server enumeration is still
/// single-server today (`store.sessions`); the cross-server index lands
/// when saved-server switching is real (MOBILE-FEATURE-BACKLOG #4).
struct SessionSearchView: View {
    @Environment(SessionStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State private var query: String = ""

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
            .tint(SweKittyTheme.accentStrong)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(SweKittyTheme.textMuted)
            TextField("Search sessions, transcripts, paths…", text: $query)
                .textFieldStyle(.plain)
                .submitLabel(.search)
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

    private func resultRow(_ result: SearchResult) -> some View {
        Button {
            store.selectedSessionID = result.sessionID
            dismiss()
        } label: {
            HStack(spacing: 10) {
                HealthDot(health: "unknown", size: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(SweKittyTheme.textPrimary)
                        .lineLimit(1)
                    Text(result.subtitle)
                        .font(.caption)
                        .foregroundStyle(SweKittyTheme.textMuted)
                        .lineLimit(2)
                }
                Spacer()
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

    /// v1 client-side index: case-insensitive substring match over
    /// session name, agent, branch, and conversation log content. Empty
    /// query returns every session so this view doubles as the "all
    /// threads" list. v2 (multi-server) can push search server-side via
    /// the harness once saved-server switching is real.
    private var results: [SearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return store.sessions.map { session in
                SearchResult(
                    sessionID: session.id,
                    title: store.displayName(for: session),
                    subtitle: "\(session.assistant) · \(session.branch ?? "no branch")"
                )
            }
        }
        let needle = trimmed.lowercased()
        var out: [SearchResult] = []
        for session in store.sessions {
            let snippet = matchSnippet(in: session, needle: needle)
            let titleHit = session.name.lowercased().contains(needle)
            let agentHit = session.assistant.lowercased().contains(needle)
            let branchHit = (session.branch ?? "").lowercased().contains(needle)
            if snippet != nil || titleHit || agentHit || branchHit {
                out.append(SearchResult(
                    sessionID: session.id,
                    title: store.displayName(for: session),
                    subtitle: snippet ?? "\(session.assistant) · \(session.branch ?? "no branch")"
                ))
            }
        }
        return out
    }

    private func matchSnippet(in session: ProjectSession, needle: String) -> String? {
        let log = store.conversationLog[session.id] ?? []
        for ev in log.reversed() {
            let lower = ev.content.lowercased()
            if let range = lower.range(of: needle) {
                let start = lower.index(range.lowerBound, offsetBy: -20, limitedBy: lower.startIndex) ?? lower.startIndex
                let end = lower.index(range.upperBound, offsetBy: 40, limitedBy: lower.endIndex) ?? lower.endIndex
                return String(ev.content[start..<end])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }
}

struct SearchResult: Identifiable {
    let sessionID: String
    let title: String
    let subtitle: String

    var id: String { sessionID + ":" + subtitle }
}
