# Task 004 — Android app shell (terminal view only)

## Scope
Mirror of task 003 for Android. Compose UI, Rust core as JNI lib, minimal app connecting to a harness and rendering terminal view.

**In scope:**
- `apps/android/build-rust.sh` — compiles `core/` for `aarch64-linux-android`, `armv7-linux-androideabi`, `x86_64-linux-android`, `i686-linux-android`; drops `.so` into `app/src/main/jniLibs/<abi>/`
- `apps/android/settings.gradle.kts`, `build.gradle.kts`
- `apps/android/app/build.gradle.kts` — applicationId `sh.nikhil.conduit`, signing config reads env vars
- `apps/android/app/src/main/AndroidManifest.xml`
- `apps/android/app/src/main/kotlin/sh/nikhil/conduit/MainActivity.kt`
- `apps/android/app/src/main/kotlin/sh/nikhil/conduit/SessionStore.kt`
- `.../ProjectListScreen.kt`, `ProjectScreen.kt`, `TerminalPage.kt`, `ChatPage.kt` (stub), `BrowserPage.kt` (stub)

**Out of scope:**
- Chat + Browser pages → task 007
- CameraX QR scanner → task 009
- PiP polish

## Frozen contracts
- `docs/WEBSOCKET-PROTOCOL.md` (via Rust core)
- `docs/AGENT-ADAPTERS.md`

## Done means
- `./gradlew assembleDebug` succeeds
- Install on Pixel 8 emulator, enter endpoint + token, create session, type in terminal → PTY echoes
- `ci.yml` `android-build` job green

## Files allowed
- `apps/android/**`
- `Makefile` (only `android` target)

## Branch
`agent/<your-name>-004-android-shell`
