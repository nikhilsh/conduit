package sh.nikhil.conduit.ui

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import sh.nikhil.conduit.ui.components.DiffHunkData
import sh.nikhil.conduit.ui.components.DiffLineData
import sh.nikhil.conduit.ui.components.DiffLineKind

/**
 * Unit tests for the Android "Changes" surface pure model
 * ([ChangesJson], [PromptComposer], [ReAnchor]) -- Feature A
 * (docs/PLAN-REVIEW-SHIP.md). Pure JVM: JSON parsing + string building +
 * list matching, no Android/Compose runtime touched.
 */
class ChangesViewModelTest {

    private fun line(kind: DiffLineKind, old: Int, new: Int, text: String) =
        DiffLineData(kind = kind, old = old, new = new, text = text)

    // ── PromptComposer -- byte-identical template (docs/PLAN-REVIEW-SHIP.md §2) ──

    @Test
    fun compose_singleAnnotation_withContext_matchesTemplate() {
        val ann = ChangeAnnotation(
            filePath = "a.go",
            kind = DiffLineKind.ADD,
            lineNo = 11,
            lineText = "  new()",
            contextBefore = listOf("func serve() {"),
            contextAfter = emptyList(),
            comment = "Should this be renamed?",
        )
        val expected = "I reviewed the current changes and left 1 inline comment(s). Please address each one, then stop so I can re-review.\n" +
            "\n" +
            "===== Comment 1 of 1 =====\n" +
            "File: a.go\n" +
            "Location: add line 11\n" +
            "Annotated line:\n" +
            "      new()\n" +
            "Context:\n" +
            "    func serve() {\n" +
            ">>>   new()\n" +
            "Comment:\n" +
            "Should this be renamed?\n" +
            "\n===== End of comments =====\n" +
            "Guidance: make only the changes these comments call for; keep the diff focused. " +
            "When done, reply with a one-line summary per comment and wait for my re-review."
        assertEquals(expected, PromptComposer.compose(listOf(ann)))
    }

    @Test
    fun compose_delKind_usesOldLineNoLabel() {
        val ann = ChangeAnnotation(
            filePath = "b.go",
            kind = DiffLineKind.DEL,
            lineNo = 11,
            lineText = "  old()",
            contextBefore = emptyList(),
            contextAfter = emptyList(),
            comment = "why remove this?",
        )
        val result = PromptComposer.compose(listOf(ann))
        assertTrue(result.contains("Location: del line 11"))
    }

    @Test
    fun compose_noContext_omitsContextBlockEntirely() {
        // Single-line hunk -> contextBefore/After both empty -> "Context:" section dropped.
        val ann = ChangeAnnotation(
            filePath = "b.go",
            kind = DiffLineKind.DEL,
            lineNo = 3,
            lineText = "  old()",
            contextBefore = emptyList(),
            contextAfter = emptyList(),
            comment = "Remove this.",
        )
        val result = PromptComposer.compose(listOf(ann))
        assertFalse(result.contains("Context:"))
        assertFalse(result.contains(">>>"))
        assertTrue(result.contains("Annotated line:\n      old()\n"))
    }

    @Test
    fun compose_unanchored_usesPlaceholderLocation_andNoContext() {
        val ann = ChangeAnnotation(
            filePath = "c.go",
            kind = DiffLineKind.CONTEXT,
            lineNo = 5,
            lineText = "foo()",
            contextBefore = listOf("bar()"),
            contextAfter = listOf("baz()"),
            comment = "still relevant?",
            anchored = false,
        )
        val result = PromptComposer.compose(listOf(ann))
        assertTrue(result.contains("Location: (unanchored — line text no longer present)"))
        // Even though stale contextBefore/After are still stored, an
        // unanchored comment is sent with NO context block.
        assertFalse(result.contains("Context:"))
        assertFalse(result.contains(">>>"))
    }

