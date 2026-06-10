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
    // Google Services plugin — processes google-services.json into
    // BuildConfig / res values consumed by Firebase SDKs. Pinned to
    // 4.4.2 (latest at time of writing): uses kotlin-stdlib-jdk8:1.7.x
    // (verified via POM) — no Kotlin 2.1+ metadata risk. Paired with
    // AGP 8.5.2; 4.4.x targets AGP 8.x (the plugin's own AGP
    // dependency is a compile-only marker, not a runtime constraint).
    id("com.google.gms.google-services") version "4.4.2" apply false
}
