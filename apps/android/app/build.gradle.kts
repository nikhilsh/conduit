plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
    // Plugin 5.x pairs with sentry-android SDK 8.x (plugin 4.x is SDK-7-only
    // and warns it may crash at runtime against an 8.x SDK). Bumped together
    // with the SDK below to reach Session Replay GA.
    id("io.sentry.android.gradle") version "5.8.0"
    // Roborazzi: Compose snapshot testing on the JVM. See docs/
    // TESTING-STRATEGY.md for the rationale (Paparazzi alternative).
    id("io.github.takahirom.roborazzi")
    // Processes google-services.json into BuildConfig / res values that
    // Firebase SDKs read at startup. Version declared in root build.gradle.kts.
    id("com.google.gms.google-services")
}

android {
    namespace = "sh.nikhil.conduit"
    compileSdk = 35
    ndkVersion = "26.3.11579264"

    defaultConfig {
        applicationId = "sh.nikhil.conduit"
        minSdk = 26
        targetSdk = 35
        versionCode = 12
        versionName = "0.0.1"
        buildConfigField("String", "SENTRY_DSN", "\"${System.getenv("SENTRY_DSN_ANDROID") ?: ""}\"")
        // Release provenance for Settings → About, mirroring iOS BuildInfo.
        // release-android.yml sets RELEASE_TAG/GIT_SHA; local builds get "dev"
        // so the About row falls back to versionName (device bug #7).
        buildConfigField("String", "RELEASE_TAG", "\"${System.getenv("RELEASE_TAG") ?: "dev"}\"")
        buildConfigField("String", "GIT_SHA", "\"${(System.getenv("GIT_SHA") ?: "dev").take(7)}\"")

        ndk { abiFilters += listOf("arm64-v8a", "armeabi-v7a", "x86_64", "x86") }
    }

    signingConfigs {
        create("release") {
            val storeFromEnv = System.getenv("ANDROID_KEYSTORE_PATH")
            if (!storeFromEnv.isNullOrBlank()) {
                storeFile = file(storeFromEnv)
                storePassword = System.getenv("ANDROID_KEYSTORE_PASSWORD")
                keyAlias = System.getenv("ANDROID_KEY_ALIAS")
                keyPassword = System.getenv("ANDROID_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        getByName("debug") {
            isMinifyEnabled = false
        }
        getByName("release") {
            isMinifyEnabled = false
            // Only attach release signing if the keystore env vars are present;
            // otherwise leave unsigned so local `assembleRelease` doesn't fail.
            if (!System.getenv("ANDROID_KEYSTORE_PATH").isNullOrBlank()) {
                signingConfig = signingConfigs.getByName("release")
            }
        }
    }

    sourceSets {
        getByName("main") {
            // UniFFI-generated Kotlin binding (regenerated via `make bindings`).
            kotlin.srcDir("../../../core/generated/kotlin")
            jniLibs.srcDir("src/main/jniLibs")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    packaging {
        resources.excludes += setOf(
            "/META-INF/{AL2.0,LGPL2.1}",
            "/META-INF/LICENSE*",
            "/META-INF/NOTICE*",
        )
    }

    testOptions {
        unitTests {
            // Robolectric needs the Android framework available on the
            // unit-test classpath; otherwise tests that touch any
            // android.* class throw RuntimeException("Method ... not
            // mocked"). Cheap to enable — costs nothing for tests that
            // don't use Android types.
            isIncludeAndroidResources = true
        }
    }
}

sentry {
    org = System.getenv("SENTRY_ORG")
    projectName = System.getenv("SENTRY_PROJECT_ANDROID")
    authToken = System.getenv("SENTRY_AUTH_TOKEN")

    includeProguardMapping = true
    autoUploadProguardMapping = true
    uploadNativeSymbols = true
    autoUploadNativeSymbols = true
    includeNativeSources = true
    includeSourceContext = true
}

dependencies {
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.activity:activity-compose:1.9.2")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.8.6")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.6")
    implementation("androidx.lifecycle:lifecycle-process:2.8.6")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.6")

    implementation(platform("androidx.compose:compose-bom:2024.09.02"))
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    debugImplementation("androidx.compose.ui:ui-tooling")

    // Persists endpoint+token for v0.1; replaced by EncryptedSharedPreferences in task 009.
    implementation("androidx.security:security-crypto:1.1.0-alpha06")

    // Chrome Custom Tabs — system-blessed OAuth browser surface used by
    // `auth/OAuthClient.kt`. Same role as iOS's
    // `ASWebAuthenticationSession`: hands the authorize URL to a Chrome
    // tab, gets called back via the `conduit://oauth/...` intent
    // filter. See `docs/PLAN-AGENT-OAUTH.md` §F.1.
    implementation("androidx.browser:browser:1.8.0")

    // OkHttp — token-exchange POST to provider `/oauth/token`. Picked
    // over `HttpURLConnection` because we need explicit body buffering +
    // status-code branching and OkHttp is already pulled in
    // transitively by sentry-android.
    implementation("com.squareup.okhttp3:okhttp:4.12.0")

    // UniFFI Kotlin runtime.
    implementation("net.java.dev.jna:jna:5.13.0@aar")
    // Bumped 7.14.0 → 8.x for Session Replay GA (the `options.sessionReplay.*`
    // masking API graduated out of `experimental` at 7.20.0; 8.x is the
    // current stable line). 8.0 is a major bump but its breaking changes don't
    // touch us: minSdk 21 (we're 26), enableTracing removal (unused), and the
    // sentry-android-okhttp → sentry-okhttp rename (we don't use the Sentry
    // OkHttp integration). Pairs with gradle plugin 5.x above.
    implementation("io.sentry:sentry-android:8.16.0")

    // ZXing-embedded QR scanner. Ships its own activity + permission flow.
    implementation("com.journeyapps:zxing-android-embedded:4.3.0")

    // UnifiedPush android-connector — vendor-free push (WS-P.3).
    // The device must have a distributor app installed (e.g. ntfy) for
    // registration to succeed; the library is a ~20 kB connector only,
    // no bundled distributor. Published on Maven Central.
    // https://github.com/UnifiedPush/android-connector
    implementation("org.unifiedpush.android:connector:3.3.3")

    // FCM push fallback (WS-P.3 fallback path). Direct version pin (NOT BOM)
    // because the firebase-bom pulls in firebase-common-ktx and related KTX
    // artifacts compiled with Kotlin 2.1 metadata in recent BOM revisions,
    // which poisons the build against our pinned Kotlin 2.0.0 toolchain.
    // 23.4.1 verified: kotlin-stdlib dep is 1.7.10 (POM inspection); no tink
    // or duplicate-class risk against existing deps. Java-first library — the
    // service and token APIs are all Java surface, no KTX required.
    implementation("com.google.firebase:firebase-messaging:23.4.1")

    // Termux terminal stack — Apache-2.0, pinned to v0.118.3 (May 22
    // 2025 release; see docs/PLAN-TERMINAL-REWRITE.md Android section).
    // Published as a multi-module JitPack build under the parent
    // `com.github.termux.termux-app` group; `terminal-view` transitively
    // pulls in `terminal-emulator` via its POM but we declare both
    // explicitly so a future Termux split can't break the build
    // silently. NOT on Maven Central as of this writing — the JitPack
    // repo is scoped in settings.gradle.kts.
    implementation("com.github.termux.termux-app:terminal-view:v0.118.3")
    implementation("com.github.termux.termux-app:terminal-emulator:v0.118.3")

    // Test dependencies — pinned per docs/TESTING-STRATEGY.md.
    // JUnit 4 stays the default because Compose tooling assumes it.
    testImplementation("junit:junit:4.13.2")
    testImplementation("io.mockk:mockk:1.13.13")
    testImplementation("org.robolectric:robolectric:4.14.1")
    testImplementation("androidx.test:core-ktx:1.6.1")
    // org.json's actual implementation isn't on the JVM unit-test
    // classpath by default — Robolectric ships an inert stub. Pull the
    // real artifact so JSONObject parsing in TerminalBridge can be
    // exercised under `./gradlew testDebugUnitTest`.
    testImplementation("org.json:json:20240303")
    // Roborazzi snapshot testing — JVM Compose snapshots, no emulator.
    // Compose runtime + JUnit rule + Robolectric integration glue.
    testImplementation("io.github.takahirom.roborazzi:roborazzi:1.32.0")
    testImplementation("io.github.takahirom.roborazzi:roborazzi-compose:1.32.0")
    testImplementation("io.github.takahirom.roborazzi:roborazzi-junit-rule:1.32.0")
    testImplementation("androidx.compose.ui:ui-test-junit4")
    testImplementation("androidx.activity:activity-compose:1.9.2")
}
