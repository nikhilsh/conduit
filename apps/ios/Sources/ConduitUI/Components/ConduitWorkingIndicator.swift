import SwiftUI

// MARK: - Style + debug setting -----------------------------------------------------------

enum ConduitWorkingStyle: String, CaseIterable, Identifiable, Sendable {
    case spine, packets, mark, prompt
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .spine:   return "A - Conduit spine"
        case .packets: return "B - Packets"
        case .mark:    return "C - Breathing mark"
        case .prompt:  return "D - At the prompt"
        }
    }
}

enum ConduitWorkingDebug {
    /// Backing store key. `@AppStorage` on `UserDefaults.standard` reads
    /// the same key; no App Group suite is needed (other @AppStorage uses
    /// in the app also bind to standard).
    static let key = "debug.workingIndicatorStyle"
    static var current: ConduitWorkingStyle {
        ConduitWorkingStyle(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .spine
    }
}

// MARK: - The indicator -------------------------------------------------------------------

extension ConduitUI {

    /// Four-style pre-output working indicator (design handoff "working-indicator").
    /// Replaces the legacy mono `WORKING...` label + single pulsing dot.
    ///
    /// Styles: `.spine` (breathing mark + flowing rail), `.packets` (3 flowing
    /// packets), `.mark` (shimmer sweep), `.prompt` (shell prompt card). Selected
    /// via `debug.workingIndicatorStyle` UserDefaults key (default `.spine`).
    ///
    /// Animation periods are pinned to match the Android mirror:
    ///   2.1s breathe  1.4s rail  1.5s packet  2.2s shimmer  1s caret  1.9s verb cycle
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
                case .spine:   SpineStyle(t: t, verb: verb)
                case .packets: PacketsStyle(t: t, verb: verb)
                case .mark:    MarkStyle(t: t)
                case .prompt:  PromptStyle(t: t, verb: verb)
                }
            }
            .accessibilityElement()
            .accessibilityLabel("\(agent) is working")
        }

        private var agentTint: Color { neon.agentTint(forAgent: agent) }

        // A: spine, warming up ------------------------------------------------------------
        @ViewBuilder private func SpineStyle(t: TimeInterval, verb: String) -> some View {
            let breathe = 0.5 + 0.5 * sin(t * 2.0 * .pi / 2.1)
            HStack(alignment: .top, spacing: 13) {
                VStack(spacing: 6) {
                    ConduitUI.ConduitMark(size: 16, glow: false)
                        .frame(width: 26, height: 26)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.white.opacity(0.03))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .strokeBorder(neon.border)
                                )
                        )
                        .shadow(
                            color: neon.accent.opacity(0.25 + 0.35 * breathe),
                            radius: 6 + 8 * breathe
                        )
                    FlowingRail(t: t).frame(width: 2).frame(minHeight: 26)
                }
                (Text(agent).font(neon.sans(15).weight(.bold)).foregroundColor(agentTint)
                 + Text(" is ").font(neon.sans(15)).foregroundColor(neon.textFaint)
                 + Text(verb).font(neon.mono(13.5)).foregroundColor(neon.text))
                    .padding(.top, 3)
                Caret(t: t)
                Spacer(minLength: 0)
            }
        }

        // B: packets through the pipe -----------------------------------------------------
        @ViewBuilder private func PacketsStyle(t: TimeInterval, verb: String) -> some View {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(agentTint.opacity(0.12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(agentTint.opacity(0.36))
                        )
                        .frame(width: 30, height: 30)
                        .overlay(AgentAvatar(assistant: agent, size: 16))
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
                    .frame(height: 26)
                }
                (Text(agent).font(neon.mono(12)).foregroundColor(agentTint)
                 + Text("  -  ").font(neon.mono(12)).foregroundColor(neon.textFaint.opacity(0.6))
                 + Text(verb).font(neon.mono(12)).foregroundColor(neon.textFaint))
                    .padding(.leading, 40)
            }
        }

        // C: the mark, breathing ----------------------------------------------------------
        @ViewBuilder private func MarkStyle(t: TimeInterval) -> some View {
            let breathe = 0.5 + 0.5 * sin(t * 2.0 * .pi / 2.1)
            HStack(spacing: 12) {
                ConduitUI.ConduitMark(size: 20, glow: false)
                    .frame(width: 32, height: 32)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color.white.opacity(0.03))
                            .overlay(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
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

        // D: at the prompt ----------------------------------------------------------------
        @ViewBuilder private func PromptStyle(t: TimeInterval, verb: String) -> some View {
            VStack(alignment: .leading, spacing: 2) {
                (Text(agent).foregroundColor(agentTint)
                 + Text("@prod").foregroundColor(neon.textFaint)
                 + Text(" ~/broker").foregroundColor(neon.textFaint.opacity(0.6)))
                    .font(neon.mono(13))
                HStack(spacing: 0) {
                    Text("$ ").font(neon.mono(13)).foregroundColor(neon.green)
                    Text(verb).font(neon.mono(13)).foregroundColor(neon.text)
                    Caret(t: t)
                }
            }
            .padding(.horizontal, 13).padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .neonCardSurface(neon, fill: neon.codeBg, cornerRadius: 12)
        }

        // Shared atoms --------------------------------------------------------------------

        @ViewBuilder private func Caret(t: TimeInterval) -> some View {
            RoundedRectangle(cornerRadius: 1)
                .fill(neon.accent)
                .frame(width: 7, height: 16)
                .shadow(color: neon.accent.opacity(0.7), radius: 8)
                .opacity(t.truncatingRemainder(dividingBy: 1.0) < 0.52 ? 1 : 0)
                .padding(.leading, 4)
        }

        @ViewBuilder private func FlowingRail(t: TimeInterval) -> some View {
            let shift = (t / 1.4).truncatingRemainder(dividingBy: 1.0)
            RoundedRectangle(cornerRadius: 2).fill(
                LinearGradient(
                    stops: [
                        .init(color: neon.accent, location: 0),
                        .init(color: neon.green, location: 0.35),
                        .init(color: neon.accent, location: 0.7),
                        .init(color: neon.green, location: 1),
                    ],
                    startPoint: UnitPoint(x: 0.5, y: -shift),
                    endPoint: UnitPoint(x: 0.5, y: 1 - shift)
                )
            )
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
