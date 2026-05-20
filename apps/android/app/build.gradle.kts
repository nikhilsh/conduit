plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
    id("io.sentry.android.gradle") version "4.11.0"
}

android {
    namespace = "sh.nikhil.swekitty"
    compileSdk = 35
    ndkVersion = "26.3.11579264"

    defaultConfig {
        applicationId = "sh.nikhil.swekitty"
        minSdk = 26
        targetSdk = 35
        versionCode = 8
        versionName = "0.0.1"
        buildConfigField("String", "SENTRY_DSN", "\"${System.getenv("SENTRY_DSN_ANDROID") ?: ""}\"")

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

    // UniFFI Kotlin runtime.
    implementation("net.java.dev.jna:jna:5.13.0@aar")
    implementation("io.sentry:sentry-android:7.14.0")

    // ZXing-embedded QR scanner. Ships its own activity + permission flow.
    implementation("com.journeyapps:zxing-android-embedded:4.3.0")
}
