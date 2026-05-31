package sh.nikhil.conduit.ui

import android.graphics.Color
import sh.nikhil.conduit.AppearanceStore

/**
 * Android mirror of `apps/ios/Sources/Views/TerminalPalette.swift`.
 *
 * Termux's [com.termux.terminal.TerminalEmulator] owns the live 256-
 * color table (it parses SGR sequences itself and paints with its
 * own colours); we feed that table from this palette via
 * [com.termux.terminal.TerminalColors.mCurrentColors] in
 * [TermuxTerminalView]. The 16 ANSI slots + the two "default
 * foreground / default background" entries that this struct carries
 * are what the emulator actually reads when it renders.
 *
 * Indexing follows the iOS / xterm-256-color convention:
 *  - `ansi[0..7]` — normal ANSI colours (black, red, green, yellow,
 *    blue, magenta, cyan, white)
 *  - `ansi[8..15]` — bright variants
 *  - The two default colours are passed separately; Termux's
 *    `TerminalColors` slots them at indices `TextStyle.COLOR_INDEX_FOREGROUND`
 *    (256) and `TextStyle.COLOR_INDEX_BACKGROUND` (257).
 *
 * Values are packed-int ARGB ([Color.argb]) so they're trivial to
 * hand to Termux without a per-call conversion. Kept in sync with
 * the iOS [TerminalPalette.dark] / `.light` static factories — if
 * one platform's palette changes, update the other too.
 */
