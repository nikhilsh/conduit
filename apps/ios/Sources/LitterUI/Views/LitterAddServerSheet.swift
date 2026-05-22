import SwiftUI

// MARK: - LitterAddServerSheet
//
// Add-server sheet for the LitterUI tree. The legacy AddServerSheet
// already covers QR pairing + manual entry + SSH bootstrap, all of
// which are well-tested. Rather than re-implement all three flows
// for visual parity in this PR, we wrap the legacy sheet so the
// LitterUI tree is shippable today and the visual rebuild lands in a
// follow-up. Tracked under PLAN-LITTER-UI.md.
//
// Name resolution note: this struct lives inside the `LitterUI` enum
// namespace, so writing `AddServerSheet()` directly inside its body
// would resolve to itself. We pull the legacy reference out to file
// scope via the helper view below.

extension LitterUI {
    struct AddServerSheet: View {
        @Environment(SessionStore.self) private var store

        var body: some View {
            LegacyAddServerSheetWrapper().environment(store)
        }
    }
}

/// File-scope wrapper that resolves to the top-level (legacy)
/// `AddServerSheet`. Defined outside the `extension LitterUI` block so
/// nested-name shadowing doesn't kick in.
private struct LegacyAddServerSheetWrapper: View {
    var body: some View { AddServerSheet() }
}
