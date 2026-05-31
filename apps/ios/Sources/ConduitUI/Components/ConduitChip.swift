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
            .conduitGlassCapsule(tint: capsuleTint)
        }

        private var foreground: Color {
            if isSelected {
                return ConduitUI.Palette.textOnAccent.color
            }
            return tint ?? ConduitUI.Palette.textPrimary.color
        }

        private var capsuleTint: Color? {
            if isSelected {
                return tint ?? neon.accent
            }
            return tint
        }
    }
}
