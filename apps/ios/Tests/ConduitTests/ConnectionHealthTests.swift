import Testing
@testable import Conduit

// MARK: - WS-H.2: broker version comparison

@Suite("brokerVersionStatus")
struct BrokerVersionStatusTests {

    // MARK: Unknown paths

    @Test func devVersionIsUnknown() {
        #expect(brokerVersionStatus(brokerVersion: "dev", minimumVersion: "v0.0.100") == .unknown)
    }

    @Test func emptyVersionIsUnknown() {
        #expect(brokerVersionStatus(brokerVersion: "", minimumVersion: "v0.0.100") == .unknown)
    }

    @Test func unparsableVersionIsUnknown() {
        #expect(brokerVersionStatus(brokerVersion: "not-semver", minimumVersion: "v0.0.100") == .unknown)
        #expect(brokerVersionStatus(brokerVersion: "1.2", minimumVersion: "v0.0.100") == .unknown)
    }

    @Test func unparsableMinimumIsUnknown() {
        // If the minimum itself can't be parsed we can't compare — treat as unknown.
        #expect(brokerVersionStatus(brokerVersion: "v0.0.120", minimumVersion: "dev") == .unknown)
    }

    // MARK: Current paths

    @Test func exactMatchIsCurrent() {
        #expect(brokerVersionStatus(brokerVersion: "v0.0.120", minimumVersion: "v0.0.120") == .current)
    }

    @Test func newerPatchIsCurrent() {
        #expect(brokerVersionStatus(brokerVersion: "v0.0.121", minimumVersion: "v0.0.120") == .current)
    }

    @Test func newerMinorIsCurrent() {
        #expect(brokerVersionStatus(brokerVersion: "v0.1.0", minimumVersion: "v0.0.120") == .current)
    }

    @Test func newerMajorIsCurrent() {
        #expect(brokerVersionStatus(brokerVersion: "v1.0.0", minimumVersion: "v0.0.120") == .current)
    }

    @Test func vPrefixOptional() {
        // Broker may omit the "v" prefix.
        #expect(brokerVersionStatus(brokerVersion: "0.0.121", minimumVersion: "v0.0.120") == .current)
        #expect(brokerVersionStatus(brokerVersion: "v0.0.121", minimumVersion: "0.0.120") == .current)
    }

    // MARK: Update-available paths

    @Test func olderPatchIsUpdateAvailable() {
        let result = brokerVersionStatus(brokerVersion: "v0.0.119", minimumVersion: "v0.0.120")
        if case .updateAvailable(let v) = result {
            #expect(v == "v0.0.119")
        } else {
            Issue.record("Expected .updateAvailable, got \(result)")
        }
    }

    @Test func olderMinorIsUpdateAvailable() {
        let result = brokerVersionStatus(brokerVersion: "v0.0.50", minimumVersion: "v0.1.0")
        if case .updateAvailable = result {
            // pass
        } else {
            Issue.record("Expected .updateAvailable, got \(result)")
        }
    }
}

// MARK: - WS-H.3: readiness checklist derivation

@Suite("readinessCheckItems")
struct ReadinessCheckItemsTests {

    private func makeReadiness(
        brokerVersion: String = "v0.0.120",
        nodePresent: Bool = true,
        tmuxPresent: Bool = true,
        gitPresent: Bool = true,
        agents: [String: AgentReadiness] = [:]
    ) -> BrokerReadiness {
        BrokerReadiness(
            brokerVersion: brokerVersion,
            nodePresent: nodePresent,
            tmuxPresent: tmuxPresent,
            gitPresent: gitPresent,
            agents: agents
        )
    }

    // MARK: Empty / infra-only paths

    @Test func emptyAgentsProducesNoItems() {
        let items = readinessCheckItems(readiness: makeReadiness(), descriptors: [:])
        #expect(items.isEmpty)
    }

    @Test func missingNodeProducesNoRow() {
        // node is a terminal-scrollback sidecar; absence must not block the picker.
        let items = readinessCheckItems(readiness: makeReadiness(nodePresent: false), descriptors: [:])
        #expect(!items.contains(where: { $0.id == "node" }))
    }

    @Test func missingTmuxAppendsAbsentRow() {
        let items = readinessCheckItems(readiness: makeReadiness(tmuxPresent: false), descriptors: [:])
        #expect(items.count == 1)
        #expect(items[0].id == "tmux")
        #expect(items[0].status == .absent)
    }

