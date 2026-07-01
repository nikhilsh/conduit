import SwiftUI

// MARK: - ConduitActionPill
//
// A small capsule pill in two variants, extracted from the hand-rolled pills
// in ConduitHomeView (the "ACTIVE" status badge and the "Open guide"/"Review"
// action CTAs). Pure addition — ConduitHomeView is NOT migrated in this PR.
//
// Variants:
//   .soft  — tint@0.14 fill, tint foreground, mono 10 bold + 0.8 tracking.
//            Use for status badges ("ACTIVE"). Padding (h6, v2).
//   .solid — solid tint fill, accentText foreground, sans 12 semibold.
//            Use for action CTAs ("Open guide", "Connect", "Review").
//            Padding (h11, v6).
//
// When `action` is non-nil the pill is wrapped in a plain-style SwiftUI
// Button; when nil it renders as a static label.
//
// Naming note: "ActionPill" does not shadow any SwiftUI type, matching the
// ConduitUI namespace safety rule (unlike Button, Text, Label, etc.).

extension ConduitUI {

    struct ActionPill: View {
        enum Variant {
            /// Low-opacity tint fill — status badge look (e.g. "ACTIVE").
            case soft
            /// Solid tint fill — CTA action look (e.g. "Open guide").
            case solid
        }

        let label: String
        var systemImage: String? = nil
        var variant: Variant = .soft
        /// `nil` resolves to `neon.accent`.
        var tint: Color? = nil
        /// `nil` = static (non-tappable). Non-nil = wrapped in a plain-style Button.
        var action: (() -> Void)? = nil

        @Environment(\.neonTheme) private var neon

        var body: some View {
            if let action {
                SwiftUI.Button(action: action) {
                    pillContent
                }
                .buttonStyle(.plain)
            } else {
                pillContent
            }
        }

        // MARK: Private

        private var resolvedTint: Color {
            tint ?? neon.accent
        }

        @ViewBuilder
        private var pillContent: some View {
            HStack(spacing: 4) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 10, weight: .semibold))
                }
                switch variant {
                case .soft:
                    Text(label)
                        .font(neon.mono(10).weight(.bold))
                        .tracking(0.8)
                case .solid:
                    Text(label)
                        .font(neon.sans(12).weight(.semibold))
                }
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background(Capsule().fill(fill))
        }

        private var foreground: Color {
            switch variant {
            case .soft:  return resolvedTint
            case .solid: return neon.accentText
            }
        }

        private var fill: Color {
            switch variant {
            case .soft:  return resolvedTint.opacity(0.14)
            case .solid: return resolvedTint
            }
        }

        private var horizontalPadding: CGFloat {
            switch variant {
            case .soft:  return 6
            case .solid: return 11
            }
        }

        private var verticalPadding: CGFloat {
            switch variant {
            case .soft:  return 2
            case .solid: return 6
            }
        }
    }
}
