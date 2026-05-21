import SwiftUI

/// Horizontal strip of pinned-context chips, rendered just above the
/// composer when one or more contexts are pinned. Hides itself when
/// `contexts` is empty so the composer doesn't gain dead vertical
/// space.
struct ContextBarView: View {
    let contexts: [PinnedContext]
    let onRemove: (UUID) -> Void

    var body: some View {
        if contexts.isEmpty {
            EmptyView()
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(contexts) { ctx in
                        ContextChipView(context: ctx) {
                            onRemove(ctx.id)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .accessibilityIdentifier("composer-context-bar")
        }
    }
}
