package sh.nikhil.swekitty

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import uniffi.swe_kitty_core.ConversationItem

/**
 * Pins the home-card latest-activity preview (iOS #238 parity). Pure
 * JUnit — [SessionNaming.activityPreview] is Compose- and core-type-free,
 * and [latestActivityPreviewOf] just picks the last non-user item. Mirror
 * of iOS `LitterHomeViewModelTests` activity-preview coverage.
 */
class ActivityPreviewTest {

    private fun item(
        role: String,
        content: String,
        kind: String = if (role.lowercase() == "tool") "tool" else "message",
        toolName: String? = null,
        command: String? = null,
        ts: String = "2026-05-25T18:00:00Z",
    ): ConversationItem = ConversationItem(
        id = "$ts-$role",
        role = role,
        kind = kind,
        status = "done",
        content = content,
        ts = ts,
        files = emptyList(),
        toolName = toolName,
        command = command,
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

    // ---------- activityPreview (pure string helper) ----------

    @Test
    fun toolWithCommandPrefersCommand() {
        val preview = SessionNaming.activityPreview(
            role = "tool",
            kind = "tool",
            toolName = "Bash",
            command = "cargo test --all",
            content = "exit 0",
        )
        assertEquals("Bash: cargo test --all", preview)
    }

    @Test
    fun toolWithoutCommandFallsBackToBodyWithToolPrefix() {
        val preview = SessionNaming.activityPreview(
            role = "tool",
            kind = "tool",
            toolName = "Read",
            command = null,
            content = "  opened src/main.rs  ",
        )
        assertEquals("Read: opened src/main.rs", preview)
    }

    @Test
    fun assistantUsesFirstNonEmptyBodyLine() {
        val preview = SessionNaming.activityPreview(
            role = "assistant",
            kind = "message",
            toolName = null,
            command = null,
            content = "\n\n  Here is the   plan  \nmore details",
        )
        assertEquals("Here is the plan", preview)
    }

    @Test
    fun overBudgetClips() {
        val long = "x".repeat(200)
        val preview = SessionNaming.activityPreview(
            role = "assistant",
            kind = "message",
            toolName = null,
            command = null,
            content = long,
            budget = 10,
        )
        assertEquals(10, preview!!.length)
        assertEquals("…", preview.takeLast(1))
    }

    @Test
    fun emptyBodyYieldsNull() {
        val preview = SessionNaming.activityPreview(
            role = "assistant",
            kind = "message",
            toolName = null,
            command = null,
            content = "   \n  ",
        )
        assertNull(preview)
    }

    // ---------- latestActivityPreviewOf (item selection) ----------

    @Test
    fun picksLatestNonUserItem() {
        val log = listOf(
            item(role = "user", content = "fix the bug"),
            item(role = "assistant", content = "looking into it"),
            item(role = "tool", toolName = "Bash", command = "go test ./...", content = "ok"),
            item(role = "user", content = "thanks"),
        )
        assertEquals("Bash: go test ./...", latestActivityPreviewOf(log))
    }

    @Test
    fun userOnlyTranscriptYieldsNull() {
        val log = listOf(item(role = "user", content = "hello"))
        assertNull(latestActivityPreviewOf(log))
    }

    @Test
    fun emptyOrNullLogYieldsNull() {
        assertNull(latestActivityPreviewOf(emptyList()))
        assertNull(latestActivityPreviewOf(null))
    }
}
