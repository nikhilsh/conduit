import SwiftUI

// MARK: - ConduitUI.ActionButton
//
// Full-width text action button in three semantic variants:
//
//   .primary   — filled CTA (resolvedTint fill, accentText foreground, box glow).
//                Mirrors the `primaryCTA` shape from ConduitOnboardingView.
//   .secondary — ghost card (neon card surface + tinted border + glow).
//                Mirrors the `actionPillBody` shape from ConduitSessionRecapView.
//   .ghost     — stroke-only (strokeBorder at 35% opacity, no fill).
//
// Named ActionButton (not Button) to avoid shadowing SwiftUI.Button inside
// `extension ConduitUI { }` scopes, which would break every bare Button(...)
// call across all nested view files.
//
// The generic `Label` param lets callers compose an icon+text HStack
// via the @ViewBuilder initializer, or use the convenience `init(_:variant:tint:action:)`
// when a plain text label is enough.
//
// Usage (icon + text, secondary):
//   ShareLink(item: markdown) {
//       ConduitUI.ActionButton(variant: .secondary, tint: neon.green, action: {}) {
//           Label("Export markdown", systemImage: "square.and.arrow.up")
//       }
//   }
//
// Usage (text-only, primary):
//   ConduitUI.ActionButton("Start", variant: .primary) { startAction() }

extension ConduitUI {

    struct ActionButton<Label: View>: View {
        enum Variant { case primary, secondary, ghost }

        let variant: Variant
        var tint: Color? = nil
        let action: () -> Void
        @ViewBuilder var label: () -> Label
        @Environment(\.neonTheme) private var neon

        private var resolvedTint: Color {
            tint ?? (variant == .primary ? neon.green : neon.accent)
        }

        var body: some View {
            SwiftUI.Button(action: action) {
                label()
                    .font(neon.sans(15).weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .foregroundStyle(foreground)
                    .background(background)
            }
            .buttonStyle(.plain)
        }

        @ViewBuilder private var background: some View {
            switch variant {
            case .primary:
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(resolvedTint)
                    .neonGlowBox(neon.glow ? neon.glowBox?.tinted(resolvedTint) : nil)
            case .secondary:
                Color.clear
                    .neonCardSurface(
                        neon,
                        fill: neon.surface,
                        cornerRadius: 14,
                        border: resolvedTint.opacity(0.4),
                        glowTint: neon.glow ? resolvedTint : nil
                    )
            case .ghost:
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(resolvedTint.opacity(0.35), lineWidth: 1)
            }
        }

        private var foreground: Color {
            variant == .primary ? neon.accentText : resolvedTint
        }
    }
}

// MARK: - Text-only convenience initializer

extension ConduitUI.ActionButton where Label == Text {
    init(
        _ title: String,
        variant: Variant,
        tint: Color? = nil,
        action: @escaping () -> Void
    ) {
        self.variant = variant
        self.tint = tint
        self.action = action
        self.label = { Text(title) }
    }
}