    @Test
    fun compose_multipleAnnotations_numbersSequentiallyAndSeparatesBlocks() {
        val a1 = ChangeAnnotation(
            filePath = "x.go", kind = DiffLineKind.ADD, lineNo = 1, lineText = "l1",
            contextBefore = emptyList(), contextAfter = emptyList(), comment = "c1",
        )
        val a2 = ChangeAnnotation(
            filePath = "y.go", kind = DiffLineKind.DEL, lineNo = 2, lineText = "l2",
            contextBefore = emptyList(), contextAfter = emptyList(), comment = "c2",
        )
        val result = PromptComposer.compose(listOf(a1, a2))
        assertTrue(result.startsWith("I reviewed the current changes and left 2 inline comment(s)."))
        assertTrue(result.contains("===== Comment 1 of 2 ====="))
        assertTrue(result.contains("===== Comment 2 of 2 ====="))
        // Exactly one blank line separates the first block's comment text
        // from the second block's marker, and the last block from the End marker.
        assertTrue(result.contains("Comment:\nc1\n\n===== Comment 2 of 2 ====="))
        assertTrue(result.contains("Comment:\nc2\n\n===== End of comments ====="))
        assertTrue(result.endsWith("wait for my re-review."))
    }

    // ── ReAnchor -- exact (file, line text) match, docs/PLAN-REVIEW-SHIP.md §1.3.6 ──

    @Test
    fun reanchor_exactMatch_staysAnchoredAndUpdatesContext() {
        val hunk = DiffHunkData(
            header = "@@ -1,3 +1,3 @@", oldStart = 1, oldLines = 3, newStart = 1, newLines = 3,
            lines = listOf(
                line(DiffLineKind.CONTEXT, 1, 1, "a"),
                line(DiffLineKind.ADD, 0, 2, "b"),
                line(DiffLineKind.CONTEXT, 2, 3, "c"),
            ),
        )
        val file = DiffFile(
            path = "f.go", oldPath = null, status = "modified", staged = false, binary = false,
            additions = 1, deletions = 0, truncated = false, hunks = listOf(hunk),
        )
        val ann = ChangeAnnotation(
            filePath = "f.go", kind = DiffLineKind.ADD, lineNo = 2, lineText = "b",
            contextBefore = emptyList(), contextAfter = emptyList(), comment = "x",
        )
        val result = ReAnchor.reanchor(listOf(ann), listOf(file))
        assertTrue(result[0].anchored)
        assertEquals(listOf("a"), result[0].contextBefore)
        assertEquals(listOf("c"), result[0].contextAfter)
    }

    @Test
    fun reanchor_lineMovedToNewLineNo_reanchorsByText() {
        val hunk = DiffHunkData(
            header = "@@ @@", oldStart = 9, oldLines = 1, newStart = 9, newLines = 1,
            lines = listOf(line(DiffLineKind.CONTEXT, 9, 9, "moved()")),
        )
        val file = DiffFile(
            path = "f.go", oldPath = null, status = "modified", staged = false, binary = false,
            additions = 0, deletions = 0, truncated = false, hunks = listOf(hunk),
        )
        val ann = ChangeAnnotation(
            filePath = "f.go", kind = DiffLineKind.CONTEXT, lineNo = 5, lineText = "moved()",
            contextBefore = emptyList(), contextAfter = emptyList(), comment = "x",
        )
        val result = ReAnchor.reanchor(listOf(ann), listOf(file))
        assertTrue(result[0].anchored)
        assertEquals(9, result[0].lineNo)
    }

