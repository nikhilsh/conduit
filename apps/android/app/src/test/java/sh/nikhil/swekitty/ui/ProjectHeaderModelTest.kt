package sh.nikhil.swekitty.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import sh.nikhil.swekitty.SessionLifecycle
import uniffi.swe_kitty_core.ProjectSession
import uniffi.swe_kitty_core.SessionStatus

/**
 * Android mirror of `apps/ios/Tests/SweKittyTests/ProjectViewHeaderTests.swift`.
 *
 * Stage 2 — litter-style header restructure. The header is now an
 * explicit three-row layout (controls / path / tab-picker) and the
 * agent dropdown is a compound control (status dot · name · effort ·
 * chevron). These tests defend that shape so a future refactor can't
 * quietly collapse it.
 *
 * We don't host the Compose body (no Roborazzi snapshot here, see
 * `RoborazziHowToTest` for that pattern). Instead we test the pure
 * [ProjectHeaderModel] that the rendered surface renders from, which
 * is the same source-of-truth for what shows on screen.
 *
 * Pure JUnit — no Robolectric — because the model has zero Android
 * dependencies. Faster than `RoborazziHowToTest`'s Robolectric boot.
 */
class ProjectHeaderModelTest {

    // ---------- three-row structure ----------

    @Test
    fun headerHasThreeRowsInOrder() {
        // Stage 2 lock: render order is controls → path → tab picker.
        // Drift (collapsed rows, reordered) means the litter visual
        // reference is broken.
        assertEquals(
            listOf(
                ProjectHeaderModel.Row.Controls,
                ProjectHeaderModel.Row.Path,
                ProjectHeaderModel.Row.TabPicker,
            ),
            ProjectHeaderModel.rows,
        )
        assertEquals(3, ProjectHeaderModel.rows.size)
    }

    // ---------- compound agent dropdown ----------

    @Test
    fun agentPillExposesDropdownPayload() {
        val session = makeSession(assistant = "claude", branch = "main")
        val status = makeStatus(assistant = "claude", phase = "running", health = "green")
        val model = ProjectHeaderModel.from(session, status, lifecycleLabel = null)

        // Status dot + agent name + reasoning-effort label + chevron
        // are all carried on the same pill — one compound control,
        // not four sibling chips.
        assertEquals("green", model.agentPill.healthKey)
        assertEquals("claude", model.agentPill.agentName)
        assertEquals("medium", model.agentPill.reasoningEffort)
        assertTrue(model.agentPill.showsChevron)
    }

    @Test
    fun reasoningEffortFallsBackToMedium() {
        // Older harnesses don't emit reasoning_effort yet; the pill
        // must always read *something* so the layout doesn't shift.
        val session = makeSession(assistant = "codex", reasoning = null)
        val model = ProjectHeaderModel.from(session, status = null, lifecycleLabel = null)
        assertEquals("medium", model.agentPill.reasoningEffort)
    }

    @Test
    fun reasoningEffortHonoursHarnessValue() {
        val session = makeSession(assistant = "claude", reasoning = "high")
        val model = ProjectHeaderModel.from(session, status = null, lifecycleLabel = null)
        assertEquals("high", model.agentPill.reasoningEffort)
    }

    @Test
    fun unknownHealthShowsAsUnknownDot() {
        // No status frame yet → dot defaults to "unknown" (grey),
        // matching litter's "we don't know yet" treatment.
        val session = makeSession(assistant = "claude")
        val model = ProjectHeaderModel.from(session, status = null, lifecycleLabel = null)
        assertEquals("unknown", model.agentPill.healthKey)
    }

    // ---------- path row ----------

    @Test
    fun pathRowPrefersCwdWhenAvailable() {
        val session = makeSession(
            assistant = "claude",
            name = "fallback-name",
            cwd = "/srv/work/repo",
        )
        val model = ProjectHeaderModel.from(session, status = null, lifecycleLabel = null)
        assertEquals("/srv/work/repo", model.pathLabel)
    }

    @Test
    fun pathRowFallsBackToSessionName() {
        val session = makeSession(assistant = "claude", name = "fallback-name", cwd = null)
        val model = ProjectHeaderModel.from(session, status = null, lifecycleLabel = null)
        assertEquals("fallback-name", model.pathLabel)
    }

    /**
     * `displayName` (broker `rename_session`, protocol §3.3) wins over
     * both cwd and name in the header label. Mirror of the iOS
     * `pathRowPrefersDisplayNameOverCwdAndName` test so the two shells
     * render the same renamed label.
     */
    @Test
    fun pathRowPrefersDisplayNameOverCwdAndName() {
        val session = ProjectSession(
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
        val model = ProjectHeaderModel.from(session, status = null, lifecycleLabel = null)
        assertEquals("rename-from-server", model.pathLabel)
    }

    // ---------- caption ----------

    @Test
    fun captionJoinsPathBranchPhaseAndLifecycle() {
        val session = makeSession(assistant = "claude", branch = "feature/x", cwd = "/repo")
        val status = makeStatus(assistant = "claude", phase = "running", health = "green")
        val model = ProjectHeaderModel.from(session, status, lifecycleLabel = "exited(0)")
        assertEquals("/repo · feature/x · running · exited(0)", model.captionLabel)
    }

    @Test
    fun captionFallsBackToNoBranchAndReady() {
        // No branch + no status — caption should still produce a
        // sensible mono line rather than blank fragments.
        val session = makeSession(assistant = "claude", branch = null, name = "demo")
        val model = ProjectHeaderModel.from(session, status = null, lifecycleLabel = null)
        assertEquals("demo · no branch · ready", model.captionLabel)
    }

    // ---------- lifecycle label mapping ----------

    @Test
    fun lifecycleLabelOnlySurfacesExitedAndFailed() {
        // Live / Creating / null collapse to null so the caption
        // doesn't grow a "live" suffix on the happy path.
        assertEquals(null, ProjectHeaderModel.lifecycleLabel(null))
        assertEquals(null, ProjectHeaderModel.lifecycleLabel(SessionLifecycle.Live))
        assertEquals(null, ProjectHeaderModel.lifecycleLabel(SessionLifecycle.Creating))
        assertEquals("exited(7)", ProjectHeaderModel.lifecycleLabel(SessionLifecycle.Exited(7)))
        assertEquals(
            "boom",
            ProjectHeaderModel.lifecycleLabel(SessionLifecycle.FailedToStart("boom")),
        )
    }

    // ---------- helpers ----------

    private fun makeSession(
        assistant: String,
        name: String = "swe-kitty",
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
