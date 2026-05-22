import SwiftUI

// MARK: - LitterRenameSheet
//
// Rename session sheet for LitterUI. Wraps the existing
// RenameSessionSheet which already validates the trimmed name and
// calls `SessionStore.renameSession`. Visual rebuild is a follow-up.

extension LitterUI {
    struct RenameSheet: View {
        @Environment(SessionStore.self) private var store

        let session: ProjectSession

        var body: some View {
            LegacyRenameWrapper(
                sessionID: session.id,
                draft: store.displayName(for: session)
            )
            .environment(store)
        }
    }
}

private struct LegacyRenameWrapper: View {
    let sessionID: String
    let draft: String
    var body: some View {
        RenameSessionSheet(sessionID: sessionID, draft: draft)
    }
}
