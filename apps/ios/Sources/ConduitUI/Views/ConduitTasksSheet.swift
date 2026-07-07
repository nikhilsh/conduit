import Foundation
import SwiftUI

// MARK: - ConduitTasksSheet
//
// Bottom sheet grouping a session's background tasks (design handoff
// session_tasks, "3. Tasks sheet"), opened from `ConduitUI.RunningPill`
// (PR2) via the chat view's `showTasksSheet` state.
//
// Data source: the live subagent roster (`SessionStore.subagentRosters`)
// -- there is no dedicated "task" model yet, so `ConduitTasksSheetLogic`
// maps `SubagentEntry` -> row directly. Two real gaps, both intentional:
//   - No "gate" status exists in the roster today, so the "Needs you"
//     group is always empty in production. The mapping + rendering are
//     built fully so the group lights up the moment the broker adds a
//     gate status string.
//   - No broker verb exists to stop an individual subagent. `canStop` is
//     hard-false for real rows (only previews set it true to show the
//     control) -- wiring `onStop` to a real kill is a follow-up.
// "View transcript" is intentionally omitted: neither
// `ConduitSubagentCard` (chat transcript card) nor the Android
// `SubagentCard` navigate anywhere today, so there is no destination to
// link to yet -- also a follow-up.

/// One row in the Tasks sheet, derived from a `SubagentEntry`.
public struct ConduitTaskSheetRow: Identifiable, Equatable {
    public let id: String
    public let title: String
    public let status: ConduitTaskStatus
    public let agent: String
    public let meta: String
    public let canStop: Bool
    let startedEpoch: Double
    let endedEpoch: Double
}

/// The sheet's three ordered groups (gate rows first, then running
/// newest-first, then finished newest-first -- design handoff "Behavior
/// & state" ordering rule).
public struct ConduitTaskSheetGroups: Equatable {
    public let needsYou: [ConduitTaskSheetRow]
    public let running: [ConduitTaskSheetRow]
    public let finished: [ConduitTaskSheetRow]

    public var isEmpty: Bool { needsYou.isEmpty && running.isEmpty && finished.isEmpty }
}

/// Pure mapping/grouping/formatting logic, kept out of the view body so
/// it's directly callable from previews and (if a future PR adds an XCTest
/// target for ConduitUI) unit-testable without a live roster.
enum ConduitTasksSheetLogic {
    /// Roster `status` string -> `ConduitTaskStatus`. "working" (the only
    /// value the broker sends today) maps to `.running`; `.gate` is mapped
    /// defensively for a future broker addition -- never sent today.
    static func statusFromRaw(_ raw: String) -> ConduitTaskStatus {
        switch raw.lowercased() {
        case "done": return .done
        case "failed", "error": return .error
        case "gate": return .gate
        default: return .running
        }
    }

    /// "4m 02s" -- zero-padded seconds, ticking display for running/gated
    /// rows. Distinct from the coarser `finishedDurationLabel` below
    /// (existing formatters in the codebase drop the zero-pad and don't
    /// match the design's running-row format).
    static func elapsedLabel(seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let minutes = total / 60
        let secs = total % 60
        return String(format: "%dm %02ds", minutes, secs)
    }

    /// Coarse "12m" / "1h 05m" duration for a FINISHED row's meta line.
    static func finishedDurationLabel(ms: Int) -> String {
        let totalSeconds = max(0, ms) / 1000
        if totalSeconds < 60 { return "\(totalSeconds)s" }
        let minutes = totalSeconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let remMinutes = minutes % 60
        return remMinutes == 0 ? "\(hours)h" : "\(hours)h \(remMinutes)m"
    }

    static func meta(for entry: SubagentEntry, status: ConduitTaskStatus, elapsedSeconds: Double?) -> String {
        switch status {
        case .running:
            let tool = entry.lastTool.trimmingCharacters(in: .whitespaces)
            let elapsed = elapsedLabel(seconds: elapsedSeconds ?? 0)
            return tool.isEmpty ? elapsed : "\(elapsed) \u{b7} \(tool)"
        case .gate:
            let description = entry.description.trimmingCharacters(in: .whitespaces)
            return description.isEmpty ? "gate - review before merge" : description
        case .done:
            return "completed \u{b7} \(finishedDurationLabel(ms: entry.durationMs))"
        case .error:
            return "failed \u{b7} \(finishedDurationLabel(ms: entry.durationMs))"
        }
    }

