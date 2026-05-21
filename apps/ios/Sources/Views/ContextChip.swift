import SwiftUI

/// One pinned-context chip, rendered above the composer. Tap clears
/// the chip via `onRemove`. The chip is purely presentational —
/// data lives in `SessionStore.pinnedContexts`.
struct ContextChipView: View {
    let context: PinnedContext
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: context.iconName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(SweKittyTheme.textSecondary)
            Text(context.label)
                .font(.caption.weight(.medium))
                .foregroundStyle(SweKittyTheme.textBody)
                .lineLimit(1)
                .truncationMode(.middle)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(SweKittyTheme.textSecondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(context.label)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .glassCapsule(interactive: false, tint: SweKittyTheme.accent.opacity(0.22))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Pinned: \(context.label)")
    }
}
