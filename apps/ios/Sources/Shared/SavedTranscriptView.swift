import SwiftUI

/// Read-only viewer for an EXITED session's persisted transcript.
///
/// Tapping an exited row in `SessionsScreen` (no live WS to attach to)
/// fetches `conversation.jsonl` over HTTP via
/// `SessionStore.fetchConversation` and replays it through the existing
/// litter chat renderer (`LitterUI.ChatView` in read-only mode — the
/// composer + quick-reply bar are suppressed).
///
/// CAVEAT (broker PR #196): `conversation.jsonl` is only written for
/// sessions created *after* the broker was redeployed with #196. Older
/// exited rows 404 — `fetchConversation` raises `ConversationNotFoundError`
/// and we render the "no saved transcript" empty state rather than a
/// generic failure.
struct SavedTranscriptView: View {
    @Environment(SessionStore.self) private var store
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    let session: SavedSession

    enum LoadState: Equatable {
        case loading
        case loaded([ConversationItem])
        case notFound
        case failed(String)
    }

    @State private var state: LoadState = .loading

    var body: some View {
        ZStack {
            LitterUI.Palette.surface.color.ignoresSafeArea()

            switch state {
            case .loading:
                ProgressView()
                    .tint(LitterUI.Palette.brand.color)
            case .loaded(let items):
                if items.isEmpty {
                    emptyTranscript
                } else {
                    LitterUI.ChatView(session: projectSession, readOnlyItems: items)
                }
            case .notFound:
                noTranscript
            case .failed(let message):
                failure(message)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .tint(LitterUI.Palette.brand.color)
        .task { await load() }
        .appearanceColorScheme()
    }

    // MARK: - Fetch

    private func load() async {
        do {
            let items = try await store.fetchConversation(sessionID: session.id)
            state = .loaded(items)
        } catch is ConversationNotFoundError {
            state = .notFound
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    // MARK: - Synthetic session

    /// `ChatView` needs a `ProjectSession` for its title / assistant /
    /// composer placeholder, but an exited row has no live one. Build a
    /// stand-in from the saved metadata — only the read-only render path
    /// runs against it, so the unused live fields are harmless.
    private var projectSession: ProjectSession {
        ProjectSession(
            id: session.id,
            name: title,
            assistant: session.agent,
            branch: nil,
            preview: nil,
            reasoningEffort: nil,
            cwd: session.cwd,
            startedAt: session.firstSeen,
            lastActivityAt: session.lastSeen,
            displayName: nil
        )
    }

    private var title: String {
        session.summary.isEmpty ? session.id : session.summary
    }

    // MARK: - States

    private var emptyTranscript: some View {
        infoState(
            icon: "text.bubble",
            title: "Empty transcript",
            message: "This session ended without any recorded messages."
        )
    }

    private var noTranscript: some View {
        infoState(
            icon: "clock.badge.xmark",
            title: "No saved transcript",
            message: "This session ended before transcripts were saved on the server, so there's nothing to replay."
        )
    }

    private func failure(_ message: String) -> some View {
        infoState(
            icon: "exclamationmark.triangle",
            title: "Couldn't load transcript",
            message: message
        )
    }

    private func infoState(icon: String, title: String, message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(LitterUI.Palette.textSecondary.color)
            Text(title)
                .font(.headline)
                .foregroundStyle(LitterUI.Palette.textPrimary.color)
            Text(message)
                .font(.footnote)
                .foregroundStyle(LitterUI.Palette.textMuted.color)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