    /// Map + group + sort the live roster into the sheet's three sections.
    /// `now` is injectable so previews/tests can pin a stable elapsed value.
    static func groups(from roster: [SubagentEntry], sessionAgent: String, now: Date = Date()) -> ConduitTaskSheetGroups {
        let rows: [ConduitTaskSheetRow] = roster.map { entry in
            let status = statusFromRaw(entry.status)
            let startedEpoch = entry.startedAt.isEmpty ? Double.greatestFiniteMagnitude : conduitConversationTsEpoch(entry.startedAt)
            let endedEpoch = entry.endedAt.isEmpty ? Double.greatestFiniteMagnitude : conduitConversationTsEpoch(entry.endedAt)
            let elapsedSeconds: Double? = {
                guard status == .running || status == .gate else { return nil }
                guard startedEpoch.isFinite, startedEpoch != .greatestFiniteMagnitude else { return nil }
                return max(0, now.timeIntervalSince1970 - startedEpoch)
            }()
            let title = entry.name.isEmpty ? (entry.description.isEmpty ? "Task" : entry.description) : entry.name
            return ConduitTaskSheetRow(
                id: entry.taskId,
                title: title,
                status: status,
                agent: sessionAgent,
                meta: meta(for: entry, status: status, elapsedSeconds: elapsedSeconds),
                // No broker verb exists to stop an individual subagent yet --
                // real rows never offer the control (see file header).
                canStop: false,
                startedEpoch: startedEpoch,
                endedEpoch: endedEpoch
            )
        }
        let needsYou = rows.filter { $0.status == .gate }.sorted { $0.startedEpoch > $1.startedEpoch }
        let running = rows.filter { $0.status == .running }.sorted { $0.startedEpoch > $1.startedEpoch }
        let finished = rows.filter { $0.status == .done || $0.status == .error }.sorted { $0.endedEpoch > $1.endedEpoch }
        return ConduitTaskSheetGroups(needsYou: needsYou, running: running, finished: finished)
    }
}

extension ConduitUI {
    struct TasksSheet: View {
        @Environment(SessionStore.self) private var store
        @Environment(\.neonTheme) private var neon
        @Environment(\.dismiss) private var dismiss

        let sessionID: String
        let sessionAgent: String
        /// Invoked when a gate row's "Review" pill is tapped. No-op today
        /// (no gate data exists in production) -- wired for when it does.
        var onReview: (ConduitTaskSheetRow) -> Void = { _ in }
        /// Invoked after the stop confirmation, for rows with `canStop`.
        /// No production row sets `canStop` yet (see file header) -- this
        /// only fires from previews/tests today.
        var onStop: (ConduitTaskSheetRow) -> Void = { _ in }

        @State private var stopCandidate: ConduitTaskSheetRow?

        private var roster: [SubagentEntry] { store.subagentRosters[sessionID] ?? [] }

