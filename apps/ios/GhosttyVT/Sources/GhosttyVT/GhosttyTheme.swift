import Foundation

/// Terminal color themes. Pure data (no libghostty dependency) so the app's
/// model + settings layers can use it directly; `GhosttySurface` turns the
/// selected theme into a libghostty config. Colors are `#rrggbb`.
public enum GhosttyTheme: String, CaseIterable, Identifiable, Sendable {
    case ghosttyDark
    case solarizedDark
    case nord
    case dracula
    case gruvboxDark

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .ghosttyDark:   return "Ghostty Dark"
        case .solarizedDark: return "Solarized Dark"
        case .nord:          return "Nord"
        case .dracula:       return "Dracula"
        case .gruvboxDark:   return "Gruvbox Dark"
        }
    }

    var background: String {
        switch self {
        case .ghosttyDark:   return "#1d1f21"
        case .solarizedDark: return "#002b36"
        case .nord:          return "#2e3440"
        case .dracula:       return "#282a36"
        case .gruvboxDark:   return "#282828"
        }
    }

    var foreground: String {
        switch self {
        case .ghosttyDark:   return "#c5c8c6"
        case .solarizedDark: return "#839496"
        case .nord:          return "#d8dee9"
        case .dracula:       return "#f8f8f2"
        case .gruvboxDark:   return "#ebdbb2"
        }
    }

    var cursor: String {
        switch self {
        case .ghosttyDark:   return "#c5c8c6"
        case .solarizedDark: return "#93a1a1"
        case .nord:          return "#d8dee9"
        case .dracula:       return "#f8f8f2"
        case .gruvboxDark:   return "#ebdbb2"
        }
    }

    /// 16-color ANSI palette (`#rrggbb`), index 0..15 (8 normal + 8 bright).
    var palette: [String] {
        switch self {
        case .ghosttyDark:
            return ["#1d1f21", "#cc6666", "#b5bd68", "#f0c674",
                    "#81a2be", "#b294bb", "#8abeb7", "#c5c8c6",
                    "#666666", "#d54e53", "#b9ca4a", "#e7c547",
                    "#7aa6da", "#c397d8", "#70c0b1", "#eaeaea"]
        case .solarizedDark:
            return ["#073642", "#dc322f", "#859900", "#b58900",
                    "#268bd2", "#d33682", "#2aa198", "#eee8d5",
                    "#002b36", "#cb4b16", "#586e75", "#657b83",
                    "#839496", "#6c71c4", "#93a1a1", "#fdf6e3"]
        case .nord:
            return ["#3b4252", "#bf616a", "#a3be8c", "#ebcb8b",
                    "#81a1c1", "#b48ead", "#88c0d0", "#e5e9f0",
                    "#4c566a", "#bf616a", "#a3be8c", "#ebcb8b",
                    "#81a1c1", "#b48ead", "#8fbcbb", "#eceff4"]
        case .dracula:
            return ["#21222c", "#ff5555", "#50fa7b", "#f1fa8c",
                    "#bd93f9", "#ff79c6", "#8be9fd", "#f8f8f2",
                    "#6272a4", "#ff6e6e", "#69ff94", "#ffffa5",
                    "#d6acff", "#ff92df", "#a4ffff", "#ffffff"]
        case .gruvboxDark:
            return ["#282828", "#cc241d", "#98971a", "#d79921",
                    "#458588", "#b16286", "#689d6a", "#a89984",
                    "#928374", "#fb4934", "#b8bb26", "#fabd2f",
                    "#83a598", "#d3869b", "#8ec07c", "#ebdbb2"]
        }
    }

    /// Background as RGB 0…1 — for the host view to paint behind/around the grid.
    public var backgroundRGB: (red: Double, green: Double, blue: Double) {
        Self.rgb(background)
    }

    private static func rgb(_ hex: String) -> (red: Double, green: Double, blue: Double) {
        var s = Substring(hex)
        if s.first == "#" { s = s.dropFirst() }
        let v = UInt32(s, radix: 16) ?? 0
        return (Double((v >> 16) & 0xff) / 255.0,
                Double((v >> 8) & 0xff) / 255.0,
                Double(v & 0xff) / 255.0)
    }

    /// libghostty config body for this theme + font size. Line-based
    /// `key = value` syntax (matches the reference repos' `ghostty.conf`). A 10 MB
    /// scrollback is folded in so touch-scroll has history.
    func configBody(fontSize: Float) -> String {
        let fs = Int(min(max(fontSize, 6), 32).rounded())
        var lines = [
            "font-size = \(fs)",
            "scrollback-limit = 10000000",
            "background = \(background)",
            "foreground = \(foreground)",
            "cursor-color = \(cursor)",
        ]
        for (index, color) in palette.enumerated() {
            lines.append("palette = \(index)=\(color)")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
