package sh.nikhil.conduit.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import sh.nikhil.conduit.SessionStore
import sh.nikhil.conduit.parseModelCatalog

/**
 * Pins the catalog-aware fork option helpers: with a broker-discovered
 * catalog the picker options come from the agent itself (per-model effort
 * ranges, live display names); without one everything falls back to the
 * static lists. Mirror of iOS `ConduitForkOptionsCatalogTests`.
 */
class AgentModelCatalogTest {
    // Shapes mirror what the broker normalizes from the live agents
    // (claude initialize control response / codex model/list).
    private val claudeCatalog = listOf(
        SessionStore.AgentModel(
            id = "", displayName = "Default (recommended)",
            description = "Opus 4.8 with 1M context · Best for everyday, complex tasks",
            isDefault = true, efforts = listOf("low", "medium", "high", "xhigh", "max"),
        ),
        SessionStore.AgentModel(
            id = "claude-fable-5[1m]", displayName = "Fable",
            description = "Fable 5 · Most capable",
            efforts = listOf("low", "medium", "high", "xhigh", "max"),
        ),
        SessionStore.AgentModel(
            id = "sonnet", displayName = "Sonnet",
            description = "Sonnet 4.6 · Efficient for routine tasks",
            efforts = listOf("low", "medium", "high", "max"),
        ),
        SessionStore.AgentModel(
            id = "haiku", displayName = "Haiku",
            description = "Haiku 4.5 · Fastest for quick answers",
        ),
    )
    private val codexCatalog = listOf(
        SessionStore.AgentModel(
            id = "gpt-5.5", displayName = "GPT-5.5",
            description = "Frontier model for complex coding.",
            isDefault = true, defaultEffort = "medium",
            efforts = listOf("low", "medium", "high", "xhigh"),
        ),
        SessionStore.AgentModel(
            id = "gpt-5.4-mini", displayName = "GPT-5.4-Mini",
            description = "Small and fast.", defaultEffort = "medium",
            efforts = listOf("low", "medium"),
        ),
    )

    @Test
    fun catalogModelsPrependInheritWhenAbsent() {
        // codex's catalog has an explicit non-empty isDefault ("gpt-5.5") — that
        // entry IS the recommended row, so the "" sentinel is NOT prepended (no duplicate).
        assertEquals(listOf("gpt-5.5", "gpt-5.4-mini"), forkModelOptions("codex", codexCatalog))
        assertFalse(forkModelOptions("codex", codexCatalog).contains(""))
        // claude's catalog already leads with the normalized "" entry (id="" isDefault).
        assertEquals(listOf("", "claude-fable-5[1m]", "sonnet", "haiku"), forkModelOptions("claude", claudeCatalog))
    }

    @Test
    fun nullOrEmptyCatalogFallsBackToStaticLists() {
        assertEquals(forkModelOptions("claude"), forkModelOptions("claude", null))
        assertEquals(forkModelOptions("codex"), forkModelOptions("codex", emptyList()))
        assertEquals(forkEffortOptions("claude"), forkEffortOptions("claude", "", null))
    }

    @Test
    fun effortsArePerModel() {
        // sonnet lacks xhigh; haiku has no effort control at all.
        assertEquals(listOf("low", "medium", "high", "max"), forkEffortOptions("claude", "sonnet", claudeCatalog))
        assertTrue(forkEffortOptions("claude", "haiku", claudeCatalog).isEmpty())
        // codex xhigh flows through from the live catalog (the static
        // fallback list tops out at high).
        assertTrue(forkEffortOptions("codex", "gpt-5.5", codexCatalog).contains("xhigh"))
        assertFalse(forkEffortOptions("codex").contains("xhigh"))
    }

    @Test
    fun inheritResolvesToDefaultEntryForEfforts() {
        // Selecting "Default (inherit)" on codex uses the default model's
        // effort range (gpt-5.5), not an empty list.
        assertEquals(listOf("low", "medium", "high", "xhigh"), forkEffortOptions("codex", "", codexCatalog))
    }

    @Test
    fun defaultEffortPrefersAgentAdvertisedDefault() {
        assertEquals("medium", forkDefaultEffort("codex", "gpt-5.5", codexCatalog))
        // haiku: no effort control → empty (UI hides the section).
        assertEquals("", forkDefaultEffort("claude", "haiku", claudeCatalog))
        // No catalog → static list default.
        assertEquals("medium", forkDefaultEffort("claude"))
    }

