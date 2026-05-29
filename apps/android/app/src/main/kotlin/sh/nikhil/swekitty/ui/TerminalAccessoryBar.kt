package sh.nikhil.swekitty.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive

/**
 * Android mirror of iOS `TerminalAccessoryBar`. A horizontally
 * scrollable row of rounded key caps that sits above the soft keyboard
 * on the Terminal tab, giving TUIs the Esc/Tab/arrows/Ctrl chords and
 * the Home/End/PgUp/PgDn navigation keys the Android soft keyboard
 * doesn't provide. Bytes emitted match the iOS
 * bar exactly (and the standard xterm sequences) so the agent on the
 * other end of the PTY can't tell the source apart — see
 * `apps/ios/Sources/Shared/TerminalAccessoryBar.swift`.
 *
 * Press-and-hold auto-repeat (backspace + the four arrows) uses the
 * same ~0.4s initial delay / ~0.1s cadence as iOS.
 *
 * The byte table + repeat flags live in [TerminalAccessoryKey] so a
 * JUnit test can lock the iOS↔Android parity without a Compose host.
 */
object TerminalAccessoryBarModel {
    /** Press-and-hold timings — match iOS `repeatInitialDelay` / `repeatInterval`. */
    const val REPEAT_INITIAL_DELAY_MS: Long = 400
    const val REPEAT_INTERVAL_MS: Long = 100

    /**
     * Ordered key list — identical labels, bytes, and repeat flags to
     * the iOS `TerminalAccessoryBar.keys` array. Tests pin this so the
     * two platforms can't drift.
     */
    val keys: List<TerminalAccessoryKey> = listOf(
        TerminalAccessoryKey("esc", byteArrayOf(0x1B), wide = true),
        TerminalAccessoryKey("tab", byteArrayOf(0x09), wide = true),
        TerminalAccessoryKey("⌫", byteArrayOf(0x7F), repeats = true),
        TerminalAccessoryKey("↑", byteArrayOf(0x1B, 0x5B, 0x41), repeats = true),
        TerminalAccessoryKey("↓", byteArrayOf(0x1B, 0x5B, 0x42), repeats = true),
        TerminalAccessoryKey("←", byteArrayOf(0x1B, 0x5B, 0x44), repeats = true),
        TerminalAccessoryKey("→", byteArrayOf(0x1B, 0x5B, 0x43), repeats = true),
        // Document navigation — standard xterm sequences, wide caps for
        // the multi-glyph labels: Home ESC[H, End ESC[F, PgUp ESC[5~,
        // PgDn ESC[6~. Must stay byte-for-byte in step with iOS.
        TerminalAccessoryKey("home", byteArrayOf(0x1B, 0x5B, 0x48), wide = true),
        TerminalAccessoryKey("end", byteArrayOf(0x1B, 0x5B, 0x46), wide = true),
        TerminalAccessoryKey("pgup", byteArrayOf(0x1B, 0x5B, 0x35, 0x7E), wide = true),
        TerminalAccessoryKey("pgdn", byteArrayOf(0x1B, 0x5B, 0x36, 0x7E), wide = true),
        TerminalAccessoryKey("^C", byteArrayOf(0x03)),
        TerminalAccessoryKey("^D", byteArrayOf(0x04)),
        TerminalAccessoryKey("^Z", byteArrayOf(0x1A)),
        TerminalAccessoryKey("^L", byteArrayOf(0x0C)),
        TerminalAccessoryKey("^R", byteArrayOf(0x12)),
        TerminalAccessoryKey("^U", byteArrayOf(0x15)),
        TerminalAccessoryKey("^W", byteArrayOf(0x17)),
        TerminalAccessoryKey("^A", byteArrayOf(0x01)),
        TerminalAccessoryKey("^E", byteArrayOf(0x05)),
        TerminalAccessoryKey("|", byteArrayOf(0x7C)),
        TerminalAccessoryKey("/", byteArrayOf(0x2F)),
        TerminalAccessoryKey("\\", byteArrayOf(0x5C)),
        TerminalAccessoryKey("~", byteArrayOf(0x7E)),
        TerminalAccessoryKey("-", byteArrayOf(0x2D)),
    )
}

