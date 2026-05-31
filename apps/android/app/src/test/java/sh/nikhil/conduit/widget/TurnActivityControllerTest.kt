package sh.nikhil.conduit.widget

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Verifies the controller routes per-session model effects to its sink
 * and stays idempotent on a re-emitted item — mirrors iOS
 * `TurnLiveActivityController`.
 */
class TurnActivityControllerTest {

    private sealed class Call {
        data class Start(val sessionID: String) : Call()
        data class Update(val sessionID: String) : Call()
        data class End(val sessionID: String) : Call()
    }

    private class RecordingSink : TurnActivitySink {
        val calls = mutableListOf<Call>()
        override fun onStart(attributes: TurnActivityAttributesData, state: TurnActivityContentState) {
            calls.add(Call.Start(attributes.sessionID))
        }
        override fun onUpdate(sessionID: String, state: TurnActivityContentState) {
            calls.add(Call.Update(sessionID))
        }
        override fun onEnd(sessionID: String, state: TurnActivityContentState) {
            calls.add(Call.End(sessionID))
        }
    }

    private fun tool(id: String, ts: Long, name: String = "bash") =
        TurnActivityItem(id = id, kind = TurnActivityItem.Kind.TOOL, toolName = name, timestampMillis = ts)

    @Test
    fun firstTool_startsThenSecondUpdates() {
        val sink = RecordingSink()
        val controller = TurnActivityController(sink)
        controller.observe(tool("a", 1_000L), "s1", "claude")
        controller.observe(tool("b", 2_000L), "s1", "claude")
        assertEquals(listOf(Call.Start("s1"), Call.Update("s1")), sink.calls)
    }

    @Test
    fun reEmittedItem_doesNotDuplicate() {
        val sink = RecordingSink()
        val controller = TurnActivityController(sink)
        controller.observe(tool("a", 1_000L), "s1", "claude")
        // Same id again — idempotent stream refresh, no second Start/Update.
        controller.observe(tool("a", 1_000L), "s1", "claude")
        assertEquals(listOf(Call.Start("s1")), sink.calls)
    }

    @Test
    fun sessionExited_endsActiveSession() {
        val sink = RecordingSink()
        val controller = TurnActivityController(sink)
        controller.observe(tool("a", 1_000L), "s1", "claude")
        controller.sessionExited("s1", nowMillis = 2_000L)
        assertEquals(listOf(Call.Start("s1"), Call.End("s1")), sink.calls)
    }

    @Test
    fun sessionExited_unknownSession_isNoop() {
        val sink = RecordingSink()
        val controller = TurnActivityController(sink)
        controller.sessionExited("ghost", nowMillis = 1_000L)
        assertTrue(sink.calls.isEmpty())
    }

    @Test
    fun applyIntents_routesBridgeOutput() {
        val sink = RecordingSink()
        val controller = TurnActivityController(sink)
        val intents = listOf(
            TurnActivityIntent.Observe("s1", "claude", tool("a", 1_000L)),
            TurnActivityIntent.Observe("s1", "claude", tool("b", 2_000L)),
            TurnActivityIntent.End("s1"),
            TurnActivityIntent.Tick,
        )
        controller.applyIntents(intents, nowMillis = 3_000L)
        assertEquals(listOf(Call.Start("s1"), Call.Update("s1"), Call.End("s1")), sink.calls)
    }
}
