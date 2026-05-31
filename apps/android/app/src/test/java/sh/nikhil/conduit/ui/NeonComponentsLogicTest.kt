package sh.nikhil.conduit.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins the pure decision helpers behind the neon card composables —
 * tool-icon family map, bash/command-card detection, diff-stat parsing,
 * and plan-shape detection. These mirror the handoff spec's tints and
 * gate which card look a tool call gets, so a casual edit shouldn't
 * silently reclassify. No Compose runtime needed.
 */
class NeonComponentsLogicTest {

    @Test
    fun toolKindMapsHandoffFamilies() {
        assertEquals(NeonToolKind.SEARCH, neonToolKind("Grep"))
        assertEquals(NeonToolKind.SEARCH, neonToolKind("ripgrep_search"))
        assertEquals(NeonToolKind.READ, neonToolKind("Read"))
        assertEquals(NeonToolKind.READ, neonToolKind("cat"))
        assertEquals(NeonToolKind.EDIT, neonToolKind("Edit"))
        assertEquals(NeonToolKind.EDIT, neonToolKind("apply_patch"))
        assertEquals(NeonToolKind.BASH, neonToolKind("Bash"))
        assertEquals(NeonToolKind.BASH, neonToolKind("exec"))
        assertEquals(NeonToolKind.GENERIC, neonToolKind("mystery_tool"))
        assertEquals(NeonToolKind.GENERIC, neonToolKind(null))
        assertEquals(NeonToolKind.GENERIC, neonToolKind(""))
    }

    @Test
    fun commandCardWhenBashOrCommandPresent() {
        assertTrue(isNeonCommandCard("bash", null))
        assertTrue(isNeonCommandCard("sh", ""))
        // A command string forces the headline look even for odd tool names.
        assertTrue(isNeonCommandCard("mystery", "ls -la"))
        assertTrue(isNeonCommandCard(null, "git status"))
        // No command + non-bash tool → not a command card.
        assertFalse(isNeonCommandCard("read", null))
        assertFalse(isNeonCommandCard("edit", "   "))
    }

    @Test
    fun diffStatPrefersExplicitSummary() {
        assertEquals(NeonDiffStat(12, 3), parseNeonDiffStat("+12 -3", null))
        assertEquals(NeonDiffStat(12, 3), parseNeonDiffStat("+12 −3", null))
        assertEquals(
            NeonDiffStat(5, 2),
            parseNeonDiffStat("5 insertions, 2 deletions", null),
        )
    }

    @Test
    fun diffStatFallsBackToBodyCounts() {
        val body = """
            --- a/foo.kt
            +++ b/foo.kt
            +added one
            +added two
            -removed one
             context
        """.trimIndent()
        assertEquals(NeonDiffStat(2, 1), parseNeonDiffStat(null, body))
    }

    @Test
    fun diffStatNullWhenNothingDiffShaped() {
        assertNull(parseNeonDiffStat(null, "just prose, no markers"))
        assertNull(parseNeonDiffStat("  ", ""))
    }

    @Test
    fun planShapeDetectsTodoNameOrCheckboxes() {
        assertTrue(isNeonPlanShaped("TodoWrite", null))
        assertTrue(isNeonPlanShaped("update_plan", ""))
        assertTrue(isNeonPlanShaped("mystery", "- [ ] step one\n- [x] step two"))
        assertFalse(isNeonPlanShaped("bash", "ls -la"))
        assertFalse(isNeonPlanShaped(null, "- a plain bullet"))
    }
}
