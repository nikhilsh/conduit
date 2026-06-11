package sh.nikhil.conduit

import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * Unit tests for WS-H.2 (broker version comparison) and WS-H.3 (readiness
 * checklist derivation). Pure-logic only — no Android framework or Compose.
 * Mirrors iOS `ConnectionHealthTests.swift`.
 */
@RunWith(RobolectricTestRunner::class)
class ConnectionHealthTest {

    // ------------------------------------------------------------------
    // WS-H.2: brokerVersionStatus
    // ------------------------------------------------------------------

    @Test fun devVersionIsUnknown() {
        assertEquals(BrokerVersionStatus.Unknown, brokerVersionStatus("dev"))
    }

    @Test fun emptyVersionIsUnknown() {
        assertEquals(BrokerVersionStatus.Unknown, brokerVersionStatus(""))
    }

    @Test fun unparsableVersionIsUnknown() {
        assertEquals(BrokerVersionStatus.Unknown, brokerVersionStatus("not-semver"))
        assertEquals(BrokerVersionStatus.Unknown, brokerVersionStatus("1.2"))
    }

    @Test fun unparsableMinimumIsUnknown() {
        assertEquals(BrokerVersionStatus.Unknown, brokerVersionStatus("v0.0.120", "dev"))
    }

    @Test fun exactMatchIsCurrent() {
        assertEquals(BrokerVersionStatus.Current, brokerVersionStatus("v0.0.120", "v0.0.120"))
    }

    @Test fun newerPatchIsCurrent() {
        assertEquals(BrokerVersionStatus.Current, brokerVersionStatus("v0.0.121", "v0.0.120"))
    }

    @Test fun newerMinorIsCurrent() {
        assertEquals(BrokerVersionStatus.Current, brokerVersionStatus("v0.1.0", "v0.0.120"))
    }

    @Test fun newerMajorIsCurrent() {
        assertEquals(BrokerVersionStatus.Current, brokerVersionStatus("v1.0.0", "v0.0.120"))
    }

    @Test fun vPrefixOptional() {
        assertEquals(BrokerVersionStatus.Current, brokerVersionStatus("0.0.121", "v0.0.120"))
        assertEquals(BrokerVersionStatus.Current, brokerVersionStatus("v0.0.121", "0.0.120"))
    }

    @Test fun olderPatchIsUpdateAvailable() {
        val result = brokerVersionStatus("v0.0.119", "v0.0.120")
        assertTrue(result is BrokerVersionStatus.UpdateAvailable)
        assertEquals("v0.0.119", (result as BrokerVersionStatus.UpdateAvailable).brokerVersion)
    }

    @Test fun olderMinorIsUpdateAvailable() {
        assertTrue(brokerVersionStatus("v0.0.50", "v0.1.0") is BrokerVersionStatus.UpdateAvailable)
    }

    @Test fun olderMajorIsUpdateAvailable() {
        assertTrue(brokerVersionStatus("v0.9.99", "v1.0.0") is BrokerVersionStatus.UpdateAvailable)
    }

    // ------------------------------------------------------------------
    // WS-H.3: readinessCheckItems
    // ------------------------------------------------------------------

    private fun readiness(
        brokerVersion: String = "v0.0.120",
        nodePresent: Boolean = true,
        tmuxPresent: Boolean = true,
        agents: Map<String, AgentReadiness> = emptyMap(),
    ) = BrokerReadiness(brokerVersion, nodePresent, tmuxPresent, agents)

    @Test fun emptyAgentsProducesNoItems() {
        assertTrue(readinessCheckItems(readiness(), emptyMap()).isEmpty())
    }

    @Test fun missingNodeAppendsAbsentRow() {
        val items = readinessCheckItems(readiness(nodePresent = false), emptyMap())
        assertEquals(1, items.size)
        assertEquals("node", items[0].id)
        assertEquals(ReadinessStatus.Absent, items[0].status)
    }

    @Test fun missingTmuxAppendsAbsentRow() {
        val items = readinessCheckItems(readiness(tmuxPresent = false), emptyMap())
        assertEquals(1, items.size)
        assertEquals("tmux", items[0].id)
    }

    @Test fun bothInfraAbsent() {
        val items = readinessCheckItems(readiness(nodePresent = false, tmuxPresent = false), emptyMap())
        assertEquals(2, items.size)
        val ids = items.map { it.id }
        assertTrue(ids.contains("node"))
        assertTrue(ids.contains("tmux"))
    }

