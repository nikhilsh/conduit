package sh.nikhil.conduit.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import sh.nikhil.conduit.SubagentEntry
import sh.nikhil.conduit.ui.components.ConduitTaskStatus

/**
 * Pins the pure roster -> row mapping/grouping/formatting logic behind
 * [TasksSheet], mirroring the [ConduitRunningPillLogicTest] pattern. No
 * Compose runtime dependency.
 */
class TasksSheetLogicTest {

    private fun entry(
        taskId: String = "t1",
        name: String = "Task",
        description: String = "",
        status: String = "working",
        lastTool: String = "",
        durationMs: Long = 0L,
        startedAt: String = "",
        endedAt: String = "",
    ) = SubagentEntry(
        taskId = taskId,
        name = name,
        description = description,
        status = status,
        lastTool = lastTool,
        tokens = 0L,
        toolUses = 0,
        durationMs = durationMs,
        startedAt = startedAt,
        endedAt = endedAt,
    )

    // region statusFromRaw

    @Test
    fun statusFromRaw_working_isRunning() {
        assertEquals(ConduitTaskStatus.Running, TasksSheetLogic.statusFromRaw("working"))
    }

    @Test
    fun statusFromRaw_done_isDone() {
        assertEquals(ConduitTaskStatus.Done, TasksSheetLogic.statusFromRaw("done"))
    }

    @Test
    fun statusFromRaw_failed_isError() {
        assertEquals(ConduitTaskStatus.Error, TasksSheetLogic.statusFromRaw("failed"))
    }

    @Test
    fun statusFromRaw_gate_isGate() {
        assertEquals(ConduitTaskStatus.Gate, TasksSheetLogic.statusFromRaw("gate"))
    }

    @Test
    fun statusFromRaw_unknown_fallsBackToRunning() {
        assertEquals(ConduitTaskStatus.Running, TasksSheetLogic.statusFromRaw("something-new"))
    }

    // endregion

    // region elapsedLabel / finishedDurationLabel

    @Test
    fun elapsedLabel_zeroPadsSeconds() {
        assertEquals("4m 02s", TasksSheetLogic.elapsedLabel(242))
    }

    @Test
    fun elapsedLabel_underAMinute() {
        assertEquals("0m 31s", TasksSheetLogic.elapsedLabel(31))
    }

    @Test
    fun finishedDurationLabel_minutesOnly() {
        assertEquals("12m", TasksSheetLogic.finishedDurationLabel(12 * 60 * 1000L))
    }

    @Test
    fun finishedDurationLabel_underAMinute() {
        assertEquals("45s", TasksSheetLogic.finishedDurationLabel(45 * 1000L))
    }

    @Test
    fun finishedDurationLabel_hoursAndMinutes() {
        assertEquals("1h 5m", TasksSheetLogic.finishedDurationLabel((65 * 60 * 1000).toLong()))
    }

    @Test
    fun finishedDurationLabel_exactHour_dropsZeroMinutes() {
        assertEquals("1h", TasksSheetLogic.finishedDurationLabel((60 * 60 * 1000).toLong()))
    }

    // endregion

    // region metaFor

    @Test
    fun metaFor_running_withTool() {
        val meta = TasksSheetLogic.metaFor(
            entry(status = "working", lastTool = "swift build"),
            ConduitTaskStatus.Running,
            elapsedSeconds = 242,
        )
        assertEquals("4m 02s · swift build", meta)
    }

    @Test
    fun metaFor_running_noTool_elapsedOnly() {
        val meta = TasksSheetLogic.metaFor(
            entry(status = "working"),
            ConduitTaskStatus.Running,
            elapsedSeconds = 133,
        )
        assertEquals("2m 13s", meta)
    }

    @Test
    fun metaFor_gate_usesDescription() {
        val meta = TasksSheetLogic.metaFor(
            entry(status = "gate", description = "waiting on your review"),
            ConduitTaskStatus.Gate,
            elapsedSeconds = 0,
        )
        assertEquals("waiting on your review", meta)
    }

