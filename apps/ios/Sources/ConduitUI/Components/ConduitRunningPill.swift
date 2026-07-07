import SwiftUI

// MARK: - ConduitUI.RunningPill
//
// Persistent capsule above the chat composer showing the live count of
// background tasks (design handoff session_tasks Sec 2 "RunningPill").
// Normal: green fill/border, 13px spinner, mono bold green text, chevron-up.
// Gated (any task waiting on the user): amber tint + soft glow, text swaps
// to "N running (middle dot) M needs you". Visible only while there's
// something to show; appears/disappears with a gentle fade + vertical
// move, no layout jump (not present at all when hidden -- no reserved
// space).

extension ConduitUI {
    struct RunningPill: View {
        var runningCount: Int
        var gatedCount: Int = 0
        var onTap: () -> Void = {}

        @Environment(\.neonTheme) private var neon
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        private var isGated: Bool { gatedCount >= 1 }
        private var isVisible: Bool { runningCount >= 1 || gatedCount >= 1 }

        private var tint: Color { isGated ? neon.yellow : neon.green }

        private var label: String {
            if isGated {
                return "\(runningCount) running \u{b7} \(gatedCount) needs you"
            }
            return "\(runningCount) running task\(runningCount == 1 ? "" : "s")"
        }

        var body: some View {
            Group {
                if isVisible {
                    Button(action: onTap) {
                        HStack(spacing: 8) {
                            ConduitUI.TaskSpinner(size: 13, tint: tint)
                            Text(label)
                                .font(neon.mono(11.5).weight(.bold))
                                .foregroundStyle(tint)
                            Image(systemName: "chevron.up")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(tint)
                        }
                        .padding(.vertical, 7)
                        .padding(.horizontal, 13)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                        .background(Capsule(style: .continuous).fill(tint.opacity(0.08)))
                        .overlay(
                            Capsule(style: .continuous).stroke(tint.opacity(0.27), lineWidth: 1)
                        )
                        .shadow(
                            color: (isGated && neon.glow) ? tint.opacity(0.35) : .clear,
                            radius: (isGated && neon.glow) ? 10 : 0
                        )
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: isVisible)
        }
    }
}

#Preview("RunningPill - normal n=1") {
    ConduitUI.RunningPill(runningCount: 1)
        .padding(20)
        .background(Color(hex: "#04050a"))
        .environment(\.neonTheme, NeonTheme.resolve(palette: .ice, dark: true, glow: true))
}

#Preview("RunningPill - normal n=3") {
    ConduitUI.RunningPill(runningCount: 3)
        .padding(20)
        .background(Color(hex: "#04050a"))
        .environment(\.neonTheme, NeonTheme.resolve(palette: .ice, dark: true, glow: true))
}

#Preview("RunningPill - gated") {
    ConduitUI.RunningPill(runningCount: 2, gatedCount: 1)
        .padding(20)
        .background(Color(hex: "#04050a"))
        .environment(\.neonTheme, NeonTheme.resolve(palette: .ice, dark: true, glow: true))
}
