# Sentry

Conduit now has mobile telemetry hooks for handled connection and session failures.

## Secrets

Add these repository secrets before expecting remote events:

- `SENTRY_DSN_IOS`
- `SENTRY_DSN_ANDROID`

Add these too for release-time symbol and source uploads:

- `SENTRY_AUTH_TOKEN`
- `SENTRY_ORG`
- `SENTRY_PROJECT_IOS`
- `SENTRY_PROJECT_ANDROID`

## Current behavior

- iOS reads `SentryDSN` from the app bundle at build time.
- Android reads `BuildConfig.SENTRY_DSN` at build time.
- If the DSN is empty, telemetry is a no-op.
- If the DSN is present, handled errors from:
  - broker connect
  - session creation
  - agent switching
  are captured with endpoint, assistant, and session context.
- iOS release builds upload dSYMs to Sentry with `sentry-cli`.
- Android release builds use the Sentry Android Gradle plugin to upload JVM source context and native symbols.

## Why this exists

The broker bearer token is minted in memory on every server startup. A saved mobile pairing can therefore become stale after a broker restart. Before this patch, the apps showed `Ready` immediately after `connect()` even though no authenticated round-trip had happened yet.

The current UI now treats that state as `Paired`, not verified, and maps auth failures to a re-pair instruction instead of a raw `Auth(message: "auth")` banner.

## Secret values

- `SENTRY_DSN_IOS`: DSN for the `conduit-ios` Sentry project
- `SENTRY_DSN_ANDROID`: DSN for the `conduit-android` Sentry project
- `SENTRY_AUTH_TOKEN`: org token with release and project write access
- `SENTRY_ORG`: Sentry org slug
- `SENTRY_PROJECT_IOS`: iOS project slug
- `SENTRY_PROJECT_ANDROID`: Android project slug

## Relationship to Rust

The shared error model can live in Rust, but Sentry SDK startup and final event submission stay native:

- iOS needs the Apple Sentry SDK
- Android needs the Android Sentry SDK

So the right shared split is:

- Rust: structured error classification, error codes, event context
- Native apps: DSN injection, SDK initialization, crash/log upload, and platform breadcrumbs

The current implementation already uses that boundary pragmatically: the apps capture Rust-surfaced failures with platform Sentry SDKs.

## Ops

For day-to-day issue triage from this server, use:

- [docs/SENTRY-OPS.md](/root/developer/projects/kitty-swe/docs/SENTRY-OPS.md:1)
- `scripts/sentry-check.sh`
