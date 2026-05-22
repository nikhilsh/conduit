import Foundation

/// Build provenance the user can read from Settings → About so a bug
/// report tells us exactly which IPA they're on.
///
/// Two sources of truth:
///
/// - `marketingVersion` / `buildNumber` come from the bundle Info.plist
///   (`CFBundleShortVersionString` / `CFBundleVersion`). These are
///   already populated by xcodegen from `MARKETING_VERSION` /
///   `CURRENT_PROJECT_VERSION` in `project.yml`, so they show up on
///   every build (local dev, CI, ad-hoc).
///
/// - `gitSHA` / `releaseTag` are baked into the binary via the
///   literals below. Local dev builds ship the "dev" sentinels; the
///   release workflow (`.github/workflows/release-ios.yml`) overwrites
///   the two `static let` lines with real values just before invoking
///   `xcodebuild archive`. We picked literal-rewriting over xcodebuild
///   `-buildSetting` + Info.plist substitution because (a) it survives
///   without an Info.plist round-trip, (b) it's trivially testable
///   (`gitSHA == "dev"` in tests), and (c) any future surface that
///   wants to read this (crash report header, in-app diagnostic
///   bundle) gets it as a pure Swift constant.
enum BuildInfo {
    /// First 7 chars of the commit the IPA was built from, or "dev"
    /// for an unstamped (local) build. Format-stable — the release
    /// workflow always writes exactly 7 chars.
    static let gitSHA: String = "dev"

    /// Full release tag the IPA was uploaded under (e.g.
    /// `manual-2026-05-22-oauth-redesign`), or "dev" for a local
    /// build. Useful when the SHA alone doesn't disambiguate two
    /// hot-fix builds from the same commit.
    static let releaseTag: String = "dev"

    /// `CFBundleShortVersionString` — the marketing version
    /// (`MARKETING_VERSION` in project.yml). Falls back to "—" when
    /// the bundle is missing the key, which shouldn't happen for the
    /// app target but keeps the UI safe in unit-test hosts.
    static var marketingVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "—"
    }

    /// `CFBundleVersion` — the build number (`CURRENT_PROJECT_VERSION`
    /// in project.yml). Same fallback rationale as `marketingVersion`.
    static var buildNumber: String {
        (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "—"
    }

    /// `true` when the IPA was stamped by the release workflow.
    /// Settings hides rows whose value is the "dev" sentinel via this
    /// flag so unstamped builds don't look broken.
    static var isStamped: Bool { gitSHA != "dev" }
}