internal data class TerminalPalette(
    val defaultForeground: Int,
    val defaultBackground: Int,
    /** Exactly 16 entries, normal 0..7 then bright 8..15. */
    val ansi: IntArray,
) {
    init {
        require(ansi.size == 16) {
            "TerminalPalette.ansi must have 16 entries, got ${ansi.size}"
        }
    }

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is TerminalPalette) return false
        return defaultForeground == other.defaultForeground &&
            defaultBackground == other.defaultBackground &&
            ansi.contentEquals(other.ansi)
    }

    override fun hashCode(): Int {
        var r = defaultForeground
        r = 31 * r + defaultBackground
        r = 31 * r + ansi.contentHashCode()
        return r
    }

    companion object {

        /** Hand-tuned dark palette — black bg, light fg, the 16 ANSI
         *  slots mirroring `apps/ios/Sources/Views/TerminalPalette.swift`'s
         *  `.dark` static factory. Pre-PR Stage 3 behaviour. */
        val DARK = TerminalPalette(
            defaultForeground = rgb(0.93f, 0.93f, 0.93f),
            defaultBackground = Color.BLACK,
            ansi = intArrayOf(
                // Normal (0..7)
                rgb(0.00f, 0.00f, 0.00f),
                rgb(0.80f, 0.20f, 0.20f),
                rgb(0.30f, 0.70f, 0.30f),
                rgb(0.80f, 0.65f, 0.20f),
                rgb(0.25f, 0.45f, 0.85f),
                rgb(0.70f, 0.35f, 0.75f),
                rgb(0.25f, 0.70f, 0.75f),
                rgb(0.85f, 0.85f, 0.85f),
                // Bright (8..15)
                rgb(0.45f, 0.45f, 0.45f),
                rgb(0.95f, 0.40f, 0.40f),
                rgb(0.50f, 0.85f, 0.50f),
                rgb(0.95f, 0.85f, 0.40f),
                rgb(0.45f, 0.65f, 0.95f),
                rgb(0.85f, 0.55f, 0.90f),
                rgb(0.45f, 0.85f, 0.90f),
                rgb(1.00f, 1.00f, 1.00f),
            ),
        )

        /** Hand-tuned light palette — paper-white bg, near-black fg,
         *  ANSI slots desaturated so a red `error:` still reads as red
         *  on a white surface without blinding the user. Mirrors
         *  `apps/ios/Sources/Views/TerminalPalette.swift` `.light`. */
        val LIGHT = TerminalPalette(
            defaultForeground = rgb(0.10f, 0.10f, 0.10f),
            defaultBackground = rgb(0.98f, 0.98f, 0.97f),
            ansi = intArrayOf(
                // Normal (0..7)
                rgb(0.10f, 0.10f, 0.10f),
                rgb(0.70f, 0.15f, 0.15f),
                rgb(0.15f, 0.55f, 0.20f),
                rgb(0.60f, 0.50f, 0.10f),
                rgb(0.15f, 0.30f, 0.70f),
                rgb(0.55f, 0.20f, 0.60f),
                rgb(0.15f, 0.55f, 0.60f),
                rgb(0.55f, 0.55f, 0.55f),
                // Bright (8..15)
                rgb(0.35f, 0.35f, 0.35f),
                rgb(0.85f, 0.25f, 0.25f),
                rgb(0.20f, 0.70f, 0.30f),
                rgb(0.75f, 0.60f, 0.10f),
                rgb(0.25f, 0.45f, 0.85f),
                rgb(0.70f, 0.30f, 0.75f),
                rgb(0.20f, 0.65f, 0.70f),
                rgb(0.20f, 0.20f, 0.20f),
            ),
        )

        /**
         * Resolve a theme-aware palette from the user's
         * [AppearanceStore.ThemeMode]. `.System` reads the supplied
         * `isSystemDark` flag (which the caller pulls from the live
         * Compose [androidx.compose.foundation.isSystemInDarkTheme]
         * lambda) so the resolution happens at the call site — toggling
         * system theme mid-session recomposes and reapplies the right
         * palette.
         */
        fun forMode(
            mode: AppearanceStore.ThemeMode,
            isSystemDark: Boolean,
        ): TerminalPalette = when (mode) {
            AppearanceStore.ThemeMode.Light -> LIGHT
            AppearanceStore.ThemeMode.Dark -> DARK
            AppearanceStore.ThemeMode.System -> if (isSystemDark) DARK else LIGHT
        }

        /**
         * Resolve the curated terminal color theme the user picked in
         * Settings into a concrete palette. These are the SAME five
         * themes (and exact `#rrggbb` values) iOS ships in
         * `GhosttyVT.GhosttyTheme` — read from
         * `apps/ios/GhosttyVT/Sources/GhosttyVT/Terminal.swift` so the
         * two platforms render identically. Used by both the xterm.js
         * path ([WebTerminal]) and the Termux path
         * ([TermuxTerminalView]); the chosen terminal theme is
         * independent of the chat light/dark [forMode] split above (all
         * five are dark backgrounds, matching iOS).
         */
        fun forTheme(theme: AppearanceStore.TerminalTheme): TerminalPalette = when (theme) {
            AppearanceStore.TerminalTheme.GhosttyDark -> GHOSTTY_DARK
            AppearanceStore.TerminalTheme.SolarizedDark -> SOLARIZED_DARK
            AppearanceStore.TerminalTheme.Nord -> NORD
            AppearanceStore.TerminalTheme.Dracula -> DRACULA
            AppearanceStore.TerminalTheme.GruvboxDark -> GRUVBOX_DARK
        }

        /** Ghostty Dark — the default. Colors lifted verbatim from
         *  iOS `GhosttyTheme.ghosttyDark`. */
        val GHOSTTY_DARK = TerminalPalette(
            defaultForeground = hex("#c5c8c6"),
            defaultBackground = hex("#1d1f21"),
            ansi = hexAnsi(
                "#1d1f21", "#cc6666", "#b5bd68", "#f0c674",
                "#81a2be", "#b294bb", "#8abeb7", "#c5c8c6",
                "#666666", "#d54e53", "#b9ca4a", "#e7c547",
                "#7aa6da", "#c397d8", "#70c0b1", "#eaeaea",
            ),
        )

        /** Solarized Dark — iOS `GhosttyTheme.solarizedDark`. */
        val SOLARIZED_DARK = TerminalPalette(
            defaultForeground = hex("#839496"),
            defaultBackground = hex("#002b36"),
            ansi = hexAnsi(
                "#073642", "#dc322f", "#859900", "#b58900",
                "#268bd2", "#d33682", "#2aa198", "#eee8d5",
                "#002b36", "#cb4b16", "#586e75", "#657b83",
                "#839496", "#6c71c4", "#93a1a1", "#fdf6e3",
            ),
        )

        /** Nord — iOS `GhosttyTheme.nord`. */
        val NORD = TerminalPalette(
            defaultForeground = hex("#d8dee9"),
            defaultBackground = hex("#2e3440"),
            ansi = hexAnsi(
                "#3b4252", "#bf616a", "#a3be8c", "#ebcb8b",
                "#81a1c1", "#b48ead", "#88c0d0", "#e5e9f0",
                "#4c566a", "#bf616a", "#a3be8c", "#ebcb8b",
                "#81a1c1", "#b48ead", "#8fbcbb", "#eceff4",
            ),
        )

        /** Dracula — iOS `GhosttyTheme.dracula`. */
        val DRACULA = TerminalPalette(
            defaultForeground = hex("#f8f8f2"),
            defaultBackground = hex("#282a36"),
            ansi = hexAnsi(
                "#21222c", "#ff5555", "#50fa7b", "#f1fa8c",
                "#bd93f9", "#ff79c6", "#8be9fd", "#f8f8f2",
                "#6272a4", "#ff6e6e", "#69ff94", "#ffffa5",
                "#d6acff", "#ff92df", "#a4ffff", "#ffffff",
            ),
        )

        /** Gruvbox Dark — iOS `GhosttyTheme.gruvboxDark`. */
        val GRUVBOX_DARK = TerminalPalette(
            defaultForeground = hex("#ebdbb2"),
            defaultBackground = hex("#282828"),
            ansi = hexAnsi(
                "#282828", "#cc241d", "#98971a", "#d79921",
                "#458588", "#b16286", "#689d6a", "#a89984",
                "#928374", "#fb4934", "#b8bb26", "#fabd2f",
                "#83a598", "#d3869b", "#8ec07c", "#ebdbb2",
            ),
        )

        /** Cursor color per theme, matching iOS `GhosttyTheme.cursor`. */
        fun cursorHex(theme: AppearanceStore.TerminalTheme): String = when (theme) {
            AppearanceStore.TerminalTheme.GhosttyDark -> "#c5c8c6"
            AppearanceStore.TerminalTheme.SolarizedDark -> "#93a1a1"
            AppearanceStore.TerminalTheme.Nord -> "#d8dee9"
            AppearanceStore.TerminalTheme.Dracula -> "#f8f8f2"
            AppearanceStore.TerminalTheme.GruvboxDark -> "#ebdbb2"
        }

        /**
         * Build the xterm.js `theme` option object (as a JSON string)
         * for a curated [AppearanceStore.TerminalTheme]. xterm.js wants
         * `{ background, foreground, cursor, black, red, … brightWhite }`
         * with `#rrggbb` strings; the 16 ANSI slots map to its named
         * keys in order. The values come straight from [forTheme] /
         * [cursorHex] so xterm.js and Termux render the same colours
         * (and both match iOS).
         */
        fun xtermThemeJson(theme: AppearanceStore.TerminalTheme): String {
            val p = forTheme(theme)
            val names = arrayOf(
                "black", "red", "green", "yellow",
                "blue", "magenta", "cyan", "white",
                "brightBlack", "brightRed", "brightGreen", "brightYellow",
                "brightBlue", "brightMagenta", "brightCyan", "brightWhite",
            )
            val sb = StringBuilder()
            sb.append("{")
            sb.append("\"background\":\"").append(toHex(p.defaultBackground)).append("\",")
            sb.append("\"foreground\":\"").append(toHex(p.defaultForeground)).append("\",")
            sb.append("\"cursor\":\"").append(cursorHex(theme)).append("\"")
            for (i in names.indices) {
                sb.append(",\"").append(names[i]).append("\":\"")
                    .append(toHex(p.ansi[i])).append("\"")
            }
            sb.append("}")
            return sb.toString()
        }

        /** Packed ARGB int → `#rrggbb` (alpha dropped; xterm wants RGB). */
        fun toHex(argb: Int): String =
            String.format("#%06x", argb and 0x00FFFFFF)

        /** Parse a `#rrggbb` string into a packed opaque ARGB int. */
        private fun hex(s: String): Int = Color.parseColor(s)

        /** Parse 16 `#rrggbb` strings into the ANSI slot int array. */
        private fun hexAnsi(vararg s: String): IntArray {
            require(s.size == 16) { "expected 16 ANSI hex colours, got ${s.size}" }
            return IntArray(16) { Color.parseColor(s[it]) }
        }

        /**
         * Build an ARGB int from 0..1 float channels. Local helper so
         * the palette constants stay readable. Same fixed-point math
         * iOS uses on its `UIColor(red:green:blue:alpha:)` calls.
         */
        private fun rgb(r: Float, g: Float, b: Float): Int {
            return Color.argb(
                255,
                (r * 255f).toInt().coerceIn(0, 255),
                (g * 255f).toInt().coerceIn(0, 255),
                (b * 255f).toInt().coerceIn(0, 255),
            )
        }
    }
}
