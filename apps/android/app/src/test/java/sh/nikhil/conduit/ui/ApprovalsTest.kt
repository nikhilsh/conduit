package sh.nikhil.conduit.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import uniffi.conduit_core.ConversationItem

/**
 * Pins the pure Approvals queue + risk rules ([approvalQueue],
 * [approvalPrompt], [classifyApprovalRisk]). The Compose screen renders over
 * the queue, so these rules are what's load-bearing — and the inclusion gate
 * must stay identical to the Home needs-you banner ([isAwaitingInput]).
 * Mirror of iOS `ConduitApprovalsViewModelTests`.
 */
class ApprovalsTest {

    private fun item(
        role: String,
        kind: String,
        command: String? = null,
        content: String = "",
    ): ConversationItem = ConversationItem(
        id = "$role-$kind",
        role = role,
        kind = kind,
        status = "done",
        content = content,
        ts = "2026-06-05T18:00:00Z",
        files = emptyList(),
        toolName = null,
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

    private fun candidate(
        id: String,
        agent: String,
        branch: String?,
        log: List<ConversationItem>?,
    ) = ApprovalCandidate(id = id, title = "Session $id", agent = agent, branch = branch, conversation = log)

    @Test
    fun queueIncludesOnlyPendingInputSessions() {
        val queue = approvalQueue(
            listOf(
                candidate("s1", "claude", "fix/auth", listOf(item("assistant", "pending_input", command = "git push origin fix/auth"))),
                candidate("s2", "codex", null, listOf(item("assistant", "message", content = "done"))),
                candidate("s3", "claude", null, null),
            ),
        )
        assertEquals(1, queue.size)
        assertEquals("s1", queue[0].id)
        assertEquals("fix/auth", queue[0].branch)
        assertEquals("git push origin fix/auth", queue[0].prompt)
    }

    @Test
    fun userReplyAfterPromptClearsItFromQueue() {
        // Mirrors isAwaitingInput: a user item after the prompt means it's answered.
        val queue = approvalQueue(
            listOf(
                candidate("s1", "claude", null, listOf(item("assistant", "pending_input"), item("user", "message"))),
            ),
        )
        assertTrue(queue.isEmpty())
    }

    @Test
    fun promptFallsBackToContentThenGeneric() {
        assertEquals("Pick one:\n1. yes", approvalPrompt(null, "Pick one:\n1. yes"))
        assertEquals("Agent is waiting for your input", approvalPrompt("  ", "  "))
    }

    @Test
    fun riskDestructiveBeatsWrites() {
        assertEquals(ApprovalRisk.DESTRUCTIVE, classifyApprovalRisk("rm -rf node_modules && pnpm i", ""))
        assertEquals(ApprovalRisk.DESTRUCTIVE, classifyApprovalRisk("git push --force", ""))
    }

    @Test
    fun riskWritesFiles() {
        assertEquals(ApprovalRisk.WRITES_FILES, classifyApprovalRisk("git commit -m wip", ""))
        assertEquals(ApprovalRisk.WRITES_FILES, classifyApprovalRisk(null, "I'll write_file src/usage.ts"))
    }

    @Test
    fun riskDefaultsToSafe() {
        assertEquals(ApprovalRisk.SAFE, classifyApprovalRisk("ls -la", ""))
        assertEquals(ApprovalRisk.SAFE, classifyApprovalRisk(null, ""))
    }

    @Test
    fun riskIsCaseInsensitive() {
        assertEquals(ApprovalRisk.DESTRUCTIVE, classifyApprovalRisk("GIT PUSH --FORCE", ""))
    }
}
