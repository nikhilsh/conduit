package sh.nikhil.conduit.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import sh.nikhil.conduit.descriptorFor
import sh.nikhil.conduit.loginProviderFor
import sh.nikhil.conduit.parseAgentDescriptors

/**
 * Pins the agent-descriptor parsing + gating helpers introduced in WS-3.2.
 * Structure mirrors [AgentModelCatalogTest] in the same package.
 *
 * Tests are pure JVM (no Compose / no Android) — descriptors live in
 * `AgentModelCatalog.kt` alongside the model catalog, and the gating
 * helpers are top-level functions.
 */
class AgentDescriptorTest {

    // ---- wire JSON helpers -------------------------------------------

    private val wireWithAgents = """
        {
          "name": "conduit-broker",
          "agents": {
            "claude": {
              "display_name": "Claude",
              "login_provider": "anthropic",
              "supports": {
                "compact": true,
                "ask_user_question": true,
                "effort": true,
                "plan_mode": true,
                "usage": true
              }
            },
            "codex": {
              "display_name": "Codex",
              "login_provider": "openai",
              "supports": {
                "compact": false,
                "ask_user_question": false,
                "effort": true,
                "plan_mode": true,
                "usage": true
              }
            },
            "opencode": {
              "display_name": "OpenCode",
              "login_provider": "",
              "supports": {
                "compact": false,
                "ask_user_question": false,
                "effort": false,
                "plan_mode": false,
                "usage": false
              }
            }
          }
        }
    """.trimIndent()

    private val wireNoAgents = """{"name":"conduit-broker"}"""

    // ---- parseAgentDescriptors tests ---------------------------------

    @Test
    fun parseAgentDescriptorsDecodesAllFields() {
        val parsed = parseAgentDescriptors(wireWithAgents)
        assertEquals(setOf("claude", "codex", "opencode"), parsed.keys)

        val claude = parsed.getValue("claude")
        assertEquals("Claude", claude.displayName)
        assertEquals("anthropic", claude.loginProvider)
        assertTrue(claude.supportsCompact)
        assertTrue(claude.supportsAskUserQuestion)
        assertTrue(claude.supportsEffort)
        assertTrue(claude.supportsPlanMode)
        assertTrue(claude.supportsUsage)

        val codex = parsed.getValue("codex")
        assertEquals("Codex", codex.displayName)
        assertEquals("openai", codex.loginProvider)
        assertFalse(codex.supportsCompact)
        assertFalse(codex.supportsAskUserQuestion)
        assertTrue(codex.supportsEffort)
        assertTrue(codex.supportsPlanMode)
        assertTrue(codex.supportsUsage)

        val opencode = parsed.getValue("opencode")
        assertEquals("OpenCode", opencode.displayName)
        assertFalse(opencode.supportsEffort)
        assertFalse(opencode.supportsUsage)
    }

    @Test
    fun parseAgentDescriptorsWithoutAgentsKeyIsEmpty() {
        assertTrue(parseAgentDescriptors(wireNoAgents).isEmpty())
    }

    @Test
    fun parseAgentDescriptorsMissingFieldsDefaultSafely() {
        // A minimal entry — only display_name, no supports block.
        val raw = """{"agents":{"myagent":{"display_name":"MyAgent"}}}"""
        val parsed = parseAgentDescriptors(raw)
        val desc = parsed.getValue("myagent")
        assertEquals("MyAgent", desc.displayName)
        assertFalse(desc.supportsCompact)
        assertFalse(desc.supportsEffort)
        assertFalse(desc.supportsUsage)
        assertEquals("", desc.loginProvider)
    }

    // ---- descriptorFor / static fallback tests -----------------------

    @Test
    fun descriptorForPrefersLiveDescriptorsOverStatic() {
        val liveDescriptors = parseAgentDescriptors(wireWithAgents)
        // Live descriptor for claude has supportsUsage=true.
        val d = descriptorFor("claude", liveDescriptors)
        assertEquals("Claude", d.displayName)
        assertTrue(d.supportsUsage)
    }

