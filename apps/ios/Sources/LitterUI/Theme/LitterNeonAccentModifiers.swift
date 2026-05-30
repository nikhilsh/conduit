import SwiftUI

// MARK: - Neon accent convenience modifiers
//
// Copper-cutover helpers: many surfaces tinted their controls / glyphs
// with the legacy copper brand (`LitterUI.Palette.brand.color`). These
// modifiers read the active `\.neonTheme` from the environment and apply
// the selected palette accent, so a view can drop copper without having
// to declare an `@Environment(\.neonTheme)` property itself.
//
//   .tint(LitterUI.Palette.brand.color)            → .neonAccentTint()
//   .foregroundStyle(LitterUI.Palette.brand.color) → .neonAccentForeground()

extension View {
    /// `.tint(neon.accent)` — control accent follows the active palette.
    func neonAccentTint() -> some View {
        modifier(NeonAccentModifier(kind: .tint))
    }

    /// `.foregroundStyle(neon.accent)` — glyph/text accent follows the palette.
    func neonAccentForeground() -> some View {
        modifier(NeonAccentModifier(kind: .foreground))
    }
}

private struct NeonAccentModifier: ViewModifier {
    enum Kind { case tint, foreground }
    let kind: Kind
    @Environment(\.neonTheme) private var neon

    func body(content: Content) -> some View {
        switch kind {
        case .tint:       content.tint(neon.accent)
        case .foreground: content.foregroundStyle(neon.accent)
        }
    }
}