    @Test
    fun reanchor_lineTextGone_marksUnanchoredButKeepsStoredText() {
        val hunk = DiffHunkData(
            header = "@@ @@", oldStart = 1, oldLines = 1, newStart = 1, newLines = 1,
            lines = listOf(line(DiffLineKind.CONTEXT, 1, 1, "still here")),
        )
        val file = DiffFile(
            path = "f.go", oldPath = null, status = "modified", staged = false, binary = false,
            additions = 0, deletions = 0, truncated = false, hunks = listOf(hunk),
        )
        val ann = ChangeAnnotation(
            filePath = "f.go", kind = DiffLineKind.ADD, lineNo = 3, lineText = "gone now",
            contextBefore = emptyList(), contextAfter = emptyList(), comment = "x",
        )
        val result = ReAnchor.reanchor(listOf(ann), listOf(file))
        assertFalse(result[0].anchored)
        assertEquals("gone now", result[0].lineText)
    }

    @Test
    fun reanchor_fileRemovedFromDiff_marksUnanchored() {
        val ann = ChangeAnnotation(
            filePath = "deleted.go", kind = DiffLineKind.CONTEXT, lineNo = 1, lineText = "x",
            contextBefore = emptyList(), contextAfter = emptyList(), comment = "c",
        )
        val result = ReAnchor.reanchor(listOf(ann), emptyList())
        assertFalse(result[0].anchored)
    }

    @Test
    fun reanchor_neverDropsAnnotations() {
        // Re-anchor must return the SAME count in, whether matched or not --
        // never silently drop a comment (docs/PLAN-REVIEW-SHIP.md §1.3.6).
        val anns = listOf(
            ChangeAnnotation(filePath = "a", kind = DiffLineKind.ADD, lineNo = 1, lineText = "x", contextBefore = emptyList(), contextAfter = emptyList(), comment = "1"),
            ChangeAnnotation(filePath = "b", kind = DiffLineKind.ADD, lineNo = 2, lineText = "y", contextBefore = emptyList(), contextAfter = emptyList(), comment = "2"),
        )
        val result = ReAnchor.reanchor(anns, emptyList())
        assertEquals(2, result.size)
        assertFalse(result[0].anchored)
        assertFalse(result[1].anchored)
    }

    // ── ChangesJson.parseDiff (docs/PLAN-REVIEW-SHIP.md §3.1) ──────────────

    @Test
    fun parseDiff_fullExample_parsesFieldsAndHunks() {
        val json = JSONObject(
            """
            {
              "scope": "uncommitted",
              "default_branch": "main",
              "files": [
                {
                  "path": "broker/internal/ws/git.go",
                  "old_path": "",
                  "status": "modified",
                  "staged": true,
                  "binary": false,
                  "additions": 12,
                  "deletions": 3,
                  "truncated": false,
                  "hunks": [
                    {
                      "header": "@@ -10,6 +10,8 @@ func serve() {",
                      "old_start": 10, "old_lines": 6,
                      "new_start": 10, "new_lines": 8,
                      "lines": [
                        {"kind":"context","old":10,"new":10,"text":"func serve() {"},
                        {"kind":"del","old":11,"new":0,"text":"  old()"},
                        {"kind":"add","old":0,"new":11,"text":"  new()"}
                      ]
                    }
                  ]
                }
              ],
              "diffstat": {"files_changed": 3, "additions": 47, "deletions": 12},
              "truncated": false
            }
            """.trimIndent(),
        )
        val diff = ChangesJson.parseDiff(json)
        assertEquals("uncommitted", diff.scope)
        assertEquals("main", diff.defaultBranch)
        assertNull(diff.base)
        assertEquals(1, diff.files.size)

        val file = diff.files[0]
        assertEquals("broker/internal/ws/git.go", file.path)
        assertNull(file.oldPath)
        assertEquals("modified", file.status)
        assertTrue(file.staged)
        assertFalse(file.binary)
        assertEquals(12, file.additions)
        assertEquals(3, file.deletions)
        assertEquals(1, file.hunks.size)

        val hunk = file.hunks[0]
        assertEquals(10, hunk.oldStart)
        assertEquals(3, hunk.lines.size)
        assertEquals(DiffLineKind.DEL, hunk.lines[1].kind)
        assertEquals(11, hunk.lines[1].old)
        assertEquals(0, hunk.lines[1].new)
        assertEquals(11, hunk.lines[1].anchorLineNo)
        assertEquals(DiffLineKind.ADD, hunk.lines[2].kind)
        assertEquals(11, hunk.lines[2].anchorLineNo)

        assertEquals(3, diff.diffstat.filesChanged)
        assertEquals(47, diff.diffstat.additions)
        assertEquals(12, diff.diffstat.deletions)
        assertFalse(diff.truncated)
    }

