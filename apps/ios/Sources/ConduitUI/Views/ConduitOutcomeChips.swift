import SwiftUI

// MARK: - OutcomeChips
//
// iOS mirror of the design's `OutcomeChips` (palette.jsx): a session's
// result at a glance — landed diff (+add / −rem), the associated PR
// (#num + state), and commit count. Fed by the broker's git/gh stats
// rolled onto `ProjectSession` (linesAdded / linesRemoved / commits /
// prNumber / prState / prUrl). The tests chip is intentionally omitted until
// there's a non-fragile test-result data source.
//
// Each value is gated on > 0 / present, so an untouched session (or a
// non-git workspace, where everything is nil) renders nothing rather than
// a noisy row of zeros. Compact + few (≤3) chips, so a plain HStack is
// enough — no flow layout needed.
//
// When prUrl is non-nil the PR chip is tappable and opens the URL in the
// system browser. When nil the chip is read-only (prior behaviour).

extension ConduitUI {

    struct OutcomeChips: View {
        @Environment(\.neonTheme) private var neon
        @Environment(\.openURL) private var openURL

        let linesAdded: Int?
        let linesRemoved: Int?
        let commits: Int?
        let prNumber: Int?
        let prState: String?
        var prUrl: String? = nil
        var dense: Bool = false

        private var showDiff: Bool { (linesAdded ?? 0) > 0 || (linesRemoved ?? 0) > 0 }
        private var showPR: Bool { (prNumber ?? 0) > 0 }
        private var showCommits: Bool { (commits ?? 0) > 0 }
        private var hasAny: Bool { showDiff || showPR || showCommits }

        private var fontSize: CGFloat { dense ? 9.5 : 10.5 }

        private var prColor: Color {
            switch prState {
            case "merged": return neon.purple
            case "open":   return neon.green
            default:       return neon.textFaint // draft / closed
            }
        }

        var body: some View {
            if hasAny {
                HStack(spacing: 6) {
                    if showDiff {
                        chip(neon.textDim) {
                            Text("+\(linesAdded ?? 0)")
                                .font(neon.mono(fontSize).weight(.semibold))
                                .foregroundStyle(neon.green)
                            Text("−\(linesRemoved ?? 0)")
                                .font(neon.mono(fontSize).weight(.semibold))
                                .foregroundStyle(neon.red)
                        }
                    }
                    if showPR {
                        prChip
                    }
                    if showCommits {
                        let n = commits ?? 0
                        chip(neon.textFaint) {
                            Text("\(n) commit\(n == 1 ? "" : "s")")
                                .font(neon.mono(fontSize).weight(.semibold))
                                .foregroundStyle(neon.textFaint)
                        }
                    }
                }
            }
        }

        // PR chip — tappable when prUrl is non-nil and parses to a valid URL.
        @ViewBuilder
        private var prChip: some View {
            let label = "#\(prNumber ?? 0) \(prState ?? "")".trimmingCharacters(in: .whitespaces)
            if let rawURL = prUrl, let url = URL(string: rawURL) {
                Button {
                    Telemetry.breadcrumb(
                        "pr_link",
                        "tapped PR chip",
                        ["pr_number": "\(prNumber ?? 0)", "pr_state": prState ?? ""]
                    )
                    openURL(url)
                } label: {
                    chip(prColor) {
                        Text(label)
                            .font(neon.mono(fontSize).weight(.semibold))
                            .foregroundStyle(prColor)
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: fontSize - 1.5, weight: .semibold))
                            .foregroundStyle(prColor.opacity(0.7))
                    }
                }
                .buttonStyle(.plain)
            } else {
                chip(prColor) {
                    Text(label)
                        .font(neon.mono(fontSize).weight(.semibold))
                        .foregroundStyle(prColor)
                }
            }
        }

        private func chip<Content: View>(
            _ color: Color,
            @ViewBuilder _ content: () -> Content
        ) -> some View {
            HStack(spacing: 3) { content() }
                .padding(.horizontal, dense ? 6 : 7)
                .padding(.vertical, dense ? 1 : 2)
                .background(Capsule().fill(color.opacity(0.08)))
                .overlay(Capsule().stroke(color.opacity(0.20), lineWidth: 1))
        }
    }
}
