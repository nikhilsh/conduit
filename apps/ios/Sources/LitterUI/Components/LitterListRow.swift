import SwiftUI

// MARK: - LitterListRow
//
// Sectioned-settings row: leading SF Symbol in brand tint, title +
// optional subtitle, trailing chevron / value / toggle. Structurally
// mirrors litter's SettingsView row, our SettingsToggleRow shape, and
// litter's NavLink rows.
//
// Three variants:
//   - `.navigation(...)` - chevron trailing
//   - `.value(...)`      - right-aligned value text
//   - `.toggle(...)`     - trailing UISwitch via SwiftUI Toggle

extension LitterUI {

    struct ListRow<Trailing: View>: View {
        let icon: String
        let title: String
        var subtitle: String? = nil
        /// Leading-icon tint. `nil` (the default) resolves to the active
        /// Neon palette accent — replacing the legacy copper brand default
        /// so settings rows / toggles follow the selected palette.
        var iconTint: Color? = nil
        @ViewBuilder var trailing: () -> Trailing
        @Environment(\.neonTheme) private var neon

        var body: some View {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.body)
                    .frame(width: 20)
                    .foregroundStyle(iconTint ?? neon.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(LitterUI.Palette.textPrimary.color)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(LitterUI.Palette.textMuted.color)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 6)
                trailing()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
    }

    // MARK: Convenience factories

    /// Navigation chevron row.
    static func navRow(
        icon: String,
        title: String,
        subtitle: String? = nil,
        iconTint: Color? = nil
    ) -> some View {
        ListRow(icon: icon, title: title, subtitle: subtitle, iconTint: iconTint) {
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(LitterUI.Palette.textMuted.color)
        }
    }

    /// Toggle row. The switch tints to the active Neon palette accent
    /// (via [NeonTintedToggle]) instead of the legacy copper brand.
    static func toggleRow(
        icon: String,
        title: String,
        subtitle: String? = nil,
        isOn: Binding<Bool>,
        iconTint: Color? = nil
    ) -> some View {
        ListRow(icon: icon, title: title, subtitle: subtitle, iconTint: iconTint) {
            NeonTintedToggle(isOn: isOn)
        }
    }

    /// A `Toggle` whose accent follows the active Neon palette. Wraps the
    /// switch so the tint can read `\.neonTheme` from the environment
    /// (the static row factories can't, being plain functions).
    struct NeonTintedToggle: View {
        let isOn: Binding<Bool>
        @Environment(\.neonTheme) private var neon

        var body: some View {
            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(neon.accent)
        }
    }

    /// Value row (right-aligned label).
    static func valueRow(
        icon: String,
        title: String,
        value: String,
        subtitle: String? = nil,
        iconTint: Color? = nil
    ) -> some View {
        ListRow(icon: icon, title: title, subtitle: subtitle, iconTint: iconTint) {
            Text(value)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(LitterUI.Palette.textMuted.color)
        }
    }
}
