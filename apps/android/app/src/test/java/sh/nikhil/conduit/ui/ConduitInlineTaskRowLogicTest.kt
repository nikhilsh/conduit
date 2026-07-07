package sh.nikhil.conduit.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import sh.nikhil.conduit.SubagentEntry
import sh.nikhil.conduit.tsEpochMillis
import sh.nikhil.conduit.ui.components.ConduitTaskStatus
import uniffi.conduit_core.ConversationItem

/**
 * Pins [ConduitInlineTaskLogic] (design handoff session_tasks PR4): the
 * transcript's `kind == "subagent"` event has no shared id with a live
 * [SubagentEntry], so these tests exercise the name/description +
 * nearest-timestamp fallback match, and the static last-resort mapping
 * when nothing in the roster matches. Mirrors the iOS
 * `ConduitInlineTaskRowLogicTests` precedent.
 */
class ConduitInlineTaskRowLogicTest {

    private fun item(
        content: String,
        status: String = "done",
        ts: String = "2026-07-01T10:00:10Z",
    ): ConversationItem = ConversationItem(
        id = java.util.UUID.randomUUID().toString(),
        role = "system",
        kind = "subagent",
        status = status,
        content = content,
        ts = ts,
        files = emptyList(),
        toolName = null,
        command = null,
        exitCode = null,
        durationMs = null,
        diffSummary = null,
        pendingOptions = emptyList(),
        sourceAgent = null,
        targetAgent = null,
        taskText = null,
        resultSummary = null,
        planSteps = emptyList(),
    )

    private fun entry(
        taskId: String = "t1",
        name: String = "",
        description: String = "",
        status: String = "working",
        lastTool: String = "",
        startedAt: String = "2026-07-01T10:00:00Z",
        endedAt: String = "",
    ): SubagentEntry = SubagentEntry(
        taskId = taskId,
        name = name,
        description = description,
        status = status,
        lastTool = lastTool,
        tokens = 0,
        toolUses = 0,
        durationMs = 0,
        startedAt = startedAt,
        endedAt = endedAt,
    )

    // region extractedTitle

    @Test
    fun extractsTitleAfterSubagentStartedPrefix() {
        assertEquals(
            "investigating the build failure",
            ConduitInlineTaskLogic.extractedTitle("subagent started: investigating the build failure"),
        )
    }

    @Test
    fun extractsTitleAfterSpawningAgentPrefix() {
        assertEquals(
            "for parallel investigation",
            ConduitInlineTaskLogic.extractedTitle("Spawning agent for parallel investigation"),
        )
    }

    @Test
    fun extractsTitleAfterHyphenatedPrefix() {
        assertEquals("build broke", ConduitInlineTaskLogic.extractedTitle("sub-agent failed: build broke"))
    }

    @Test
    fun fallsBackToFirstLineWhenNoKnownPrefix() {
        assertEquals(
            "some other system text",
            ConduitInlineTaskLogic.extractedTitle("some other system text\nsecond line"),
        )
    }

    @Test
    fun fallsBackToPlaceholderForEmptyContent() {
        assertEquals("Subagent activity", ConduitInlineTaskLogic.extractedTitle("   "))
    }

    // endregion

    // region matchingRosterEntry

    @Test
    fun matchesByNameSubstring() {
        val roster = listOf(
            entry(taskId = "a", name = "ci-reviewer"),
            entry(taskId = "b", name = "build-fixer"),
        )
        val match = ConduitInlineTaskLogic.matchingRosterEntry(
            title = "build-fixer is investigating the build failure",
            eventTs = "2026-07-01T10:00:05Z",
            roster = roster,
        )
        assertEquals("b", match?.taskId)
    }

    @Test
    fun matchesByDescriptionSubstring() {
        val roster = listOf(entry(taskId = "a", description = "investigating the build failure"))
        val match = ConduitInlineTaskLogic.matchingRosterEntry(
            title = "investigating the build failure",
            eventTs = "2026-07-01T10:00:05Z",
            roster = roster,
        )
        assertEquals("a", match?.taskId)
    }

