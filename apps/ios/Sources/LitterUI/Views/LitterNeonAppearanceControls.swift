import SwiftUI

// MARK: - Shared Neon "Appearance" controls
//
// The accent-palette swatch picker + glow toggle + live preview chip are
// shown in BOTH the focused `LitterUI.AppearanceSheet` and the full
// `LitterUI.SettingsView`. They live here once so the two entry points
// stay in lock-step. Both consume `AppearanceStore` + `\.neonTheme` from
// the environment and persist via the store's `didSet` observers.
//
// Matches the design's `NeonSettingsScreen` Appearance card: a row of
// gradient swatches (each palette's `accent → accent2`) labelled with the
// active palette, then a "Glow & scanlines" row; a terminal-styled
// `$ swe-kitty --theme <id>` preview chip sits beneath the card.

extension LitterUI {

    /// Inner content for the "Neon Terminal" section card: the accent-
    /// palette swatch picker + the glow toggle. Wrap it in each view's own
    /// `sectionCard(title: "Neon Terminal")`.
    struct NeonPalettePickerContent: View {
        @Environment(AppearanceStore.self) private var appearance
        @Environment(\.neonTheme) private var neon

        var body: some View {
            @Bindable var appearance = appearance
            return VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 11) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Accent palette")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(neon.text)
                        Spacer(minLength: 6)
                        Text(appearance.neonPalette.label)
                            .font(neon.mono(11.5))
                            .foregroundStyle(neon.accent)
                    }
                    HStack(spacing: 9) {
                        ForEach(AppearanceStore.NeonPaletteChoice.allCases) { palette in
                            NeonPaletteSwatch(palette: palette)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 13)

                Divider().background(neon.border)

                LitterUI.toggleRow(
                    icon: "sparkles",
                    title: "Glow & scanlines",
                    subtitle: neon.dark ? "neon halos · on dark" : "neon halos · dimmed in light",
                    isOn: $appearance.neonGlow
                )
            }
        }
    }

    /// A single accent-palette swatch: a 38pt rounded chip filled with that
    /// palette's `accent → accent2` gradient (resolved against the active
    /// mode so each chip reads as its own palette, not the current one),
    /// with the palette label beneath. Selected swatch gets a text-coloured
    /// border + (when glow is on) an accent halo.
    struct NeonPaletteSwatch: View {
        let palette: AppearanceStore.NeonPaletteChoice
        @Environment(AppearanceStore.self) private var appearance
        @Environment(\.neonTheme) private var neon

        var body: some View {
            let resolved = NeonTheme.resolve(
                palette: palette.neonPalette,
                dark: neon.dark,
                glow: neon.glow
            )
            let selected = appearance.neonPalette == palette
            return Button {
                appearance.neonPalette = palette
            } label: {
                VStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [resolved.accentBright, resolved.accent2],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 38, height: 38)
                        .overlay(
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .strokeBorder(
                                    selected ? neon.text : neon.border,
                                    lineWidth: selected ? 2 : 1
                                )
                        )
                        .shadow(
                            color: selected && neon.glow
                                ? resolved.accentBright.opacity(0.53)
                                : .clear,
                            radius: selected ? 8 : 0
                        )
                    Text(palette.label)
                        .font(neon.mono(9.5).weight(selected ? .bold : .regular))
                        .foregroundStyle(selected ? neon.text : neon.textFaint)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
        }
    }

    /// Live preview chip — a terminal-styled `$ swe-kitty --theme <id>`
    /// line that re-tints with the active palette/glow (design's "preview"
    /// chip beneath the Appearance card).
    struct NeonThemePreviewChip: View {
        @Environment(AppearanceStore.self) private var appearance
        @Environment(\.neonTheme) private var neon

        var body: some View {
            HStack(spacing: 10) {
                Text("$")
                    .font(neon.mono(13))
                    .foregroundStyle(neon.accentBright)
                    .neonTextGlow(neon.textGlow)
                Text("swe-kitty --theme \(appearance.neonPalette.rawValue)")
                    .font(neon.mono(12.5))
                    .foregroundStyle(neon.codeText)
                Spacer(minLength: 6)
                Text("preview")
                    .font(neon.mono(11))
                    .foregroundStyle(neon.green)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(neon.codeBg)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(neon.borderStrong, lineWidth: 1)
                    )
            )
        }
    }
}
