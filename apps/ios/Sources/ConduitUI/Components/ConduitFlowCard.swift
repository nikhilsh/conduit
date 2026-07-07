import SwiftUI

// MARK: - ConduitFlowCard
//
// Home-screen presence card for the "Flow" (pipeline v2) redesign --
// design_handoff_flow/README.md "Screens > 1. Home" + "Components > FlowCard"
// (flow-proto-screens.jsx). Built on the existing `ConduitUI.Chip` + the new
// `ConduitFlowAtoms` (`TopoMini`, `GateGlyph`). Android mirror:
// `apps/android/.../ui/components/FlowCard.kt` (value-for-value).
//
// Input is the EXISTING `PipelineSummary` model (`id, title, state,
// current_step, step_count, created` -- see ConduitPipelineListView.swift).
// It carries no per-step agent/gate array, so `TopoMini` here is a graceful
// DEGRADATION from step_count/current_step alone: generic (agent == nil)
// dots, no gate pips. A future PR that threads richer per-step data through
// `GET /api/pipelines` can upgrade this without changing the call sites.
//
// Nested Button footgun (see #914/#918): the card's "open" tap target is
// its OWN `Button`, scoped to just the title/topo rows -- NOT a row-wide
// `.onTapGesture` wrapping the whole card, which would swallow the sibling
// "Review output"/"Continue" buttons' taps.

extension ConduitUI {

    struct FlowCard: View {
        let summary: ConduitUI.PipelineSummary
        /// True while a "Continue" network call for this card is in
        /// flight -- the caller owns the request + telemetry (mirrors
        /// `ConduitPipelineMonitorView.isContinuing`).
        var isContinuing: Bool = false
        var onOpen: () -> Void
        var onContinue: () -> Void
        @Environment(\.neonTheme) private var neon

