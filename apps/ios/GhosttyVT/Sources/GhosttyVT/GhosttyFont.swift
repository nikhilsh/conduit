import Foundation

/// Terminal fonts. `system` keeps libghostty's built-in default; the rest are
/// bundled with the app (registered via `UIAppFonts`) and resolved by libghostty
/// through CoreText with `font-family`. Pure data, like `GhosttyTheme`.
public enum GhosttyFont: String, CaseIterable, Identifiable, Sendable {
    case system
    case jetBrainsMono
    case hack
    case firaCode
    case ibmPlexMono

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .system:        return "System Default"
        case .jetBrainsMono: return "JetBrains Mono"
        case .hack:          return "Hack"
        case .firaCode:      return "Fira Code"
        case .ibmPlexMono:   return "IBM Plex Mono"
        }
    }

    /// CoreText family name for `font-family`, or nil to keep libghostty's default.
    var familyName: String? {
        switch self {
        case .system:        return nil
        case .jetBrainsMono: return "JetBrains Mono"
        case .hack:          return "Hack"
        case .firaCode:      return "Fira Code"
        case .ibmPlexMono:   return "IBM Plex Mono"
        }
    }
}
