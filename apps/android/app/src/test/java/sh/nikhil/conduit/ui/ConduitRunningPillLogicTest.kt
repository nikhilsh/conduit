package sh.nikhil.conduit.ui

import org.junit.Assert.assertEquals
import org.junit.Test
import sh.nikhil.conduit.ui.components.runningPillLabel
import sh.nikhil.conduit.ui.components.runningTaskCount

/**
 * Pins the pure label + roster-counting logic behind
 * [sh.nikhil.conduit.ui.components.ConduitRunningPill]. No Compose runtime
 * dependency, mirroring the pattern in [ConduitTaskRowLogicTest].
 */
class ConduitRunningPillLogicTest {

    // region label

    @Test
    fun label_oneRunning_singular() {
        assertEquals("1 running task", runningPillLabel(runningCount = 1, gatedCount = 0))
    }

    @Test
    fun label_multipleRunning_plural() {
        assertEquals("3 running tasks", runningPillLabel(runningCount = 3, gatedCount = 0))
    }

    @Test
    fun label_gated_showsNeedsYou() {
        assertEquals("2 running · 1 needs you", runningPillLabel(runningCount = 2, gatedCount = 1))
    }

    @Test
    fun label_gatedWithZeroRunning_stillShowsNeedsYou() {
        assertEquals("0 running · 1 needs you", runningPillLabel(runningCount = 0, gatedCount = 1))
    }

    // endregion

    // region roster counting

    @Test
    fun runningTaskCount_countsOnlyWorking() {
        assertEquals(2, runningTaskCount(listOf("working", "done", "working", "failed")))
    }

    @Test
    fun runningTaskCount_emptyRoster_isZero() {
        assertEquals(0, runningTaskCount(emptyList()))
    }

    @Test
    fun runningTaskCount_noneWorking_isZero() {
        assertEquals(0, runningTaskCount(listOf("done", "failed")))
    }

    // endregion
}
