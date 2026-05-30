import SwiftUI

// MARK: - LitterPillButton
//
// Capsule / circular button used for the BottomActionBar's mic / search
// (44pt) and for the centered "+" FAB which uses the brand tint.
//
// Uses Apple's native `.buttonStyle(.glass)` / `.buttonStyle(.glassProminent)`
// — Liquid Glass. The system owns the specular highlight that responds
// to motion, content displacement on press, spring physics, and the
// dynamic light-source edge. We only feed in the glyph and the tint
// (the prominent variant honours `.tint(_:)`; the regular variant
// ignores it).
//
// The app's iOS deployment target is 26.0, so there's no pre-26
// branch — every device running this binary has Liquid Glass.

extension LitterUI {

    struct PillButton: View {
        let systemImage: String
        var size: CGFloat = 44
        var tint: Color? = nil
        var isProminent: Bool = false
        let action: () -> Void
        @Environment(\.neonTheme) private var neon

        var body: some View {
            Button(action: action) {
                Image(systemName: systemImage)
                    .font(.system(size: isProminent ? 22 : 18, weight: isProminent ? .bold : .semibold))
                    .frame(width: size, height: size)
            }
            .modifier(LiquidGlassButtonStyleModifier(isProminent: isProminent))
            .tint(tint ?? neon.accent)
        }
    }
}

/// Carries the `.buttonStyle(.glass)` vs `.buttonStyle(.glassProminent)`
/// choice. The two style values have distinct types, so Swift won't let
/// us write `.buttonStyle(isProminent ? .glassProminent : .glass)` at a
/// single call site; the conditional has to live behind a ViewModifier.
private struct LiquidGlassButtonStyleModifier: ViewModifier {
    let isProminent: Bool

    func body(content: Content) -> some View {
        if isProminent {
            content.buttonStyle(.glassProminent)
        } else {
            content.buttonStyle(.glass)
        }
    }
}
