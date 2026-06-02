import SwiftUI

/// Standard health/state dot used in lists and headers.
struct HealthDot: View {
    let health: String
    var size: CGFloat = 9

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .overlay(
                Circle()
                    .stroke(ConduitTheme.border.opacity(0.45), lineWidth: 0.5)
            )
            .accessibilityLabel("health: \(health)")
    }

    private var color: Color {
        switch health {
        case "green":  return ConduitTheme.success
        case "yellow": return ConduitTheme.warning
        case "red":    return ConduitTheme.danger
        default:       return ConduitTheme.textMuted
        }
    }
}
