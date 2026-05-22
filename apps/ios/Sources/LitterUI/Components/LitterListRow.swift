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
        var iconTint: Color = LitterUI.Palette.brand.color
        @ViewBuilder var trailing: () -> Trailing

        var body: some View {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.body)
                    .frame(width: 20)
                    .foregroundStyle(iconTint)
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
        iconTint: Color = LitterUI.Palette.brand.color
    ) -> some View {
        ListRow(icon: icon, title: title, subtitle: subtitle, iconTint: iconTint) {
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(LitterUI.Palette.textMuted.color)
        }
    }

    /// Toggle row.
    static func toggleRow(
        icon: String,
        title: String,
        subtitle: String? = nil,
        isOn: Binding<Bool>,
        iconTint: Color = LitterUI.Palette.brand.color
    ) -> some View {
        ListRow(icon: icon, title: title, subtitle: subtitle, iconTint: iconTint) {
            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(LitterUI.Palette.brand.color)
        }
    }

    /// Value row (right-aligned label).
    static func valueRow(
        icon: String,
        title: String,
        value: String,
        subtitle: String? = nil,
        iconTint: Color = LitterUI.Palette.brand.color
    ) -> some View {
        ListRow(icon: icon, title: title, subtitle: subtitle, iconTint: iconTint) {
            Text(value)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(LitterUI.Palette.textMuted.color)
        }
    }
}
