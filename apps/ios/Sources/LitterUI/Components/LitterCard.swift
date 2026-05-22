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
        var cornerRadius: CGFloat = 16
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
