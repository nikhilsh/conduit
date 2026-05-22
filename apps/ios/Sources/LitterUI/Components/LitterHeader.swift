import SwiftUI

// MARK: - LitterHeader
//
// Three-zone screen header: leading icon button (back / settings),
// centered title or logo, trailing icon buttons (overflow / info).
// Used by HomeView (the top row with gear / logo / list buttons) and
// ProjectView (back / title / info).

extension LitterUI {

    struct Header<Leading: View, Center: View, Trailing: View>: View {
        @ViewBuilder var leading: () -> Leading
        @ViewBuilder var center: () -> Center
        @ViewBuilder var trailing: () -> Trailing

        var body: some View {
            HStack(spacing: 14) {
                leading()
                Spacer()
                center()
                Spacer()
                trailing()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    /// Small circular icon button used in the header zones.
    struct HeaderIconButton: View {
        let systemImage: String
        var accessibilityLabel: String? = nil
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                Image(systemName: systemImage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(LitterUI.Palette.textPrimary.color)
                    .frame(width: 36, height: 36)
                    .litterGlassCircle(
                        tint: LitterUI.Palette.surface.color.opacity(0.65),
                        config: .floating
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityLabel ?? systemImage)
        }
    }
}