        private var state: String { summary.state }
        private var isGated: Bool { state == "awaiting_gate" }
        private var isAwaitingPick: Bool { state == "awaiting_pick" }
        private var needsYou: Bool { isGated || isAwaitingPick }
        private var isFailed: Bool { state == "failed" }
        private var isComplete: Bool { state == "complete" }
        private var isCancelled: Bool { state == "cancelled" }

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                SwiftUI.Button(action: onOpen) {
                    VStack(alignment: .leading, spacing: 10) {
                        titleRow
                        HStack(spacing: 10) {
                            ConduitUI.TopoMini(steps: topoSteps, size: 24)
                            Text(caption)
                                .font(neon.mono(11.5))
                                .foregroundStyle(neon.textDim)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if needsYou {
                    buttonsRow
                        .padding(.top, 12)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .neonCardSurface(
                neon,
                fill: neon.surface,
                cornerRadius: 14,
                border: cardBorder,
                glowTint: cardGlowTint
            )
        }

        // MARK: Title row

        private var titleRow: some View {
            HStack(spacing: 10) {
                Text(summary.title.isEmpty ? "Flow" : summary.title)
                    .font(neon.sans(15.5).weight(.semibold))
                    .foregroundStyle(neon.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                ConduitUI.Chip(label: chipLabel, tint: chipTint)
            }
        }

        // MARK: Buttons (awaiting_gate / awaiting_pick only)

        @ViewBuilder
        private var buttonsRow: some View {
            if isGated {
                HStack(spacing: 8) {
                    ConduitUI.ActionButton(variant: .secondary, action: onOpen) {
                        Text("Review output").font(neon.sans(13).weight(.semibold))
                    }
                    ConduitUI.ActionButton(variant: .primary, tint: neon.yellow, action: onContinue) {
                        HStack(spacing: 6) {
                            if isContinuing {
                                ProgressView().progressViewStyle(.circular).tint(neon.accentText).scaleEffect(0.7)
                            } else {
                                ConduitUI.GateGlyph(color: neon.accentText, size: 11)
                            }
                            Text(isContinuing ? "Continuing..." : "Continue")
                                .font(neon.sans(13).weight(.semibold))
                        }
                    }
                    .disabled(isContinuing)
                    .opacity(isContinuing ? 0.7 : 1)
                }
            } else {
                // awaiting_pick: review-style single button, no inline
                // approve (the pick happens in the monitor).
                ConduitUI.ActionButton("Review", variant: .secondary, action: onOpen)
            }
        }

        // MARK: State -> chip / caption / border

        private var chipLabel: String {
            if needsYou { return "needs you" }
            if isFailed { return "failed · step \(summary.current_step + 1)" }
            if isComplete { return "done" }
            if isCancelled { return "cancelled" }
            return "step \(min(summary.current_step + 1, max(summary.step_count, 1)))/\(max(summary.step_count, 1))"
        }

        private var chipTint: Color {
            if needsYou { return neon.yellow }
            if isFailed { return neon.red }
            if isComplete { return neon.accent }
            if isCancelled { return neon.textFaint }
            return neon.green
        }

        private var caption: String {
            // Real per-step data (broker #922) upgrades the caption with
            // the actual role name / diffstat instead of a generic
            // "Step N" placeholder -- falls through to the degraded
            // caption below when `summary.steps` is absent (older broker).
            if let steps = summary.steps, !steps.isEmpty {
                if isGated, let role = roleAt(summary.current_step, in: steps) {
                    return "\(role) done · review"
                }
                if isComplete { return completeCaption }
                if !isAwaitingPick && !isFailed && !isCancelled,
                   let role = roleAt(summary.current_step, in: steps) {
                    return "\(role) · running"
                }
            }
            if isGated { return "Step \(summary.current_step + 1) done · review" }
            if isAwaitingPick { return "Pick a result to continue" }
            if isFailed { return "halted — open to inspect" }
            if isComplete { return completeCaption }
            if isCancelled { return "cancelled" }
            if state == "step_done" { return "step done" }
            if state == "pending" { return "queued" }
            return "running"
        }

        /// Capitalized role name of the step at `index`, if in range --
        /// feeds the role-forward captions above.
        private func roleAt(_ index: Int, in steps: [ConduitUI.PipelineSummaryStep]) -> String? {
            guard steps.indices.contains(index) else { return nil }
            let role = steps[index].role
            return role.isEmpty ? nil : role.capitalized
        }

        /// "+N -N · N files" from the completed pipeline's diffstat (broker
        /// #922 `result`) -- falls back to the generic recap when the
        /// result is absent (older broker or a pre-#906 pipeline).
        private var completeCaption: String {
            guard let result = summary.result else { return "all steps finished" }
            var parts: [String] = []
            if result.insertions > 0 { parts.append("+\(result.insertions)") }
            if result.deletions > 0 { parts.append("-\(result.deletions)") }
            let stats = parts.joined(separator: " ")
            if result.files_changed > 0 {
                return stats.isEmpty ? "\(result.files_changed) files" : "\(stats) · \(result.files_changed) files"
            }
            return stats.isEmpty ? "all steps finished" : stats
        }

        private var cardBorder: Color {
            if needsYou { return neon.yellow.opacity(0.44) }
            if isFailed { return neon.red.opacity(0.44) }
            return neon.lineSoft
        }

        private var cardGlowTint: Color? {
            guard neon.glow else { return nil }
            return needsYou ? neon.yellow : nil
        }

        /// Real per-step topology (broker #922 `steps`) when available --
        /// actual agent dots + gate glyphs instead of the degraded generic
        /// strip. Tolerates absence (older broker / not-yet-refreshed
        /// summary) by falling back to `degradedTopoSteps`.
        private var topoSteps: [ConduitUI.FlowTopoStep] {
            guard let steps = summary.steps, !steps.isEmpty else { return degradedTopoSteps }
            return steps.map { step in
                ConduitUI.FlowTopoStep(
                    agent: step.agent,
                    status: Self.topoStatus(step.status),
                    gateAfter: step.gate_after
                )
            }
        }

        /// Maps the broker's coarse per-step status string (#922
        /// `stepDisplayStatus`) to `AgentDot.Status`. "awaiting_gate" /
        /// "awaiting_pick" both read as the amber "needs attention" ring
        /// (same family as `running` per the README status map); "queued"
        /// degrades to `nil` (faint, no ring/glow).
        private static func topoStatus(_ raw: String) -> ConduitUI.AgentDot.Status? {
            switch raw {
            case "running", "awaiting_gate", "awaiting_pick": return .running
            case "done": return .done
            case "failed": return .error
            default: return nil
            }
        }

        /// Degrade `TopoMini` from `step_count`/`current_step` alone (no
        /// per-step agent/gate data in `PipelineSummary`): generic dots,
        /// no gate pips. `current_step` is the step that's DONE/current per
        /// the broker's gate semantics (mirrors
        /// `ConduitPipelineMonitorView.gateCard`'s "Step N+1 ... gated").
        private var degradedTopoSteps: [ConduitUI.FlowTopoStep] {
            let n = max(summary.step_count, 1)
            let doneThrough: Int = {
                if isComplete { return n }
                if needsYou { return summary.current_step + 1 }
                return summary.current_step
            }()
            return (0..<n).map { i in
                let status: ConduitUI.AgentDot.Status
                if isFailed && i == summary.current_step {
                    status = .error
                } else if i < doneThrough {
                    status = .done
                } else if i == summary.current_step && (state == "running" || state == "step_done" || state == "pending") {
                    status = .running
                } else {
                    status = .idle
                }
                return ConduitUI.FlowTopoStep(agent: nil, status: status, gateAfter: false)
            }
        }
    }
}

#Preview("FlowCard states") {
    ScrollView {
        VStack(spacing: 12) {
            ConduitUI.FlowCard(
                summary: .init(id: "1", title: "Add rate limiter to broker", state: "awaiting_gate", current_step: 1, step_count: 3, created: nil),
                onOpen: {}, onContinue: {}
            )
            ConduitUI.FlowCard(
                summary: .init(id: "2", title: "Migrate settings to KV store", state: "running", current_step: 1, step_count: 3, created: nil),
                onOpen: {}, onContinue: {}
            )
            ConduitUI.FlowCard(
                summary: .init(id: "3", title: "Refactor auth module", state: "complete", current_step: 3, step_count: 3, created: nil),
                onOpen: {}, onContinue: {}
            )
            ConduitUI.FlowCard(
                summary: .init(id: "4", title: "Ship dark mode toggle", state: "failed", current_step: 1, step_count: 3, created: nil),
                onOpen: {}, onContinue: {}
            )
            // Real per-step topology (broker #922) -- exercises the
            // non-degraded TopoMini + role/diffstat captions.
            ConduitUI.FlowCard(
                summary: {
                    var s = ConduitUI.PipelineSummary(
                        id: "5", title: "Add rate limiter to broker", state: "complete",
                        current_step: 2, step_count: 3, created: nil
                    )
                    s.steps = [
                        .init(agent: "claude", role: "research", status: "done", gate_after: false),
                        .init(agent: "claude", role: "design", status: "done", gate_after: true),
                        .init(agent: "codex", role: "build", status: "done", gate_after: false),
                    ]
                    s.result = .init(files_changed: 6, insertions: 214, deletions: 38)
                    return s
                }(),
                onOpen: {}, onContinue: {}
            )
        }
        .padding()
    }
    .background(Color.black)
}
