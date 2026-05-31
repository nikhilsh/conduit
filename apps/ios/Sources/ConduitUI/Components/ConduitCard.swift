import SwiftUI

// MARK: - ConduitCard
//
// Container shape for any "card" surface in the ConduitUI tree. Just a
// `conduitGlassRoundedRect`-wrapped VStack with consistent padding.
// Exists so callers don't have to remember the right padding +
// corner-radius pair.

extension ConduitUI {
    struct Card<Content: View>: View {
        var padding: CGFloat = 14
        // Default corner radius dropped 16 → 14 in PLAN-CONDUIT-VISUAL-
        // PARITY PR 2 to match `conduitGlassRoundedRect`'s new default
        // and the audit's flatter card target.
        var cornerRadius: CGFloat = 14
        var tint: Color? = nil
        @ViewBuilder var content: () -> Content

        var body: some View {
            content()
                .padding(padding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .conduitGlassRoundedRect(cornerRadius: cornerRadius, tint: tint)
        }
    }
}
