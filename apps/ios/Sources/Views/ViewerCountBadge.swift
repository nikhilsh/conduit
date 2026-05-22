import SwiftUI

/// sweswe-parity audit item — surfaces the **multi-viewer hint** broadcast
/// on the `view: "status"` mirror of the broker's `status` envelope (see
/// `docs/WEBSOCKET-PROTOCOL.md` §3.2). When two or more WebSocket clients
/// are attached to the same session, every viewer's UI needs a tiny
/// reminder that someone else is watching — otherwise a pair-programming
/// or hand-off session is invisibly shared and surprising.
///
/// Wired up nowhere yet on purpose: the broker fan-out work that emits
/// the `viewer_count` field is deferred (separate PR). This file ships
/// the pure-data + presentation half so the consumer side is reviewed
/// independently of the Go work that produces the field.
///
/// Visibility rule (defended by `ViewerCountBadgeModelTests`):
///   - `nil` count → invisible (broker has not yet emitted `viewer_count`;
///     don't render a placeholder that flickers in once the first frame
///     arrives).
///   - `count <= 1` → invisible (you are the only viewer; announcing
///     yourself to yourself is noise).
///   - `count >= 2` → render a pill `"👥 N"`.
struct ViewerCountBadge: View {
    let model: ViewerCountBadgeModel

    init(count: Int?) {
        self.model = ViewerCountBadgeModel(count: count)
    }

    var body: some View {
        if let label = model.label {
            Text(label)
                .font(.caption2.weight(.semibold))
                .monospacedDigit()
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Capsule(style: .continuous)
                        .fill(SweKittyTheme.surface.opacity(0.85))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(SweKittyTheme.textMuted.opacity(0.25), lineWidth: 0.5)
                )
                .foregroundStyle(SweKittyTheme.textSecondary)
                .accessibilityLabel(model.accessibilityLabel ?? "")
        }
    }
}

/// Pure-data backing for `ViewerCountBadge`. Lifts the visibility &
/// formatting rules into a value type so the contract is unit-testable
/// without standing up a SwiftUI host — same pattern as
/// `ServerPillModel` (PR #63) and `ProjectHeaderModel` (PR B).
struct ViewerCountBadgeModel: Equatable {
    /// Raw viewer-count field from the broker. `nil` means we haven't
    /// received a `status` frame yet (or the broker is older than the
    /// sweswe-parity addition and never emits the field).
    let count: Int?

    /// What the badge should render, or `nil` when the badge must be
    /// hidden. Keeping the absent state as `nil` (rather than `""`)
    /// lets the SwiftUI body short-circuit with `if let label`, which
    /// avoids reserving layout space for an invisible pill.
    var label: String? {
        guard let count, count >= 2 else { return nil }
        return "👥 \(count)"
    }

    /// VoiceOver string. Stays in sync with `label` — `nil` when the
    /// pill is hidden, otherwise spells out the count ("2 viewers" not
    /// "people emoji 2") so the reader doesn't announce the glyph
    /// codepoint.
    var accessibilityLabel: String? {
        guard let count, count >= 2 else { return nil }
        return "\(count) viewers"
    }

    /// Convenience: did we end up rendering anything? Test-readability
    /// helper so `#expect(model.isVisible)` reads better than
    /// `#expect(model.label != nil)`.
    var isVisible: Bool { label != nil }
}
