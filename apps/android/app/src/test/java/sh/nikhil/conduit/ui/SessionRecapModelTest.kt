package sh.nikhil.conduit.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import sh.nikhil.conduit.SessionLifecycle
import uniffi.conduit_core.ConversationItem
import uniffi.conduit_core.ViewEventFile

/**
 * Pins the pure recap derivation (handoff §B.9): the honest outcome chip,
 * the "what changed" priority ladder (agent prose → file paths → commit
 * count → empty), distinct-file ordering, wall-clock duration, and `fmtKLong`.
 * Mirror of iOS `ConduitSessionRecapTests`. Pure JUnit — no Compose/Android
 * runtime.
 */
class SessionRecapModelTest {

    private fun item(
        role: String = "tool",
        files: List<ViewEventFile> = emptyList(),
        command: String? = null,
        diffSummary: String? = null,
        taskText: String? = null,
        resultSummary: String? = null,
    ): ConversationItem = ConversationItem(
        id = "id",
        role = role,
        kind = if (role.lowercase() == "tool") "tool" else "message",
        status = "done",
        content = "",
        ts = "2026-06-05T10:00:00Z",
        files = files,
        toolName = null,
        command = command,
        exitCode = null,
        durationMs = null,
        diffSummary = diffSummary,
        pendingOptions = emptyList(),
        sourceAgent = null,
        targetAgent = null,
        taskText = taskText,
        resultSummary = resultSummary,
        planSteps = emptyList(),
    )

    // region Outcome

    @Test fun outcomeMergedWins() {
        assertEquals(RecapOutcome.MERGED, RecapModel.deriveOutcome(12, "merged", SessionLifecycle.Exited(0)))
    }

    @Test fun outcomeOpenPr() {
        assertEquals(RecapOutcome.PR, RecapModel.deriveOutcome(12, "open", null))
    }

    @Test fun outcomePrNumberWithoutState() {
        assertEquals(RecapOutcome.PR, RecapModel.deriveOutcome(7, null, null))
    }

    @Test fun outcomeFailedLifecycle() {
        assertEquals(RecapOutcome.FAILED, RecapModel.deriveOutcome(null, null, SessionLifecycle.FailedToStart("boom")))
    }

    @Test fun outcomeEndedLifecycle() {
        assertEquals(RecapOutcome.ENDED, RecapModel.deriveOutcome(null, null, SessionLifecycle.Exited(0)))
    }

    @Test fun outcomeNeutralWhenUnknown() {
        assertEquals(RecapOutcome.NEUTRAL, RecapModel.deriveOutcome(null, null, SessionLifecycle.Live))
        assertEquals(RecapOutcome.NEUTRAL, RecapModel.deriveOutcome(0, null, null))
    }

    // endregion

    // region What changed

    @Test fun whatChangedPrefersAgentProse() {
        val log = listOf(
            item(resultSummary = "Replaced the retry-less fetch with exponential backoff"),
            item(files = listOf(ViewEventFile("a.kt", "1"))),
        )
        val files = RecapModel.distinctFiles(log)
        assertEquals(
            listOf("Replaced the retry-less fetch with exponential backoff"),
            RecapModel.deriveWhatChanged(log, files, commits = 3),
        )
    }

    @Test fun whatChangedFirstLineOnlyAndDeduped() {
        val log = listOf(
            item(resultSummary = "Fixed auth\n\nlong details"),
            item(resultSummary = "Fixed auth"),
        )
        assertEquals(listOf("Fixed auth"), RecapModel.deriveWhatChanged(log, emptyList(), commits = 0))
    }

    @Test fun whatChangedFallsBackToFilePaths() {
        val log = listOf(item(files = listOf(ViewEventFile("src/a.rs", "1"), ViewEventFile("src/b.rs", "1"))))
        val files = RecapModel.distinctFiles(log)
        assertEquals(listOf("src/a.rs", "src/b.rs"), RecapModel.deriveWhatChanged(log, files, commits = 0))
    }

    @Test fun whatChangedFallsBackToCommitCount() {
        assertEquals(listOf("2 commits landed"), RecapModel.deriveWhatChanged(emptyList(), emptyList(), commits = 2))
    }

    @Test fun whatChangedEmptyWhenNoSignal() {
        assertTrue(RecapModel.deriveWhatChanged(emptyList(), emptyList(), commits = 0).isEmpty())
    }

    // endregion

    // region Distinct files / duration / fmt

    @Test fun distinctFilesOrderedAndDeduped() {
        val log = listOf(
            item(files = listOf(ViewEventFile("a", "1"), ViewEventFile("b", "1"))),
            item(files = listOf(ViewEventFile("a", "2"))),
        )
        assertEquals(listOf("a", "b"), RecapModel.distinctFiles(log))
    }

    @Test fun durationWallClock() {
        val start = java.time.Instant.parse("2026-06-05T10:00:00Z").toEpochMilli()
        val end = java.time.Instant.parse("2026-06-05T10:41:00Z").toEpochMilli()
        assertEquals("41m", RecapModel.durationLabel(start, end))
        assertEquals("1h 1m", RecapModel.durationLabel(start, start + 61L * 60_000L))
        assertNull(RecapModel.durationLabel(null, end))
    }

    @Test fun fmtK() {
        assertEquals("950", fmtKLong(950L))
        assertEquals("2k", fmtKLong(1_500L))
        assertEquals("2.0M", fmtKLong(2_000_000L))
    }

    // endregion
}
