# Sentry Ops

Operational playbook for pulling Conduit Sentry issues/events from this server.

## Script

- `scripts/sentry-check.sh`

This script:

1. Resolves Sentry auth token from:
   - `SENTRY_AUTH_TOKEN` env var, else
   - `/root/.config/sentry/auth-token`
2. Queries unresolved issues for configured projects.
3. Optionally prints recent event samples.

Default scope:

- org: `conduit` (post-migration org slug; the old `swe-kitty` org is retired)
- projects: `conduit-ios,conduit-android`
- query: `is:unresolved`

> The `conduit` org needs a token that is a **member** of it. A token scoped
> only to the old `swe-kitty` org returns `403 You do not have permission`.
> Drop a fresh conduit-scoped token at `/root/.config/sentry/auth-token`.
> Pre-migration history lives in the `swe-kitty` org (projects `apple-ios` /
> `android`) — reach it with `SENTRY_ORG=swe-kitty SENTRY_PROJECTS=apple-ios,android`.

## Usage

```bash
chmod +x scripts/sentry-check.sh
./scripts/sentry-check.sh
```

## Useful overrides

Only auth token is required. Everything else has defaults.

```bash
SENTRY_ORG=conduit \
SENTRY_PROJECTS=conduit-ios,conduit-android \
SENTRY_QUERY='is:unresolved level:error' \
SENTRY_LIMIT=50 \
SENTRY_SHOW_EVENTS=1 \
SENTRY_EVENTS_PER_PROJECT=10 \
./scripts/sentry-check.sh
```

## Interpreting output

For each project:

- `Issues`: unresolved issue list (`shortId`, title, count, lastSeen, status)
- `Event Samples`: latest event rows from last 7 days

Use this to quickly confirm:

- whether new mobile telemetry is arriving
- whether auth/connect failures are trending up
- whether Android or iOS is currently noisier

## Agent workflow

When you ask for “check Sentry”:

1. Run `./scripts/sentry-check.sh`
2. Extract top active issues by count and recency
3. For connection/auth failures, inspect tags (`phase`, `reason_code`, `assistant`, `session_id`)
4. Map issues back to source files and propose fixes

This keeps Sentry checks consistent and fast without manual API curls every time.
