import SwiftUI

// MARK: - LitterChip
//
// A small capsule chip with optional leading icon. Used for agent
// labels ("claude", "medium"), tab segments, and inline metadata
// badges. Modeled structurally after litter's ProjectChip /
// HomeModelChip; visual decisions:
//   - Capsule background using LitterGlass pill config
//   - Mono caption text (matches litter's badge typography)
//   - Optional `tint`: when set, the capsule background carries the
//     hue at low opacity (per-agent tinting)

extension LitterUI {

    struct Chip: View {
        let label: String
        var systemImage: String? = nil
        var tint: Color? = nil
        var isSelected: Bool = false

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
            .litterGlassCapsule(tint: capsuleTint)
        }

        private var foreground: Color {
            if isSelected {
                return LitterUI.Palette.textOnAccent.color
            }
            return tint ?? LitterUI.Palette.textPrimary.color
        }

        private var capsuleTint: Color? {
            if isSelected {
                return tint ?? LitterUI.Palette.brand.color
            }
            return tint
        }
    }
}
