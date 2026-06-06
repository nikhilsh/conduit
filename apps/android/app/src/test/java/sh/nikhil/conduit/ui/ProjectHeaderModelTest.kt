package sh.nikhil.conduit.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import sh.nikhil.conduit.SessionLifecycle
import uniffi.conduit_core.ProjectSession
import uniffi.conduit_core.SessionStatus

/**
 * Round-2 header restructure (Conduit_Fixes_Handoff images 01→02). The
 * header is now a SINGLE controls/identity row + the tab picker — the old
 * separate path row is gone, folded into the identity block's
 * `repo · branch` context line. The identity block carries the friendly
 * session title and the title-menu identity payload (agent display name +
 * honest model line). These tests defend that shape so a future refactor
 * can't quietly regrow the three-row header or the "claude / claude"
 * model line.
 *
 * Pure JUnit — no Robolectric — because the model has zero Android
 * dependencies.
 */
class ProjectHeaderModelTest {

    // ---------- single-row structure ----------

    @Test
    fun headerHasTwoRowsInOrder() {
        // Round-2 lock: ONE identity row, then the tab picker. A separate
        // path row reappearing means fix 1 regressed.
        assertEquals(
            listOf(
                ProjectHeaderModel.Row.Controls,
                ProjectHeaderModel.Row.TabPicker,
            ),
            ProjectHeaderModel.rows,
        )
        assertEquals(2, ProjectHeaderModel.rows.size)
    }

    // ---------- identity block ----------

    @Test
    fun identityCarriesTitleStatusAndChevron() {
        val session = makeSession(assistant = "claude", branch = "fix/auth", cwd = "/root/dev/PaperTrail")
        val status = makeStatus(assistant = "claude", phase = "running", health = "green")
        val model = ProjectHeaderModel.from(
            session, status,
            lifecycleLabel = null,
            title = "Fix auth refresh loop",
        )

        assertEquals("green", model.identity.healthKey)
        assertEquals("Fix auth refresh loop", model.identity.title)
        assertEquals("claude", model.identity.agentName)
        assertTrue(model.identity.showsChevron)
    }

    @Test
    fun titleFallsBackToDisplayNameThenName() {
        val renamed = ProjectSession(
            id = "uuid-1234",
            name = "fallback-name",
            assistant = "claude",
            branch = "main",
            preview = null,
            reasoningEffort = null,
            cwd = "/srv/work/repo",
            startedAt = null,
            lastActivityAt = null,
            displayName = "rename-from-server",
        )
        assertEquals(
            "rename-from-server",
            ProjectHeaderModel.from(renamed, status = null, lifecycleLabel = null).identity.title,
        )

        val bare = makeSession(assistant = "claude", name = "raw-name", cwd = null)
        assertEquals(
            "raw-name",
            ProjectHeaderModel.from(bare, status = null, lifecycleLabel = null).identity.title,
        )
    }

    // ---------- context line (repo · branch) ----------

    @Test
    fun contextLineJoinsRepoAndBranch() {
        // The repo is the LAST path component of cwd — the old full-width
        // path row folded down to the project identifier.
        val session = makeSession(assistant = "claude", branch = "fix/auth", cwd = "/root/dev/PaperTrail")
        val model = ProjectHeaderModel.from(session, status = null, lifecycleLabel = null)
        assertEquals("PaperTrail · fix/auth", model.identity.contextLine)
    }

    @Test
    fun contextLineKeepsExitedSuffix() {
        // exited/failed stays visible — honest read-only signal.
        val session = makeSession(assistant = "claude", branch = "main", cwd = "/repo")
        val model = ProjectHeaderModel.from(session, status = null, lifecycleLabel = "exited(0)")
        assertEquals("repo · main · exited(0)", model.identity.contextLine)
    }

    @Test
    fun contextLineNullWhenNothingKnown() {
        val session = makeSession(assistant = "claude", branch = null, cwd = null)
        val model = ProjectHeaderModel.from(session, status = null, lifecycleLabel = null)
        assertNull(model.identity.contextLine)
    }

    // ---------- menu identity header (agent + model) ----------

    @Test
    fun agentDisplayNameIsFriendly() {
        assertEquals(
            "Claude",
            ProjectHeaderModel.from(makeSession("claude"), null, null).identity.agentDisplayName,
        )
        assertEquals(
            "Codex",
            ProjectHeaderModel.from(makeSession("codex"), null, null).identity.agentDisplayName,
        )
    }

    @Test
    fun modelLabelPrefersRecordedAlias() {
        val model = ProjectHeaderModel.from(
            makeSession("claude"), null, null,
            modelAlias = "sonnet",
        )
        assertEquals("sonnet", model.identity.modelLabel)
    }

    @Test
    fun modelLabelFallsBackToDefaultPlusEffort() {
        // Never "claude · claude" — with no recorded alias the line says
        // "default model", with the effort appended when known.
        val withEffort = ProjectHeaderModel.from(
            makeSession("claude", reasoning = "high"), null, null,
        )
        assertEquals("default model · high", withEffort.identity.modelLabel)

        val bare = ProjectHeaderModel.from(makeSession("claude"), null, null)
        assertEquals("default model", bare.identity.modelLabel)
    }

    // ---------- lifecycle label mapping ----------

    @Test
    fun lifecycleLabelOnlySurfacesExitedAndFailed() {
        assertEquals(null, ProjectHeaderModel.lifecycleLabel(null))
        assertEquals(null, ProjectHeaderModel.lifecycleLabel(SessionLifecycle.Live))
        assertEquals(null, ProjectHeaderModel.lifecycleLabel(SessionLifecycle.Creating))
        assertEquals("exited(7)", ProjectHeaderModel.lifecycleLabel(SessionLifecycle.Exited(7)))
        assertEquals(
            "boom",
            ProjectHeaderModel.lifecycleLabel(SessionLifecycle.FailedToStart("boom")),
        )
    }

    // ---------- unknown health ----------

    @Test
    fun unknownHealthShowsAsUnknownDot() {
        val model = ProjectHeaderModel.from(makeSession("claude"), status = null, lifecycleLabel = null)
        assertEquals("unknown", model.identity.healthKey)
    }

    // ---------- helpers ----------

    private fun makeSession(
        assistant: String,
        name: String = "conduit",
        branch: String? = "main",
        cwd: String? = null,
        reasoning: String? = null,
    ): ProjectSession = ProjectSession(
        id = "test-${System.nanoTime()}",
        name = name,
        assistant = assistant,
        branch = branch,
        preview = null,
        reasoningEffort = reasoning,
        cwd = cwd,
        startedAt = null,
        lastActivityAt = null,
        displayName = null,
    )

    private fun makeStatus(
        assistant: String,
        phase: String,
        health: String,
    ): SessionStatus = SessionStatus(
        session = "test-session",
        assistant = assistant,
        phase = phase,
        health = health,
        rows = 24u,
        cols = 80u,
        yolo = false,
        preview = null,
        sessionName = null,
        viewers = null,
        reasoningEffort = null,
        cwd = null,
        startedAt = null,
        lastActivityAt = null,
        displayName = null,
    )
}
