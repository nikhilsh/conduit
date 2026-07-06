import SwiftUI

// MARK: - PipelineTopologyRail
//
// PLAN-HARNESS-BUILDER Phase 2 (docs/PLAN-HARNESS-BUILDER.md 3.1). A
// compact, read-only rail rendering a not-yet-started harness's block stack
// top-to-bottom -- mirrors the visual shape ConduitPipelineMonitorView
// already draws for a RUNNING pipeline (leading agent avatar, index, fanout
// badge, indented run cluster, gate marker) but carries no live-run state
// (no session ids, no state chips) since nothing has started yet. Used by
// the Builder as a preview above the block-card stack (phone) and inside
// the block-list rail (tablet).

extension ConduitUI {

    struct PipelineTopologyItem: Identifiable, Equatable {
        let id: UUID
        let agentType: String
        let role: String
        let gateAfter: Bool
        /// 0 = no fanout; otherwise the declared run count.
        let fanoutCount: Int
        /// "" (plain agent step, back-compatible) | "branch" | "loop"
        /// (PLAN-HARNESS-BUILDER Phase 3).
        var kind: String = ""
        /// Then/Else sub-stack counts (kind == "branch" only).
        var thenCount: Int = 0
        var elseCount: Int = 0
        /// Loop body step count + max_iterations (kind == "loop" only).
        var bodyCount: Int = 0
        var maxIterations: Int = 0

        var isControlFlow: Bool { kind == "branch" || kind == "loop" }
    }

    struct PipelineTopologyRail: View {
        let items: [PipelineTopologyItem]
        var onSelect: ((UUID) -> Void)? = nil
        @Environment(\.neonTheme) private var neon

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                    row(item, index: i, isLast: i == items.count - 1)
                }
            }
        }

        private func row(_ item: PipelineTopologyItem, index: Int, isLast: Bool) -> some View {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    if item.isControlFlow {
                        Image(systemName: item.kind == "loop" ? "repeat" : "arrow.triangle.branch")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(neon.accent)
                            .frame(width: 20, height: 20)
                    } else {
                        AgentGlyph(assistant: item.agentType, size: 20)
                    }
                    Text("\(index + 1). \(item.isControlFlow ? (item.kind == "loop" ? "Loop" : "If/Else") : item.role.capitalized)")
                        .font(neon.mono(11).weight(.semibold))
                        .foregroundStyle(neon.text)
                        .lineLimit(1)
                    if item.fanoutCount > 0 {
                        Text("\(item.fanoutCount)x")
                            .font(neon.mono(9).weight(.bold))
                            .foregroundStyle(neon.accent)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(neon.accent.opacity(0.15)))
                    }
                    if item.kind == "loop" {
                        Text("max \(item.maxIterations)x")
                            .font(neon.mono(9).weight(.bold))
                            .foregroundStyle(neon.accent)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(neon.accent.opacity(0.15)))
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
                .onTapGesture { onSelect?(item.id) }

                // Indented fanout cluster placeholder (mirrors the Monitor's
                // sub-run list shape, no run data yet).
                if item.fanoutCount > 0 {
                    HStack(spacing: 6) {
                        Rectangle().fill(neon.border.opacity(0.6)).frame(width: 1, height: 12)
                        Text("\(item.fanoutCount) parallel runs")
                            .font(neon.mono(9))
                            .foregroundStyle(neon.textFaint)
                    }
                    .padding(.leading, 9)
                }

                // Branch: two indented lanes (Then / Else). Loop: one
                // indented lane (Body). Compact/read-only, mirrors the
                // fanout cluster shape above.
                if item.kind == "branch" {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Rectangle().fill(neon.border.opacity(0.6)).frame(width: 1, height: 12)
                            Text("then: \(item.thenCount) step\(item.thenCount == 1 ? "" : "s")")
                                .font(neon.mono(9))
                                .foregroundStyle(neon.textFaint)
                        }
                        HStack(spacing: 6) {
                            Rectangle().fill(neon.border.opacity(0.6)).frame(width: 1, height: 12)
                            Text("else: \(item.elseCount) step\(item.elseCount == 1 ? "" : "s")")
                                .font(neon.mono(9))
                                .foregroundStyle(neon.textFaint)
                        }
                    }
                    .padding(.leading, 9)
                } else if item.kind == "loop" {
                    HStack(spacing: 6) {
                        Rectangle().fill(neon.border.opacity(0.6)).frame(width: 1, height: 12)
                        Text("body: \(item.bodyCount) step\(item.bodyCount == 1 ? "" : "s")")
                            .font(neon.mono(9))
                            .foregroundStyle(neon.textFaint)
                    }
                    .padding(.leading, 9)
                }

                // Connector to the next block, with a gate pause-marker when
                // this block is gated.
                if !isLast {
                    if item.gateAfter {
                        HStack(spacing: 6) {
                            Rectangle().fill(neon.yellow.opacity(0.6)).frame(width: 1, height: 8)
                            Image(systemName: "hand.raised.fill")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(neon.yellow)
                            Text("gate")
                                .font(neon.mono(8).weight(.semibold))
                                .foregroundStyle(neon.yellow)
                        }
                        .padding(.leading, 9)
                    } else {
                        Rectangle().fill(neon.border.opacity(0.4)).frame(width: 1, height: 8).padding(.leading, 9)
                    }
                }
            }
        }
    }
}
