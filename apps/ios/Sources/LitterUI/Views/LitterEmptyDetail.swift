import SwiftUI

// MARK: - LitterEmptyDetail
//
// Detail placeholder for the iPad/regular split view when no session
// is selected. Brand mark + a single line of guidance. Mirrors
// litter's "no thread picked yet" pane.

extension LitterUI {

    struct EmptyDetail: View {
        var body: some View {
            ZStack {
                LitterUI.Palette.surface.color.ignoresSafeArea()
                VStack(spacing: 14) {
                    Image("KittyMark")
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 72, height: 72)
                        .cornerRadius(16)
                        .opacity(0.85)
                        .accessibilityHidden(true)
                    Text("Pick a session from the left.")
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        .foregroundStyle(LitterUI.Palette.textSecondary.color)
                        .multilineTextAlignment(.center)
                }
                .padding(24)
            }
            .navigationBarBackButtonHidden(true)
            .toolbar(.hidden, for: .navigationBar)
        }
    }
}
