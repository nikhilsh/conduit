.PHONY: core bindings ios ios-project android android-debug

core:
	cargo test --manifest-path core/Cargo.toml
	cargo clippy --manifest-path core/Cargo.toml --all-targets -- -D warnings

bindings:
	mkdir -p core/generated/.tmp/swift core/generated/.tmp/kotlin
	cargo run --manifest-path core/Cargo.toml --bin uniffi-bindgen -- generate core/src/swe_kitty_core.udl --language swift --out-dir core/generated/.tmp/swift
	cargo run --manifest-path core/Cargo.toml --bin uniffi-bindgen -- generate core/src/swe_kitty_core.udl --language kotlin --out-dir core/generated/.tmp/kotlin
	cp core/generated/.tmp/swift/swe_kitty_core.swift core/generated/swe_kitty_core.swift
	cp core/generated/.tmp/kotlin/uniffi/swe_kitty_core/swe_kitty_core.kt core/generated/sweKittyCore.kt

# Build the SweKittyCore xcframework + UniFFI Swift bindings, then regenerate
# the Xcode project. Run before opening apps/ios/SweKitty.xcodeproj.
ios: ios-project

ios-project:
	cd apps/ios && ./build-rust.sh && xcodegen generate

# Build the Android jniLibs (+ UniFFI Kotlin bindings). Run before opening
# apps/android/ in Android Studio.
android: android-debug
android-debug:
	cd apps/android && ./build-rust.sh && ./gradlew assembleDebug --no-daemon
