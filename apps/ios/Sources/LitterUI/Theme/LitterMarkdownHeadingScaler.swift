import Foundation
import SwiftUI

/// Heading scale for assistant-rendered markdown inside the chat.
/// Litter ramps headings at `1.07× / 1.15× / 1.30× / 1.43×` of the
/// base body size (see `PLAN-LITTER-VISUAL-PARITY` §B.2 / audit
/// §A.2.2). Before this PR our `Text(AttributedString(markdown:))`
/// rendered `# H1` … `#### H4` at the body size — markdown headers
/// produced no visual hierarchy at all, which is the single biggest
/// difference between our transcripts and litter's.
///
/// Kept as a pure-function module (no SwiftUI view) so it's trivially
/// unit-testable and so the cache invariants in `LitterMarkdownBlock`
/// stay honest — the cached `AttributedString` is the already-scaled
/// one, keyed on body size.
enum LitterMarkdownHeadingScaler {

    /// Multiplier for `# h1` … `#### h4`. h5/h6 stay at body (1.0) —
    /// in practice litter's transcripts never go deeper than h4 and
    /// six distinct sizes would make the chat read like a magazine
    /// spread.
    static let multipliers: [Int: CGFloat] = [
        1: 1.43,
        2: 1.30,
        3: 1.15,
        4: 1.07,
    ]

    /// Compute the multiplier for a heading level. Returns nil for
    /// "no scaling" (body / unknown).
    static func multiplier(forLevel level: Int) -> CGFloat? {
        multipliers[level]
    }

    /// Walks every run in `attr` whose presentation intent is a
    /// header and stamps the run with a SwiftUI `Font` whose size is
    /// `basePointSize × multiplier`. Runs that aren't headers are
    /// untouched (the outer `.font(...)` modifier supplies the base).
    ///
    /// `design` carries the user's chosen font family (serif /
    /// monospaced / system) — without it, the headers would always
    /// land in `.default` regardless of the rest of the chat.
    @available(iOS 15.0, *)
    static func apply(to attr: inout AttributedString, basePointSize: CGFloat, design: Font.Design) {
        for run in attr.runs {
            guard let intent = run.attributes.presentationIntent else { continue }
            for component in intent.components {
                guard case .header(let level) = component.kind,
                      let mult = multiplier(forLevel: level) else { continue }
                attr[run.range].font = .system(
                    size: basePointSize * mult,
                    weight: .semibold,
                    design: design
                )
            }
        }
    }
}
