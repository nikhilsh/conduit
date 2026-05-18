import SwiftUI

/// Centralized visual tokens so the app reads as one product surface
/// instead of a pile of one-off `.background(.ultraThinMaterial)` calls.
enum SweKittyTheme {
    static let accent: Color = Color(red: 0.42, green: 0.62, blue: 1.0)
    static let danger: Color = Color(red: 0.95, green: 0.36, blue: 0.36)
    static let warning: Color = Color(red: 0.95, green: 0.71, blue: 0.32)
    static let success: Color = Color(red: 0.30, green: 0.78, blue: 0.49)
    static let mutedFG: Color = Color.white.opacity(0.62)
    static let cardCornerRadius: CGFloat = 22
    static let smallCornerRadius: CGFloat = 14
}

/// App-wide background gradient. Sits behind `NavigationSplitView` so the
/// glass panes have something to refract.
struct GlassAppBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.05, green: 0.07, blue: 0.13),
                    Color(red: 0.10, green: 0.13, blue: 0.24),
                    Color(red: 0.04, green: 0.05, blue: 0.10),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [
                    Color.white.opacity(0.14),
                    Color.white.opacity(0.03),
                    .clear,
                ],
                center: .topLeading,
                startRadius: 30,
                endRadius: 420
            )
            RadialGradient(
                colors: [
                    Color.cyan.opacity(0.14),
                    .clear,
                ],
                center: .bottomTrailing,
                startRadius: 20,
                endRadius: 360
            )
        }
        .ignoresSafeArea()
    }
}

extension View {
    /// Default glass pill for inline elements (rows, header chips).
    func glassPane(horizontalPadding: CGFloat = 18,
                   verticalPadding: CGFloat = 14,
                   cornerRadius: CGFloat = SweKittyTheme.cardCornerRadius) -> some View {
        self
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.18), radius: 16, y: 10)
    }

    /// Smaller glass chip used inside dense headers.
    func glassChip() -> some View {
        self
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay { Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 1) }
    }
}

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
                    .stroke(Color.white.opacity(0.45), lineWidth: 0.5)
            )
            .accessibilityLabel("health: \(health)")
    }

    private var color: Color {
        switch health {
        case "green":  return SweKittyTheme.success
        case "yellow": return SweKittyTheme.warning
        case "red":    return SweKittyTheme.danger
        default:       return Color.gray.opacity(0.7)
        }
    }
}

/// Inline error banner — used by ProjectListView for session-creation failures
/// and elsewhere for non-fatal harness errors.
struct InlineErrorBanner: View {
    let message: String
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(SweKittyTheme.danger)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.92))
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(3)
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: SweKittyTheme.smallCornerRadius, style: .continuous)
                .fill(SweKittyTheme.danger.opacity(0.16))
        )
        .overlay(
            RoundedRectangle(cornerRadius: SweKittyTheme.smallCornerRadius, style: .continuous)
                .strokeBorder(SweKittyTheme.danger.opacity(0.4), lineWidth: 1)
        )
    }
}

/// Pill that summarises the current HarnessState. Distinct from session
/// health — this is "can we talk to the server at all."
struct HarnessBadge: View {
    let state: HarnessState

    var body: some View {
        HStack(spacing: 6) {
            indicator
            Text(state.badgeLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.9))
        }
        .glassChip()
    }

    @ViewBuilder
    private var indicator: some View {
        switch state {
        case .connecting:
            ProgressView().controlSize(.mini)
        case .live:
            HealthDot(health: "green", size: 8)
        case .linked:
            HealthDot(health: "yellow", size: 8)
        case .failed:
            HealthDot(health: "red", size: 8)
        case .disconnected:
            HealthDot(health: "unknown", size: 8)
        }
    }
}
