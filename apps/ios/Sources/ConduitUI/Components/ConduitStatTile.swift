import SwiftUI

// MARK: - ConduitUI.StatTile
//
// Recap/metric tile: a large mono value above a tiny uppercase label.
// Extracted from the private `statTile(value:label:tint:)` helper in
// ConduitSessionRecapView so the shape is reusable across recap, session
// info, and any future metric surfaces.
//
// Usage:
//   ConduitUI.StatTile(value: "+42", label: "added", tint: neon.green)

extension ConduitUI {

    struct StatTile: View {
        let value: String
        let label: String
        /// Optional tint for the value text. Defaults to `neon.text` when nil.
        var tint: Color? = nil
        @Environment(\.neonTheme) private var neon

        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                Text(value)
                    .font(neon.mono(20).weight(.bold))
                    .foregroundStyle(tint ?? neon.text)
                    .neonTextGlow(neon.textGlow)
                Text(label)
                    .font(neon.mono(10.5))
                    .foregroundStyle(neon.textDim)
                    .textCase(.uppercase)
                    .tracking(0.6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .neonCardSurface(neon, fill: neon.surface, cornerRadius: 14)
        }
    }
}
