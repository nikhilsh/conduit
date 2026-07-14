package sh.nikhil.conduit.ui

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import org.json.JSONArray
import org.json.JSONObject
import sh.nikhil.conduit.ui.components.DiffHunkData
import sh.nikhil.conduit.ui.components.DiffLineData
import sh.nikhil.conduit.ui.components.DiffLineKind
import java.util.UUID

/**
 * Pure-data model + state holder for the Android "Changes" surface
 * (Feature A -- docs/PLAN-REVIEW-SHIP.md). Android mirror of iOS
 * `ConduitUI.ChangesModel`. Built on `androidx.compose.runtime` state
 * (pure Kotlin, no Android framework dependency) so the JSON parsing,
 * prompt composer, and re-anchor matcher are directly JUnit-testable
 * without Robolectric -- same pattern as [PipelineBuilderViewModel].
 *
 * Networking (the actual broker calls) stays in [ChangesScreen] via
 * `SessionStore`, exactly like every other session surface -- this class
 * only holds/derives state from the JSON the store already fetched.
 */

/** `scope` query param for `GET .../git/diff`. */
enum class DiffScope(val wire: String) {
    UNCOMMITTED("uncommitted"),
    BRANCH("branch"),
}

data class DiffStat(val filesChanged: Int, val additions: Int, val deletions: Int)

data class DiffFile(
    val path: String,
    val oldPath: String?,
    val status: String,
    val staged: Boolean,
    val binary: Boolean,
    val additions: Int,
    val deletions: Int,
    val truncated: Boolean,
    val hunks: List<DiffHunkData>,
)

data class DiffResponse(
    val scope: String,
    val defaultBranch: String,
    val base: String?,
    val files: List<DiffFile>,
    val diffstat: DiffStat,
    val truncated: Boolean,
)

data class PrInfo(val url: String, val number: Int, val state: String)

data class GitState(
    val isGitRepo: Boolean,
    val branch: String? = null,
    val detached: Boolean = false,
    val defaultBranch: String? = null,
    val upstream: String? = null,
    val ahead: Int = 0,
    val behind: Int = 0,
    val staged: Int = 0,
    val unstaged: Int = 0,
    val untracked: Int = 0,
    val dirty: Int = 0,
    val hasGh: Boolean = false,
    val pr: PrInfo? = null,
)

/**
 * One line-anchored review comment. `filePath` + `lineText` are the
 * re-anchor key (exact match) after a diff refresh; `kind`/`lineNo` are
 * the CURRENT anchor (updated on successful re-anchor). `anchored=false`
 * means the last re-anchor attempt failed to find [lineText] verbatim in
 * [filePath] -- the comment is still sent, flagged unanchored, never
 * silently dropped.
 */
data class ChangeAnnotation(
    val id: String = UUID.randomUUID().toString(),
    val filePath: String,
    val kind: DiffLineKind,
    val lineNo: Int,
    val lineText: String,
    val contextBefore: List<String>,
    val contextAfter: List<String>,
    val comment: String,
    val anchored: Boolean = true,
)

/** Parsing for the broker `git/diff` and `git/state` JSON payloads. */
object ChangesJson {

    fun parseDiff(json: JSONObject): DiffResponse {
        val filesArr = json.optJSONArray("files") ?: JSONArray()
        val files = buildList {
            for (i in 0 until filesArr.length()) {
                add(parseFile(filesArr.getJSONObject(i)))
            }
        }
        val statObj = json.optJSONObject("diffstat")
        val diffstat = DiffStat(
            filesChanged = statObj?.optInt("files_changed", 0) ?: 0,
            additions = statObj?.optInt("additions", 0) ?: 0,
            deletions = statObj?.optInt("deletions", 0) ?: 0,
        )
        return DiffResponse(
            scope = json.optString("scope", "uncommitted"),
            defaultBranch = json.optString("default_branch", ""),
            base = if (json.has("base") && !json.isNull("base")) json.optString("base") else null,
            files = files,
            diffstat = diffstat,
            truncated = json.optBoolean("truncated", false),
        )
    }

    private fun parseFile(obj: JSONObject): DiffFile {
        val hunksArr = obj.optJSONArray("hunks") ?: JSONArray()
        val hunks = buildList {
            for (i in 0 until hunksArr.length()) {
                add(parseHunk(hunksArr.getJSONObject(i)))
            }
        }
        val oldPathRaw = obj.optString("old_path", "")
        return DiffFile(
            path = obj.optString("path", ""),
            oldPath = oldPathRaw.ifBlank { null },
            status = obj.optString("status", "modified"),
            staged = obj.optBoolean("staged", false),
            binary = obj.optBoolean("binary", false),
            additions = obj.optInt("additions", 0),
            deletions = obj.optInt("deletions", 0),
            truncated = obj.optBoolean("truncated", false),
            hunks = hunks,
        )
    }

