#!/usr/bin/env bash
# Build core/ for the four Android ABIs and drop the .so files into
# app/src/main/jniLibs/<abi>/. Also regenerates UniFFI Kotlin bindings into
# core/generated/kotlin/uniffi/swe_kitty_core/ — referenced via the
# kotlin.srcDir entry in app/build.gradle.kts.
#
# Requires `cargo-ndk` (`cargo install cargo-ndk`) and an Android NDK
# discoverable by cargo-ndk (ANDROID_NDK_HOME or ANDROID_NDK_ROOT).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CORE_DIR="$REPO_ROOT/core"
JNI_DIR="$SCRIPT_DIR/app/src/main/jniLibs"
KOTLIN_OUT="$CORE_DIR/generated/kotlin"
UDL="$CORE_DIR/src/swe_kitty_core.udl"

PROFILE="${RUST_PROFILE:-release}"
CARGO_PROFILE_FLAG=$([ "$PROFILE" = "release" ] && echo "--release" || echo "")

echo "==> build-rust.sh (android): profile=$PROFILE core=$CORE_DIR"

if [[ ! -f "$CORE_DIR/Cargo.toml" ]]; then
  echo "build-rust.sh: core/Cargo.toml missing" >&2
  exit 1
fi

if ! command -v cargo-ndk >/dev/null 2>&1; then
  echo "build-rust.sh: cargo-ndk not found; install with: cargo install cargo-ndk" >&2
  exit 1
fi

rm -rf "$JNI_DIR"
mkdir -p "$JNI_DIR"

# cargo-ndk handles the toolchain dispatch + maps target triples to the
# Android jniLibs ABI directory names.
( cd "$CORE_DIR" && cargo ndk \
    -o "$JNI_DIR" \
    --manifest-path Cargo.toml \
    --target arm64-v8a \
    --target armeabi-v7a \
    --target x86_64 \
    --target x86 \
    build $CARGO_PROFILE_FLAG --lib )

# UniFFI Kotlin bindings.
rm -rf "$KOTLIN_OUT"
mkdir -p "$KOTLIN_OUT"
( cd "$CORE_DIR" && cargo run --quiet --bin uniffi-bindgen -- \
    generate "$UDL" \
    --language kotlin \
    --out-dir "$KOTLIN_OUT" )

echo "==> done: jniLibs at $JNI_DIR"
echo "==> bindings: $KOTLIN_OUT/uniffi/swe_kitty_core/swe_kitty_core.kt"
