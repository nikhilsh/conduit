import SwiftUI

// MARK: - ConduitFlowAtoms
//
// New shared atoms for the "Flow" (pipeline v2) redesign home surface --
// design_handoff_flow/README.md "Components" + px-shared.jsx (AgentDot /
// GateGlyph / GatePill / TopoMini). Composed purely from existing tokens
// (`neon.*`) + the existing per-agent tint/glyph mapping
// (`neon.agentTint(forAgent:)` / `AgentGlyph` in Shared/AgentAvatar.swift) --
// no new agent enum, no hex literals. Android mirror:
// `apps/android/.../ui/components/FlowAtoms.kt` (value-for-value).

extension ConduitUI {

    /// Small circular agent avatar with an optional status ring. `agent ==
    /// nil` renders a neutral (non-agent-tinted) placeholder dot -- used by
    /// `FlowCard` when only step-count data is available, not a per-step
    /// agent identity (`PipelineSummary` carries no per-step array).
    struct AgentDot: View {
        enum Status: Equatable {
            case running, done, idle, error, live
        }

        let agent: String?
        var size: CGFloat = 30
        var status: Status? = nil
        @Environment(\.neonTheme) private var neon

        var body: some View {
            let tint = agent.map { neon.agentTint(forAgent: $0) } ?? neon.textFaint
            return ZStack {
                Circle().fill(tint.opacity(0.18))
                if let agent {
                    // Bumped 0.55 -> 0.6 (device feedback: glyphs read too
                    // small relative to their tinted-circle container).
                    AgentGlyph(assistant: agent, size: size * 0.6)
                }
            }
            .frame(width: size, height: size)
            .overlay(Circle().strokeBorder(ringColor(tint: tint), lineWidth: 1.5))
            .neonGlowBox(glows && neon.glow ? neon.glowBox?.tinted(ringColor(tint: tint)) : nil)
        }

        private var glows: Bool { status == .running || status == .live }

        /// No status -> the agent's own tint at ~33%. With a status, the
        /// ring follows the shared status map (README "Status map").
        private func ringColor(tint: Color) -> Color {
            switch status {
            case .none:    return tint.opacity(0.33)
            case .running: return neon.yellow
            case .done:    return neon.accent
            case .idle:    return neon.textFaint
            case .error:   return neon.red
            case .live:    return neon.green
            }
        }
    }

    /// Two vertical rounded bars (a "pause" glyph) -- the human-approval
    /// checkpoint marker used inline (`TopoMini`) and standalone (`GatePill`,
    /// gate review cards). Default color is the gate token (`yellow`).
    struct GateGlyph: View {
        var color: Color? = nil
        var size: CGFloat = 12
        @Environment(\.neonTheme) private var neon

        var body: some View {
            let c = color ?? neon.yellow
            HStack(spacing: size * 0.16) {
                RoundedRectangle(cornerRadius: size * 0.13, style: .continuous)
                    .fill(c)
                    .frame(width: size * 0.24, height: size * 0.85)
                RoundedRectangle(cornerRadius: size * 0.13, style: .continuous)
                    .fill(c)
                    .frame(width: size * 0.24, height: size * 0.85)
            }
            .frame(width: size, height: size)
        }
    }

    /// Mono uppercase capsule marking a gate boundary (e.g. "GATE — YOU
    /// APPROVE" / "APPROVED"). `active` = amber fill/border/glow + amber
    /// text; inactive = a faint neutral wash + hairline border + textFaint.
    struct GatePill: View {
        let label: String
        var active: Bool = false
        @Environment(\.neonTheme) private var neon

        var body: some View {
            HStack(spacing: 5) {
                GateGlyph(color: active ? neon.yellow : neon.textFaint, size: 10)
                Text(label.uppercased())
                    .font(neon.mono(10).weight(.bold))
                    .tracking(0.8)
            }
            .foregroundStyle(active ? neon.yellow : neon.textFaint)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(
                // Design token: a faint neutral wash for the inactive
                // capsule (rgba(255,255,255,0.05) in the handoff) -- not a
                // brand hex, so it's kept as a plain system-white opacity
                // rather than a new token (mirrors AgentAvatar's white disc).
                Capsule().fill(active ? neon.yellow.opacity(0.13) : Color.white.opacity(0.05))
            )
            .overlay(
                Capsule().stroke(active ? neon.yellow.opacity(0.4) : neon.lineSoft, lineWidth: 1)
            )
            .neonGlowBox(active && neon.glow ? neon.glowBox?.tinted(neon.yellow) : nil)
        }
    }

