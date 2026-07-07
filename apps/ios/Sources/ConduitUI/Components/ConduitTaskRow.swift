import SwiftUI

// MARK: - ConduitTaskStatus
//
// Shared status enum for a dispatched background task (design handoff
// session_tasks). Public (not nested under ConduitUI) because a later
// Tasks-sheet PR reuses it for the grouped sheet rows.
public enum ConduitTaskStatus: Equatable, Sendable {
    case running
    case gate
    case done
    case error
}

// MARK: - ConduitUI.TaskRow
//
// Inline collapsed background-task row for the chat transcript (design
// handoff session_tasks Sec 1 "TaskRow"). Anatomy: ConduitCard, 11/13
// padding, leading spinner-or-dot, title, trailing status text + chevron,
// optional rich tail line.
//
// `elapsed` is a preformatted String -- there is no ticker in this PR;
// callers own re-rendering the row as time passes.

extension ConduitUI {
    struct TaskRow: View {
        let title: String
        var status: ConduitTaskStatus = .running
        var elapsed: String? = nil
        /// Live tail line (rich variant, shown only when non-nil/non-empty).
        /// Truncates the HEAD, keeping the end of the string visible --
        /// mirrors `.truncationMode(.head)` below.
        var tail: String? = nil
        var onOpen: () -> Void = {}

        @Environment(\.neonTheme) private var neon

        private var tint: Color {
            switch status {
            case .running, .gate: return neon.yellow
            case .done: return neon.green
            case .error: return neon.red
            }
        }

        private var statusText: String {
            switch status {
            case .running, .gate: return elapsed ?? ""
            case .done: return "done"
            case .error: return "failed"
            }
        }

        private var borderColor: Color {
            switch status {
            case .running, .gate: return neon.yellow.opacity(0.20)
            case .done, .error: return neon.lineSoft
            }
        }

        var body: some View {
            ConduitUI.Card(padding: 0) {
                Button(action: onOpen) {
                    VStack(alignment: .leading, spacing: 9) {
                        HStack(spacing: 10) {
                            leading
                            Text(title)
                                .font(neon.sans(14.5).weight(.semibold))
                                .foregroundStyle(neon.text)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: 6)
                            Text(statusText)
                                .font(neon.mono(11))
                                .foregroundStyle(tint)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(neon.textFaint)
                        }
                        if let tail, !tail.isEmpty {
                            Text(tail)
                                .font(neon.mono(11))
                                .foregroundStyle(neon.textFaint)
                                .lineLimit(1)
                                .truncationMode(.head)
                                .padding(.leading, 26)
                        }
                    }
                    .padding(.vertical, 11)
                    .padding(.horizontal, 13)
                    .frame(minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(borderColor, lineWidth: 1)
            )
        }

        @ViewBuilder
        private var leading: some View {
            if status == .running {
                ConduitUI.TaskSpinner(size: 16, tint: neon.yellow)
            } else {
                let glowing = status == .gate && neon.glow
                Circle()
                    .fill(tint)
                    .frame(width: 8, height: 8)
                    .shadow(color: glowing ? tint.opacity(0.6) : .clear, radius: glowing ? 4 : 0)
            }
        }
    }
}

#Preview("TaskRow - matrix") {
    ScrollView {
        VStack(spacing: 12) {
            ConduitUI.TaskRow(
                title: "PR B - Start sheet + wizard",
                status: .running,
                elapsed: "4m 02s",
                tail: "$ swift build ... 214/280 files"
            )
            ConduitUI.TaskRow(
                title: "PR A - Flow atoms + home",
                status: .running,
                elapsed: "2m 13s"
            )
            ConduitUI.TaskRow(
                title: "PR C - Monitor",
                status: .gate,
                elapsed: "6m 10s",
                tail: "waiting on your review"
            )
            ConduitUI.TaskRow(
                title: "Inventory existing pipeline UI",
                status: .gate,
                elapsed: "0m 40s"
            )
            ConduitUI.TaskRow(
                title: "PR A - Flow atoms + home",
                status: .done,
                tail: "CI green - merged 3m ago"
            )
            ConduitUI.TaskRow(
                title: "Docs sweep - rename to Flow",
                status: .done
            )
            ConduitUI.TaskRow(
                title: "PR D - Broker redeploy",
                status: .error,
                tail: "go vet failed - see log"
            )
            ConduitUI.TaskRow(
                title: "PR E - Release tag",
                status: .error
            )
        }
        .padding(16)
    }
    .background(Color(hex: "#04050a"))
    .environment(\.neonTheme, NeonTheme.resolve(palette: .ice, dark: true, glow: true))
}
