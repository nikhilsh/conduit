import SwiftUI

// MARK: - OutcomeChips
//
// iOS mirror of the design's `OutcomeChips` (palette.jsx): a session's
// result at a glance — landed diff (+add / −rem), the associated PR
// (#num + state), and commit count. Fed by the broker's git/gh stats
// rolled onto `ProjectSession` (linesAdded / linesRemoved / commits /
// prNumber / prState). The tests chip is intentionally omitted until
// there's a non-fragile test-result data source.
//
// Each value is gated on > 0 / present, so an untouched session (or a
// non-git workspace, where everything is nil) renders nothing rather than
// a noisy row of zeros. Compact + few (≤3) chips, so a plain HStack is
// enough — no flow layout needed.

extension LitterUI {

    struct OutcomeChips: View {
        @Environment(\.neonTheme) private var neon

        let linesAdded: Int?
        let linesRemoved: Int?
        let commits: Int?
        let prNumber: Int?
        let prState: String?
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
                        chip(prColor) {
                            Text("#\(prNumber ?? 0) \(prState ?? "")"
                                .trimmingCharacters(in: .whitespaces))
                                .font(neon.mono(fontSize).weight(.semibold))
                                .foregroundStyle(prColor)
                        }
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
