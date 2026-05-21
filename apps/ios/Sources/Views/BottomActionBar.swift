import SwiftUI

/// Two-control bottom bar: mic (left) and large copper `+` (right).
/// Session search/list moved to the top-right hamburger, so the
/// bottom magnifier is gone — the `+` no longer needs to be centered
/// for symmetry against a third control.
struct BottomActionBar: View {
    let onVoice: () -> Void
    let onPlus: () -> Void

    var body: some View {
        HStack {
            actionCircle(
                icon: "mic.fill",
                accessibilityLabel: "Voice dictation",
                action: onVoice
            )
            Spacer()
            primaryPlus
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
    }

    private func actionCircle(icon: String, accessibilityLabel: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.title3.weight(.semibold))
                .foregroundStyle(SweKittyTheme.textPrimary)
                .frame(width: 52, height: 52)
                .glassCircle(tint: SweKittyTheme.surface.opacity(0.6))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    private var primaryPlus: some View {
        Button(action: onPlus) {
            Image(systemName: "plus")
                .font(.title.weight(.bold))
                .foregroundStyle(SweKittyTheme.textOnAccent)
                .frame(width: 68, height: 68)
                .background(
                    Circle()
                        .fill(SweKittyTheme.accentStrong)
                        .shadow(color: SweKittyTheme.accentStrong.opacity(0.45), radius: 18, y: 8)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("New session")
    }
}
