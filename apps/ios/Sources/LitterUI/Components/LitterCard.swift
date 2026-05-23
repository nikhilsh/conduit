import SwiftUI

// MARK: - LitterCard
//
// Container shape for any "card" surface in the LitterUI tree. Just a
// `litterGlassRoundedRect`-wrapped VStack with consistent padding.
// Exists so callers don't have to remember the right padding +
// corner-radius pair.

extension LitterUI {
    struct Card<Content: View>: View {
        var padding: CGFloat = 14
        // Default corner radius dropped 16 → 14 in PLAN-LITTER-VISUAL-
        // PARITY PR 2 to match `litterGlassRoundedRect`'s new default
        // and the audit's flatter card target.
        var cornerRadius: CGFloat = 14
        var tint: Color? = nil
        @ViewBuilder var content: () -> Content

        var body: some View {
            content()
                .padding(padding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .litterGlassRoundedRect(cornerRadius: cornerRadius, tint: tint)
        }
    }
}
