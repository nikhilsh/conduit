package sh.nikhil.conduit.ui

import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * Placeholder test that proves the Roborazzi plugin + deps wired into
 * the unit-test classpath. Real snapshot tests land in a follow-up PR
 * once goldens have been recorded.
 *
 * **Why Roborazzi over Paparazzi:** the research note in docs/TESTING-
 * STRATEGY.md flagged AGP/Kotlin tracking as the deciding factor for a
 * 2-person project — Roborazzi follows new AGP versions faster, and
 * Paparazzi has historically blocked AGP 8.5 / Kotlin 2.0 upgrades.
 *
 * **Adding a snapshot test:**
 *
 * 1. Annotate the class with `@RunWith(RobolectricTestRunner::class)`.
 * 2. Add `@get:Rule val roborazzi = RoborazziRule()`.
 * 3. Render a Composable and `captureRoboImage()`:
 *
 *    ```kotlin
 *    @Test fun greenDotMatches() {
 *        captureRoboImage("HealthDot_green.png") {
 *            HealthDot(health = "green")
 *        }
 *    }
 *    ```
 *
 * 4. First run records into `src/test/snapshots/roborazzi/`; second
 *    run compares. `./gradlew :app:recordRoborazziDebug` to force
 *    re-record; `./gradlew :app:verifyRoborazziDebug` to compare
 *    without recording.
 *
 * **Compare threshold:** Roborazzi defaults are sensible. If a test
 * goes flaky against subpixel rendering, configure
 * `RoborazziOptions(compareOptions = CompareOptions(changeThreshold = 0.01))`.
 *
 * **What NOT to snapshot:** behavior. Use a regular JUnit `@Test`
 * for state assertions; snapshots are for *layout*.
 */
@RunWith(RobolectricTestRunner::class)
class RoborazziHowToTest {
    @Test
    fun pluginIsWired() {
        // If this file compiles with the testImplementation deps
        // resolved, Roborazzi is reachable. First real snapshot
        // test follows when goldens land.
        assert(true)
    }
}