    @Test
    fun parseDiff_branchScope_includesBase() {
        val json = JSONObject(
            """{"scope":"branch","default_branch":"main","base":"origin/main","files":[],"diffstat":{"files_changed":0,"additions":0,"deletions":0},"truncated":false}""",
        )
        val diff = ChangesJson.parseDiff(json)
        assertEquals("branch", diff.scope)
        assertEquals("origin/main", diff.base)
    }

    @Test
    fun parseDiff_renamedFile_setsOldPath() {
        val json = JSONObject(
            """{"scope":"uncommitted","default_branch":"main","files":[{"path":"new.go","old_path":"old.go","status":"renamed","staged":false,"binary":false,"additions":0,"deletions":0,"truncated":false,"hunks":[]}],"diffstat":{"files_changed":1,"additions":0,"deletions":0},"truncated":false}""",
        )
        val diff = ChangesJson.parseDiff(json)
        assertEquals("old.go", diff.files[0].oldPath)
        assertEquals("renamed", diff.files[0].status)
    }

    @Test
    fun parseDiff_missingFilesArray_returnsEmptyList() {
        val json = JSONObject("""{"scope":"uncommitted","default_branch":"main","diffstat":{"files_changed":0,"additions":0,"deletions":0},"truncated":false}""")
        val diff = ChangesJson.parseDiff(json)
        assertTrue(diff.files.isEmpty())
    }

    // ── ChangesJson.parseGitState (docs/PLAN-REVIEW-SHIP.md §3.2) ──────────

    @Test
    fun parseGitState_notARepo_returnsMinimalState() {
        val json = JSONObject("""{"is_git_repo":false}""")
        val state = ChangesJson.parseGitState(json)
        assertFalse(state.isGitRepo)
        assertNull(state.branch)
    }

    @Test
    fun parseGitState_fullExample_parsesPrAndCounts() {
        val json = JSONObject(
            """
            {
              "is_git_repo": true, "branch": "conduit/session-abc", "detached": false,
              "default_branch": "main", "upstream": "origin/conduit/session-abc",
              "ahead": 2, "behind": 0, "staged": 1, "unstaged": 3, "untracked": 2, "dirty": 6,
              "has_gh": true, "pr": {"url":"https://github.com/o/r/pull/9","number":9,"state":"open"}
            }
            """.trimIndent(),
        )
        val state = ChangesJson.parseGitState(json)
        assertTrue(state.isGitRepo)
        assertEquals("conduit/session-abc", state.branch)
        assertEquals(2, state.ahead)
        assertEquals(6, state.dirty)
        assertTrue(state.hasGh)
        assertEquals(9, state.pr?.number)
        assertEquals("open", state.pr?.state)
        assertEquals("https://github.com/o/r/pull/9", state.pr?.url)
    }

    @Test
    fun parseGitState_noUpstream_emptyStringBecomesNull() {
        val json = JSONObject("""{"is_git_repo":true,"branch":"main","upstream":""}""")
        val state = ChangesJson.parseGitState(json)
        assertNull(state.upstream)
    }

    @Test
    fun parseGitState_noPr_prIsNull() {
        val json = JSONObject("""{"is_git_repo":true,"branch":"main","has_gh":false}""")
        val state = ChangesJson.parseGitState(json)
        assertNull(state.pr)
        assertFalse(state.hasGh)
    }
}