        var body: some View {
            NavigationStack {
                content
                    .navigationTitle("Tasks")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button {
                                dismiss()
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 13, weight: .semibold))
                            }
                            .accessibilityLabel("Close")
                        }
                    }
                    .tint(neon.accent)
            }
            .confirmationDialog(
                "Stop this task?",
                isPresented: Binding(
                    get: { stopCandidate != nil },
                    set: { presented in if !presented { stopCandidate = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Stop", role: .destructive) {
                    if let row = stopCandidate { onStop(row) }
                    stopCandidate = nil
                }
                Button("Cancel", role: .cancel) { stopCandidate = nil }
            }
        }

        @ViewBuilder
        private var content: some View {
            ZStack {
                GlassAppBackground()
                if roster.isEmpty {
                    Text("No background tasks")
                        .font(neon.sans(14))
                        .foregroundStyle(neon.textFaint.opacity(0.7))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                } else {
                    // Elapsed on running/gated rows ticks every second while
                    // the sheet is visible.
                    TimelineView(.periodic(from: .now, by: 1)) { timeline in
                        let groups = ConduitTasksSheetLogic.groups(
                            from: roster,
                            sessionAgent: sessionAgent,
                            now: timeline.date
                        )
                        ScrollView {
                            VStack(alignment: .leading, spacing: 16) {
                                if !groups.needsYou.isEmpty {
                                    section(title: "NEEDS YOU", rows: groups.needsYou, tint: neon.yellow, glowCard: true)
                                }
                                if !groups.running.isEmpty {
                                    section(title: "RUNNING", rows: groups.running, tint: nil, glowCard: false)
                                }
                                if !groups.finished.isEmpty {
                                    section(title: "FINISHED", rows: groups.finished, tint: nil, glowCard: false)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                        }
                    }
                }
            }
        }

        private func section(title: String, rows: [ConduitTaskSheetRow], tint: Color?, glowCard: Bool) -> some View {
            VStack(alignment: .leading, spacing: 8) {
                sectionLabel("\(title) \u{b7} \(rows.count)", tint: tint)
                ConduitUI.Card(padding: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            ConduitTasksSheetRowView(
                                row: row,
                                isLast: index == rows.count - 1,
                                onReview: { onReview(row) },
                                onRequestStop: { stopCandidate = row }
                            )
                        }
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(glowCard ? neon.yellow.opacity(0.27) : Color.clear, lineWidth: glowCard ? 1 : 0)
                )
                .shadow(
                    color: (glowCard && neon.glow) ? neon.yellow.opacity(0.35) : .clear,
                    radius: (glowCard && neon.glow) ? 10 : 0
                )
            }
        }

        private func sectionLabel(_ text: String, tint: Color?) -> some View {
            Text(text.uppercased())
                .font(neon.mono(11).weight(.bold))
                .tracking(0.6)
                .foregroundStyle(tint ?? neon.textFaint)
        }
    }
}

/// One row inside a Tasks-sheet group card. Anatomy: leading
/// spinner-or-dot, title + (agent Chip + mono meta) second line, trailing
/// stop-ring (running + canStop) or Review pill (gate).
private struct ConduitTasksSheetRowView: View {
    let row: ConduitTaskSheetRow
    let isLast: Bool
    let onReview: () -> Void
    let onRequestStop: () -> Void

    @Environment(\.neonTheme) private var neon

    private var dotTint: Color {
        switch row.status {
        case .running, .gate: return neon.yellow
        case .done: return neon.green
        case .error: return neon.red
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 11) {
            leading
            VStack(alignment: .leading, spacing: 4) {
                Text(row.title)
                    .font(neon.sans(15).weight(.semibold))
                    .foregroundStyle(neon.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 8) {
                    ConduitUI.Chip(label: row.agent, tint: neon.agentTint(forAgent: row.agent))
                    Text(row.meta)
                        .font(neon.mono(11))
                        .foregroundStyle(row.status == .gate ? neon.yellow : neon.textFaint)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.vertical, 13)
        .padding(.horizontal, 14)
        .overlay(alignment: .bottom) {
            if !isLast {
                Rectangle().fill(neon.lineSoft).frame(height: 1)
            }
        }
    }

    @ViewBuilder
    private var leading: some View {
        if row.status == .running {
            ConduitUI.TaskSpinner(size: 16, tint: neon.yellow)
        } else {
            let glowing = row.status == .gate && neon.glow
            Circle()
                .fill(dotTint)
                .frame(width: 8, height: 8)
                .shadow(color: glowing ? dotTint.opacity(0.6) : .clear, radius: glowing ? 4 : 0)
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if row.status == .gate {
            ConduitUI.ActionPill(
                label: "Review",
                systemImage: "exclamationmark.triangle.fill",
                variant: .solid,
                tint: neon.yellow,
                action: onReview
            )
        } else if row.status == .running, row.canStop {
            stopButton
        }
    }

    private var stopButton: some View {
        Button(action: onRequestStop) {
            ZStack {
                Circle()
                    .stroke(neon.lineSoft, lineWidth: 1)
                    .frame(width: 34, height: 34)
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .fill(neon.red)
                    .frame(width: 10, height: 10)
            }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Stop task")
    }
}

// MARK: - Previews

#Preview("TasksSheet - all groups") {
    ConduitTasksSheetPreviewHost(rows: ConduitTasksSheetPreviewData.mixed)
}

#Preview("TasksSheet - needs you only") {
    ConduitTasksSheetPreviewHost(rows: ConduitTasksSheetPreviewData.gateOnly)
}

#Preview("TasksSheet - empty") {
    ConduitTasksSheetPreviewHost(rows: [])
}

// `groups(from:sessionAgent:)` always maps real roster entries to
// `canStop: false` (no broker kill verb exists yet -- see file header), so
// the only way to preview the stop control is to construct a row directly.
#Preview("TasksSheet row - running, canStop") {
    VStack(spacing: 0) {
        ConduitTasksSheetRowView(
            row: ConduitTaskSheetRow(
                id: "preview-stop",
                title: "PR B - Start sheet + wizard",
                status: .running,
                agent: "codex",
                meta: "4m 02s \u{b7} swift build",
                canStop: true,
                startedEpoch: 0,
                endedEpoch: 0
            ),
            isLast: true,
            onReview: {},
            onRequestStop: {}
        )
    }
    .padding(16)
    .background(Color(hex: "#04050a"))
    .environment(\.neonTheme, NeonTheme.resolve(palette: .ice, dark: true, glow: true))
}

