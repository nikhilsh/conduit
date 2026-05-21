import Testing
import SwiftUI
import SnapshotTesting
@testable import SweKitty

/// Placeholder test that proves the SnapshotTesting package is linked
/// into SweKittyTests. Real visual snapshots land in a follow-up PR
/// once goldens have been recorded on a real Mac and committed.
///
/// **Adding a new snapshot test:**
///
/// 1. Write the test calling `assertSnapshot(of:as:)`:
///
///    ```swift
///    let view = HealthDot(health: "green").frame(width: 32, height: 32)
///    assertSnapshot(of: UIHostingController(rootView: view),
///                   as: .image(precision: 0.99, perceptualPrecision: 0.99))
///    ```
///
/// 2. First run records the reference PNG under
///    `apps/ios/Tests/SweKittyTests/__Snapshots__/` and fails the test.
///
/// 3. `git add` the new PNG, commit it. Subsequent runs assert.
///
/// 4. CI uploads `xcodebuild`'s test-result bundle as an artifact on
///    failure (see ci.yml) so visual diffs are visible to PR reviewers.
///
/// **Why we use perceptualPrecision 0.99 (not 1.0):** subpixel
/// rendering varies across simulator versions and host arch. The
/// research agent's report flagged 0.98–0.99 as the sweet spot —
/// catches real regressions, ignores font-hinting flake.
///
/// **What NOT to snapshot:** behavior. Snapshots are slow and brittle
/// for assertions about state changes — use a regular Swift Testing
/// `@Test` for those. Snapshots are for *layout*.
@Suite("SnapshotTesting smoke")
struct SnapshotTestingHowTo {
    @Test func packageIsLinked() {
        // If this file compiles, `import SnapshotTesting` resolved,
        // which means the SPM dependency wired through correctly.
        // First real snapshot test follows when goldens land.
        #expect(Bool(true))
    }
}
