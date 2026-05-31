import SwiftUI

// MARK: - ConduitTypography
//
// Type ramp matching upstream. Conduit exposes a single `conduitFont`
// helper that respects the user's font-design choice (monospaced vs.
// default). We adapt that to honour `AppearanceStore.fontFamily`, so
// the ConduitUI tree picks up the user's chosen body font without any
// per-view wiring.
//
// Sizes were derived from upstream's structural notes (HomeBottomBar:
// 10pt mono meta, 12pt telemetry, headlines tracking body weight).
// The ramp here is intentionally narrow — we want clear hierarchy at
// a glance.

extension ConduitUI {

    /// Resolves a SwiftUI `Font` against the user's chosen body font
    /// family (`AppearanceStore.fontFamily`). The `design` argument
    /// is honoured when the family is `.system`; otherwise the user
    /// override wins (monospaced / serif body settings are global).
    enum Typography {
        /// Maps the appearance store's choice to a SwiftUI design.
        static func bodyDesign(for family: AppearanceStore.FontFamily) -> Font.Design {
            switch family {
            case .serif:      return .serif
            case .system:     return .default
            case .monospaced: return .monospaced
            }
        }

        // MARK: Ramp

        /// Large hero / screen title.
        static func hero(_ family: AppearanceStore.FontFamily) -> Font {
            .system(size: 28, weight: .bold, design: bodyDesign(for: family))
        }

        /// Section header — sentence-case, bold.
        static func sectionHeader(_ family: AppearanceStore.FontFamily) -> Font {
            .system(size: 17, weight: .semibold, design: bodyDesign(for: family))
        }

        /// Body text (chat messages, list-row titles).
        static func body(_ family: AppearanceStore.FontFamily) -> Font {
            .system(size: 16, weight: .regular, design: bodyDesign(for: family))
        }

        /// Strong body emphasis — list-row titles, message senders.
        static func bodyEmphasis(_ family: AppearanceStore.FontFamily) -> Font {
            .system(size: 16, weight: .semibold, design: bodyDesign(for: family))
        }

        /// Caption / subtitle line under a list row.
        static func caption(_ family: AppearanceStore.FontFamily) -> Font {
            .system(size: 12, weight: .regular, design: bodyDesign(for: family))
        }

        /// Tiny mono meta (timestamps, host IPs). Always mono regardless
        /// of body family — these are data, not prose.
        static let meta: Font = .system(size: 10, weight: .regular, design: .monospaced)

        /// Big stat value (Info screen). Always mono.
        static let statBig: Font = .system(size: 28, weight: .bold, design: .monospaced)

        /// Code block / inline mono.
        static let code: Font = .system(size: 14, weight: .regular, design: .monospaced)
    }
}
