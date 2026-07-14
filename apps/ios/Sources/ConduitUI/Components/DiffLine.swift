import SwiftUI

// MARK: - ConduitUI.DiffLineRow
//
// One rendered line of a structured git diff (PLAN-REVIEW-SHIP), from the
// broker's `GET /api/session/{id}/git/diff`. Library component -- the
// Android mirror is `ui/components/DiffLine.kt` and must stay value-for-
// value in sync (colors below are the tokens the Android agent mirrors).
//
// Named `DiffLineRow` (not `DiffLine`) because `ConduitUI.DiffLine` already
// exists (`ConduitDiffReviewModel.swift`) for the legacy chat-scraped diff
// used on brokers without the `review_ship` capability -- this is a
// deliberately distinct type, not a replacement, so both surfaces compile
// side by side.
//
// Colors reuse the EXISTING `NeonTheme` add/del/context tokens
// (`neon.green` / `neon.red` / `neon.textDim`) rather than minting new
// Palette constants -- `ConduitDiffReviewView`'s legacy inline diff already
// renders add/del/context with exactly these three tokens, so reusing them
// keeps ONE diff color language across both the legacy and structured
// surfaces instead of a near-duplicate token set. Resolved dark/Ice ARGB
// (the `NeonThemeTests`-pinned default): green `#3EF0A0`, red `#FF5C72`,
// textDim `rgba(196,214,244,0.64)` -- see NeonTheme.swift `resolve(dark:)`.

extension ConduitUI {

    struct DiffLineRow: View {
        let line: GitDiffLine
        /// Gutter chip -- rendered when this line carries a pinned
        /// annotation (review bar / gutter chip requirement).
        var isAnnotated: Bool = false
        var onTap: (() -> Void)? = nil
        @Environment(\.neonTheme) private var neon

        var body: some View {
            Button {
                onTap?()
            } label: {
                HStack(spacing: 8) {
                    gutter(line.old)
                    gutter(line.new)
                    Text(prefixedText)
                        .font(neon.mono(11.5))
                        .foregroundStyle(textColor)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if isAnnotated {
                        Image(systemName: "text.bubble.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(neon.accent)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(backgroundColor)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(onTap == nil)
        }

        private func gutter(_ number: Int) -> some View {
            Text(number > 0 ? "\(number)" : "")
                .font(neon.mono(10))
                .foregroundStyle(neon.textFaint)
                .frame(width: 30, alignment: .trailing)
        }

        private var prefixedText: String {
            switch line.kind {
            case .add:     return "+ " + line.text
            case .del:     return "− " + line.text
            case .context: return "  " + line.text
            }
        }

        private var textColor: Color {
            switch line.kind {
            case .add:     return neon.green
            case .del:     return neon.red
            case .context: return neon.textDim
            }
        }

        private var backgroundColor: Color {
            switch line.kind {
            case .add:     return neon.green.opacity(0.10)
            case .del:     return neon.red.opacity(0.10)
            case .context: return Color.clear
            }
        }
    }
}
