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

    /// A slim, tappable Home strip showing the account's Claude plan limits
    /// (weekly + 5-hour) with mini bars. Tap expands one `scope · resets` line
    /// per window. Hidden until data exists so it never dominates the session
    /// list (ambient glance, per §3b).
    struct HomeUsageStrip: View {
        @Environment(SessionStore.self) private var store
        @Environment(\.neonTheme) private var neon
        @State private var expanded = false
        private let now = Date()

        var body: some View {
            let u = store.accountUsage
            if u.hasData {
                VStack(spacing: 8) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
                    } label: {
                        HStack(spacing: 10) {
                            Circle().fill(neon.claude).frame(width: 6, height: 6)
                            Text("claude")
                                .font(neon.mono(11).weight(.semibold))
                                .foregroundStyle(neon.textDim)
                            miniBar(label: "weekly", pct: u.weekPct)
                            miniBar(label: "5h", pct: u.fivePct)
                            Spacer(minLength: 4)
                            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(neon.textFaint)
                        }
                    }
                    .buttonStyle(.plain)
                    if expanded {
                        VStack(alignment: .leading, spacing: 4) {
                            resetLine("weekly", u.weekResetsAt)
                            resetLine("5h window", u.fiveResetsAt)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .neonCardSurface(neon, fill: neon.surface, cornerRadius: 12)
            }
        }

        private func miniBar(label: String, pct: Double?) -> some View {
            let frac = CGFloat(max(0, min(1, (pct ?? 0) / 100)))
            return HStack(spacing: 5) {
                Text(label).font(neon.mono(10)).foregroundStyle(neon.textFaint)
                Capsule().fill(neon.border).frame(width: 34, height: 5)
                    .overlay(alignment: .leading) {
                        Capsule().fill(AccountUsageFormat.tint(pct ?? 0, neon))
                            .frame(width: 34 * frac, height: 5)
                    }
                Text(pct.map { "\(Int($0.rounded()))%" } ?? "—")
                    .font(neon.mono(11).weight(.bold))
                    .foregroundStyle(neon.text)
            }
        }

        private func resetLine(_ scope: String, _ iso: String?) -> some View {
            Text("\(scope) · \(AccountUsageFormat.resetCaption(iso, now: now))")
                .font(neon.mono(10.5))
                .foregroundStyle(neon.textDim)
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
