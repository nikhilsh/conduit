import SwiftUI

// MARK: - LitterAccountUsageCard
//
// The on-demand /usage card in Session Info. Shows the Claude SUBSCRIPTION
// usage — the 5-hour rolling window and the weekly (7-day) window — exactly
// what the Claude Code CLI's `/usage` reports. Distinct from `UsageCard`,
// which shows this SESSION's token/cost and hides until a turn runs: account
// usage is account-global and always shown (with a refresh button), so it's
// useful even on a fresh session.
//
// Data rides the status frame (broker fetches GET /api/oauth/usage on connect
// and on the explicit refresh). `utilization` is a percentage 0–100; reset is
// an ISO-8601 instant we render as a relative countdown.

extension LitterUI {

    struct AccountUsageCard: View {
        let session: ProjectSession
        @Environment(SessionStore.self) private var store
        @Environment(\.neonTheme) private var neon
        @State private var now = Date()

        var body: some View {
            // Prefer the live status frame; fall back to the session snapshot.
            let status = store.statusBySession[session.id]
            let fivePct = status?.account5hPct ?? session.account5hPct
            let weekPct = status?.account7dPct ?? session.account7dPct
            let fiveReset = status?.account5hResetsAt ?? session.account5hResetsAt
            let weekReset = status?.account7dResetsAt ?? session.account7dResetsAt

            VStack(alignment: .leading, spacing: 11) {
                header
                VStack(spacing: 12) {
                    usageRow(label: "5-hour", pct: fivePct, resetsAt: fiveReset)
                    usageRow(label: "Weekly", pct: weekPct, resetsAt: weekReset)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .neonCardSurface(neon, fill: neon.surface, cornerRadius: neon.radius - 4)
            }
        }

        // MARK: Header (label + refresh)

        private var header: some View {
            HStack(spacing: 10) {
                Text("Account usage")
                    .font(neon.mono(11).weight(.bold))
                    .foregroundStyle(neon.textDim)
                    .textCase(.uppercase)
                Spacer(minLength: 6)
                Button {
                    store.refreshAccountUsage(sessionID: session.id)
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(neon.accent)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(neon.surface))
                        .overlay(Circle().stroke(neon.border, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Refresh account usage")
            }
        }

        // MARK: Window row — labeled bar + percent + reset countdown

        @ViewBuilder
        private func usageRow(label: String, pct: Double?, resetsAt: String?) -> some View {
            let fraction = max(0, min(1, (pct ?? 0) / 100))
            let tint = barTint(pct ?? 0)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(label.uppercased())
                        .font(neon.mono(10).weight(.semibold))
                        .foregroundStyle(neon.textFaint)
                        .tracking(1.2)
                    Spacer(minLength: 6)
                    if let pct {
                        Text("\(Int(pct.rounded()))%")
                            .font(neon.mono(13).weight(.bold))
                            .foregroundStyle(neon.text)
                    } else {
                        Text("—")
                            .font(neon.mono(13).weight(.bold))
                            .foregroundStyle(neon.textFaint)
                    }
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(neon.border)
                        Capsule()
                            .fill(tint)
                            .frame(width: max(0, geo.size.width * fraction))
                            .neonGlowBox(neon.glow ? neon.glowBox?.tinted(tint) : nil)
                    }
                }
                .frame(height: 8)
                Text(resetCaption(resetsAt))
                    .font(neon.mono(10.5))
                    .foregroundStyle(neon.textDim)
            }
        }

        // MARK: Helpers

        /// Green under 70%, yellow 70–90%, red above — at-a-glance headroom.
        private func barTint(_ pct: Double) -> Color {
            switch pct {
            case ..<70:  return neon.green
            case ..<90:  return neon.yellow
            default:     return neon.red
            }
        }

        private func resetCaption(_ iso: String?) -> String {
            guard let iso, let date = Self.parseISO(iso) else { return "tap refresh to update" }
            let secs = date.timeIntervalSince(now)
            if secs <= 0 { return "resetting…" }
            return "resets in \(Self.fmtInterval(secs))"
        }

        private static func parseISO(_ s: String) -> Date? {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = f.date(from: s) { return d }
            f.formatOptions = [.withInternetDateTime]
            return f.date(from: s)
        }

        /// Coarse human countdown: days, else hours+minutes, else minutes.
        private static func fmtInterval(_ secs: TimeInterval) -> String {
            let total = Int(secs)
            let days = total / 86_400
            let hours = (total % 86_400) / 3_600
            let mins = (total % 3_600) / 60
            if days > 0 { return "\(days)d \(hours)h" }
            if hours > 0 { return "\(hours)h \(mins)m" }
            return "\(mins)m"
        }
    }
}