    private fun parseHunk(obj: JSONObject): DiffHunkData {
        val linesArr = obj.optJSONArray("lines") ?: JSONArray()
        val lines = buildList {
            for (i in 0 until linesArr.length()) {
                val l = linesArr.getJSONObject(i)
                add(
                    DiffLineData(
                        kind = DiffLineKind.fromWire(l.optString("kind", "context")),
                        old = l.optInt("old", 0),
                        new = l.optInt("new", 0),
                        text = l.optString("text", ""),
                    ),
                )
            }
        }
        return DiffHunkData(
            header = obj.optString("header", ""),
            oldStart = obj.optInt("old_start", 0),
            oldLines = obj.optInt("old_lines", 0),
            newStart = obj.optInt("new_start", 0),
            newLines = obj.optInt("new_lines", 0),
            lines = lines,
        )
    }

    fun parseGitState(json: JSONObject): GitState {
        val isRepo = json.optBoolean("is_git_repo", false)
        if (!isRepo) return GitState(isGitRepo = false)
        val prObj = json.optJSONObject("pr")
        val pr = prObj?.let {
            PrInfo(
                url = it.optString("url", ""),
                number = it.optInt("number", 0),
                state = it.optString("state", ""),
            )
        }
        val upstreamRaw = json.optString("upstream", "")
        return GitState(
            isGitRepo = true,
            branch = json.optString("branch", "").ifBlank { null },
            detached = json.optBoolean("detached", false),
            defaultBranch = json.optString("default_branch", "").ifBlank { null },
            upstream = upstreamRaw.ifBlank { null },
            ahead = json.optInt("ahead", 0),
            behind = json.optInt("behind", 0),
            staged = json.optInt("staged", 0),
            unstaged = json.optInt("unstaged", 0),
            untracked = json.optInt("untracked", 0),
            dirty = json.optInt("dirty", 0),
            hasGh = json.optBoolean("has_gh", false),
            pr = pr,
        )
    }

    // --- ChangeAnnotation local persistence (SharedPreferences JSON blob; no new
    // Room/DataStore dependency -- see PLAN-REVIEW-SHIP.md §1.3 local
    // persistence note; Android side keeps this to a plain JSON encode/decode
    // to avoid an unverifiable Gradle dependency add on a box with no SDK). ---

    fun encodeAnnotations(annotations: List<ChangeAnnotation>): JSONArray {
        val arr = JSONArray()
        annotations.forEach { a ->
            val obj = JSONObject()
            obj.put("id", a.id)
            obj.put("file_path", a.filePath)
            obj.put("kind", a.kind.wire)
            obj.put("line_no", a.lineNo)
            obj.put("line_text", a.lineText)
            obj.put("context_before", JSONArray().apply { a.contextBefore.forEach { put(it) } })
            obj.put("context_after", JSONArray().apply { a.contextAfter.forEach { put(it) } })
            obj.put("comment", a.comment)
            obj.put("anchored", a.anchored)
            arr.put(obj)
        }
        return arr
    }

    fun decodeAnnotations(arr: JSONArray): List<ChangeAnnotation> = buildList {
        for (i in 0 until arr.length()) {
            val obj = arr.getJSONObject(i)
            val beforeArr = obj.optJSONArray("context_before") ?: JSONArray()
            val afterArr = obj.optJSONArray("context_after") ?: JSONArray()
            add(
                ChangeAnnotation(
                    id = obj.optString("id", UUID.randomUUID().toString()),
                    filePath = obj.optString("file_path", ""),
                    kind = DiffLineKind.fromWire(obj.optString("kind", "context")),
                    lineNo = obj.optInt("line_no", 0),
                    lineText = obj.optString("line_text", ""),
                    contextBefore = (0 until beforeArr.length()).map { beforeArr.getString(it) },
                    contextAfter = (0 until afterArr.length()).map { afterArr.getString(it) },
                    comment = obj.optString("comment", ""),
                    anchored = obj.optBoolean("anchored", true),
                ),
            )
        }
    }
}

/**
 * Batches [ChangeAnnotation]s into ONE markdown message for the durable chat-send
 * path. MUST stay byte-identical to iOS's composer (docs/PLAN-REVIEW-SHIP.md
 * §2) -- every literal, spacing, and section marker below is load-bearing.
 */
object PromptComposer {
    fun compose(annotations: List<ChangeAnnotation>): String {
        val n = annotations.size
        val sb = StringBuilder()
        sb.append("I reviewed the current changes and left $n inline comment(s). Please address each one, then stop so I can re-review.\n")
        annotations.forEachIndexed { index, a ->
            val i = index + 1
            sb.append("\n")
            sb.append("===== Comment $i of $n =====\n")
            sb.append("File: ${a.filePath}\n")
            if (a.anchored) {
                sb.append("Location: ${a.kind.wire} line ${a.lineNo}\n")
            } else {
                sb.append("Location: (unanchored — line text no longer present)\n")
            }
            sb.append("Annotated line:\n")
            sb.append("    ${a.lineText}\n")
            val hasContext = a.anchored && (a.contextBefore.isNotEmpty() || a.contextAfter.isNotEmpty())
            if (hasContext) {
                sb.append("Context:\n")
                a.contextBefore.forEach { sb.append("    $it\n") }
                sb.append(">>> ${a.lineText}\n")
                a.contextAfter.forEach { sb.append("    $it\n") }
            }
            sb.append("Comment:\n")
            sb.append("${a.comment}\n")
        }
        sb.append("\n===== End of comments =====\n")
        sb.append(
            "Guidance: make only the changes these comments call for; keep the diff focused. " +
                "When done, reply with a one-line summary per comment and wait for my re-review.",
        )
        return sb.toString()
    }
}

