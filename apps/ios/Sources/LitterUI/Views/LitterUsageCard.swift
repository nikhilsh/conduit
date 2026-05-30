import SwiftUI

/// One token segment (in / out / cache) for the usage card's stacked bar
/// + legend. `Identifiable` so `ForEach` can key on the label (Swift has
/// no key paths to tuple elements).
private struct NeonTokenPart: Identifiable {
    let id: String
    let value: UInt64
    let color: Color
}

// MARK: - LitterUsageCard
//
// The design bundle's Session-Info usage card (usage.jsx → UsageCardA /
// UsageCardB + the Visual/Terminal segmented switch). Two variants the
// team is choosing between:
//   • Visual   — a context ring + window readout + in/out/cache tiles.
//   • Terminal — a dense mono `swe-kitty usage --session` readout with a
//                block-character context bar + a stacked token bar.
//
// Data is the live broker-accumulated `SessionStatus` (PR #274): token
// counts (in/out/cache), cost (claude), and the context-window gauge
// (claude only — codex reports neither). Turns + duration come from the
// conversation log. The design's "plan limits" (Claude weekly / Codex
// quota + reset countdowns) have NO data source anywhere in the stack, so
// they're intentionally omitted rather than faked.
//
// The card hides entirely until a turn has reported usage.

extension LitterUI {

    /// Visual ↔ Terminal usage-card variant. RawValue persisted to
    /// UserDefaults under `nk_usage_variant` (matches the prototype key).
    enum UsageVariant: String { case visual = "A", terminal = "B" }

    struct UsageCard: View {
        let session: ProjectSession
        @Environment(SessionStore.self) private var store
        @Environment(\.neonTheme) private var neon
        @AppStorage("nk_usage_variant") private var variantRaw = UsageVariant.visual.rawValue

        private var variant: UsageVariant { UsageVariant(rawValue: variantRaw) ?? .visual }

        var body: some View {
            let status = store.statusBySession[session.id]
            let input = status?.totalInputTokens ?? 0
            let output = status?.totalOutputTokens ?? 0
            let cached = status?.totalCachedTokens ?? 0
            if input > 0 || output > 0 {
                VStack(alignment: .leading, spacing: 11) {
                    header
                    if variant == .visual {
                        visualCard(input: input, output: output, cached: cached, status: status)
                    } else {
                        terminalCard(input: input, output: output, cached: cached, status: status)
                    }
                }
            }
        }

        // MARK: Header (label + A/B segmented switch)

        private var header: some View {
            HStack(spacing: 10) {
                Text("Usage")
                    .font(neon.mono(11).weight(.bold))
                    .foregroundStyle(neon.textDim)
                    .textCase(.uppercase)
                Spacer(minLength: 6)
                segmented
            }
        }

        private var segmented: some View {
            HStack(spacing: 4) {
                segmentButton("Visual", .visual)
                segmentButton("Terminal", .terminal)
            }
            .padding(3)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(neon.dark ? Color.black.opacity(0.3) : neon.text.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .strokeBorder(neon.border, lineWidth: 1)
                    )
            )
        }