    @Test
    fun descriptorForFallsBackToStaticForKnownAgentsWhenAbsent() {
        // Old broker → descriptors empty; claude/codex should get static behavior.
        val claude = descriptorFor("claude", emptyMap())
        assertTrue(claude.supportsCompact)
        assertTrue(claude.supportsEffort)
        assertTrue(claude.supportsUsage)
        assertEquals("anthropic", claude.loginProvider)

        val codex = descriptorFor("codex", emptyMap())
        assertFalse(codex.supportsCompact)
        assertTrue(codex.supportsEffort)
        assertTrue(codex.supportsUsage)
        assertEquals("openai", codex.loginProvider)
    }

    @Test
    fun descriptorForReturnsNeutralGenericForUnknownAgent() {
        val d = descriptorFor("newagent", emptyMap())
        // Generic: nothing enabled.
        assertFalse(d.supportsCompact)
        assertFalse(d.supportsEffort)
        assertFalse(d.supportsUsage)
        assertEquals("", d.loginProvider)
        // Display name derived from the key.
        assertEquals("Newagent", d.displayName)
    }

    @Test
    fun descriptorForCaseInsensitive() {
        val descriptors = parseAgentDescriptors(wireWithAgents)
        val d = descriptorFor("CLAUDE", descriptors)
        assertEquals("Claude", d.displayName)
        assertTrue(d.supportsCompact)
    }

    // ---- loginProviderFor tests --------------------------------------

    @Test
    fun loginProviderForPrefersBrokerDescriptor() {
        val descriptors = parseAgentDescriptors(wireWithAgents)
        assertEquals("anthropic", loginProviderFor("claude", descriptors))
        assertEquals("openai", loginProviderFor("codex", descriptors))
        assertEquals("", loginProviderFor("opencode", descriptors))
    }

    @Test
    fun loginProviderForStaticFallback() {
        assertEquals("anthropic", loginProviderFor("claude", emptyMap()))
        assertEquals("openai", loginProviderFor("codex", emptyMap()))
        assertEquals("", loginProviderFor("unknown", emptyMap()))
    }

    // ---- agentListFor (picker ordering) tests -----------------------

    @Test
    fun agentListForEmptyDescriptorsFallsBackToStaticPair() {
        assertEquals(listOf("claude", "codex"), agentListFor(emptyMap()))
    }

    @Test
    fun agentListForPutsClaudeFirstThenCodexThenExtras() {
        val descriptors = parseAgentDescriptors(wireWithAgents)
        val list = agentListFor(descriptors)
        assertEquals("claude", list[0])
        assertEquals("codex", list[1])
        assertTrue("opencode" in list)
    }

    @Test
    fun agentListForHandlesMissingKnownAgents() {
        // A broker that only serves opencode (no claude/codex yet).
        val raw = """{"agents":{"opencode":{"display_name":"OpenCode","login_provider":"","supports":{}}}}"""
        val descriptors = parseAgentDescriptors(raw)
        val list = agentListFor(descriptors)
        // claude/codex absent from broker's list → not in the result.
        assertFalse("claude" in list)
        assertFalse("codex" in list)
        assertTrue("opencode" in list)
    }

    // ---- gating helpers present/absent ---------------------------------

    @Test
    fun staticDescriptorGatingPreservesTodaysBehavior() {
        // With no descriptors (old broker), static fallback:
        // claude: compact=true, effort=true, usage=true
        // codex: compact=false, effort=true, usage=true
        val claudeDesc = descriptorFor("claude", emptyMap())
        assertTrue(claudeDesc.supportsCompact)
        assertTrue(claudeDesc.supportsEffort)
        assertTrue(claudeDesc.supportsUsage)

        val codexDesc = descriptorFor("codex", emptyMap())
        assertFalse(codexDesc.supportsCompact)
        assertTrue(codexDesc.supportsEffort)
        assertTrue(codexDesc.supportsUsage)
    }

    @Test
    fun liveDescriptorCanGrantOrRevokeCaps() {
        // A hypothetical future broker that enables compact for codex:
        val raw = """
            {"agents":{"codex":{"display_name":"Codex","login_provider":"openai",
              "supports":{"compact":true,"effort":false,"usage":false}}}}
        """.trimIndent()
        val descriptors = parseAgentDescriptors(raw)
        val codex = descriptorFor("codex", descriptors)
        assertTrue(codex.supportsCompact)
        assertFalse(codex.supportsEffort)
        assertFalse(codex.supportsUsage)
    }
}
