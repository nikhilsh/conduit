import Testing
import Foundation
@testable import Conduit

/// Pins the chat-shell-v2 experiment contract (handoff §2) and the
/// new-session flag persistence (§3).
@Suite("FeatureFlags")
struct FeatureFlagsTests {

    // MARK: - Deterministic bucketing

    @Test func bucketIsDeterministicForSameID() {
        // The same stable id must always land in the same arm — across calls
        // and across process launches (FNV-1a, not Swift's seeded hashValue).
        let id = "device-ABC-123"
        #expect(FeatureFlags.bucket(for: id) == FeatureFlags.bucket(for: id))
    }

    @Test func bucketSplitsAcrossIDs() {
        // Over many ids the 50/50 split should produce both arms — a sanity
        // check that bucketing isn't pinned to one side.
        var sawA = false, sawB = false
        for n in 0..<200 {
            switch FeatureFlags.bucket(for: "id-\(n)") {
            case .a: sawA = true
            case .b: sawB = true
            }
        }
        #expect(sawA && sawB)
    }

    @Test func assignedArmPersistsAndDoesNotRebucket() {
        let defaults = freshDefaults()
        let first = FeatureFlags(defaults: defaults)
        let assigned = first.chatAssignedArm
        // A relaunch reads the SAME assignment — never re-bucketed.
        let second = FeatureFlags(defaults: defaults)
        #expect(second.chatAssignedArm == assigned)
    }

    // MARK: - Resolution

    @Test func autoResolvesToAssignedBucket() {
        let flags = FeatureFlags(defaults: freshDefaults())
        flags.chatStylePreference = .auto
        #expect(flags.resolvedChatArm == flags.chatAssignedArm)
    }

    @Test func localOverrideWinsButDoesNotChangeBucket() {
        let flags = FeatureFlags(defaults: freshDefaults())
        let assigned = flags.chatAssignedArm
        flags.chatStylePreference = .b
        #expect(flags.resolvedChatArm == .b)
        flags.chatStylePreference = .a
        #expect(flags.resolvedChatArm == .a)
        // The logged bucket is untouched by a local override (§2 acceptance).
        #expect(flags.chatAssignedArm == assigned)
    }

    @Test func killSwitchForcesArmAGlobally() {
        let flags = FeatureFlags(defaults: freshDefaults())
        flags.chatStylePreference = .b   // even with a B override…
        flags.chatExperimentKilled = true
        #expect(flags.resolvedChatArm == .a)
    }

    // MARK: - Exposure

    @Test func exposureLogsOnlyOnce() {
        // The flag flips on the first call and stays flipped across a
        // relaunch — exposure must be one-per-install.
        let defaults = freshDefaults()
        let flags = FeatureFlags(defaults: defaults)
        flags.logChatExposureIfNeeded()
        flags.logChatExposureIfNeeded()
        // Re-hydrate: a fresh instance must see exposure as already logged
        // (so it won't re-fire). We assert via the persisted key staying set.
        #expect(defaults.bool(forKey: "conduit.flags.chat.exposureLogged"))
    }

    // MARK: - New-session flags

    @Test func newSessionFlagsDefaultOnAndPersist() {
        let defaults = freshDefaults()
        let first = FeatureFlags(defaults: defaults)
        #expect(first.newSessionAgentCards)
        #expect(first.newSessionEffortDial)
        #expect(first.newSessionLaunchLine)
        first.newSessionEffortDial = false
        let second = FeatureFlags(defaults: defaults)
        #expect(second.newSessionEffortDial == false)
    }

    @Test func lastEffortPersists() {
        let defaults = freshDefaults()
        let first = FeatureFlags(defaults: defaults)
        first.newSessionLastEffort = "high"
        let second = FeatureFlags(defaults: defaults)
        #expect(second.newSessionLastEffort == "high")
    }

    // MARK: - Onboarding routing (§5 — accounts-free, device-local gating)

    @Test func routeFullWhenNoBrokerPaired() {
        // No pairing key on this device → full setup. Reachability is moot
        // when nothing is paired.
        #expect(FeatureFlags.onboardingRoute(pairedBrokers: 0, brokerReachable: false) == .full)
        #expect(FeatureFlags.onboardingRoute(pairedBrokers: 0, brokerReachable: true) == .full)
    }

    @Test func routeNoneWhenAnyBrokerPairedRegardlessOfReachability() {
        // Paired-but-offline = Home + offline banner; paired-and-reachable =
        // Home. Neither re-onboards. No account / pair-only fast-path exists.
        #expect(FeatureFlags.onboardingRoute(pairedBrokers: 1, brokerReachable: false) == .none)
        #expect(FeatureFlags.onboardingRoute(pairedBrokers: 2, brokerReachable: true) == .none)
    }

    @Test func fullRouteSkipsWelcomeOnceSeen() {
        let flags = FeatureFlags(defaults: freshDefaults())
        // Fresh: Welcome (0).
        #expect(flags.onboardingInitialStep(for: .full) == 0)
        // After Welcome seen: enters at Install (1), never back at Welcome.
        flags.onboardingSeenWelcome = true
        #expect(flags.onboardingInitialStep(for: .full) == 1)
    }

    @Test func fullRouteResumesAtFurthestStep() {
        let flags = FeatureFlags(defaults: freshDefaults())
        flags.onboardingSeenWelcome = true
        flags.onboardingFurthestStep = 2   // got to Pair before quitting
        #expect(flags.onboardingInitialStep(for: .full) == 2)
    }

    @Test func noneRouteLandsOnDone() {
        let flags = FeatureFlags(defaults: freshDefaults())
        #expect(flags.onboardingInitialStep(for: .none) == 3)
    }

    // MARK: - Helpers

    private func freshDefaults() -> UserDefaults {
        let suite = "conduit.tests.flags.\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }
}