    @Test
    fun metaFor_gate_blankDescription_fallsBackToDefault() {
        val meta = TasksSheetLogic.metaFor(
            entry(status = "gate", description = ""),
            ConduitTaskStatus.Gate,
            elapsedSeconds = 0,
        )
        assertEquals("gate - review before merge", meta)
    }

    @Test
    fun metaFor_done_showsCompletedDuration() {
        val meta = TasksSheetLogic.metaFor(
            entry(status = "done", durationMs = 12 * 60 * 1000L),
            ConduitTaskStatus.Done,
            elapsedSeconds = null,
        )
        assertEquals("completed · 12m", meta)
    }

    @Test
    fun metaFor_error_showsFailedDuration() {
        val meta = TasksSheetLogic.metaFor(
            entry(status = "failed", durationMs = 45 * 1000L),
            ConduitTaskStatus.Error,
            elapsedSeconds = null,
        )
        assertEquals("failed · 45s", meta)
    }

    // endregion

    // region groups -- mapping, grouping, ordering, canStop

    @Test
    fun groups_emptyRoster_isEmpty() {
        val groups = TasksSheetLogic.groups(emptyList(), sessionAgent = "claude")
        assertTrue(groups.isEmpty)
    }

    @Test
    fun groups_realEntries_neverCanStop() {
        val groups = TasksSheetLogic.groups(
            listOf(entry(status = "working")),
            sessionAgent = "claude",
        )
        assertFalse(groups.running.single().canStop)
    }

    @Test
    fun groups_partitionsByStatus() {
        val roster = listOf(
            entry(taskId = "g1", status = "gate"),
            entry(taskId = "r1", status = "working"),
            entry(taskId = "d1", status = "done"),
            entry(taskId = "e1", status = "failed"),
        )
        val groups = TasksSheetLogic.groups(roster, sessionAgent = "codex")
        assertEquals(listOf("g1"), groups.needsYou.map { it.id })
        assertEquals(listOf("r1"), groups.running.map { it.id })
        assertEquals(setOf("d1", "e1"), groups.finished.map { it.id }.toSet())
    }

    @Test
    fun groups_running_sortedNewestStartedFirst() {
        val roster = listOf(
            entry(taskId = "old", status = "working", startedAt = "2026-01-01T00:00:00Z"),
            entry(taskId = "new", status = "working", startedAt = "2026-01-02T00:00:00Z"),
        )
        val groups = TasksSheetLogic.groups(roster, sessionAgent = "claude")
        assertEquals(listOf("new", "old"), groups.running.map { it.id })
    }

    @Test
    fun groups_finished_sortedNewestEndedFirst() {
        val roster = listOf(
            entry(taskId = "old", status = "done", endedAt = "2026-01-01T00:00:00Z"),
            entry(taskId = "new", status = "done", endedAt = "2026-01-02T00:00:00Z"),
        )
        val groups = TasksSheetLogic.groups(roster, sessionAgent = "claude")
        assertEquals(listOf("new", "old"), groups.finished.map { it.id })
    }

    @Test
    fun groups_titleFallsBackToDescriptionThenTask() {
        val roster = listOf(
            entry(taskId = "named", name = "PR A", status = "done"),
            entry(taskId = "described", name = "", description = "does a thing", status = "done"),
            entry(taskId = "bare", name = "", description = "", status = "done"),
        )
        val groups = TasksSheetLogic.groups(roster, sessionAgent = "claude")
        val byId = groups.finished.associateBy { it.id }
        assertEquals("PR A", byId.getValue("named").title)
        assertEquals("does a thing", byId.getValue("described").title)
        assertEquals("Task", byId.getValue("bare").title)
    }

    @Test
    fun groups_usesSessionAgentForAllRows() {
        val roster = listOf(entry(status = "working"), entry(taskId = "t2", status = "done"))
        val groups = TasksSheetLogic.groups(roster, sessionAgent = "opencode")
        assertTrue((groups.running + groups.finished).all { it.agent == "opencode" })
    }

    // endregion
}
