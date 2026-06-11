package sh.nikhil.conduit

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * Unit tests for [SubagentEntry.listFrom] — the decoder for the
 * `view:"agents"` view_event payload the broker emits on every
 * task_* frame. Runs under Robolectric for the real `org.json`
 * implementation. Pins the exact JSON keys from the spec (task_id,
 * name, description, status, last_tool, tokens, tool_uses,
 * duration_ms, started_at, ended_at).
 */
@RunWith(RobolectricTestRunner::class)
class SubagentEntryDecodeTest {

    @Test
    fun decodesFullRosterSnapshot() {
        val payload = mapOf(
            "agents" to """
                [
                  {
                    "task_id": "a85166712f62b002d",
                    "name": "ci-reviewer",
                    "description": "Read a.txt contents",
                    "status": "working",
                    "last_tool": "Read",
                    "tokens": 10226,
                    "tool_uses": 1,
                    "duration_ms": 2843,
                    "started_at": "2026-06-11T10:00:00Z",
                    "ended_at": ""
                  }
                ]
            """.trimIndent(),
        )
        val entries = SubagentEntry.listFrom(payload)
        assertEquals(1, entries.size)
        val e = entries[0]
        assertEquals("a85166712f62b002d", e.taskId)
        assertEquals("ci-reviewer", e.name)
        assertEquals("Read a.txt contents", e.description)
        assertEquals("working", e.status)
        assertEquals("Read", e.lastTool)
        assertEquals(10226L, e.tokens)
        assertEquals(1, e.toolUses)
        assertEquals(2843L, e.durationMs)
        assertEquals("2026-06-11T10:00:00Z", e.startedAt)
        assertEquals("", e.endedAt)
    }

    @Test
    fun decodesMultipleEntriesWithVariedStatuses() {
        val payload = mapOf(
            "agents" to """
                [
                  {
                    "task_id": "id1",
                    "name": "planner",
                    "description": "Plan the work",
                    "status": "done",
                    "last_tool": "Write",
                    "tokens": 500,
                    "tool_uses": 3,
                    "duration_ms": 1200,
                    "started_at": "2026-06-11T09:00:00Z",
                    "ended_at": "2026-06-11T09:01:00Z"
                  },
                  {
                    "task_id": "id2",
                    "name": "executor",
                    "description": "",
                    "status": "failed",
                    "last_tool": "",
                    "tokens": 0,
                    "tool_uses": 0,
                    "duration_ms": 0,
                    "started_at": "2026-06-11T09:02:00Z",
                    "ended_at": "2026-06-11T09:02:30Z"
                  }
                ]
            """.trimIndent(),
        )
        val entries = SubagentEntry.listFrom(payload)
        assertEquals(2, entries.size)
        assertEquals("id1", entries[0].taskId)
        assertEquals("done", entries[0].status)
        assertEquals("2026-06-11T09:01:00Z", entries[0].endedAt)
        assertEquals("id2", entries[1].taskId)
        assertEquals("failed", entries[1].status)
        assertEquals(0L, entries[1].tokens)
    }

    @Test
    fun returnsEmptyListOnMissingKey() {
        assertTrue(SubagentEntry.listFrom(emptyMap()).isEmpty())
        assertTrue(SubagentEntry.listFrom(mapOf("other" to "value")).isEmpty())
    }

    @Test
    fun returnsEmptyListOnEmptyArray() {
        assertTrue(SubagentEntry.listFrom(mapOf("agents" to "[]")).isEmpty())
    }

    @Test
    fun returnsEmptyListOnMalformedJson() {
        assertTrue(SubagentEntry.listFrom(mapOf("agents" to "not json")).isEmpty())
        assertTrue(SubagentEntry.listFrom(mapOf("agents" to "{\"not\":\"array\"}")).isEmpty())
    }

    @Test
    fun defaultsToWorkingStatusWhenAbsent() {
        // The spec says status defaults to "working" on missing key.
        val payload = mapOf(
            "agents" to """[{"task_id":"x","name":"test"}]""",
        )
        val entries = SubagentEntry.listFrom(payload)
        assertEquals(1, entries.size)
        assertEquals("working", entries[0].status)
    }

    @Test
    fun toleratesPartialObjectInArray() {
        // Null entries (e.g. a non-object array element) are skipped;
        // valid objects decode normally.
        val payload = mapOf(
            "agents" to """[{"task_id":"ok","name":"good","status":"done"},null]""",
        )
        val entries = SubagentEntry.listFrom(payload)
        assertEquals(1, entries.size)
        assertEquals("ok", entries[0].taskId)
    }
}
