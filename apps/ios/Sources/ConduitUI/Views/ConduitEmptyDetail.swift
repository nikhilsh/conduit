import SwiftUI

// MARK: - ConduitEmptyDetail
//
// Detail placeholder for the iPad/regular split view when no session
// is selected. Brand mark + a single line of guidance. Mirrors
// litter's "no thread picked yet" pane.

extension ConduitUI {

    struct EmptyDetail: View {
        var body: some View {
            ZStack {
                ConduitUI.Palette.surface.color.ignoresSafeArea()
                VStack(spacing: 14) {
                    ConduitUI.ConduitMark(size: 72)
                        .opacity(0.85)
                        .accessibilityHidden(true)
                    Text("Pick a session from the left.")
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        .foregroundStyle(ConduitUI.Palette.textSecondary.color)
                        .multilineTextAlignment(.center)
                }
                .padding(24)
            }
            .navigationBarBackButtonHidden(true)
            .toolbar(.hidden, for: .navigationBar)
        }
    }
}
