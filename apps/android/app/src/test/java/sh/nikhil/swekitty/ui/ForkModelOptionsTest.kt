package sh.nikhil.swekitty.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins [forkModelOptions] / [forkModelLabel] / [forkModelInherit]. The
 * fork chooser's model dropdown is built straight off these pure lists,
 * and the broker passes the chosen value to the agent's --model flag — so
 * the per-assistant filtering and the inherit→no-override mapping are a
 * contract worth pinning. Mirror of iOS `LitterForkOptionsTests`.
 */
class ForkModelOptionsTest {

    @Test
    fun claudeOffersInheritThenAliases() {
        val models = forkModelOptions("claude")
        assertEquals(listOf(forkModelInherit, "opus", "sonnet", "haiku"), models)
        // The leading entry is the inherit sentinel (no override).
        assertEquals(forkModelInherit, models.first())
    }

    @Test
    fun codexOffersInheritThenCodexAlias() {
        assertEquals(listOf(forkModelInherit, "gpt-5-codex"), forkModelOptions("codex"))
    }

    @Test
    fun unknownAssistantOnlyOffersInherit() {
        assertEquals(listOf(forkModelInherit), forkModelOptions("gemini"))
    }

    @Test
    fun optionsAreFilteredByAssistant() {
        val claude = forkModelOptions("claude")
        val codex = forkModelOptions("codex")
        assertTrue(claude.contains("opus"))
        assertFalse(codex.contains("opus"))
        assertTrue(codex.contains("gpt-5-codex"))
        assertFalse(claude.contains("gpt-5-codex"))
    }

    @Test
    fun inheritModelIsTheEmptyNoOverrideSentinel() {
        // The dialog sends `forkModel.trim().ifEmpty { null }` to
        // forkSession, so the inherit option must be the empty string for
        // an untouched fork to carry no --model override.
        assertEquals("", forkModelInherit)
    }

    @Test
    fun modelLabelRendersInheritAsDefaultAndAliasesVerbatim() {
        assertEquals("Default (inherit)", forkModelLabel(forkModelInherit))
        assertEquals("Default (inherit)", forkModelLabel(""))
        assertEquals("opus", forkModelLabel("opus"))
        assertEquals("gpt-5-codex", forkModelLabel("gpt-5-codex"))
    }
}
