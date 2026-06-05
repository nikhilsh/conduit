package sh.nikhil.conduit.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import uniffi.conduit_core.ConversationItem
import uniffi.conduit_core.ProjectSession

/**
 * Pins [DiffReviewStats] — the pure unified-diff parser + summary math behind
 * [DiffReviewScreen]. Mirror of iOS `ConduitDiffReviewModelTests`. Pure JUnit;
 * no Compose / FFI runtime needed (the data classes are plain bindings).
 */
class DiffReviewStatsTest {

    private fun diffItem(content: String, id: String = "d1"): ConversationItem =
        ConversationItem(
            id = id,
            role = "tool",
            kind = "diff",
            status = "done",
            content = content,
            ts = "2026-06-05T00:00:00Z",
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

    private fun session(added: UInt? = null, removed: UInt? = null): ProjectSession =
        ProjectSession(
            id = "s1",
            name = "s",
            assistant = "claude",
            branch = "fix/auth",
            preview = null,
            reasoningEffort = null,
            cwd = null,
            startedAt = null,
            lastActivityAt = null,
            displayName = null,
            linesAdded = added,
            linesRemoved = removed,
        )

    @Test
    fun parsesGitHeaderPathAndCounts() {
        val patch = """
            diff --git a/src/auth/refresh.ts b/src/auth/refresh.ts
            index 1111111..2222222 100644
            --- a/src/auth/refresh.ts
            +++ b/src/auth/refresh.ts
            @@ -1,3 +1,4 @@
             async function refresh(token) {
            -  const r = await fetch(url);
            -  return r.json();
            +  const r = await backoff(() => fetch(url));
            +  if (!r.ok) throw new AuthError(r.status);
            +  return r.json();
             }
        """.trimIndent()
        val files = DiffReviewStats.parsePatch(patch)
        assertEquals(1, files.size)
        assertEquals("src/auth/refresh.ts", files[0].path)
        assertEquals(3, files[0].added)
        assertEquals(2, files[0].removed)
    }

    @Test
    fun parsesMultipleFiles() {
        val patch = """
            diff --git a/a.ts b/a.ts
            @@ -1 +1 @@
            -x
            +y
            diff --git a/b.ts b/b.ts
            @@ -0,0 +1,2 @@
            +line1
            +line2
        """.trimIndent()
        val files = DiffReviewStats.parsePatch(patch)
        assertEquals(listOf("a.ts", "b.ts"), files.map { it.path })
        assertEquals(1, files[0].added)
        assertEquals(1, files[0].removed)
        assertEquals(2, files[1].added)
        assertEquals(0, files[1].removed)
    }

    @Test
    fun tripleHeaderWithoutGitLineStartsFile() {
        val patch = """
            --- a/only.ts
            +++ b/only.ts
            @@ -1 +1 @@
            -old
            +new
        """.trimIndent()
        val files = DiffReviewStats.parsePatch(patch)
        assertEquals(1, files.size)
        assertEquals("only.ts", files[0].path)
        assertEquals(1, files[0].added)
        assertEquals(1, files[0].removed)
    }

    @Test
    fun fileMarkersNotCountedAsBodyLines() {
        val patch = """
            diff --git a/x.ts b/x.ts
            --- a/x.ts
            +++ b/x.ts
            @@ -1 +1 @@
            +real add
        """.trimIndent()
        val files = DiffReviewStats.parsePatch(patch)
        assertEquals(1, files[0].added)
        assertEquals(0, files[0].removed)
    }

    @Test
    fun summaryPrefersParsedTotals() {
        val log = listOf(
            diffItem(
                """
                diff --git a/a.ts b/a.ts
                @@ -1 +1 @@
                -x
                +y
                +z
                """.trimIndent(),
            ),
        )
        val files = DiffReviewStats.files(log)
        val summary = DiffReviewStats.summary(session(added = 999u, removed = 999u), files, log)
        assertEquals(1, summary.fileCount)
        assertEquals(2, summary.added)
        assertEquals(1, summary.removed)
        assertEquals("+2 −1", summary.deltaLabel)
        assertEquals("1 file", summary.fileCountLabel)
    }

    @Test
    fun summaryFallsBackToSessionRollupWhenNoDiffItem() {
        val summary = DiffReviewStats.summary(session(added = 162u, removed = 39u), emptyList(), emptyList())
        assertEquals(162, summary.added)
        assertEquals(39, summary.removed)
        assertEquals(0, summary.fileCount)
        assertEquals("0 files", summary.fileCountLabel)
    }

    @Test
    fun addedFractionClampsAndNeutralizes() {
        assertEquals(0.5, DiffReviewStats.Summary(0, 0, 0).addedFraction, 0.0001)
        assertEquals(0.75, DiffReviewStats.Summary(1, 3, 1).addedFraction, 0.0001)
        assertEquals(1.0, DiffReviewStats.Summary(1, 1, 0).addedFraction, 0.0001)
    }

    @Test
    fun filesPicksMostRecentDiffItem() {
        val log = listOf(
            diffItem("diff --git a/old.ts b/old.ts\n@@ -1 +1 @@\n+a", id = "1"),
            diffItem("diff --git a/new.ts b/new.ts\n@@ -1 +1 @@\n+b\n+c", id = "2"),
        )
        val files = DiffReviewStats.files(log)
        assertEquals(listOf("new.ts"), files.map { it.path })
        assertEquals(2, files[0].added)
    }

    @Test
    fun hasInlineDiffReflectsPresence() {
        assertFalse(DiffReviewStats.hasInlineDiff(emptyList()))
        assertTrue(DiffReviewStats.hasInlineDiff(listOf(diffItem("diff --git a/x b/x\n+y"))))
    }

    @Test
    fun lineKindsClassified() {
        val patch = """
            diff --git a/x.ts b/x.ts
            @@ -1,2 +1,2 @@
             context
            -gone
            +added
        """.trimIndent()
        val kinds = DiffReviewStats.parsePatch(patch)[0].lines.map { it.kind }
        assertTrue(kinds.contains(DiffReviewStats.LineKind.HUNK))
        assertTrue(kinds.contains(DiffReviewStats.LineKind.CONTEXT))
        assertTrue(kinds.contains(DiffReviewStats.LineKind.REMOVED))
        assertTrue(kinds.contains(DiffReviewStats.LineKind.ADDED))
    }
}
