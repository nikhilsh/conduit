import SwiftUI

/// Shared typography ramp for non-ConduitUI surfaces (Settings sheets,
/// Appearance sheet, AccessoryBar, etc.). Mirrors the
/// `ConduitUI/Theme/ConduitTypography.swift` shape so call sites can be
/// ported 1:1 when subsequent PR 2–5 rebuilds touch them.
///
/// **Why a parent-level ramp at all?** Before PR 1, non-ConduitUI views
/// reached for raw `Font.system(.body, design: …)` calls, which:
///   - ignored `AppearanceStore.fontFamily` (the user's serif /
///     monospaced / system preference)
///   - had no heading scale, so Markdown `#` / `##` rendered identical
///     to body text
///   - couldn't honour the new [AppearanceStore.bodyPointSize] slider
///
/// This enum centralises the scaling so the audit's PR 2 (Settings
/// rebuild) can replace ad-hoc `.system(.caption2)` calls with
/// `ConduitTypography.caption(appearance)` once and have everything
/// downstream pick up the user's chosen family + base size.
///
/// Heading scale (1.07× / 1.15× / 1.30× / 1.43× of base) is
/// extracted from upstream's `MessageBubbleView` markdown rendering —
/// see `docs/PLAN-CONDUIT-VISUAL-PARITY.md` §B.2.
enum ConduitTypography {

    // MARK: Body

    /// Body text — chat content, list-row titles. Scales with
    /// [AppearanceStore.bodyPointSize] and honours the chosen
    /// family. Use this rather than `.system(.body)` so the user's
    /// preference + scale slider both take effect.
    static func body(_ appearance: AppearanceStore, weight: Font.Weight = .regular) -> Font {
        appearance.fontFamily.font(size: appearance.bodyPointSize, weight: weight)
    }

    // MARK: Headings (1.07× / 1.15× / 1.30× / 1.43× of body)

    /// h1 — page hero / screen title.
    static func heading1(_ appearance: AppearanceStore) -> Font {
        appearance.fontFamily.font(size: appearance.bodyPointSize * 1.43, weight: .bold)
    }

    /// h2 — section title inside a screen.
    static func heading2(_ appearance: AppearanceStore) -> Font {
        appearance.fontFamily.font(size: appearance.bodyPointSize * 1.30, weight: .semibold)
    }

    /// h3 — subsection / list-section header.
    static func heading3(_ appearance: AppearanceStore) -> Font {
        appearance.fontFamily.font(size: appearance.bodyPointSize * 1.15, weight: .semibold)
    }

    /// h4 — emphasis above a small block (settings row title).
    static func heading4(_ appearance: AppearanceStore) -> Font {
        appearance.fontFamily.font(size: appearance.bodyPointSize * 1.07, weight: .semibold)
    }

    // MARK: Captions

    /// Caption — labels above body content.
    static func caption(_ appearance: AppearanceStore) -> Font {
        appearance.fontFamily.font(textStyle: .caption)
    }

    /// Footnote — meta text under body content (timestamps, hints).
    static func footnote(_ appearance: AppearanceStore) -> Font {
        appearance.fontFamily.font(textStyle: .footnote)
    }

    /// Subheadline — between body and footnote.
    static func subheadline(_ appearance: AppearanceStore) -> Font {
        appearance.fontFamily.font(textStyle: .subheadline)
    }

    // MARK: Always-mono

    /// Always-monospaced caption — for paths, SHAs, branch labels.
    /// Bypasses the user's family preference because these strings
    /// are unreadable in serif and lose alignment in proportional
    /// system. Mirror of upstream's mono-locked metadata rows.
    static func monoCaption() -> Font {
        .system(.caption, design: .monospaced)
    }

    /// Always-monospaced footnote — same rationale as `monoCaption`.
    static func monoFootnote() -> Font {
        .system(.footnote, design: .monospaced)
    }
}
