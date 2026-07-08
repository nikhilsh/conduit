import SwiftUI

// MARK: - ConduitUI.OptionPickerSheet
//
// Generic kit sheet for a small option list (Reasoning effort, Permission
// mode, ...) -- the model-sheet's card-row look (accent border + checkmark
// on selected) with no catalog, used by any Advanced-section row that isn't
// picking a model (design_handoff_review_fixes README item 4 / ds-review.jsx
// RvModelSheet: "Same sheet component reused for Reasoning and Permissions
// rows in Advanced"). Replaces the stock SwiftUI `Menu` those rows used to
// be. Mirror of Android `ConduitUI.OptionPickerSheet` (ModelPicker.kt).

extension ConduitUI {
    /// One row in an `OptionPickerSheet` -- a value/label pair plus an
    /// optional caption (mirrors `ModelPickerSheet`'s detail line).
    struct OptionPickerItem: Identifiable {
        let value: String
        let label: String
        var detail: String?

        var id: String { value }

        init(value: String, label: String, detail: String? = nil) {
            self.value = value
            self.label = label
            self.detail = detail
        }
    }

    struct OptionPickerSheet: View {
        let title: String
        let options: [OptionPickerItem]
        @Binding var selection: String
        /// Accent used for the checkmark and selected card border --
        /// typically the caller's agent tint.
        var tint: Color
        /// Telemetry breadcrumb category tag, mirrors `ModelPickerSheet`.
        var telemetryContext: String

        @Environment(\.neonTheme) private var neon
        @Environment(\.dismiss) private var dismiss

        var body: some View {
            NavigationStack {
                ZStack {
                    GlassAppBackground()
                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(options) { option in
                                let isSelected = option.value == selection
                                Button {
                                    selection = option.value
                                    Telemetry.breadcrumb(telemetryContext, "option picked",
                                        data: ["value": option.value])
                                    dismiss()
                                } label: {
                                    HStack(alignment: .top, spacing: 12) {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(option.label)
                                                .font(neon.sans(14).weight(.semibold))
                                                .foregroundStyle(neon.text)
                                            if let d = option.detail, !d.isEmpty {
                                                Text(d)
                                                    .font(neon.sans(12))
                                                    .foregroundStyle(neon.textDim)
                                                    .fixedSize(horizontal: false, vertical: true)
                                            }
                                        }
                                        Spacer(minLength: 0)
                                        if isSelected {
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 13, weight: .bold))
                                                .foregroundStyle(tint)
                                        }
                                    }
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 12)
                                    .neonCardSurface(
                                        neon,
                                        fill: isSelected ? tint.opacity(neon.dark ? 0.12 : 0.07) : neon.surface,
                                        cornerRadius: 13,
                                        border: isSelected ? tint.opacity(0.45) : neon.border
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 18)
                    }
                    .scrollIndicators(.hidden)
                }
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .tint(tint)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(neon.textFaint)
                        }
                    }
                }
            }
            .presentationDetents([.medium, .large])
            .presentationCornerRadius(26)
            .appearanceColorScheme()
        }
    }

    /// The trigger row for `OptionPickerSheet` -- current label + chevron on
    /// a glass rounded-rect surface, tapping opens the sheet. Mirrors
    /// `ModelPickerRow`.
    struct OptionPickerRow: View {
        let title: String
        let options: [OptionPickerItem]
        @Binding var selection: String
        var tint: Color
        var telemetryContext: String

        @State private var showSheet = false
        @Environment(\.neonTheme) private var neon

        private var currentLabel: String {
            options.first(where: { $0.value == selection })?.label ?? selection
        }

        var body: some View {
            Button {
                showSheet = true
            } label: {
                HStack {
                    Text(currentLabel)
                        .font(neon.sans(13).weight(.medium))
                        .foregroundStyle(neon.text)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(neon.textDim)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .neonCardSurface(neon, fill: neon.surface, cornerRadius: 13)
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $showSheet) {
                OptionPickerSheet(
                    title: title,
                    options: options,
                    selection: $selection,
                    tint: tint,
                    telemetryContext: telemetryContext
                )
            }
        }
    }
}
