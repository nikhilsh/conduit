package sh.nikhil.conduit.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import uniffi.conduit_core.ConversationItem

/**
 * Pure-logic unit tests for the §10 / §10b command-run Mono block helpers
 * and the groupChatUnits monoBlock parameter. Runs under plain JUnit --
 * all tested functions are top-level internal with no Compose dependency.
 */
class CommandRunBlockTest {

    // ── Helpers ──────────────────────────────────────────────────────────

    private fun item(
        role: String = "tool",
        status: String = "done",
        exitCode: Int? = null,
        durationMs: ULong? = null,
        command: String? = null,
        toolName: String? = null,
        content: String = "",
    ): ConversationItem = ConversationItem(
        id = java.util.UUID.randomUUID().toString(),
        role = role,
        kind = if (role.lowercase() == "tool") "tool" else "message",
        status = status,
        content = content,
        ts = "2026-06-22T00:00:00Z",
        files = emptyList(),
        toolName = toolName,
        command = command,
        exitCode = exitCode,
        durationMs = durationMs,
        diffSummary = null,
        pendingOptions = emptyList(),
        sourceAgent = null,
        targetAgent = null,
        taskText = null,
        resultSummary = null,
        planSteps = emptyList(),
    )

    // ── clusterFailCount ─────────────────────────────────────────────────

    @Test fun failCount_allPassed() {
        val items = listOf(
            item(status = "done", exitCode = 0),
            item(status = "done", exitCode = 0),
        )
        assertEquals(0, clusterFailCount(items))
    }

    @Test fun failCount_statusFailed() {
        val items = listOf(
            item(status = "failed"),
            item(status = "done", exitCode = 0),
        )
        assertEquals(1, clusterFailCount(items))
    }

    @Test fun failCount_nonzeroExit() {
        val items = listOf(
            item(status = "done", exitCode = 127),
            item(status = "done", exitCode = 0),
        )
        assertEquals(1, clusterFailCount(items))
    }

    @Test fun failCount_multipleFailures() {
        val items = listOf(
            item(status = "done", exitCode = 1),
            item(status = "failed"),
            item(status = "done", exitCode = 0),
        )
        assertEquals(2, clusterFailCount(items))
    }

    @Test fun failCount_empty() {
        assertEquals(0, clusterFailCount(emptyList()))
    }

    // ── clusterFailedRows ────────────────────────────────────────────────

    @Test fun failedRows_empty_whenAllPass() {
        val items = listOf(
            item(status = "done", exitCode = 0),
            item(status = "done", exitCode = 0),
        )
        assertTrue(clusterFailedRows(items).isEmpty())
    }

    @Test fun failedRows_returnsOnlyFailed() {
        val pass = item(status = "done", exitCode = 0, command = "ls")
        val fail = item(status = "done", exitCode = 1, command = "bad")
        val items = listOf(pass, fail)
        val failed = clusterFailedRows(items)
        assertEquals(1, failed.size)
        assertEquals("bad", failed[0].command)
    }

    @Test fun failedRows_includesStatusFailed() {
        val a = item(status = "failed", command = "cmd-a")
        val b = item(status = "done", exitCode = 0, command = "cmd-b")
        val failed = clusterFailedRows(listOf(a, b))
        assertEquals(1, failed.size)
        assertEquals("cmd-a", failed[0].command)
    }

    // ── clusterTickerFraction ────────────────────────────────────────────

    @Test fun tickerFraction_allRunning() {
        val items = listOf(
            item(status = "running"),
            item(status = "pending"),
        )
        assertEquals(0f, clusterTickerFraction(items), 0.001f)
    }

    @Test fun tickerFraction_halfDone() {
        val items = listOf(
            item(status = "done"),
            item(status = "running"),
        )
        assertEquals(0.5f, clusterTickerFraction(items), 0.001f)
    }

    @Test fun tickerFraction_allDone() {
        val items = listOf(
            item(status = "done"),
            item(status = "done"),
        )
        assertEquals(1f, clusterTickerFraction(items), 0.001f)
    }

