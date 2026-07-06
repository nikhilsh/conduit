import SwiftUI

// MARK: - ConduitUI.ModelPickerSheet
//
// Conduit-native model picker, extracted from the new-session
// `DirectoryPicker` (config-sheet redesign, owner ask: "make the pipeline
// Builder's config sheet look like the new session picker"). One card per
// model option -- RECOMMENDED badge on the default, checkmark on the
// selection, description caption below each -- replacing the stock
// SwiftUI `Menu`/`Picker` dropdown everywhere a model needs picking
// (new-session directory step, pipeline Builder step/sub-step/fan-out-run
// config). Single implementation so every call site dedupes the "Default"
// row the same way (`ForkOptions.models(forAssistant:catalog:)` already
// folds the catalog's own "" entry and the inherit sentinel into ONE row --
// see its doc comment).

extension ConduitUI {
    struct ModelPickerSheet: View {
        /// Agent whose catalog is being shown (drives the picker title).
        let agentKind: String
        /// The agent's live model catalog (broker-discovered); nil/empty
        /// falls back to `ForkOptions`'s static per-assistant list.
        let catalog: [AgentModel]?
        @Binding var model: String
        /// Accent used for the RECOMMENDED badge, checkmark, and selected
        /// card border -- typically the caller's agent tint.
        var tint: Color
        /// Telemetry breadcrumb category tag so pipeline vs. new-session
        /// picks are distinguishable in Sentry without separate call sites.
        var telemetryContext: String = "new_session"

        @Environment(\.neonTheme) private var neon
        @Environment(\.dismiss) private var dismiss

        private var modelOptions: [String] {
            ForkOptions.models(forAssistant: agentKind, catalog: catalog)
        }

        var body: some View {
            NavigationStack {
                ZStack {
                    GlassAppBackground()
                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(modelOptions, id: \.self) { option in
                                let entry = ForkOptions.catalogEntry(for: option, in: catalog)
                                let isSelected = option == model
                                let isRecommended = entry?.isDefault == true || option == ForkOptions.inheritModel
                                let label = ForkOptions.modelLabel(option, catalog: catalog)
                                let detail = ForkOptions.modelDetail(option, catalog: catalog)
                                Button {
                                    model = option
                                    Telemetry.breadcrumb(telemetryContext, "model picked",
                                        data: ["model": option, "agent": agentKind])
                                    dismiss()
                                } label: {
                                    HStack(alignment: .top, spacing: 12) {
                                        VStack(alignment: .leading, spacing: 4) {
                                            HStack(spacing: 6) {
                                                Text(label)
                                                    .font(neon.sans(14).weight(.semibold))
                                                    .foregroundStyle(neon.text)
                                                if isRecommended {
                                                    Text("RECOMMENDED")
                                                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                                                        .tracking(0.4)
                                                        .foregroundStyle(tint)
                                                        .padding(.horizontal, 5)
                                                        .padding(.vertical, 2)
                                                        .background(Capsule().fill(tint.opacity(0.14)))
                                                        .overlay(Capsule().stroke(tint.opacity(0.35), lineWidth: 1))
                                                }
                                            }
                                            if let d = detail, !d.isEmpty {
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
                .navigationTitle("Model")
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

    /// The model-row trigger button shared by every model picker call site:
    /// current label + chevron on a glass rounded-rect surface, tapping
    /// opens `ModelPickerSheet`. Compose from this rather than re-rolling
    /// the row (config-sheet redesign).
    struct ModelPickerRow: View {
        let agentKind: String
        let catalog: [AgentModel]?
        @Binding var model: String
        var tint: Color
        var telemetryContext: String = "pipeline"

        @State private var showSheet = false
        @Environment(\.neonTheme) private var neon

        var body: some View {
            Button {
                showSheet = true
            } label: {
                HStack {
                    Text(ForkOptions.modelLabel(model, catalog: catalog))
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
                ModelPickerSheet(
                    agentKind: agentKind,
                    catalog: catalog,
                    model: $model,
                    tint: tint,
                    telemetryContext: telemetryContext
                )
            }
        }
    }
}