        private func segmentButton(_ label: String, _ value: UsageVariant) -> some View {
            let selected = variant == value
            return Button {
                variantRaw = value.rawValue
            } label: {
                Text(label)
                    .font(neon.sans(12).weight(selected ? .bold : .medium))
                    .foregroundStyle(selected ? neon.accent : neon.textDim)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(selected ? neon.accent.opacity(neon.dark ? 0.13 : 0.10) : .clear)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(selected ? neon.accent.opacity(0.4) : .clear, lineWidth: 1)
                            )
                    )
            }
            .buttonStyle(.plain)
        }

        // MARK: Variant A — Visual

        @ViewBuilder
        private func visualCard(input: UInt64, output: UInt64, cached: UInt64, status: SessionStatus?) -> some View {
            VStack(spacing: 14) {
                if let used = status?.contextUsedTokens,
                   let window = status?.contextWindowTokens, window > 0 {
                    contextRing(used: used, window: window)
                }
                tokenTiles(input: input, output: output, cached: cached, cost: status?.totalCostUsd)
            }
        }

        private func contextRing(used: UInt64, window: UInt64) -> some View {
            let pct = min(1.0, Double(used) / Double(window))
            return HStack(spacing: 18) {
                ZStack {
                    Circle()
                        .stroke(neon.border, lineWidth: 11)
                    Circle()
                        .trim(from: 0, to: pct)
                        .stroke(neon.accentBright, style: StrokeStyle(lineWidth: 11, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .neonGlowBox(neon.glow ? neon.glowBox?.tinted(neon.accentBright) : nil)
                    VStack(spacing: 1) {
                        Text("\(Int(pct * 100))")
                            .font(neon.mono(28).weight(.bold))
                            .foregroundStyle(neon.text)
                            .neonTextGlow(neon.textGlow)
                        Text("context")
                            .font(neon.mono(9.5))
                            .foregroundStyle(neon.textFaint)
                    }
                }
                .frame(width: 116, height: 116)

                VStack(alignment: .leading, spacing: 5) {
                    Text("WINDOW")
                        .font(neon.mono(10).weight(.semibold))
                        .foregroundStyle(neon.textFaint)
                        .tracking(1.2)
                    Text("\(Self.fmtK(used)) / \(Self.fmtK(window))")
                        .font(neon.mono(19).weight(.bold))
                        .foregroundStyle(neon.text)
                    Text("\(Self.fmtK(window - min(window, used))) left")
                        .font(neon.mono(11.5))
                        .foregroundStyle(neon.textDim)
                    agentPill
                        .padding(.top, 4)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .neonCardSurface(neon, fill: neon.surface, cornerRadius: neon.radius - 4)
        }

        private var agentPill: some View {
            let agent = session.assistant
            let c = neon.agentTint(forAgent: agent)
            return HStack(spacing: 6) {
                Circle().fill(c).frame(width: 6, height: 6)
                Text(agent.lowercased())
                    .font(neon.mono(10.5))
                    .foregroundStyle(c)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(c.opacity(0.11))
                    .overlay(Capsule().strokeBorder(c.opacity(0.27), lineWidth: 1))
            )
        }

        private func tokenTiles(input: UInt64, output: UInt64, cached: UInt64, cost: Double?) -> some View {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("TOKENS · SESSION")
                        .font(neon.mono(10).weight(.semibold))
                        .foregroundStyle(neon.textFaint)
                        .tracking(1.2)
                    Spacer(minLength: 6)
                    if let cost, cost > 0 {
                        Text(String(format: "$%.2f", cost))
                            .font(neon.mono(11))
                            .foregroundStyle(neon.textDim)
                    }
                }
                HStack(spacing: 9) {
                    tokenTile("in", input, neon.blue)
                    tokenTile("out", output, neon.green)
                    tokenTile("cache", cached, neon.purple)
                }
            }
        }

        private func tokenTile(_ label: String, _ value: UInt64, _ color: Color) -> some View {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Circle().fill(color).frame(width: 6, height: 6)
                    Text(label)
                        .font(neon.mono(10.5))
                        .foregroundStyle(neon.textFaint)
                }
                Text(Self.fmtK(value))
                    .font(neon.mono(18).weight(.bold))
                    .foregroundStyle(neon.text)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .neonCardSurface(neon, fill: neon.surface, cornerRadius: 13)
        }

        // MARK: Variant B — Terminal

        private func terminalCard(input: UInt64, output: UInt64, cached: UInt64, status: SessionStatus?) -> some View {
            let total = max(1, input + output + cached)
            let turns = turnCount
            let duration = durationLabel
            return VStack(alignment: .leading, spacing: 0) {
                // title bar
                HStack(spacing: 8) {
                    Text("$").font(neon.mono(12.5)).foregroundStyle(neon.accentBright)
                        .neonTextGlow(neon.textGlow)
                    Text("swe-kitty usage --session")
                        .font(neon.mono(12))
                        .foregroundStyle(neon.codeText)
                    Spacer(minLength: 6)
                    Text([duration, turns.map { "\($0) turns" }].compactMap { $0 }.joined(separator: " · "))
                        .font(neon.mono(10.5))
                        .foregroundStyle(neon.green)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(neon.borderStrong).frame(height: 1)
                }

                VStack(alignment: .leading, spacing: 12) {
                    if let used = status?.contextUsedTokens,
                       let window = status?.contextWindowTokens, window > 0 {
                        contextBlockBar(used: used, window: window)
                    }
                    tokenStack(input: input, output: output, cached: cached, total: total, cost: status?.totalCostUsd)
                }
                .padding(14)
            }
            .background(
                RoundedRectangle(cornerRadius: neon.radius - 4, style: .continuous)
                    .fill(neon.codeBg)
                    .overlay(
                        RoundedRectangle(cornerRadius: neon.radius - 4, style: .continuous)
                            .strokeBorder(neon.borderStrong, lineWidth: 1)
                    )
            )
        }

        private func contextBlockBar(used: UInt64, window: UInt64) -> some View {
            let pct = min(1.0, Double(used) / Double(window))
            let seg = 28
            let on = Int((pct * Double(seg)).rounded())
            return VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("context")
                        .font(neon.mono(12))
                        .foregroundStyle(neon.codeText.opacity(0.6))
                        .frame(width: 56, alignment: .leading)
                    Text(String(repeating: "█", count: on) + String(repeating: "░", count: seg - on))
                        .font(neon.mono(12))
                        .foregroundStyle(neon.accentBright)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                    Text("\(Int(pct * 100))%")
                        .font(neon.mono(12).weight(.bold))
                        .foregroundStyle(neon.codeText)
                }
                Text("\(Self.fmtK(used)) / \(Self.fmtK(window))")
                    .font(neon.mono(10.5))
                    .foregroundStyle(neon.codeText.opacity(0.6))
                    .padding(.leading, 64)
            }
        }

        private func tokenStack(input: UInt64, output: UInt64, cached: UInt64, total: UInt64, cost: Double?) -> some View {
            let parts: [NeonTokenPart] = [
                NeonTokenPart(id: "in", value: input, color: neon.blue),
                NeonTokenPart(id: "out", value: output, color: neon.green),
                NeonTokenPart(id: "cache", value: cached, color: neon.purple),
            ]
            return VStack(alignment: .leading, spacing: 8) {
                Text("tokens · \(Self.fmtK(total)) total" + (cost.map { $0 > 0 ? String(format: " · $%.2f", $0) : "" } ?? ""))
                    .font(neon.mono(10.5))
                    .foregroundStyle(neon.codeText.opacity(0.6))
                GeometryReader { geo in
                    HStack(spacing: 0) {
                        ForEach(parts) { part in
                            Rectangle()
                                .fill(part.color)
                                .frame(width: geo.size.width * CGFloat(Double(part.value) / Double(total)))
                        }
                    }
                }
                .frame(height: 12)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                HStack(spacing: 16) {
                    ForEach(parts) { part in
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 2).fill(part.color).frame(width: 9, height: 9)
                            Text(part.id).font(neon.mono(11)).foregroundStyle(neon.codeText)
                            Text(Self.fmtK(part.value)).font(neon.mono(11)).foregroundStyle(neon.codeText.opacity(0.6))
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }

        // MARK: Derived (turns / duration from the conversation log)

        private var turnCount: Int? {
            let log = store.conversationLog[session.id] ?? []
            let n = log.filter { $0.role.lowercased() == "user" }.count
            return n > 0 ? n : nil
        }

        private var durationLabel: String? {
            let log = store.conversationLog[session.id] ?? []
            let ms = log.compactMap { $0.durationMs }.reduce(0, +)
            guard ms > 0 else { return nil }
            let secs = Int(ms) / 1000
            if secs >= 60 { return "\(secs / 60)m" }
            return "\(secs)s"
        }

        static func fmtK(_ n: UInt64) -> String {
            if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
            if n >= 1_000 { return "\(Int((Double(n) / 1_000).rounded()))k" }
            return "\(n)"
        }
    }
}
