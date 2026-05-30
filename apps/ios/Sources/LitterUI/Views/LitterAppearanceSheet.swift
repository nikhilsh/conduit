import SwiftUI

// MARK: - LitterAppearanceSheet
//
// Focused appearance editor presented as a sheet (e.g. from Session
// Info's "Appearance" action). Reuses the exact Theme / Neon / Font /
// Font Size controls from `LitterSettingsView`, scoped to just
// appearance so the Session Info entry point lands on the relevant
// controls instead of the full Settings screen. All edits are
// AppearanceStore-backed and persist to UserDefaults via the store's
// `didSet` observers.
//
// Styling follows the Neon Terminal idiom (matches `LitterSettingsView`):
// `@Environment(\.neonTheme)`, `.neonCardSurface(neon, ...)` section
// cards, mono uppercase section labels in `neon.textDim`, and accent-
// tinted SF Symbols / checkmarks / controls.

extension LitterUI {

    struct AppearanceSheet: View {
        @Environment(AppearanceStore.self) private var appearance
        @Environment(\.neonTheme) private var neon
        @Environment(\.dismiss) private var dismiss

        var body: some View {
            @Bindable var appearance = appearance

            NavigationStack {
                ZStack {
                    GlassAppBackground()

                    ScrollView {
                        VStack(spacing: 18) {
                            themeSection
                            neonSection
                            previewChip
                            fontSection
                            fontSizeSection
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 18)
                    }
                    .scrollIndicators(.hidden)
                }
                .navigationTitle("Appearance")
                .navigationBarTitleDisplayMode(.inline)
                .tint(neon.accent)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
            }
            // Re-binds the SwiftUI \.colorScheme environment AND re-resolves
            // \.neonTheme from the AppearanceStore so picking Light / Dark
            // (or a palette / glow) INSIDE this sheet updates the sheet
            // itself live, not just the underlying root view tree.
            .appearanceColorScheme()
        }

        // MARK: Sections

        private var themeSection: some View {
            @Bindable var appearance = appearance
            return sectionCard(title: "Theme") {
                VStack(spacing: 0) {
                    ForEach(AppearanceStore.ThemeMode.allCases) { mode in
                        Button {
                            appearance.themeMode = mode
                        } label: {
                            LitterUI.ListRow(
                                icon: themeIcon(for: mode),
                                title: mode.label,
                                subtitle: nil,
                                iconTint: neon.accent
                            ) {
                                if appearance.themeMode == mode {
                                    Image(systemName: "checkmark")
                                        .font(.footnote.weight(.bold))
                                        .foregroundStyle(neon.accent)
                                        .neonTextGlow(neon.textGlow)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        rowDivider(after: mode, in: AppearanceStore.ThemeMode.allCases)
                    }
                }
            }
        }

        private func themeIcon(for mode: AppearanceStore.ThemeMode) -> String {
            switch mode {
            case .system: return "iphone"
            case .light:  return "sun.max.fill"
            case .dark:   return "moon.fill"
            }
        }

        /// Neon Terminal theme controls — accent-palette swatch picker +
        /// glow toggle (shared with `LitterSettingsView` via
        /// `LitterUI.NeonPalettePickerContent`). Mode is handled by
        /// `themeSection` above (Neon reuses `themeMode` for light/dark).
        private var neonSection: some View {
            sectionCard(title: "Neon Terminal") {
                LitterUI.NeonPalettePickerContent()
            }
        }

        /// Live `$ swe-kitty --theme <id>` preview chip (shared component).
        private var previewChip: some View {
            LitterUI.NeonThemePreviewChip()
        }

        private var fontSection: some View {
            @Bindable var appearance = appearance
            return sectionCard(title: "Font") {
                VStack(spacing: 0) {
                    ForEach(AppearanceStore.FontFamily.allCases) { family in
                        Button {
                            appearance.fontFamily = family
                        } label: {
                            LitterUI.ListRow(
                                icon: fontIcon(for: family),
                                title: family.label,
                                subtitle: "The quick brown fox",
                                iconTint: neon.accent
                            ) {
                                if appearance.fontFamily == family {
                                    Image(systemName: "checkmark")
                                        .font(.footnote.weight(.bold))
                                        .foregroundStyle(neon.accent)
                                        .neonTextGlow(neon.textGlow)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        rowDivider(after: family, in: AppearanceStore.FontFamily.allCases)
                    }
                }
            }
        }

        private func fontIcon(for family: AppearanceStore.FontFamily) -> String {
            switch family {
            case .serif:      return "textformat.alt"
            case .system:     return "textformat"
            case .monospaced: return "chevron.left.forwardslash.chevron.right"
            }
        }

        private var fontSizeSection: some View {
            @Bindable var appearance = appearance
            return sectionCard(title: "Font Size") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        Image(systemName: "textformat.size")
                            .font(.body)
                            .frame(width: 20)
                            .foregroundStyle(neon.accent)
                        Text("Body")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(neon.text)
                        Spacer(minLength: 6)
                        Text("\(Int(appearance.bodyPointSize))pt")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(neon.textFaint)
                    }
                    Slider(
                        value: $appearance.bodyPointSize,
                        in: AppearanceStore.bodyPointSizeRange,
                        step: 1
                    )
                    .tint(neon.accent)
                    Text("The quick brown fox jumps over the lazy dog.")
                        .font(SweKittyTypography.body(appearance))
                        .foregroundStyle(neon.textDim)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
        }

        // MARK: Layout helpers

        @ViewBuilder
        private func sectionCard<C: View>(title: String, @ViewBuilder content: () -> C) -> some View {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(neon.mono(11).weight(.bold))
                    .foregroundStyle(neon.textDim)
                    .textCase(.uppercase)
                    .padding(.horizontal, 4)
                // Neon section surface: hairline border + glow (or light-
                // mode elevation) via the shared card-surface rule.
                content()
                    .neonCardSurface(neon, fill: neon.surface, cornerRadius: 14)
            }
        }

        @ViewBuilder
        private func rowDivider<T: Equatable>(after element: T, in collection: [T]) -> some View {
            if let idx = collection.firstIndex(of: element), idx < collection.count - 1 {
                Divider()
                    .background(neon.border)
                    .padding(.leading, 46)
            }
        }
    }
}