/**
 * One accessory key: the glyph it shows, the bytes it sends, whether it
 * gets a slightly wider cap (multi-glyph labels), and whether
 * press-and-hold auto-repeats it.
 */
data class TerminalAccessoryKey(
    val label: String,
    val bytes: ByteArray,
    val wide: Boolean = false,
    val repeats: Boolean = false,
) {
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is TerminalAccessoryKey) return false
        return label == other.label &&
            bytes.contentEquals(other.bytes) &&
            wide == other.wide &&
            repeats == other.repeats
    }

    override fun hashCode(): Int {
        var r = label.hashCode()
        r = 31 * r + bytes.contentHashCode()
        r = 31 * r + wide.hashCode()
        r = 31 * r + repeats.hashCode()
        return r
    }
}

/**
 * The scrollable accessory bar. `onSend` is wired straight to
 * `SessionStore.sendInput` by the caller so a key tap reaches the
 * broker on the same path as keyboard input.
 */
@Composable
fun TerminalAccessoryBar(
    onSend: (ByteArray) -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .horizontalScroll(rememberScrollState())
            .padding(horizontal = 10.dp, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(7.dp),
    ) {
        for (key in TerminalAccessoryBarModel.keys) {
            KeyCap(key = key, onSend = onSend)
        }
    }
}

@Composable
private fun KeyCap(
    key: TerminalAccessoryKey,
    onSend: (ByteArray) -> Unit,
) {
    val neon = LocalNeonTheme.current
    val capShape = RoundedCornerShape(10.dp)
    val sendBytes = { onSend(key.bytes.copyOf()) }
    Box(
        contentAlignment = Alignment.Center,
        modifier = Modifier
            // Multi-glyph caps (esc/tab/home/end/pgup/pgdn) get a wider
            // floor so a 4-char monospace label is never squeezed; the
            // single-glyph keys are square-ish. Uniform horizontal
            // padding for all caps — over-padding the wide labels was
            // what clipped the first two keys.
            .defaultMinSize(minWidth = if (key.wide) 56.dp else 40.dp, minHeight = 36.dp)
            // Neon key cap: a darker code-surface fill with a neon
            // hairline border — reads as a terminal key, mono label tinted
            // to the accent. No glow on each cap (the row would shimmer);
            // the accent border carries the neon feel.
            .clip(capShape)
            .background(if (neon.dark) neon.surface2 else neon.codeBg, capShape)
            .border(1.dp, neon.border, capShape)
            .padding(horizontal = 12.dp, vertical = 6.dp)
            .semantics { contentDescription = key.label }
            .then(
                if (key.repeats) {
                    Modifier.pointerInput(key) {
                        // Press-and-hold auto-repeat. The `onPress`
                        // coroutine runs for the duration of the press and
                        // is cancelled the instant the finger lifts (or the
                        // gesture is cancelled), which tears down the loop
                        // below. Fire once immediately, wait the initial
                        // delay, then emit on the steady cadence until
                        // cancelled. Mirrors iOS `beginRepeat`.
                        detectTapGestures(
                            onPress = {
                                sendBytes()
                                delay(TerminalAccessoryBarModel.REPEAT_INITIAL_DELAY_MS)
                                // `PressGestureScope` is not a CoroutineScope,
                                // so reach for the active flag via the
                                // current coroutine context. The loop exits
                                // when the press coroutine is cancelled on
                                // finger-up.
                                while (currentCoroutineContext().isActive) {
                                    sendBytes()
                                    delay(TerminalAccessoryBarModel.REPEAT_INTERVAL_MS)
                                }
                            },
                        )
                    }
                } else {
                    Modifier.pointerInput(key) {
                        detectTapGestures(onTap = { sendBytes() })
                    }
                },
            ),
    ) {
        Text(
            text = key.label,
            style = MaterialTheme.typography.titleMedium,
            fontFamily = neon.mono,
            fontWeight = FontWeight.Medium,
            color = neon.accent,
            // Caps are single-line; never wrap or clip the label so the
            // first two (wide) keys stay fully legible.
            maxLines = 1,
            softWrap = false,
        )
    }
}
