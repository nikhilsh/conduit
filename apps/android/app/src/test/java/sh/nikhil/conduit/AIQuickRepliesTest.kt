package sh.nikhil.conduit

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * Android mirror of `apps/ios/Tests/ConduitTests/AIQuickRepliesTests.swift`
 * (task #233). Pins the decode of the core's flattened `quick_replies`
 * `onViewEvent` payload (`replies` = JSON-array string, `for_message_id`
 * plain) the chat composer renders as chips. Runs under Robolectric so
 * `org.json.JSONArray` is the real implementation, not the throwing stub.
 */
@RunWith(RobolectricTestRunner::class)
class AIQuickRepliesTest {

    @Test
    fun decodesRepliesAndMessageId() {
        val qr = AIQuickReplies.from(
            mapOf(
                "replies" to """["Yes, go ahead","No","Tell me more"]""",
                "for_message_id" to "msg-7",
            ),
        )
        assertEquals(listOf("Yes, go ahead", "No", "Tell me more"), qr?.replies)
        assertEquals("msg-7", qr?.forMessageId)
    }

    @Test
    fun trimsEmptiesAndCapsAtFour() {
        val qr = AIQuickReplies.from(
            mapOf("replies" to """["  Run it  ","","A","B","C","D","E"]"""),
        )
        assertEquals(listOf("Run it", "A", "B", "C"), qr?.replies)
        assertEquals("", qr?.forMessageId)
    }

    @Test
    fun returnsNullOnUnusablePayload() {
        assertNull(AIQuickReplies.from(emptyMap()))
        assertNull(AIQuickReplies.from(mapOf("replies" to "[]")))
        assertNull(AIQuickReplies.from(mapOf("replies" to "not json")))
        assertNull(AIQuickReplies.from(mapOf("replies" to """["   ",""]""")))
    }
}
