import SwiftUI

// MARK: - LitterPillButton
//
// Capsule-shaped button — used for the BottomActionBar's mic / search
// (44x44 floating glass capsules) and for the centered "+" FAB which
// is sized larger and uses the brand tint.

extension LitterUI {

    struct PillButton: View {
        let systemImage: String
        var size: CGFloat = 44
        var tint: Color? = nil
        var isProminent: Bool = false
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                Image(systemName: systemImage)
                    .font(.system(size: isProminent ? 22 : 18, weight: .semibold))
                    .foregroundStyle(foreground)
                    .frame(width: size, height: size)
                    .litterGlassCircle(
                        tint: backgroundTint,
                        config: .floating
                    )
            }
            .buttonStyle(.plain)
        }

        private var backgroundTint: Color {
            isProminent ? (tint ?? LitterUI.Palette.brand.color) : (tint ?? LitterUI.Palette.surfaceLight.color)
        }

        private var foreground: Color {
            isProminent
                ? LitterUI.Palette.textOnAccent.color
                : LitterUI.Palette.textPrimary.color
        }
    }
}