#Preview("TasksSheet row - gate") {
    VStack(spacing: 0) {
        ConduitTasksSheetRowView(
            row: ConduitTaskSheetRow(
                id: "preview-gate",
                title: "PR C - Monitor",
                status: .gate,
                agent: "claude",
                meta: "gate - review before merge",
                canStop: false,
                startedEpoch: 0,
                endedEpoch: 0
            ),
            isLast: true,
            onReview: {},
            onRequestStop: {}
        )
    }
    .padding(16)
    .background(Color(hex: "#04050a"))
    .environment(\.neonTheme, NeonTheme.resolve(palette: .ice, dark: true, glow: true))
}

/// Preview-only host: seeds a throwaway `SessionStore` with a fixed roster
/// so `ConduitUI.TasksSheet` renders without a live broker connection.
private struct ConduitTasksSheetPreviewHost: View {
    let rows: [SubagentEntry]
    @State private var store = SessionStore()

    var body: some View {
        ConduitUI.TasksSheet(sessionID: "preview-session", sessionAgent: "claude")
            .environment(store)
            .environment(\.neonTheme, NeonTheme.resolve(palette: .ice, dark: true, glow: true))
            .onAppear {
                store.subagentRosters["preview-session"] = rows
            }
    }
}

private enum ConduitTasksSheetPreviewData {
    /// One row per group, including a gate row and a `canStop` running row
    /// (preview-only -- no production roster entry sets `canStop` true).
    static let mixed: [SubagentEntry] = [
        SubagentEntry(
            taskId: "gate-1",
            name: "PR C - Monitor",
            description: "gate - review before merge",
            status: "gate",
            lastTool: "",
            tokens: 0,
            toolUses: 0,
            durationMs: 0,
            startedAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-370)),
            endedAt: ""
        ),
        SubagentEntry(
            taskId: "running-1",
            name: "PR B - Start sheet + wizard",
            description: "",
            status: "working",
            lastTool: "swift build",
            tokens: 0,
            toolUses: 0,
            durationMs: 0,
            startedAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-242)),
            endedAt: ""
        ),
        SubagentEntry(
            taskId: "done-1",
            name: "PR A - Flow atoms + home",
            description: "",
            status: "done",
            lastTool: "",
            tokens: 0,
            toolUses: 0,
            durationMs: 12 * 60 * 1000,
            startedAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-900)),
            endedAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-180))
        ),
        SubagentEntry(
            taskId: "error-1",
            name: "PR D - Broker redeploy",
            description: "",
            status: "failed",
            lastTool: "",
            tokens: 0,
            toolUses: 0,
            durationMs: 45 * 1000,
            startedAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-500)),
            endedAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-400))
        ),
    ]

    static let gateOnly: [SubagentEntry] = [
        SubagentEntry(
            taskId: "gate-2",
            name: "Docs sweep - rename to Flow",
            description: "",
            status: "gate",
            lastTool: "",
            tokens: 0,
            toolUses: 0,
            durationMs: 0,
            startedAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-31)),
            endedAt: ""
        ),
    ]
}
