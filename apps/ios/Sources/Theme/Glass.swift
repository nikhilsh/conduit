import SwiftUI

// MARK: - Glass effect wrappers
//
// The previous pass tried to use unreleased Liquid Glass-specific SwiftUI
// symbols that are not present in the runner SDK yet. Keep the same visual
// direction, but implement it with compile-safe material layering so CI and
// release builds stay shippable.

private struct GlassSurfaceModifier<S: InsettableShape>: ViewModifier {
    let shape: S
    var tint: Color?
    var highlightOpacity: Double = 0.24
    var shadowOpacity: Double = 0.16

    func body(content: Content) -> some View {
        let stroke = (tint ?? SweKittyTheme.border).opacity(0.42)
        let glow = (tint ?? SweKittyTheme.accentStrong).opacity(highlightOpacity)

        content
            .background {
                shape
                    .fill(.ultraThinMaterial)
                    .overlay {
                        shape
                            .fill(
                                LinearGradient(
                                    colors: [
                                        glow,
                                        SweKittyTheme.surfaceLight.opacity(0.08),
                                        .clear,
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    }
            }
            .overlay {
                shape
                    .stroke(stroke, lineWidth: 1)
            }
            .clipShape(shape)
            .shadow(color: SweKittyTheme.textPrimary.opacity(shadowOpacity), radius: 18, x: 0, y: 10)
    }
}

struct GlassRectModifier: ViewModifier {
    let cornerRadius: CGFloat
    var tint: Color?

    func body(content: Content) -> some View {
        content.modifier(
            GlassSurfaceModifier(
                shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
                tint: tint
            )
        )
    }
}

struct GlassRoundedRectModifier: ViewModifier {
    var cornerRadius: CGFloat = SweKittyTheme.cardCornerRadius

    func body(content: Content) -> some View {
        content.modifier(
            GlassSurfaceModifier(
                shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
        )
    }
}

struct GlassCapsuleModifier: ViewModifier {
    var interactive: Bool = false
    var tint: Color?

    func body(content: Content) -> some View {
        content
            .modifier(
                GlassSurfaceModifier(
                    shape: Capsule(),
                    tint: tint,
                    highlightOpacity: interactive ? 0.34 : 0.22,
                    shadowOpacity: interactive ? 0.22 : 0.14
                )
            )
            .scaleEffect(interactive ? 1.0 : 0.995)
    }
}

struct GlassCircleModifier: ViewModifier {
    var tint: Color?

    func body(content: Content) -> some View {
        content.modifier(
            GlassSurfaceModifier(
                shape: Circle(),
                tint: tint,
                highlightOpacity: 0.28
            )
        )
    }
}

/// Future shell rewrites can replace this with platform-native morphing
/// once the SDK is available in CI. For now it is a pass-through wrapper.
struct GlassMorphContainer<Content: View>: View {
    var spacing: CGFloat = 10
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
    }
}

extension View {
    func glassRect(cornerRadius: CGFloat = SweKittyTheme.cardCornerRadius, tint: Color? = nil) -> some View {
        modifier(GlassRectModifier(cornerRadius: cornerRadius, tint: tint))
    }

    func glassRoundedRect(cornerRadius: CGFloat = SweKittyTheme.cardCornerRadius) -> some View {
        modifier(GlassRoundedRectModifier(cornerRadius: cornerRadius))
    }

    func glassCapsule(interactive: Bool = false, tint: Color? = nil) -> some View {
        modifier(GlassCapsuleModifier(interactive: interactive, tint: tint))
    }

    func glassCircle(tint: Color? = nil) -> some View {
        modifier(GlassCircleModifier(tint: tint))
    }

    func glassMorphID(_ id: String, in namespace: Namespace.ID) -> some View {
        matchedGeometryEffect(id: id, in: namespace)
    }
}
