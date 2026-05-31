package sh.nikhil.conduit.widget

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Android mirror of iOS Swift Testing suite for `TurnActivityModel`.
 *
 * The two platforms MUST agree on the start / update / end transition
 * rules — drift here shows up as one phone keeping a lock-screen card
 * alive after the agent moved on while the other phone cleared it
 * (or worse, vice versa).
 */
class TurnActivityModelTest {

    private fun item(
        id: String,
        kind: TurnActivityItem.Kind,
        toolName: String? = null,
        command: String? = null,
        status: String = "running",
        timestampMillis: Long,
    ) = TurnActivityItem(
        id = id,
        kind = kind,
        toolName = toolName,
        command = command,
        status = status,
        timestampMillis = timestampMillis,
    )

    @Test
    fun firstTool_emitsStart() {
        val model = TurnActivityModel()
        val effect = model.apply(
            item = item("a", TurnActivityItem.Kind.TOOL, toolName = "bash", timestampMillis = 1_000L),
            sessionID = "s1",
            agentName = "claude",
        )
        assertTrue("expected Start, got $effect", effect is TurnActivityEffect.Start)
        effect as TurnActivityEffect.Start
        assertEquals("claude", effect.attributes.agentName)
        assertEquals("s1", effect.attributes.sessionID)
        assertEquals("bash", effect.state.currentTool)
        assertTrue(model.isActive)
    }

    @Test
    fun firstMessage_isNoop() {
        val model = TurnActivityModel()
        val effect = model.apply(
            item = item("a", TurnActivityItem.Kind.MESSAGE, timestampMillis = 1_000L),
            sessionID = "s1",
            agentName = "claude",
        )
        assertEquals(TurnActivityEffect.Noop, effect)
        assertFalse(model.isActive)
    }

    @Test
    fun subsequentTool_emitsUpdate() {
        val model = TurnActivityModel()
        model.apply(item("a", TurnActivityItem.Kind.TOOL, toolName = "bash", timestampMillis = 1_000L), "s1", "claude")
        val effect = model.apply(
            item = item("b", TurnActivityItem.Kind.TOOL, toolName = "edit", timestampMillis = 2_000L),
            sessionID = "s1",
            agentName = "claude",
        )
        assertTrue("expected Update, got $effect", effect is TurnActivityEffect.Update)
        effect as TurnActivityEffect.Update
        assertEquals("edit", effect.state.currentTool)
    }

    @Test
    fun command_alsoDrivesStart() {
        val model = TurnActivityModel()
        val effect = model.apply(
            item = item("a", TurnActivityItem.Kind.COMMAND, command = "ls -la", timestampMillis = 1_000L),
            sessionID = "s1",
            agentName = "codex",
        )
        assertTrue(effect is TurnActivityEffect.Start)
        effect as TurnActivityEffect.Start
        assertEquals("ls -la", effect.state.currentCommand)
    }

    @Test
    fun exitItem_endsActivity() {
        val model = TurnActivityModel()
        model.apply(item("a", TurnActivityItem.Kind.TOOL, toolName = "bash", timestampMillis = 1_000L), "s1", "claude")
        val effect = model.apply(
            item = item("z", TurnActivityItem.Kind.EXIT, timestampMillis = 2_000L),
            sessionID = "s1",
            agentName = "claude",
        )
        assertTrue("expected End, got $effect", effect is TurnActivityEffect.End)
        effect as TurnActivityEffect.End
        assertEquals("exited", effect.state.status)
        assertFalse(model.isActive)
    }

    @Test
    fun statusExitedOnActiveItem_endsActivity() {
        val model = TurnActivityModel()
        model.apply(item("a", TurnActivityItem.Kind.TOOL, toolName = "bash", timestampMillis = 1_000L), "s1", "claude")
        val effect = model.apply(
            item = item("b", TurnActivityItem.Kind.TOOL, toolName = "edit", status = "exited", timestampMillis = 2_000L),
            sessionID = "s1",
            agentName = "claude",
        )
        assertTrue("expected End, got $effect", effect is TurnActivityEffect.End)
    }

    @Test
    fun tickBeforeIdleTimeout_isNoop() {
        val model = TurnActivityModel()
        model.apply(item("a", TurnActivityItem.Kind.TOOL, toolName = "bash", timestampMillis = 1_000L), "s1", "claude")
        // 2s after — well under the 5s default.
        assertEquals(TurnActivityEffect.Noop, model.tick(3_000L))
        assertTrue(model.isActive)
    }

    @Test
    fun tickPastIdleTimeout_emitsEnd() {
        val model = TurnActivityModel()
        model.apply(item("a", TurnActivityItem.Kind.TOOL, toolName = "bash", timestampMillis = 1_000L), "s1", "claude")
        val effect = model.tick(10_000L) // 9 s after last tool
        assertTrue("expected End, got $effect", effect is TurnActivityEffect.End)
        assertFalse(model.isActive)
    }

    @Test
    fun tickWhenInactive_isNoop() {
        val model = TurnActivityModel()
        // Never applied a tool item — no `lastActivityAt`.
        assertEquals(TurnActivityEffect.Noop, model.tick(System.currentTimeMillis()))
    }

    @Test
    fun sessionExited_endsIdempotently() {
        val model = TurnActivityModel()
        model.apply(item("a", TurnActivityItem.Kind.TOOL, toolName = "bash", timestampMillis = 1_000L), "s1", "claude")
        val first = model.sessionExited(nowMillis = 1_500L)
        val second = model.sessionExited(nowMillis = 1_500L)
        assertTrue("first call should End", first is TurnActivityEffect.End)
        assertEquals("second call should noop", TurnActivityEffect.Noop, second)
    }

    @Test
    fun updateTokens_emitsUpdate() {
        val model = TurnActivityModel()
        model.apply(item("a", TurnActivityItem.Kind.TOOL, toolName = "bash", timestampMillis = 1_000L), "s1", "claude")
        val effect = model.updateTokens(tokensIn = 42, tokensOut = 100)
        assertTrue(effect is TurnActivityEffect.Update)
        effect as TurnActivityEffect.Update
        assertEquals(42, effect.state.tokensIn)
        assertEquals(100, effect.state.tokensOut)
        assertNotNull(model.contentState)
        assertEquals(42, model.contentState?.tokensIn)
    }

    @Test
    fun updateTokensWhenInactive_isNoop() {
        val model = TurnActivityModel()
        assertEquals(TurnActivityEffect.Noop, model.updateTokens(42, 100))
        assertNull(model.contentState)
    }

    @Test
    fun defaultIdleTimeoutMatchesIOS() {
        // 5 seconds — iOS uses 5.0 TimeInterval. If either platform
        // drifts to a different value, the lock-screen card lingers
        // (or vanishes) at a different point in the conversation.
        assertEquals(5_000L, TurnActivityModel.DEFAULT_IDLE_TIMEOUT_MILLIS)
    }
}