    @Test
    fun breaksTiesByNearestStartedAt() {
        val roster = listOf(
            entry(taskId = "far", name = "worker", startedAt = "2026-07-01T09:00:00Z"),
            entry(taskId = "near", name = "worker", startedAt = "2026-07-01T10:00:08Z"),
        )
        val match = ConduitInlineTaskLogic.matchingRosterEntry(
            title = "worker",
            eventTs = "2026-07-01T10:00:10Z",
            roster = roster,
        )
        assertEquals("near", match?.taskId)
    }

    @Test
    fun returnsNullForEmptyRoster() {
        assertNull(
            ConduitInlineTaskLogic.matchingRosterEntry(
                title = "anything",
                eventTs = "2026-07-01T10:00:10Z",
                roster = emptyList(),
            ),
        )
    }

    @Test
    fun fallsBackToFirstEntryWhenNoTextMatch() {
        val roster = listOf(entry(taskId = "only", name = "totally-unrelated-name"))
        val match = ConduitInlineTaskLogic.matchingRosterEntry(
            title = "investigating the build failure",
            eventTs = "2026-07-01T10:00:10Z",
            roster = roster,
        )
        assertEquals("only", match?.taskId)
    }

    // endregion

    // region rowModel

    @Test
    fun rowModelBindsLiveRunningEntryWithElapsedAndTail() {
        val startedAt = "2026-07-01T10:00:30Z"
        val roster = listOf(
            entry(
                taskId = "t1",
                name = "build-fixer",
                status = "working",
                lastTool = "swift build",
                startedAt = startedAt,
            ),
        )
        val ev = item(content = "subagent started: build-fixer", ts = startedAt)
        val nowMs = tsEpochMillis(startedAt) + 70_000
        val model = ConduitInlineTaskLogic.rowModel(ev, roster, nowMs)
        assertTrue(model.isLive)
        assertEquals(ConduitTaskStatus.Running, model.status)
        assertEquals("build-fixer", model.title)
        assertEquals("swift build", model.tail)
        assertEquals(TasksSheetLogic.elapsedLabel(70L), model.elapsed)
    }

    @Test
    fun rowModelBindsLiveDoneEntryWithNoElapsed() {
        val roster = listOf(entry(taskId = "t1", name = "build-fixer", status = "done"))
        val ev = item(content = "subagent done: build-fixer", status = "done")
        val model = ConduitInlineTaskLogic.rowModel(ev, roster, System.currentTimeMillis())
        assertTrue(model.isLive)
        assertEquals(ConduitTaskStatus.Done, model.status)
        assertNull(model.elapsed)
    }

    @Test
    fun rowModelFallsBackToStaticDoneWithNoRosterMatch() {
        val ev = item(content = "subagent started: orphaned task", status = "done")
        val model = ConduitInlineTaskLogic.rowModel(ev, emptyList(), System.currentTimeMillis())
        assertEquals(false, model.isLive)
        assertEquals(ConduitTaskStatus.Done, model.status)
        assertEquals("orphaned task", model.title)
        assertNull(model.elapsed)
    }

    @Test
    fun rowModelFallsBackToStaticErrorWhenEventStatusFailed() {
        val ev = item(content = "subagent failed: orphaned task", status = "failed")
        val model = ConduitInlineTaskLogic.rowModel(ev, emptyList(), System.currentTimeMillis())
        assertEquals(false, model.isLive)
        assertEquals(ConduitTaskStatus.Error, model.status)
    }

    @Test
    fun rowModelStaticTailUsesSecondContentLine() {
        val ev = item(content = "subagent started: orphaned task\n\$ swift build ... 214/280 files")
        val model = ConduitInlineTaskLogic.rowModel(ev, emptyList(), System.currentTimeMillis())
        assertEquals("\$ swift build ... 214/280 files", model.tail)
    }

    // endregion
}
