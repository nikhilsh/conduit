import Testing
import Foundation
@testable import SweKitty

/// Pins the contract `release-ios.yml` depends on when it rewrites
/// `Sources/Models/BuildInfo.swift` in place: a fresh checkout (the
/// state these tests run against) ships the "dev" sentinels, and the
/// `isStamped` predicate keys off `gitSHA != "dev"`. If a future PR
/// renames the constants or the sentinel literal, this suite fails
/// loudly so the workflow doesn't silently start shipping a "dev"
/// stamp on a production IPA.
@Suite("BuildInfo")
struct BuildInfoTests {

    /// Unstamped local builds report "dev" for the git SHA so the UI
    /// can fall back to an em-dash + dev hint instead of a fake hash.
    @Test func devBuildShipsDevSentinelForSHA() {
        #expect(BuildInfo.gitSHA == "dev")
    }

    /// Same for the release tag — the workflow overwrites both
    /// literals together, so an unstamped build must report "dev" for
    /// the tag too.
    @Test func devBuildShipsDevSentinelForTag() {
        #expect(BuildInfo.releaseTag == "dev")
    }

    /// `isStamped` keys off the SHA, not the tag. Mirrors the gate
    /// `SettingsSheet.aboutSection` uses to decide whether to render
    /// the Release tag row + Copy SHA menu item.
    @Test func isStampedIsFalseForDevBuild() {
        #expect(BuildInfo.isStamped == false)
    }

    /// `marketingVersion` / `buildNumber` come from the bundle, not
    /// the BuildInfo literals. Whichever `Bundle.main` resolves to in
    /// the test process, the accessors must return a non-empty string
    /// — either the real Info.plist value or the "—" fallback. The
    /// SettingsSheet UI relies on this to never render an empty label.
    @Test func bundleVersionsAreNeverEmpty() {
        #expect(!BuildInfo.marketingVersion.isEmpty)
        #expect(!BuildInfo.buildNumber.isEmpty)
    }
}
