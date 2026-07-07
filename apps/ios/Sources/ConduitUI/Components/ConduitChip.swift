import SwiftUI

// MARK: - ConduitChip
//
// A small capsule chip with optional leading icon. Used for agent
// labels ("claude", "medium"), tab segments, and inline metadata
// badges. Modeled structurally after upstream's ProjectChip /
// HomeModelChip; visual decisions:
//   - Capsule background using ConduitGlass pill config
//   - Mono caption text (matches upstream's badge typography)
//   - Optional `tint`: when set, the capsule background carries the
//     hue at low opacity (per-agent tinting)

extension ConduitUI {

    struct Chip: View {
        let label: String
        var systemImage: String? = nil
        var tint: Color? = nil
        var isSelected: Bool = false
        @Environment(\.neonTheme) private var neon

        var body: some View {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 10, weight: .semibold))
                }
                Text(label)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(foreground)
            .background {
                // Selected chips need a genuinely SOLID bright fill for
                // contrast (device feedback: the step editor's selected
                // ROLE chip rendered dark-on-dark). `conduitGlassCapsule`'s
                // tint overlay is a translucent 6% wash over the dark glass
                // material -- fine for the unselected soft-chip look, but
                // not solid enough to pair with a bright `accentText`
                // label. Draw the solid fill ourselves underneath the glass
                // layer instead.
                if isSelected {
                    Capsule().fill(tint ?? neon.accent)
                }
            }
            .conduitGlassCapsule(tint: isSelected ? nil : tint)
        }

        private var foreground: Color {
            if isSelected {
                return neon.accentText
            }
            return tint ?? ConduitUI.Palette.textPrimary.color
        }
    }
}
