.PHONY: core bindings

core:
	cargo test --manifest-path core/Cargo.toml
	cargo clippy --manifest-path core/Cargo.toml --all-targets -- -D warnings

bindings:
	mkdir -p core/generated/.tmp/swift core/generated/.tmp/kotlin
	cargo run --manifest-path core/Cargo.toml --bin uniffi-bindgen -- generate core/src/swe_kitty_core.udl --language swift --out-dir core/generated/.tmp/swift
	cargo run --manifest-path core/Cargo.toml --bin uniffi-bindgen -- generate core/src/swe_kitty_core.udl --language kotlin --out-dir core/generated/.tmp/kotlin
	cp core/generated/.tmp/swift/swe_kitty_core.swift core/generated/swe_kitty_core.swift
	cp core/generated/.tmp/kotlin/uniffi/swe_kitty_core/swe_kitty_core.kt core/generated/sweKittyCore.kt
