# apps/android — Conduit Android app

Native Compose shell for the conduit harness. Mirrors `apps/ios/`: drawer
of projects + per-project multi-view (Terminal wired, Chat / Browser
stubbed for task 007).

## Layout

```
apps/android/
├── settings.gradle.kts
├── build.gradle.kts
├── gradle.properties
├── gradle/wrapper/                 gradle wrapper (jar committed)
├── gradlew, gradlew.bat
├── build-rust.sh                   compiles core/ for the 4 Android ABIs
└── app/
    ├── build.gradle.kts            applicationId sh.nikhil.conduit
    └── src/main/
        ├── AndroidManifest.xml
        ├── kotlin/sh/nikhil/conduit/
        │   ├── MainActivity.kt
        │   ├── SessionStore.kt     ViewModel + ConduitDelegate
        │   └── ui/{AppRoot,EmptyDetail,SettingsScreen,
        │            ProjectListScreen,ProjectScreen,
        │            TerminalPage,ChatPage,BrowserPage}.kt
        ├── res/                    minimal launcher icon + theme
        └── jniLibs/                populated by build-rust.sh (gitignored)
```

## Build & run

Requires JDK 17, Android SDK + NDK 26.3.x, Rust with the four Android targets,
`cargo install cargo-ndk`.

```bash
# from repo root
make android           # ./build-rust.sh + ./gradlew assembleDebug
adb install apps/android/app/build/outputs/apk/debug/app-debug.apk
```

## CI

`.github/workflows/ci.yml` `android-build` runs the same flow on
`ubuntu-24.04`: installs the NDK, builds the native libs via `cargo-ndk`,
then `./gradlew assembleDebug --no-daemon`.
