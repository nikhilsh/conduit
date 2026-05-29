import SwiftUI

// MARK: - NeonChrome
//
// Small chrome helpers shared by the Phase-2 screen re-skin: a neon
// agent-tint resolver (maps an agent name to one of the neon brand
// tokens so chips/avatars read in the active palette rather than the
// legacy copper/green SweKitty hues) and a compact mono chip + a
// floating segmented pill, both built on the resolved `NeonTheme` +
// `NeonComponents` helpers so the surface/glow rules stay in one place.

extension NeonTheme {
    /// Per-agent accent resolved against the neon palette: Claude →
    /// `claude` (warm), Codex → `codex` (bright accent), others land on
    /// distinct neon hues. Falls back to `textDim` for unknown agents so
    /// an unknown adapter doesn't masquerade as a known one.
    func agentTint(forAgent assistant: String) -> Color {
        switch assistant.lowercased() {
        case "claude":   return claude
        case "codex":    return codex
        case "hermes":   return purple
        case "pi":       return blue
        case "opencode": return claude
        default:         return textDim
        }
    }
}

// MARK: - NeonAgentChip

/// Compact mono capsule chip (agent label / effort badge). Mirrors the
/// terminal-shaped chrome the chat cards use: mono text, a tinted hairline
/// capsule on `surface2`, and a quiet glow when the tint is a real accent.
struct NeonAgentChip: View {
    let label: String
    var tint: Color
    @Environment(\.neonTheme) private var neon

    var body: some View {
        Text(label)
            .font(neon.mono(11).weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(neon.surface2))
            .overlay(Capsule().stroke(tint.opacity(0.45), lineWidth: 1))
    }
}

// MARK: - NeonSegmentedPill

/// A floating segmented pill (iOS idiom) for the in-session tab bar.
/// Each segment is a glyph + label; the active segment fills with
/// `neon.accent` and (dark-only) text-glows. The whole bar floats on a
/// neon surface capsule with a hairline border + box glow.
struct NeonSegmentedPill<Tab: Hashable>: View {
    struct Segment: Identifiable {
        let id: Tab
        let label: String
        let systemImage: String
    }

    let segments: [Segment]
    @Binding var selection: Tab
    @Environment(\.neonTheme) private var neon

    var body: some View {
        HStack(spacing: 4) {
            ForEach(segments) { seg in
                let isActive = seg.id == selection
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { selection = seg.id }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: seg.systemImage)
                            .font(.system(size: 11, weight: .semibold))
                        Text(seg.label)
                            .font(neon.mono(12).weight(.semibold))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .foregroundStyle(isActive ? neon.accentText : neon.textDim)
                    .background(
                        Capsule().fill(isActive ? neon.accent : Color.clear)
                    )
                    .neonGlowBox(isActive && neon.glow ? neon.glowBox : nil)
                    .neonTextGlow(isActive ? neon.textGlow?.tinted(neon.accentText) : nil)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isActive ? .isSelected : [])
            }
        }
        .padding(4)
        .background(Capsule().fill(neon.surface))
        .overlay(Capsule().stroke(neon.borderStrong, lineWidth: 1))
        .neonGlowBox(neon.glow ? neon.glowBox : nil)
    }
}