    @Test
    fun modelLabelAndDetailComeFromCatalog() {
        // codex's gpt-5.5 is the isDefault entry — show "(recommended)" suffix.
        assertEquals("GPT-5.5 (recommended)", forkModelLabel("gpt-5.5", codexCatalog))
        // claude's "" entry has displayName "Default (recommended)" → resolved name.
        assertEquals("Opus 4.8 (recommended)", forkModelLabel("", claudeCatalog))
        // Unknown id (stale selection) falls back to verbatim.
        assertEquals("opus", forkModelLabel("opus", codexCatalog))
        assertEquals("Sonnet 4.6 · Efficient for routine tasks", forkModelDetail("sonnet", claudeCatalog))
        // Inherit resolves to the default entry's description.
        assertEquals("Frontier model for complex coding.", forkModelDetail("", codexCatalog))
        assertNull(forkModelDetail("opus", null))
    }

    @Test
    fun defaultModelTitleResolvesCardLabel() {
        // codex: the default entry's display name verbatim.
        assertEquals("GPT-5.5", defaultModelTitle(codexCatalog))
        // claude: "Default (recommended)" resolves through the description's
        // first ·-chunk, with the context-size suffix stripped.
        assertEquals("Opus 4.8", defaultModelTitle(claudeCatalog))
        assertNull(defaultModelTitle(null))
        assertNull(defaultModelTitle(emptyList()))
    }

    @Test
    fun effortLabelsCoverKnownLevelsAndFallBack() {
        assertEquals("Fast", effortLabel("low"))
        assertEquals("Balanced", effortLabel("medium"))
        assertEquals("Deep", effortLabel("high"))
        assertEquals("X-High", effortLabel("xhigh"))
        assertEquals("Max", effortLabel("max"))
        assertEquals("Turbo", effortLabel("turbo"))
    }

    @Test
    fun parseModelCatalogDecodesBrokerWireShape() {
        val raw = """
            {"name":"conduit-broker","models":{
              "codex":[
                {"id":"gpt-5.5","display_name":"GPT-5.5","description":"Frontier.",
                 "is_default":true,"default_effort":"medium","efforts":["low","medium","high","xhigh"]},
                {"id":"gpt-5.4-mini","display_name":"GPT-5.4-Mini"}
              ],
              "claude":[
                {"id":"","display_name":"Default (recommended)","is_default":true,
                 "efforts":["low","medium","high","xhigh","max"]}
              ]
            }}
        """.trimIndent()
        val parsed = parseModelCatalog(raw)
        assertEquals(setOf("claude", "codex"), parsed.keys)
        val codex = parsed.getValue("codex")
        assertEquals(2, codex.size)
        assertEquals("gpt-5.5", codex[0].id)
        assertTrue(codex[0].isDefault)
        assertEquals(listOf("low", "medium", "high", "xhigh"), codex[0].efforts)
        // Omitted optional fields parse to inert defaults.
        assertTrue(codex[1].efforts.isEmpty())
        assertFalse(codex[1].isDefault)
        assertEquals("", codex[1].defaultEffort)
        // claude's normalized inherit entry survives with id "".
        assertEquals("", parsed.getValue("claude")[0].id)
    }

    @Test
    fun parseModelCatalogWithoutModelsKeyIsEmpty() {
        assertTrue(parseModelCatalog("""{"name":"conduit-broker"}""").isEmpty())
    }

    @Test
    fun supportsFastModeOnlyOnAnnotatedEntries() {
        val withFastMode = listOf(
            SessionStore.AgentModel(
                id = "", displayName = "Default (recommended)",
                description = "Opus 4.8 with 1M context · Best for everyday, complex tasks",
                isDefault = true, efforts = listOf("low", "medium", "high", "xhigh", "max"),
                supportsFastMode = true,
            ),
            SessionStore.AgentModel(
                id = "sonnet", displayName = "Sonnet",
                description = "Sonnet 4.6 · Efficient for routine tasks",
                efforts = listOf("low", "medium", "high", "max"),
            ),
        )
        // Inherit sentinel resolves to the default entry — fast mode true.
        assertTrue(forkModelSupportsFastMode("", withFastMode))
        // Explicit sonnet entry — fast mode false.
        assertFalse(forkModelSupportsFastMode("sonnet", withFastMode))
        // No catalog — always false.
        assertFalse(forkModelSupportsFastMode("", null))
    }

    @Test
    fun parseModelCatalogDecodesSupportsFastMode() {
        val raw = """
            {"name":"conduit-broker","models":{
              "claude":[
                {"id":"","display_name":"Default (recommended)","is_default":true,
                 "supports_fast_mode":true,"efforts":["low","medium","high","xhigh","max"]},
                {"id":"sonnet","display_name":"Sonnet"}
              ]
            }}
        """.trimIndent()
        val parsed = parseModelCatalog(raw)
        val claude = parsed.getValue("claude")
        assertTrue(claude[0].supportsFastMode)
        assertFalse(claude[1].supportsFastMode)
    }
}
