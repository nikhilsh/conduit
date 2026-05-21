import Testing
import Foundation
@testable import SweKitty

/// Stage 5 — sessions-across-servers search. The actual filter lives
/// in `SessionSearchIndex` so the view body has nothing to decide and
/// these tests can pin the substring + case-insensitive + recency
/// rules without standing up a SwiftUI host. Same pattern as
/// `ProjectHeaderModel` / `ServerPillModel` / `InSessionBottomBarModel`.
@Suite("SessionSearchIndex — pure-data substring + ordering")
struct SessionSearchTests {

    // MARK: - Index shape

    @Test func indexCarriesPerSessionFields() {
        // Pin the index shape: one Entry per session, carrying the
        // four searchable fields the view binds to (server name,
        // title, agent+branch, conversation content) plus the
        // lastActivityAt timestamp that drives ordering.
        let index = makeIndex(
            sessions: [makeSession(id: "s1", name: "alpha", branch: "main")],
            log: ["s1": ["hello world"]]
        )
        #expect(index.entries.count == 1)
        let entry = index.entries[0]
        #expect(entry.sessionID == "s1")
        #expect(entry.title == "alpha")
        #expect(entry.assistant == "claude")
        #expect(entry.branch == "main")
        #expect(entry.serverName == "studio")
        #expect(entry.conversationContent == "hello world")
    }

    @Test func displayNameOverridesSessionName() {
        // A user-supplied display name (from the rename map) wins
        // over the raw harness name — the search results need to
        // show the same label the home list shows.
        let index = makeIndex(
            sessions: [makeSession(id: "s1", name: "auto-name")],
            displayNames: ["s1": "rebrand"]
        )
        #expect(index.entries.first?.title == "rebrand")
    }

    @Test func conversationContentIsConcatenatedAcrossEvents() {
        // The conversation log has many events; the index joins them
        // so a single substring scan covers everything the user has
        // said or seen in the session.
        let index = makeIndex(
            sessions: [makeSession(id: "s1")],
            log: ["s1": ["first message", "second one", "third"]]
        )
        let joined = index.entries.first?.conversationContent ?? ""
        #expect(joined.contains("first message"))
        #expect(joined.contains("second one"))
        #expect(joined.contains("third"))
    }

    // MARK: - Substring matching

    @Test func caseInsensitiveTitleMatch() {
        // Searching "Alpha" must hit "alpha" — humans don't shift on
        // case when scanning their own sessions.
        let index = makeIndex(
            sessions: [makeSession(id: "s1", name: "alpha-build")]
        )
        let hits = index.filter(query: "ALPHA")
        #expect(hits.count == 1)
        #expect(hits.first?.sessionID == "s1")
    }

    @Test func conversationContentMatchReturnsSnippet() {
        // A query that lands in conversation content rather than
        // title surfaces a snippet (with ±context) so the user can
        // see *why* the row matched.
        let index = makeIndex(
            sessions: [makeSession(id: "s1", name: "untitled")],
            log: ["s1": ["the migration plan touches lib/database.rs"]]
        )
        let hits = index.filter(query: "database")
        #expect(hits.count == 1)
        #expect(hits.first?.snippet?.contains("database.rs") == true)
        #expect(hits.first?.needle == "database")
    }

    @Test func branchMatchSurfacesRow() {
        let index = makeIndex(
            sessions: [makeSession(id: "s1", branch: "feature/voice")]
        )
        let hits = index.filter(query: "voice")
        #expect(hits.count == 1)
        #expect(hits.first?.sessionID == "s1")
    }

    @Test func serverNameMatchSurfacesRow() {
        let index = makeIndex(
            sessions: [makeSession(id: "s1")],
            serverName: "Studio Mac"
        )
        let hits = index.filter(query: "studio")
        #expect(hits.count == 1)
        #expect(hits.first?.serverName == "Studio Mac")
    }

    @Test func noMatchReturnsEmpty() {
        let index = makeIndex(
            sessions: [makeSession(id: "s1", name: "alpha")]
        )
        let hits = index.filter(query: "zeta")
        #expect(hits.isEmpty)
    }

    @Test func emptyQueryReturnsEveryEntry() {
        // The search view doubles as the "all threads" list — an
        // empty query must return every session, not zero rows.
        let index = makeIndex(
            sessions: [
                makeSession(id: "s1"),
                makeSession(id: "s2"),
                makeSession(id: "s3"),
            ]
        )
        let hits = index.filter(query: "")
        #expect(hits.count == 3)
    }

    @Test func emptyQueryHasNoSnippet() {
        // Empty-query rows act as "list everything" so they show the
        // `assistant · branch` subtitle, not a snippet — the view
        // renders accordingly.
        let index = makeIndex(sessions: [makeSession(id: "s1")])
        let hits = index.filter(query: "")
        #expect(hits.first?.snippet == nil)
        #expect(hits.first?.subtitle.contains("claude") == true)
    }

    // MARK: - Recency ordering

