package sh.nikhil.swekitty.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import uniffi.swe_kitty_core.ChatEvent
import uniffi.swe_kitty_core.ConversationItem

/**
 * `litter-ui-trash-rebuild` chat-ordering fix — pure-data assertions
 * against [mergedConversation]. Mirror of iOS
 * `LitterUI.ChatViewModel.mergedEvents`: a single chronologically-sorted
 * stream, dedup raw chat events by role+content, and interleave user /
 * assistant turns by `ts` instead of clumping by source.
 */
class MergedConversationTest {

    private fun item(role: String, content: String, ts: String, id: String = "$ts-$role"): ConversationItem =
        ConversationItem(
            id = id,
            role = role,
            kind = if (role.lowercase() == "tool") "tool" else "message",
            status = "done",
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

    private fun chat(role: String, content: String, ts: String): ChatEvent =
        ChatEvent(role = role, content = content, ts = ts, files = emptyList())

    @Test fun emptyChatLog_returnsConversationUnchanged() {
        val conversation = listOf(
            item("user", "hello", "2026-05-25T00:00:01Z"),
            item("assistant", "hi", "2026-05-25T00:00:02Z"),
        )
        val merged = mergedConversation(conversation, emptyList())
        assertSame(conversation, merged)
    }

    @Test fun foldsInCodexReplyMissingFromTypedLog() {
        // Codex assistant reply arrives only via on_chat_event → chatLog;
        // the typed log carries just the locally-echoed user turn.
        val conversation = listOf(item("user", "hello", "2026-05-25T00:00:01Z"))
        val chatLog = listOf(
            chat("user", "hello", "2026-05-25T00:00:01Z"), // dup of typed echo
            chat("assistant", "Hello. How can I help?", "2026-05-25T00:00:02Z"),
        )
        val merged = mergedConversation(conversation, chatLog)
        assertEquals(2, merged.size)
        assertEquals(listOf("user", "assistant"), merged.map { it.role })
        assertEquals("Hello. How can I help?", merged[1].content)
    }

    @Test fun interleavesUserAndAssistantByTimestamp() {
        // The reported bug shape: the typed log holds both assistant turns
        // plus the user echoes appended *after* them (out of order). A new
        // codex reply arriving only via chatLog forces the merge path,
        // which sorts the whole stream by ts and restores the true
        // chronological interleave (user → assistant → user → assistant).
        val conversation = listOf(
            item("assistant", "Hello. How can I help?", "2026-05-25T00:00:02Z"),
            item("user", "hello", "2026-05-25T00:00:01Z"),
            item("user", "is this working", "2026-05-25T00:00:03Z"),
        )
        val chatLog = listOf(
            chat("assistant", "Yes, it's working.", "2026-05-25T00:00:04Z"),
        )
        val merged = mergedConversation(conversation, chatLog)
        assertEquals(
            listOf("hello", "Hello. How can I help?", "is this working", "Yes, it's working."),
            merged.map { it.content },
        )
    }

    @Test fun dedupesByRoleAndContent() {
        val conversation = listOf(
            item("user", "hello", "2026-05-25T00:00:01Z"),
            item("assistant", "hi there", "2026-05-25T00:00:02Z"),
        )
        val chatLog = listOf(
            chat("user", "hello", "2026-05-25T00:00:01Z"),
            chat("assistant", "hi there", "2026-05-25T00:00:02Z"),
        )
        // Everything in chatLog already exists in the typed log → no
        // synthetic items, conversation returned unchanged.
        val merged = mergedConversation(conversation, chatLog)
        assertSame(conversation, merged)
    }

    @Test fun syntheticToolEventGetsToolKind() {
        val merged = mergedConversation(
            emptyList(),
            listOf(chat("tool", "ran tests", "2026-05-25T00:00:01Z")),
        )
        assertEquals(1, merged.size)
        assertEquals("tool", merged[0].kind)
        assertTrue(merged[0].id.startsWith("chatlog-"))
    }
}