    @Test fun tickerFraction_empty() {
        assertEquals(0f, clusterTickerFraction(emptyList()), 0.001f)
    }

    @Test fun tickerFraction_clamped() {
        // Edge: status is blank (should not count as done).
        val items = listOf(item(status = ""))
        assertEquals(0f, clusterTickerFraction(items), 0.001f)
    }

    // ── clusterAnyRunning ────────────────────────────────────────────────

    @Test fun anyRunning_trueWhenRunning() {
        val items = listOf(item(status = "running"), item(status = "done"))
        assertTrue(clusterAnyRunning(items))
    }

    @Test fun anyRunning_trueWhenPending() {
        val items = listOf(item(status = "pending"), item(status = "done"))
        assertTrue(clusterAnyRunning(items))
    }

    @Test fun anyRunning_falseWhenAllDone() {
        val items = listOf(item(status = "done"), item(status = "done"))
        assertFalse(clusterAnyRunning(items))
    }

    @Test fun anyRunning_falseWhenEmpty() {
        assertFalse(clusterAnyRunning(emptyList()))
    }

    // ── collapse threshold ───────────────────────────────────────────────

    @Test fun collapseThreshold_value() {
        // The threshold must be 9: counts 1-9 stay inline, counts >= 10 collapse.
        assertEquals(9, MONO_COLLAPSE_THRESHOLD)
    }

    @Test fun collapseThreshold_nineStaysInline() {
        // 9 items: count <= 9 -> inline (no collapse).
        assertTrue(9 <= MONO_COLLAPSE_THRESHOLD)
    }

    @Test fun collapseThreshold_tenCollapses() {
        // 10 items: count > 9 -> collapse ledger.
        assertTrue(10 > MONO_COLLAPSE_THRESHOLD)
    }

    // ── groupChatUnits with monoBlock=true ───────────────────────────────

    @Test fun groupChatUnits_monoBlock_loneTool_collapses() {
        // monoBlock=true: even a lone tool event must cluster into ToolCluster.
        val units = groupChatUnits(
            roles = listOf("user", "tool", "assistant"),
            signature = true,
            hideCommands = false,
            monoBlock = true,
        )
        assertEquals(3, units.size)
        assertTrue(units[0] is ChatRenderUnit.Single)
        assertTrue(units[1] is ChatRenderUnit.ToolCluster)
        assertEquals(1, (units[1] as ChatRenderUnit.ToolCluster).indices.size)
        assertTrue(units[2] is ChatRenderUnit.Single)
    }

    @Test fun groupChatUnits_monoBlock_multiTool_collapses() {
        val units = groupChatUnits(
            roles = listOf("tool", "tool", "tool"),
            signature = true,
            monoBlock = true,
        )
        assertEquals(1, units.size)
        val cluster = units[0] as ChatRenderUnit.ToolCluster
        assertEquals(3, cluster.indices.size)
    }

    @Test fun groupChatUnits_monoBlock_false_loneTool_staysInline() {
        // monoBlock=false, hideCommands=false, signature=true (arm B):
        // a lone tool stays inline (not clustered).
        val units = groupChatUnits(
            roles = listOf("tool"),
            signature = true,
            hideCommands = false,
            monoBlock = false,
        )
        assertEquals(1, units.size)
        assertTrue(units[0] is ChatRenderUnit.Single)
    }

    @Test fun groupChatUnits_monoBlock_false_armA_noClustering() {
        // monoBlock=false, signature=false (arm A): all events stay inline.
        val units = groupChatUnits(
            roles = listOf("tool", "tool", "user"),
            signature = false,
            monoBlock = false,
        )
        assertEquals(3, units.size)
        assertTrue(units.all { it is ChatRenderUnit.Single })
    }

    @Test fun groupChatUnits_monoBlock_independentOfHideCommands() {
        // monoBlock=true overrides even when hideCommands=false:
        // lone tool must cluster.
        val units = groupChatUnits(
            roles = listOf("tool"),
            signature = false,
            hideCommands = false,
            monoBlock = true,
        )
        assertEquals(1, units.size)
        assertTrue(units[0] is ChatRenderUnit.ToolCluster)
    }
}
