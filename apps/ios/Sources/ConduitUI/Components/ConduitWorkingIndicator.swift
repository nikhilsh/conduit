import SwiftUI

// MARK: - Style + debug setting -----------------------------------------------------------

enum ConduitWorkingStyle: String, CaseIterable, Identifiable, Sendable {
    case packets, mark
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .packets:        return "B - Packets"
        case .mark:           return "C - Breathing mark"
        }
    }
}

enum ConduitWorkingDebug {
    /// Backing store key. `@AppStorage` on `UserDefaults.standard` reads
    /// the same key; no App Group suite is needed (other @AppStorage uses
    /// in the app also bind to standard).
    static let key = "debug.workingIndicatorStyle"
    /// Falls back to `.packets` for both an unset key AND a stale rawValue
    /// left over from a removed style (spine/prompt/packetsPrompt/pipedPrompt).
    static var current: ConduitWorkingStyle {
        ConduitWorkingStyle(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .packets
    }
}

// MARK: - The indicator -------------------------------------------------------------------

extension ConduitUI {

    /// Two-style pre-output working indicator (design handoff "working-indicator",
    /// trimmed per owner device feedback: single inline row, no detached bar).
    /// Replaces the legacy mono `WORKING...` label + single pulsing dot.
    ///
    /// Styles: `.packets` (avatar + flowing packets + verb, one line), `.mark`
    /// (breathing mark + shimmer verb, one line). Selected via
    /// `debug.workingIndicatorStyle` UserDefaults key (default `.packets`).
    ///
    /// Animation periods are pinned to match the Android mirror:
    ///   2.1s breathe  1.5s packet  2.2s shimmer  1.9s verb cycle
    struct WorkingIndicator: View {
        let style: ConduitWorkingStyle
        /// Agent key -> tint (e.g. "claude", "codex"). Falls back to accent.
        var agent: String = "claude"
        /// Live activity text. nil -> cycles a neutral verb set.
        var status: String? = nil

        @Environment(\.neonTheme) private var neon
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        init(style: ConduitWorkingStyle, agent: String = "claude", status: String? = nil) {
            self.style = style
            self.agent = agent
            self.status = status
        }

        private static let verbs = [
            "thinking", "reading files", "running tests", "writing the patch", "pushing",
        ]

        var body: some View {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                let verb = status ?? Self.verbs[Int(t / 1.9) % Self.verbs.count]
                switch style {
                case .packets:        PacketsStyle(t: t, verb: verb)
                case .mark:           MarkStyle(t: t)
                }
            }
            .accessibilityElement()
            .accessibilityLabel("\(agent) is working")
        }

        private var agentTint: Color { neon.agentTint(forAgent: agent) }

        // B: packets through the pipe, single inline row ------------------------------------
        @ViewBuilder private func PacketsStyle(t: TimeInterval, verb: String) -> some View {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(agentTint.opacity(0.12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(agentTint.opacity(0.36))
                    )
                    .frame(width: 22, height: 22)
                    .overlay(AgentAvatar(assistant: agent, size: 13))
                PacketPipe(t: t).frame(width: 34, height: 14)
                (Text(agent).font(neon.mono(12)).foregroundColor(agentTint)
                 + Text("  -  ").font(neon.mono(12)).foregroundColor(neon.textFaint.opacity(0.6))
                 + Text(verb).font(neon.mono(12)).foregroundColor(neon.textFaint))
            }
        }

        // C: the mark, breathing -- single inline row ----------------------------------------
        @ViewBuilder private func MarkStyle(t: TimeInterval) -> some View {
            let breathe = 0.5 + 0.5 * sin(t * 2.0 * .pi / 2.1)
            HStack(spacing: 10) {
                ConduitUI.ConduitMark(size: 15, glow: false)
                    .frame(width: 22, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.white.opacity(0.03))
                            .overlay(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .strokeBorder(neon.border)
                            )
                    )
                    .shadow(
                        color: neon.accent.opacity(0.25 + 0.35 * breathe),
                        radius: 6 + 8 * breathe
                    )
                ShimmerText("\(agent) is working...", t: t)
            }
        }

        // Shared atoms --------------------------------------------------------------------

        /// Capsule pipe with 3 flowing packets.
        @ViewBuilder private func PacketPipe(t: TimeInterval) -> some View {
            GeometryReader { geo in
                let w = geo.size.width
                ZStack {
                    Capsule().fill(neon.codeBg)
                    Capsule().strokeBorder(neon.border)
                    ForEach(0..<3, id: \.self) { i in
                        let phase = (t / 1.5 + Double(i) / 3.0)
                            .truncatingRemainder(dividingBy: 1.0)
                        Circle()
                            .fill(i % 2 == 0 ? neon.accent : neon.green)
                            .frame(width: 6, height: 6)
                            .shadow(
                                color: (i % 2 == 0 ? neon.accent : neon.green).opacity(0.8),
                                radius: 5
                            )
                            .position(
                                x: phase * (w + 12) - 6,
                                y: geo.size.height / 2
                            )
                            .opacity(
                                phase < 0.12
                                    ? phase / 0.12
                                    : (phase > 0.88 ? (1 - phase) / 0.12 : 1)
                            )
                    }
                }
            }
        }

        @ViewBuilder private func ShimmerText(_ s: String, t: TimeInterval) -> some View {
            let x = (t / 2.2).truncatingRemainder(dividingBy: 1.0) * 2.2 - 0.6
            Text(s).font(neon.sans(15).weight(.semibold))
                .foregroundColor(neon.textFaint)
                .overlay(
                    Text(s).font(neon.sans(15).weight(.semibold))
                        .foregroundColor(neon.text)
                        .mask(
                            LinearGradient(
                                stops: [
                                    .init(color: .clear, location: max(0, x - 0.18)),
                                    .init(color: .white, location: min(1, x)),
                                    .init(color: .clear, location: min(1, x + 0.18)),
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                )
        }
    }
}

// MARK: - Preview -------------------------------------------------------------------------

#Preview("Working Indicator - all styles") {
    VStack(alignment: .leading, spacing: 28) {
        ForEach(ConduitWorkingStyle.allCases) { style in
            VStack(alignment: .leading, spacing: 6) {
                Text(style.displayName)
                    .font(.caption)
                    .foregroundColor(.secondary)
                ConduitUI.WorkingIndicator(style: style, agent: "claude", status: nil)
            }
        }
    }
    .padding(20)
    .background(Color(hex: "#04050a"))
    .environment(\.neonTheme, NeonTheme.resolve(palette: .ice, dark: true, glow: true))
}

#Preview("Working Indicator - synth dark") {
    VStack(alignment: .leading, spacing: 28) {
        ForEach(ConduitWorkingStyle.allCases) { style in
            ConduitUI.WorkingIndicator(style: style, agent: "codex", status: "reading files")
        }
    }
    .padding(20)
    .background(Color(hex: "#04050a"))
    .environment(\.neonTheme, NeonTheme.resolve(palette: .synth, dark: true, glow: true))
}
