package sh.nikhil.conduit.ui

import androidx.compose.ui.graphics.Color
import org.junit.Assert.assertEquals
import org.junit.Test
import sh.nikhil.conduit.ui.components.ConduitTaskStatus
import sh.nikhil.conduit.ui.components.headTruncated
import sh.nikhil.conduit.ui.components.resolveTaskBorderColor
import sh.nikhil.conduit.ui.components.resolveTaskStatusText
import sh.nikhil.conduit.ui.components.resolveTaskTint

/**
 * Pins the pure status -> tint/text/border resolution logic behind
 * [sh.nikhil.conduit.ui.components.ConduitTaskRow], plus the head-truncate
 * helper. No Compose runtime dependency, mirroring the pattern in
 * [ConduitComponentsLogicTest].
 */
class ConduitTaskRowLogicTest {

    private val yellow = Color(0xFFFFD24D)
    private val green = Color(0xFF3EF0A0)
    private val red = Color(0xFFFF5C72)
    private val lineSoft = Color(0x1EA0B8E0)

    // region tint

    @Test
    fun tint_running_isYellow() {
        assertEquals(yellow, resolveTaskTint(ConduitTaskStatus.Running, yellow, green, red))
    }

    @Test
    fun tint_gate_isYellow() {
        assertEquals(yellow, resolveTaskTint(ConduitTaskStatus.Gate, yellow, green, red))
    }

    @Test
    fun tint_done_isGreen() {
        assertEquals(green, resolveTaskTint(ConduitTaskStatus.Done, yellow, green, red))
    }

    @Test
    fun tint_error_isRed() {
        assertEquals(red, resolveTaskTint(ConduitTaskStatus.Error, yellow, green, red))
    }

    // endregion

    // region status text

    @Test
    fun statusText_running_returnsElapsed() {
        assertEquals("2m 13s", resolveTaskStatusText(ConduitTaskStatus.Running, "2m 13s"))
    }

    @Test
    fun statusText_running_nullElapsed_returnsEmpty() {
        assertEquals("", resolveTaskStatusText(ConduitTaskStatus.Running, null))
    }

    @Test
    fun statusText_gate_returnsElapsed() {
        assertEquals("6m 10s", resolveTaskStatusText(ConduitTaskStatus.Gate, "6m 10s"))
    }

    @Test
    fun statusText_done_returnsDone() {
        assertEquals("done", resolveTaskStatusText(ConduitTaskStatus.Done, "ignored"))
    }

    @Test
    fun statusText_error_returnsFailed() {
        assertEquals("failed", resolveTaskStatusText(ConduitTaskStatus.Error, "ignored"))
    }

    // endregion

    // region border color

    @Test
    fun border_running_isYellowAt20Percent() {
        assertEquals(yellow.copy(alpha = 0.20f), resolveTaskBorderColor(ConduitTaskStatus.Running, yellow, lineSoft))
    }

    @Test
    fun border_gate_isYellowAt20Percent() {
        assertEquals(yellow.copy(alpha = 0.20f), resolveTaskBorderColor(ConduitTaskStatus.Gate, yellow, lineSoft))
    }

    @Test
    fun border_done_isLineSoft() {
        assertEquals(lineSoft, resolveTaskBorderColor(ConduitTaskStatus.Done, yellow, lineSoft))
    }

    @Test
    fun border_error_isLineSoft() {
        assertEquals(lineSoft, resolveTaskBorderColor(ConduitTaskStatus.Error, yellow, lineSoft))
    }

    // endregion

    // region head truncation

    @Test
    fun headTruncated_shortString_isUnchanged() {
        assertEquals("short tail", headTruncated("short tail", maxChars = 46))
    }

    @Test
    fun headTruncated_longString_keepsEnd() {
        val input = "$ swift build --target ConduitApp -- 214/280 files compiled successfully"
        val result = headTruncated(input, maxChars = 30)
        assertEquals(30, result.length)
        assertEquals("...", result.take(3))
        assertEquals(input.takeLast(27), result.removePrefix("..."))
    }

    @Test
    fun headTruncated_exactlyMaxChars_isUnchanged() {
        val input = "0123456789"
        assertEquals(input, headTruncated(input, maxChars = 10))
    }

    // endregion

    @Test
    fun conduitTaskStatusEnumHasFourMembers() {
        assertEquals(4, ConduitTaskStatus.entries.size)
    }
}