    @Test fun presentInfraProducesNoInfraRows() {
        val items = readinessCheckItems(readiness(), emptyMap())
        assertFalse(items.any { it.id == "node" || it.id == "tmux" })
    }

    @Test fun signedInAgentIsOk() {
        val r = readiness(agents = mapOf("claude" to AgentReadiness(cliPresent = true, signedIn = true, authExpiresInS = null)))
        val items = readinessCheckItems(r, emptyMap())
        assertEquals(1, items.size)
        assertEquals("claude", items[0].id)
        assertEquals(ReadinessStatus.Ok, items[0].status)
    }

    @Test fun notSignedInAgentShowsNotSignedIn() {
        val r = readiness(agents = mapOf("claude" to AgentReadiness(true, false, null)))
        val items = readinessCheckItems(r, emptyMap())
        assertEquals(ReadinessStatus.NotSignedIn, items[0].status)
    }

    @Test fun notInstalledAgentShowsNotInstalled() {
        val r = readiness(agents = mapOf("opencode" to AgentReadiness(false, false, null)))
        val items = readinessCheckItems(r, emptyMap())
        assertEquals(ReadinessStatus.NotInstalled, items[0].status)
    }

    @Test fun loginProviderPropagated() {
        val r = readiness(agents = mapOf("claude" to AgentReadiness(true, false, null)))
        val desc = mapOf("claude" to AgentDescriptor(
            displayName = "Claude",
            loginProvider = "anthropic",
            supportsCompact = false, supportsAskUserQuestion = false,
            supportsEffort = true, supportsPlanMode = false, supportsUsage = false,
        ))
        val items = readinessCheckItems(r, desc)
        assertEquals("anthropic", items[0].loginProvider)
    }

    @Test fun displayNameFromDescriptorWhenAvailable() {
        val r = readiness(agents = mapOf("claude" to AgentReadiness(true, true, null)))
        val desc = mapOf("claude" to AgentDescriptor(
            displayName = "Claude",
            loginProvider = "anthropic",
            supportsCompact = false, supportsAskUserQuestion = false,
            supportsEffort = true, supportsPlanMode = false, supportsUsage = false,
        ))
        val items = readinessCheckItems(r, desc)
        assertEquals("Claude", items[0].label)
    }

    @Test fun agentKeyFallbackToCapitalized() {
        val r = readiness(agents = mapOf("opencode" to AgentReadiness(true, true, null)))
        val items = readinessCheckItems(r, emptyMap())
        assertEquals("Opencode", items[0].label)
    }

    @Test fun agentRowsSortedAlphabetically() {
        val r = readiness(agents = mapOf(
            "zapp"   to AgentReadiness(true, true, null),
            "alpha"  to AgentReadiness(true, true, null),
            "middle" to AgentReadiness(true, true, null),
        ))
        val items = readinessCheckItems(r, emptyMap())
        val ids = items.map { it.id }
        assertEquals(ids.sorted(), ids)
    }

    @Test fun agentRowsBeforeInfraRows() {
        val r = readiness(
            nodePresent = false,
            agents = mapOf("claude" to AgentReadiness(true, true, null)),
        )
        val items = readinessCheckItems(r, emptyMap())
        assertEquals(2, items.size)
        assertEquals("claude", items[0].id)
        assertEquals("node", items[1].id)
    }

    // ------------------------------------------------------------------
    // parseReadiness
    // ------------------------------------------------------------------

    @Test fun parseReadinessFullBlock() {
        val json = """
        {
          "readiness": {
            "broker_version": "v0.0.120",
            "node_present": true,
            "tmux_present": false,
            "agents": {
              "claude": {"cli_present": true, "signed_in": true, "auth_expires_in_s": null},
              "codex":  {"cli_present": false, "signed_in": false}
            }
          }
        }
        """.trimIndent()
        val r = parseReadiness(json)!!
        assertEquals("v0.0.120", r.brokerVersion)
        assertTrue(r.nodePresent)
        assertFalse(r.tmuxPresent)
        assertEquals(2, r.agents.size)
        assertTrue(r.agents["claude"]!!.cliPresent)
        assertTrue(r.agents["claude"]!!.signedIn)
        assertNull(r.agents["claude"]!!.authExpiresInS)
        assertFalse(r.agents["codex"]!!.cliPresent)
    }

    @Test fun parseReadinessMissingBlockReturnsNull() {
        val json = """{"models": {}}"""
        assertNull(parseReadiness(json))
    }

    @Test fun parseReadinessMalformedReturnsNull() {
        assertNull(parseReadiness("not json"))
    }
}
