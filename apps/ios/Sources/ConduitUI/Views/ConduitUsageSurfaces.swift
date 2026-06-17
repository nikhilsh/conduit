import SwiftUI

// MARK: - Ambient account-usage surfaces (design handoff §3b)
//
// Account plan limits (the 5-hour + weekly windows) used to live only in the
// per-session Info sheet. These two surfaces lift them into ambient places — a
// slim Home strip and a Settings card — reading `store.accountUsage`
// (account-level, not per-session). These ambient surfaces show the CLAUDE
// account (Anthropic /api/oauth/usage) as the at-a-glance primary. Codex usage
// (ChatGPT /wham/usage — see broker codexaccountusage.go) IS surfaced, but
// per-session in the Info sheet's AccountUsageCard, since with mixed claude +
// codex sessions an ambient account-level strip can only show one. Shared
// formatting/tint helpers live in `AccountUsageFormat`.

extension ConduitUI {

    /// Shared % → tint and ISO-reset → countdown formatting for the usage
    /// surfaces and the Session-Info account card.
    enum AccountUsageFormat {
        /// Green under 70%, yellow 70–90%, red above — at-a-glance headroom.
        static func tint(_ pct: Double, _ neon: NeonTheme) -> Color {
            switch pct {
            case ..<70:  return neon.green
            case ..<90:  return neon.yellow
            default:     return neon.red
            }
        }

        static func resetCaption(_ iso: String?, now: Date) -> String {
            guard let iso, let date = parseISO(iso) else { return "tap refresh to update" }
            let secs = date.timeIntervalSince(now)
            if secs <= 0 { return "resetting…" }
            return "resets in \(fmtInterval(secs))"
        }

        /// Compact reset for tight window rows — just the countdown
        /// (`5d 8h`), or `resetting…` once it elapses. "—" when unknown.
        static func resetShort(_ iso: String?, now: Date) -> String {
            guard let iso, let date = parseISO(iso) else { return "—" }
            let secs = date.timeIntervalSince(now)
            if secs <= 0 { return "resetting…" }
            return fmtInterval(secs)
        }

        static func parseISO(_ s: String) -> Date? {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = f.date(from: s) { return d }
            f.formatOptions = [.withInternetDateTime]
            return f.date(from: s)
        }

        /// Coarse human countdown: days, else hours+minutes, else minutes.
        static func fmtInterval(_ secs: TimeInterval) -> String {
            let total = Int(secs)
            let days = total / 86_400
            let hours = (total % 86_400) / 3_600
            let mins = (total % 3_600) / 60
            if days > 0 { return "\(days)d \(hours)h" }
            if hours > 0 { return "\(hours)h \(mins)m" }
            return "\(mins)m"
        }
    }

    /// A slim, tappable Home strip showing each agent's plan headroom at a
    /// glance — `claude 62% · codex 28%` (handoff §B.10), one dot + mini-bar
    /// + % per agent that carries usage. The headline % is the 5-hour window
    /// (the one that bites soonest). Tap expands per-agent 5h + weekly reset
    /// countdowns. Hidden until data exists so it never dominates the session
    /// list (ambient glance, §3b). Only agents with real data appear — a
    /// codex-less account simply shows claude, never a fabricated number.
    struct HomeUsageStrip: View {
        @Environment(SessionStore.self) private var store
        @Environment(\.neonTheme) private var neon
        @State private var expanded = false
        /// Natural (unconstrained) height of the expanded detail, measured by a
        /// transparent overlay copy so the visible copy's height can be animated
        /// between 0 (collapsed) and this value (expanded).
        @State private var detailHeight: CGFloat = 0
        private let now = Date()

        /// Single source of truth for the expand transition.
        private static let expandAnim: Animation = .easeInOut(duration: 0.28)

        /// Preference key carrying the expanded detail's measured natural height.
        private struct DetailHeightKey: PreferenceKey {
            static var defaultValue: CGFloat = 0
            static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
                value = max(value, nextValue())
            }
        }

