package sh.nikhil.conduit.widget

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Android mirror of the iOS `TurnLiveActivityBridgeCore` behaviour. The
 * two platforms MUST agree on the multi-session start/observe/end edges
 * so a turn that closes on one phone closes on the other.
 */
class TurnActivityBridgeCoreTest {

    private fun item(
        id: String,
        kind: TurnActivityItem.Kind,
        toolName: String? = null,
        ts: Long,
    ) = TurnActivityItem(id = id, kind = kind, toolName = toolName, timestampMillis = ts)

    private fun frame(
        sessionID: String = "s1",
        agentName: String = "claude",
        phase: String? = "running",
        conversation: List<TurnActivityItem>,
    ) = TurnActivityFrame(listOf(TurnActivityFrame.Session(sessionID, agentName, phase, conversation)))

    private fun observes(intents: List<TurnActivityIntent>) =
        intents.filterIsInstance<TurnActivityIntent.Observe>()

    private fun ends(intents: List<TurnActivityIntent>) =
        intents.filterIsInstance<TurnActivityIntent.End>()

    @Test
    fun firstTool_emitsObserveAndTrailingTick() {
        val core = TurnActivityBridgeCore()
        val intents = core.ingest(
            frame(conversation = listOf(item("a", TurnActivityItem.Kind.TOOL, "bash", 1_000L))),
            nowMillis = 1_000L,
        )
        assertEquals(1, observes(intents).size)
        assertEquals("a", observes(intents).first().item.id)
        assertTrue("every ingest ends with a Tick", intents.last() is TurnActivityIntent.Tick)
    }

    @Test
    fun cursorAdvances_secondFrameOnlyEmitsNewItems() {
        val core = TurnActivityBridgeCore()
        core.ingest(frame(conversation = listOf(item("a", TurnActivityItem.Kind.TOOL, ts = 1_000L))), 1_000L)
        val second = core.ingest(
            frame(
                conversation = listOf(
                    item("a", TurnActivityItem.Kind.TOOL, ts = 1_000L),
                    item("b", TurnActivityItem.Kind.COMMAND, ts = 2_000L),
                ),
            ),
            nowMillis = 2_000L,
        )
        // Only "b" is new — "a" must not replay.
        assertEquals(listOf("b"), observes(second).map { it.item.id })
    }

    @Test
    fun messageRows_doNotSurface() {
        val core = TurnActivityBridgeCore()
        val intents = core.ingest(
            frame(conversation = listOf(item("m", TurnActivityItem.Kind.MESSAGE, ts = 1_000L))),
            nowMillis = 1_000L,
        )
        assertTrue(observes(intents).isEmpty())
        assertTrue(ends(intents).isEmpty())
    }

    @Test
    fun exitItem_emitsEndOnce() {
        val core = TurnActivityBridgeCore()
        core.ingest(frame(conversation = listOf(item("a", TurnActivityItem.Kind.TOOL, ts = 1_000L))), 1_000L)
        val intents = core.ingest(
            frame(
                conversation = listOf(
                    item("a", TurnActivityItem.Kind.TOOL, ts = 1_000L),
                    item("x", TurnActivityItem.Kind.EXIT, ts = 2_000L),
                ),
            ),
            nowMillis = 2_000L,
        )
        assertEquals(1, ends(intents).size)
        assertEquals("s1", ends(intents).first().sessionID)
    }

    @Test
    fun exitedPhase_emitsEndOnceOnTheEdge() {
        val core = TurnActivityBridgeCore()
        core.ingest(frame(conversation = listOf(item("a", TurnActivityItem.Kind.TOOL, ts = 1_000L))), 1_000L)
        val first = core.ingest(frame(phase = "exited(0)", conversation = emptyList()), 1_500L)
        assertEquals(1, ends(first).size)
        // Same exited phase again must not re-emit End.
        val second = core.ingest(frame(phase = "exited(0)", conversation = emptyList()), 1_600L)
        assertTrue(ends(second).isEmpty())
    }

    @Test
    fun idleTimeout_emitsEndAfterWindow() {
        val core = TurnActivityBridgeCore(idleTimeoutMillis = 5_000L)
        core.ingest(frame(conversation = listOf(item("a", TurnActivityItem.Kind.TOOL, ts = 1_000L))), 1_000L)
        // No new item; 5s later the idle sweep ends the session.
        val intents = core.ingest(frame(conversation = listOf(item("a", TurnActivityItem.Kind.TOOL, ts = 1_000L))), 6_000L)
        assertEquals(1, ends(intents).size)
    }

    @Test
    fun freshToolAfterEnd_reopens() {
        val core = TurnActivityBridgeCore(idleTimeoutMillis = 5_000L)
        core.ingest(frame(conversation = listOf(item("a", TurnActivityItem.Kind.TOOL, ts = 1_000L))), 1_000L)
        core.ingest(frame(conversation = listOf(item("a", TurnActivityItem.Kind.TOOL, ts = 1_000L))), 6_000L) // ended
        val reopen = core.ingest(
            frame(
                conversation = listOf(
                    item("a", TurnActivityItem.Kind.TOOL, ts = 1_000L),
                    item("b", TurnActivityItem.Kind.TOOL, ts = 7_000L),
                ),
            ),
            nowMillis = 7_000L,
        )
        assertEquals(listOf("b"), observes(reopen).map { it.item.id })
        // The fresh tool cleared the ended flag, so no spurious End fires.
        assertTrue(ends(reopen).isEmpty())
    }

    @Test
    fun emptyFirstFrame_doesNotReplayPrefixLater() {
        val core = TurnActivityBridgeCore()
        core.ingest(frame(conversation = emptyList()), 1_000L)
        val intents = core.ingest(
            frame(conversation = listOf(item("a", TurnActivityItem.Kind.TOOL, ts = 2_000L))),
            nowMillis = 2_000L,
        )
        assertEquals(listOf("a"), observes(intents).map { it.item.id })
    }
}