    @Test func resultsOrderedByLastActivityDescending() {
        // Newest activity first. The view doesn't do its own
        // sorting; the index is the single source of truth so a
        // future "pin a session" affordance has one place to extend.
        let index = makeIndex(
            sessions: [
                makeSession(id: "old",    lastActivity: "2026-05-01T00:00:00Z"),
                makeSession(id: "newest", lastActivity: "2026-05-21T12:00:00Z"),
                makeSession(id: "mid",    lastActivity: "2026-05-15T00:00:00Z"),
            ]
        )
        let hits = index.filter(query: "")
        #expect(hits.map(\.sessionID) == ["newest", "mid", "old"])
    }

    @Test func sessionsWithoutActivityTimestampSinkToBottom() {
        // Sessions that haven't emitted a status frame yet — typically
        // freshly spawned — show up at the end so the user's actively
        // worked-in threads stay at the top.
        let index = makeIndex(
            sessions: [
                makeSession(id: "pristine", lastActivity: nil),
                makeSession(id: "active",   lastActivity: "2026-05-21T12:00:00Z"),
            ]
        )
        let hits = index.filter(query: "")
        #expect(hits.map(\.sessionID) == ["active", "pristine"])
    }

    @Test func matchesAlsoOrderedByRecency() {
        // Recency applies to filtered results too, not just the
        // "empty query" path.
        let index = makeIndex(
            sessions: [
                makeSession(id: "old",    name: "alpha", lastActivity: "2026-05-01T00:00:00Z"),
                makeSession(id: "newest", name: "alpha", lastActivity: "2026-05-21T12:00:00Z"),
            ]
        )
        let hits = index.filter(query: "alpha")
        #expect(hits.map(\.sessionID) == ["newest", "old"])
    }

    // MARK: - Snippet extraction

    @Test func snippetIncludesContextAroundMatch() {
        // Snippet should include leading + trailing context so the
        // user sees enough surrounding text to understand the match.
        let big = String(repeating: "x", count: 80)
            + " <<NEEDLE>> "
            + String(repeating: "y", count: 80)
        let snippet = SessionSearchIndex.matchSnippet(in: big, needle: "<<needle>>")
        #expect(snippet != nil)
        #expect(snippet!.contains("<<NEEDLE>>"))
        // The snippet should be much shorter than the input — bounded
        // by the configured context windows.
        let cap = SessionSearchIndex.snippetContextBefore
            + SessionSearchIndex.snippetContextAfter
            + 10 /* needle */
            + 5  /* whitespace slack */
        #expect(snippet!.count <= cap)
    }

    @Test func snippetReturnsNilWhenNeedleMissing() {
        let snippet = SessionSearchIndex.matchSnippet(in: "hello world", needle: "absent")
        #expect(snippet == nil)
    }

    @Test func attributedSnippetHighlightsMatch() {
        // `AttributedString` carries the highlight metadata; the
        // view applies it via the accent color + bold weight. Empty
        // matches return nil so the view falls back to plain text.
        let attr = SessionSearchIndex.attributedSnippet(snippet: "the database matters", needle: "database")
        #expect(attr != nil)
        let nothing = SessionSearchIndex.attributedSnippet(snippet: "no match here", needle: "absent")
        #expect(nothing == nil)
    }

    // MARK: - Helpers

    private func makeIndex(
        sessions: [ProjectSession],
        displayNames: [String: String] = [:],
        log: [String: [String]] = [:],
        serverName: String = "studio"
    ) -> SessionSearchIndex {
        let endpoint = StoredEndpoint(url: "ws://10.0.0.4:1977", token: "t")
        let savedServers = [
            SavedServer(id: "studio-id", name: serverName, endpoint: endpoint, isDefault: true)
        ]
        let conversation: [String: [ConversationItem]] = log.mapValues { contents in
            contents.enumerated().map { idx, content in
                ConversationItem(
                    id: "evt-\(idx)",
                    role: "user",
                    kind: "message",
                    status: "done",
                    content: content,
                    ts: "2026-05-21T12:00:0\(idx)Z",
                    files: [],
                    toolName: nil,
                    command: nil,
                    exitCode: nil,
                    durationMs: nil,
                    diffSummary: nil,
                    pendingOptions: []
                )
            }
        }
        return SessionSearchIndex.build(
            sessions: sessions,
            displayNames: displayNames,
            savedServers: savedServers,
            currentEndpoint: endpoint,
            conversationLog: conversation
        )
    }

    private func makeSession(
        id: String,
        name: String = "session",
        branch: String? = "main",
        assistant: String = "claude",
        lastActivity: String? = "2026-05-21T12:00:00Z"
    ) -> ProjectSession {
        ProjectSession(
            id: id,
            name: name,
            assistant: assistant,
            branch: branch,
            preview: nil,
            reasoningEffort: nil,
            cwd: nil,
            startedAt: nil,
            lastActivityAt: lastActivity
        )
    }
}
