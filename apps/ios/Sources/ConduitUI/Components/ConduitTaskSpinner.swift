import SwiftUI

// MARK: - ConduitUI.TaskSpinner
//
// Calm indeterminate ring for background-task rows (design handoff
// session_tasks, "TaskRow" / "StSpin"). Full-circle track at ~20% tint
// opacity + a quarter-arc head in the full tint, 1s linear rotation.
// Freezes (static ring + head, no rotation) under Reduce Motion so the
// calm end-state still reads as "in progress" without motion.
//
// Size 16 / stroke 2 is the inline TaskRow default; a future RunningPill
// caller needs size 13 -- both are exposed as parameters so callers don't
// fork a variant.

extension ConduitUI {
    struct TaskSpinner: View {
        var size: CGFloat = 16
        var lineWidth: CGFloat = 2
        /// Ring tint. Defaults to `neon.yellow` (the "amber" design token).
        var tint: Color? = nil

        @Environment(\.neonTheme) private var neon
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var rotation: Double = 0

        private var resolvedTint: Color { tint ?? neon.yellow }

        var body: some View {
            ZStack {
                Circle()
                    .stroke(resolvedTint.opacity(0.20), lineWidth: lineWidth)
                Circle()
                    .trim(from: 0, to: 0.25)
                    .stroke(resolvedTint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(rotation))
            }
            .frame(width: size, height: size)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
            }
            .accessibilityHidden(true)
        }
    }
}

#Preview("TaskSpinner") {
    HStack(spacing: 24) {
        ConduitUI.TaskSpinner()
        ConduitUI.TaskSpinner(size: 13)
    }
    .padding(20)
    .background(Color(hex: "#04050a"))
    .environment(\.neonTheme, NeonTheme.resolve(palette: .ice, dark: true, glow: true))
}