    /// Gate toggle row: leading amber `GateGlyph` (the shared two-bar pause
    /// glyph, not a generic SF Symbol) + title/subtitle + trailing amber
    /// switch. Layout mirrors `ListRow` so it drops into a
    /// `neonCardSurface` exactly like `toggleRow(...)` --
    /// design_handoff_flow "StepEditSheet" gate row (IconTile + `GateGlyph`,
    /// amber). Android mirror: `FlowAtoms.kt` `FlowGateToggleRow`.
    struct GateToggleRow: View {
        let title: String
        var subtitle: String? = nil
        let isOn: Binding<Bool>
        @Environment(\.neonTheme) private var neon

        var body: some View {
            HStack(spacing: 12) {
                GateGlyph(color: neon.yellow, size: 16)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(ConduitUI.Palette.textPrimary.color)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(ConduitUI.Palette.textMuted.color)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 6)
                NeonTintedToggle(isOn: isOn, switchTint: neon.yellow)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
    }

    /// One step in a `TopoMini` strip. Deliberately minimal -- callers that
    /// only have step-count/current-step data (no per-step agent identity)
    /// pass `agent: nil` and `gateAfter: false` to degrade gracefully
    /// (see `FlowCard`).
    struct FlowTopoStep: Equatable {
        var agent: String? = nil
        var status: AgentDot.Status? = nil
        var gateAfter: Bool = false

        init(agent: String? = nil, status: AgentDot.Status? = nil, gateAfter: Bool = false) {
            self.agent = agent
            self.status = status
            self.gateAfter = gateAfter
        }
    }

    /// Horizontal mini topology strip: `AgentDot`s joined by thin
    /// connectors (green when the step before is done, else `lineSoft`);
    /// a `GateGlyph` splices into the connector where `gateAfter` is set,
    /// turning amber only when that gate is the active boundary (the step
    /// before is done and the next step is still idle). Sizes 20-26px.
    struct TopoMini: View {
        let steps: [FlowTopoStep]
        var size: CGFloat = 24
        @Environment(\.neonTheme) private var neon

        var body: some View {
            HStack(spacing: 6) {
                ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                    AgentDot(agent: step.agent, size: size, status: step.status)
                    if i < steps.count - 1 {
                        connector(after: step, next: steps[i + 1])
                    }
                }
            }
        }

        @ViewBuilder
        private func connector(after step: FlowTopoStep, next: FlowTopoStep) -> some View {
            let isDone = step.status == .done
            HStack(spacing: 4) {
                Rectangle()
                    .fill(isDone ? neon.green.opacity(0.55) : neon.lineSoft)
                    .frame(width: step.gateAfter ? 6 : 14, height: 1.5)
                if step.gateAfter {
                    let gateActive = isDone && next.status == .idle
                    GateGlyph(color: gateActive ? neon.yellow : neon.textFaint, size: 11)
                    Rectangle().fill(neon.lineSoft).frame(width: 6, height: 1.5)
                }
            }
        }
    }
}

#Preview("Flow atoms") {
    VStack(alignment: .leading, spacing: 20) {
        HStack(spacing: 14) {
            ConduitUI.AgentDot(agent: "claude", status: nil)
            ConduitUI.AgentDot(agent: "codex", status: .running)
            ConduitUI.AgentDot(agent: "opencode", status: .done)
            ConduitUI.AgentDot(agent: nil, status: .idle)
            ConduitUI.AgentDot(agent: "claude", status: .error)
        }
        HStack(spacing: 14) {
            ConduitUI.GateGlyph()
            ConduitUI.GatePill(label: "gate — you approve", active: true)
            ConduitUI.GatePill(label: "approved", active: false)
        }
        ConduitUI.TopoMini(steps: [
            ConduitUI.FlowTopoStep(agent: "claude", status: .done),
            ConduitUI.FlowTopoStep(agent: "claude", status: .done, gateAfter: true),
            ConduitUI.FlowTopoStep(agent: "codex", status: .idle),
        ])
    }
    .padding()
    .background(Color.black)
}