        var body: some View {
            let agents = store.accountUsageByAgent.filter { $0.hasData }
            if !agents.isEmpty {
                VStack(spacing: 8) {
                    Button {
                        // Plain assignment — the `.animation(value: expanded)`
                        // modifiers below own the transition so every animated
                        // property (chevron rotation, detail opacity, detail
                        // height) runs on the SAME transaction/curve with no
                        // second `withAnimation` racing them.
                        expanded.toggle()
                    } label: {
                        HStack(spacing: 10) {
                            ForEach(Array(agents.enumerated()), id: \.element.id) { idx, a in
                                if idx > 0 {
                                    Text("·").font(neon.mono(11)).foregroundStyle(neon.textFaint)
                                }
                                agentGlance(a)
                            }
                            Spacer(minLength: 4)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(neon.textFaint)
                                .rotationEffect(.degrees(expanded ? 180 : 0))
                                .animation(Self.expandAnim, value: expanded)
                        }
                    }
                    .buttonStyle(.plain)
                    // FIX (permanently-open regression): the previous rev used
                    // `scaleEffect(y:)` to "collapse" the detail. scaleEffect is
                    // a RENDER transform, not a layout change — it shrinks the
                    // drawn pixels but the view keeps its full layout height, so
                    // when collapsed the strip reserved a tall empty panel (the
                    // permanently-open look). `clipped()` only clips drawing,
                    // not layout, so it couldn't fix it.
                    //
                    // A real height collapse instead:
                    //  • A zero-impact overlay copy of the detail measures its
                    //    NATURAL height (it ignores the 0-height proposal and
                    //    lays out at its ideal size; its `.background`
                    //    GeometryReader reports that true height via
                    //    DetailHeightKey). The overlay never contributes to
                    //    layout, so measuring it is free of the constraint we
                    //    apply to the visible copy.
                    //  • `Color.clear.frame(height: expanded ? detailHeight : 0)`
                    //    is the LAYOUT driver: it genuinely collapses to 0 when
                    //    closed (no reserved space) and animates to the measured
                    //    height when open — a concrete, interpolatable value.
                    //  • The visible detail rides in the overlay with its OWN
                    //    opacity animation that is DECOUPLED from the height
                    //    curve: on collapse (expanded=false) the content fades
                    //    out in ~0.04s (~2 frames) so bars are gone BEFORE the
                    //    panel visibly shrinks; on expand the content fades in
                    //    after a small delay once the panel has room. The
                    //    `.animation(_:value:)` on the overlay content is the
                    //    INNERMOST modifier for that view, so it takes precedence
                    //    over the outer `.animation(expandAnim, value: expanded)`
                    //    which only controls the height frame below.
                    Color.clear
                        .frame(maxWidth: .infinity)
                        .frame(height: expanded ? detailHeight : 0)
                        .animation(Self.expandAnim, value: expanded)
                        .overlay(alignment: .top) {
                            expandedDetail(agents: agents)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    GeometryReader { geo in
                                        Color.clear.preference(
                                            key: DetailHeightKey.self,
                                            value: geo.size.height)
                                    }
                                )
                                // Asymmetric opacity: collapse fades out in ~0.04s
                                // (near-instant, before height shrinks); expand
                                // fades in gently after a brief delay once the
                                // panel has opened. This .animation wins over any
                                // ancestor animation because it is scoped directly
                                // to this view's opacity change.
                                .opacity(expanded ? 1 : 0)
                                .animation(
                                    expanded
                                        ? .easeOut(duration: 0.16).delay(0.06)
                                        : .easeOut(duration: 0.04),
                                    value: expanded
                                )
                                .allowsHitTesting(expanded)
                        }
                        .clipped()
                        .onPreferenceChange(DetailHeightKey.self) { detailHeight = $0 }
                        .accessibilityHidden(!expanded)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .neonCardSurface(neon, fill: neon.surface, cornerRadius: 12)
            }
        }