    @Test func bothInfraAbsent() {
        // node absence is suppressed; only tmux should appear.
        let items = readinessCheckItems(
            readiness: makeReadiness(nodePresent: false, tmuxPresent: false),
            descriptors: [:]
        )
        #expect(items.count == 1)
        #expect(items[0].id == "tmux")
    }

    @Test func missingGitAppendsAbsentRow() {
        let items = readinessCheckItems(readiness: makeReadiness(gitPresent: false), descriptors: [:])
        #expect(items.count == 1)
        #expect(items[0].id == "git")
        #expect(items[0].status == .absent)
    }

    @Test func presentInfraProducesNoInfraRows() {
        let items = readinessCheckItems(
            readiness: makeReadiness(nodePresent: true, tmuxPresent: true, gitPresent: true),
            descriptors: [:]
        )
        let ids: [String] = items.map(\.id)
        #expect(!ids.contains("node"))
        #expect(!ids.contains("tmux"))
        #expect(!ids.contains("git"))
    }

    // MARK: Agent rows

    @Test func signedInAgentIsOk() {
        let r = makeReadiness(agents: [
            "claude": AgentReadiness(cliPresent: true, signedIn: true)
        ])
        let items = readinessCheckItems(readiness: r, descriptors: [:])
        #expect(items.count == 1)
        #expect(items[0].id == "claude")
        #expect(items[0].status == .ok)
    }

    @Test func notSignedInAgentShowsNotSignedIn() {
        let r = makeReadiness(agents: [
            "claude": AgentReadiness(cliPresent: true, signedIn: false)
        ])
        let items = readinessCheckItems(readiness: r, descriptors: [:])
        #expect(items[0].status == .notSignedIn)
    }

    @Test func notInstalledAgentShowsNotInstalled() {
        let r = makeReadiness(agents: [
            "opencode": AgentReadiness(cliPresent: false, signedIn: false)
        ])
        let items = readinessCheckItems(readiness: r, descriptors: [:])
        #expect(items[0].status == .notInstalled)
    }

    @Test func loginProviderPropagated() {
        let r = makeReadiness(agents: [
            "claude": AgentReadiness(cliPresent: true, signedIn: false)
        ])
        let desc: [String: AgentDescriptor] = [
            "claude": AgentDescriptor(displayName: "Claude", loginProvider: "anthropic")
        ]
        let items = readinessCheckItems(readiness: r, descriptors: desc)
        #expect(items[0].loginProvider == "anthropic")
    }

    @Test func displayNameFromDescriptorWhenAvailable() {
        let r = makeReadiness(agents: [
            "claude": AgentReadiness(cliPresent: true, signedIn: true)
        ])
        let desc: [String: AgentDescriptor] = [
            "claude": AgentDescriptor(displayName: "Claude", loginProvider: "anthropic")
        ]
        let items = readinessCheckItems(readiness: r, descriptors: desc)
        #expect(items[0].label == "Claude")
    }

    @Test func agentKeysFallbackToCapitalized() {
        let r = makeReadiness(agents: [
            "opencode": AgentReadiness(cliPresent: true, signedIn: true)
        ])
        let items = readinessCheckItems(readiness: r, descriptors: [:])
        #expect(items[0].label == "Opencode")
    }

    @Test func agentRowsSortedAlphabetically() {
        let r = makeReadiness(agents: [
            "zapp":   AgentReadiness(cliPresent: true, signedIn: true),
            "alpha":  AgentReadiness(cliPresent: true, signedIn: true),
            "middle": AgentReadiness(cliPresent: true, signedIn: true),
        ])
        let items = readinessCheckItems(readiness: r, descriptors: [:])
        // Infra rows are absent (node+tmux present), so all are agent rows.
        let ids = items.map(\.id)
        #expect(ids == ids.sorted())
    }

    @Test func agentRowsBeforeInfraRows() {
        // node is suppressed; with tmux absent the infra row appears after agents.
        let r = makeReadiness(
            tmuxPresent: false,
            agents: ["claude": AgentReadiness(cliPresent: true, signedIn: true)]
        )
        let items = readinessCheckItems(readiness: r, descriptors: [:])
        #expect(items.count == 2)
        #expect(items[0].id == "claude")
        #expect(items[1].id == "tmux")
    }
}
