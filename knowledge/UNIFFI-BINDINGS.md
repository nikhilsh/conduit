---
title: UniFFI bindings — stale checksum trap
tags: [uniffi, ios, android, core, bindings, CI]
scope: repo
source: uniffi-binding-checksum-trap
status: active
---

# UniFFI bindings — stale checksum trap

When a function signature in `core/src/*.udl` changes (e.g. adding a parameter
to `create_session`), the generated Swift and Kotlin bindings embed an FFI
**checksum** of the contract. If an agent or human hand-edits or partially
regenerates the bindings, the checksum can be stale while the code still
compiles cleanly. The app then **fatal-panics at load** with
`contractVersionMismatch`.

## The rule

Never hand-edit `core/generated/conduit_core.swift`, `core/generated/conduitCore.kt`,
or the `.tmp/` variants. Always regenerate all four artifacts via:

```sh
make bindings
```

This runs `uniffi-bindgen` against the current UDL and writes all four files in
sync. A partial regen — e.g. regenerating only the Swift side and leaving the
Kotlin `.tmp/` stale — is a silent footgun.

## Why CI does not catch it

`cargo clippy` does not verify binding checksums. The mismatch surfaces only
when the app loads the library at runtime. CI compiles both apps and runs unit
tests, but unit tests do not load the native library through the full UniFFI
path. A stale-checksum PR can be green on CI and ship a broken app.

**Verification:** the only reliable check is a real app load (device or simulator
if the simulator can load the library). Comparing checksum values in the generated
files against what `make bindings` produces is a manual but effective pre-PR gate.

## Example (caught 2026-06-16)

A PR adding `device_id: Option<String>` to `create_session` carried checksum
`48656` in the committed bindings, but the correct UDL-derived checksum was
`39922`. Clippy was green; the app would have shipped broken.

Related: [IS-SANDBOX-ROOT](IS-SANDBOX-ROOT.md) (another "CI green, prod broken" trap)
