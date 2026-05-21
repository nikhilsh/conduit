// Top-level build file — only used for plugin version pinning.
plugins {
    id("com.android.application") version "8.5.2" apply false
    id("org.jetbrains.kotlin.android") version "2.0.0" apply false
    id("org.jetbrains.kotlin.plugin.compose") version "2.0.0" apply false
    // Roborazzi — JVM-only Compose snapshot testing. Picked over
    // Paparazzi because it tracks AGP/Kotlin faster (per docs/
    // TESTING-STRATEGY.md research note from the agentic-screenshot
    // workflow research). Adds `recordRoborazzi*` / `verifyRoborazzi*`
    // gradle tasks once applied in app/build.gradle.kts.
    id("io.github.takahirom.roborazzi") version "1.32.0" apply false
}