/**
 * Re-anchors annotations against a freshly-fetched diff (docs/PLAN-REVIEW-SHIP.md
 * §1.3.6): match by EXACT (file, line text); prefer the same kind, then the
 * nearest line number. No match -> `anchored=false` (still sent, never
 * dropped -- see [PromptComposer]).
 */
object ReAnchor {
    fun reanchor(existing: List<ChangeAnnotation>, files: List<DiffFile>): List<ChangeAnnotation> =
        existing.map { reanchorOne(it, files) }

    private fun reanchorOne(annotation: ChangeAnnotation, files: List<DiffFile>): ChangeAnnotation {
        val file = files.firstOrNull { it.path == annotation.filePath } ?: return annotation.copy(anchored = false)
        var bestHunk: DiffHunkData? = null
        var bestLine: DiffLineData? = null
        var bestScore = Int.MAX_VALUE
        for (hunk in file.hunks) {
            for (line in hunk.lines) {
                if (line.text != annotation.lineText) continue
                val sameKindPenalty = if (line.kind == annotation.kind) 0 else 1
                val distance = kotlin.math.abs(line.anchorLineNo - annotation.lineNo)
                val score = sameKindPenalty * 1_000_000 + distance
                if (score < bestScore) {
                    bestScore = score
                    bestHunk = hunk
                    bestLine = line
                }
            }
        }
        val hunk = bestHunk ?: return annotation.copy(anchored = false)
        val line = bestLine ?: return annotation.copy(anchored = false)
        val idx = hunk.lines.indexOf(line)
        val before = hunk.lines.subList(maxOf(0, idx - 2), idx).map { it.text }
        val after = hunk.lines.subList(minOf(hunk.lines.size, idx + 1), minOf(hunk.lines.size, idx + 3)).map { it.text }
        return annotation.copy(
            kind = line.kind,
            lineNo = line.anchorLineNo,
            contextBefore = before,
            contextAfter = after,
            anchored = true,
        )
    }
}

/**
 * Compose state holder for [ChangesScreen] -- one instance per session,
 * `remember(session.id) { ChangesViewModel() }`. Holds only UI-facing
 * state; every broker call lives in `SessionStore`/`ChangesScreen`.
 */
class ChangesViewModel {
    var scope: DiffScope by mutableStateOf(DiffScope.UNCOMMITTED)
    var diff: DiffResponse? by mutableStateOf(null)
    var gitState: GitState? by mutableStateOf(null)
    var annotations: List<ChangeAnnotation> by mutableStateOf(emptyList())
    var commitMessage: String by mutableStateOf("")
    var isLoading: Boolean by mutableStateOf(false)
    var loadError: String? by mutableStateOf(null)
    var shipError: String? by mutableStateOf(null)

    val anchoredAnnotations: List<ChangeAnnotation> get() = annotations.filter { it.anchored }
    val unanchoredAnnotations: List<ChangeAnnotation> get() = annotations.filterNot { it.anchored }

    /** Applies a freshly-fetched diff and re-anchors existing annotations against it. */
    fun applyDiff(response: DiffResponse) {
        diff = response
        annotations = ReAnchor.reanchor(annotations, response.files)
    }

    fun addAnnotation(filePath: String, hunk: DiffHunkData, line: DiffLineData, comment: String) {
        val idx = hunk.lines.indexOf(line)
        val before = if (idx >= 0) hunk.lines.subList(maxOf(0, idx - 2), idx).map { it.text } else emptyList()
        val after = if (idx >= 0) {
            hunk.lines.subList(minOf(hunk.lines.size, idx + 1), minOf(hunk.lines.size, idx + 3)).map { it.text }
        } else {
            emptyList()
        }
        annotations = annotations + ChangeAnnotation(
            filePath = filePath,
            kind = line.kind,
            lineNo = line.anchorLineNo,
            lineText = line.text,
            contextBefore = before,
            contextAfter = after,
            comment = comment,
        )
    }

    fun removeAnnotation(id: String) {
        annotations = annotations.filterNot { it.id == id }
    }

    fun isAnnotated(filePath: String, line: DiffLineData): Boolean =
        annotations.any { it.filePath == filePath && it.anchored && it.kind == line.kind && it.lineNo == line.anchorLineNo }

    /** Composes the send-to-agent prompt for the CURRENT annotation set. */
    fun composePrompt(): String = PromptComposer.compose(annotations)
}