        /// Expanded detail (two windows per agent). Revealed via an animated
        /// height collapse + opacity in `body` (see the animation fix note) so
        /// the row eases open/closed in both directions without lingering
        /// content, a gap, or — the regression this replaced — a permanently
        /// reserved empty panel when collapsed.
        @ViewBuilder
        private func expandedDetail(agents: [SessionStore.AgentUsageSnapshot]) -> some View {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(agents.enumerated()), id: \.element.id) { idx, a in
                    if idx > 0 {
                        Divider().background(neon.border)
                    }
                    let tint = neon.agentTint(forAgent: a.agent)
                    VStack(alignment: .leading, spacing: 6) {
                        // Only show per-agent header when multiple agents are
                        // present — with a single agent the glance row already
                        // shows the name, so the header would be redundant.
                        if agents.count >= 2 {
                            HStack(spacing: 5) {
                                Circle().fill(tint).frame(width: 5, height: 5)
                                Text(a.agent)
                                    .font(neon.mono(10.5).weight(.semibold))
                                    .foregroundStyle(tint)
                            }
                        }
                        windowRow("5h", pct: a.fivePct, resetsAt: a.fiveResetsAt, tint: tint)
                        windowRow("weekly", pct: a.weekPct, resetsAt: a.weekResetsAt, tint: tint)
                    }
                }
            }
            .padding(.top, 2)
        }

        /// One agent's collapsed glance: a tinted dot, the agent label, a mini
        /// bar, and the headline %. The headline is the MORE-CONSTRAINING of the
        /// two windows — `max(5h%, weekly%)` — so it surfaces whichever limit is
        /// closest to throttling (the expanded detail still breaks out both
        /// windows + their resets). Falls back to whichever single window has
        /// data; nil only when neither does (the agent is already filtered out
        /// of the strip in that case via `hasData`).
        private func agentGlance(_ a: SessionStore.AgentUsageSnapshot) -> some View {
            let pct: Double? = [a.fivePct, a.weekPct].compactMap { $0 }.max()
            let frac = CGFloat(max(0, min(1, (pct ?? 0) / 100)))
            return HStack(spacing: 6) {
                Circle().fill(neon.agentTint(forAgent: a.agent)).frame(width: 6, height: 6)
                Text(a.agent)
                    .font(neon.mono(11).weight(.semibold))
                    .foregroundStyle(neon.textDim)
                Capsule().fill(neon.border).frame(width: 34, height: 5)
                    .overlay(alignment: .leading) {
                        Capsule().fill(neon.agentTint(forAgent: a.agent))
                            .frame(width: 34 * frac, height: 5)
                    }
                Text(pct.map { "\(Int($0.rounded()))%" } ?? "—")
                    .font(neon.mono(11).weight(.bold))
                    .foregroundStyle(neon.text)
            }
        }

        /// One expanded window row: `label · meter · NN% · reset` (fix 4).
        /// The meter fills with the agent tint; % is bold; the reset is the
        /// compact countdown so the row stays one line.
        private func windowRow(_ label: String, pct: Double?, resetsAt: String?, tint: Color) -> some View {
            let frac = CGFloat(max(0, min(1, (pct ?? 0) / 100)))
            return HStack(spacing: 8) {
                Text(label)
                    .font(neon.mono(10))
                    .foregroundStyle(neon.textFaint)
                    .frame(width: 42, alignment: .leading)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(neon.border)
                        Capsule().fill(tint)
                            .frame(width: max(0, geo.size.width * frac))
                            .neonGlowBox(neon.glow ? neon.glowBox?.tinted(tint) : nil)
                    }
                }
                .frame(height: 6)
                // Compact trailing group: % and reset read as a unit near the
                // end of the meter rather than pinned to the screen edge.
                HStack(spacing: 4) {
                    Text(pct.map { "\(Int($0.rounded()))%" } ?? "—")
                        .font(neon.mono(11.5).weight(.bold))
                        .foregroundStyle(pct == nil ? neon.textFaint : neon.text)
                        .frame(width: 34, alignment: .trailing)
                    Text(AccountUsageFormat.resetShort(resetsAt, now: now))
                        .font(neon.mono(10))
                        .foregroundStyle(neon.textFaint)
                        .lineLimit(1)
                        .frame(width: 50, alignment: .trailing)
                }
            }
        }
    }

    /// Settings "Usage & limits" card: collapsed = two compact spark rows; tap
    /// to expand to full per-window bars + reset countdowns and a note that the
    /// limits are account-wide. Claude-only. On tablet the host shows it
    /// expanded (pass `startExpanded: true`).
    struct UsageLimitsCard: View {
        var startExpanded = false
        @Environment(SessionStore.self) private var store
        @Environment(\.neonTheme) private var neon
        @State private var expanded: Bool
        private let now = Date()

        init(startExpanded: Bool = false) {
            self.startExpanded = startExpanded
            _expanded = State(initialValue: startExpanded)
        }

        var body: some View {
            let u = store.accountUsage
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 10) {
                        Circle().fill(neon.claude).frame(width: 6, height: 6)
                        Text("claude").font(neon.mono(11).weight(.semibold)).foregroundStyle(neon.textDim)
                        Spacer(minLength: 6)
                        if !expanded {
                            spark("weekly", u.weekPct)
                            spark("5h", u.fivePct)
                        }
                        Button {
                            store.refreshAccountUsage()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(neon.accent)
                                .frame(width: 26, height: 26)
                                .background(Circle().fill(neon.surface))
                                .overlay(Circle().stroke(neon.border, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Refresh account usage")
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(neon.textFaint)
                    }
                }
                .buttonStyle(.plain)

                if expanded {
                    VStack(spacing: 12) {
                        usageRow(label: "5-hour", pct: u.fivePct, resetsAt: u.fiveResetsAt)
                        usageRow(label: "Weekly", pct: u.weekPct, resetsAt: u.weekResetsAt)
                    }
                    Text("usage counts every session on this account, across boxes.")
                        .font(neon.mono(10))
                        .foregroundStyle(neon.textFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }

        private func spark(_ label: String, _ pct: Double?) -> some View {
            let frac = CGFloat(max(0, min(1, (pct ?? 0) / 100)))
            return HStack(spacing: 4) {
                Text(label).font(neon.mono(9.5)).foregroundStyle(neon.textFaint)
                Capsule().fill(neon.border).frame(width: 26, height: 4)
                    .overlay(alignment: .leading) {
                        Capsule().fill(AccountUsageFormat.tint(pct ?? 0, neon)).frame(width: 26 * frac, height: 4)
                    }
                Text(pct.map { "\(Int($0.rounded()))%" } ?? "—")
                    .font(neon.mono(10.5).weight(.bold))
                    .foregroundStyle(neon.text)
            }
        }

        @ViewBuilder
        private func usageRow(label: String, pct: Double?, resetsAt: String?) -> some View {
            let frac = CGFloat(max(0, min(1, (pct ?? 0) / 100)))
            let tint = AccountUsageFormat.tint(pct ?? 0, neon)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(label.uppercased())
                        .font(neon.mono(10).weight(.semibold))
                        .foregroundStyle(neon.textFaint)
                        .tracking(1.2)
                    Spacer(minLength: 6)
                    Text(pct.map { "\(Int($0.rounded()))%" } ?? "—")
                        .font(neon.mono(13).weight(.bold))
                        .foregroundStyle(pct == nil ? neon.textFaint : neon.text)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(neon.border)
                        Capsule().fill(tint)
                            .frame(width: max(0, geo.size.width * frac))
                            .neonGlowBox(neon.glow ? neon.glowBox?.tinted(tint) : nil)
                    }
                }
                .frame(height: 8)
                Text(AccountUsageFormat.resetCaption(resetsAt, now: now))
                    .font(neon.mono(10.5))
                    .foregroundStyle(neon.textDim)
            }
        }
    }
}
