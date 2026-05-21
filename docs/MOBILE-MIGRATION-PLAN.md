# Mobile Migration Plan

Date: 2026-05-18

## Executive Summary

The current `swe-kitty` mobile apps are not missing polish by accident. They are the direct result of shipping the scoped shell tasks instead of the full reference app.

Why we got the skeleton:

- [Task 003](/root/developer/projects/kitty-swe/.swe-kitty/tasks/003-ios-shell.md:1) explicitly scoped iOS to a "terminal view only" shell.
- [Task 004](/root/developer/projects/kitty-swe/.swe-kitty/tasks/004-android-shell.md:1) did the same for Android.
- The richer product surface in [docs/PLAN.md](/root/developer/projects/kitty-swe/docs/PLAN.md:263) was planned, but not actually implemented as the first shipped mobile milestone.

Why we did not simply copy the original app:

- The repo reference is [dnakov/litter](https://github.com/dnakov/litter), not a private in-house codebase.
- Upstream `litter` is GPLv3 with an additional App Store / Play distribution permission, per its GitHub README/license page.
- Our current shared Rust core declares `license = "MIT OR Apache-2.0"` in [core/Cargo.toml](/root/developer/projects/kitty-swe/core/Cargo.toml:5).
- That means directly importing upstream `litter` code is not just an engineering shortcut. It is a repo-wide licensing choice.

So the first decision is not "how do we port the UI?" It is:

1. Do we accept upstream `litter` licensing and treat `swe-kitty` as a derivative/fork?
2. Or do we keep `swe-kitty` under its current permissive posture and reimplement the product shell using `litter` as a reference only?

## What Upstream `litter` Gives Us

From the upstream repo layout and README:

- `apps/ios/` — full native iOS app
- `apps/android/` — full native Android app
- `shared/rust-bridge/codex-mobile-client/` — shared Rust core via UniFFI
- platform code is intentionally thin; shared session/auth/discovery/hydration logic lives in Rust

That means the reference app is not just "nice visuals." It is a complete product shell with:

- mature navigation
- stronger information architecture
- real session/server management flows
- a much more opinionated iOS/Android presentation layer

So if the goal is "make `swe-kitty` feel like KittyLitter instead of a scaffold," the right move is not incremental beautification of the current shell. The right move is structural convergence toward the upstream app shape.

## Decision Gate

Before implementation, choose one path.

### Path A: Derive from `litter`

Use when:

- you are comfortable with GPLv3 + section 7 App Store/Play exception implications
- you want maximum speed and maximum fidelity to the current KittyLitter app

Effect:

- we can import/adapt real upstream files and keep much more of the UI and app structure intact
- we should expect repo licensing, notices, and attribution work
- we should assume a larger code import and a more invasive merge

### Path B: Clean-Room Product Rebuild Using `litter` as Reference

Use when:

- you want to preserve a permissive `swe-kitty` core/repo posture
- you are willing to spend more engineering time to avoid direct code carryover

Effect:

- we copy architecture, flows, and visual direction, not code
- we keep our current code ownership and licensing posture cleaner
- we should still expect a substantial UI rewrite, especially on iOS

## Recommendation

Recommended default: **Path B unless you explicitly approve relicensing / derivative-work posture.**

Reason:

- the licensing mismatch is real
- the current repo already has its own broker/core/product constraints
- we do not need voice/audio/realtime Codex-specific features from upstream to get the UI shell and product quality back

If you explicitly want the fastest route and are fine treating this as a derivative of `litter`, then Path A becomes the practical choice.

## Migration Strategy

Either path should use the same execution structure.

### Phase 0: Upstream Audit

Goal:

- pin an exact upstream `litter` tag/commit as the source of truth
- map the app shell, navigation, server management, pairing, session detail, and tab surfaces
- separate product shell code from upstream Codex-specific or audio/realtime features we do not need

Deliverable:

- file-level mapping:
  - upstream iOS files we should adopt or mirror
  - upstream Android files we should adopt or mirror
  - upstream shared Rust flows we should adapt into `swe-kitty-core`

### Phase 1: Release Automation

This should happen in parallel with the mobile migration because the current manual site refresh is operational debt.

Goal:

- remove the manual "rebuild website after assets land" step

Plan:

- create a dedicated release orchestrator workflow for tagged releases
- wait for:
  - iOS IPA
  - Android APK
  - broker binaries
- if any release job fails:
  - fail the orchestrator clearly
  - surface the exact failed workflow/job in one place
- if all succeed:
  - regenerate website release metadata
  - publish the static site to Fyra automatically

Implementation direction:

- prefer one orchestrated GitHub Actions path instead of a human "agent watching forever"
- if we still want local operator tooling, add a small watcher script that tails release runs and summarizes failures, but do not make that the primary release mechanism

Required additions:

- Fyra deploy credential in GitHub secrets
- automated website deploy workflow
- website selector logic already fixed to prefer the newest release with a real IPA

### Phase 2: iOS First-Class Migration

Priority:

- iOS first, because it is the platform you are actively dogfooding

Goal:

- replace the current skeleton shell with the real product shell shape

Scope:

- top-level navigation / server list / project list
- session detail hierarchy
- glass/material visual system
- proper settings and pairing surfaces
- terminal/chat/browser composition
- error and empty states

Important rule:

- do not continue polishing the current shell as if it is the final app
- instead, replace its structure with the target app structure
- use [docs/MOBILE-FEATURE-BACKLOG.md](/root/developer/projects/kitty-swe/docs/MOBILE-FEATURE-BACKLOG.md:1) as the concrete feature-by-feature execution list for conversation, tool-call, user-input, image, and server/session parity

### Phase 3: Android Convergence

Goal:

- bring Android to the same product model as iOS, using the upstream layout patterns where they fit

Scope:

- drawer/project/session structure
- chat/browser parity
- pairing/server persistence parity
- visual cleanup after structural parity

Note:

- Android can lag iOS slightly, but the architecture should stay aligned so the shared Rust core remains the source of truth

### Phase 4: Shared Rust Core Parity

Goal:

- make sure the shared core is sufficient for the richer mobile shell

Likely work:

- richer session hydration/state restoration
- multiple saved servers
- cleaner connection/session lifecycle states
- browser/chat state improvements
- possibly stronger discovery and auth modeling

## Concrete Work Breakdown

### Workstream A: Upstream Reference Audit

Tasks:

- inspect upstream `litter` iOS structure
- inspect upstream `litter` Android structure
- identify code/features to exclude:
  - realtime voice/audio
  - upstream Codex-only server assumptions
  - anything tightly coupled to upstream backend semantics we do not want
- produce a port matrix

### Workstream B: App Shell Replacement

Tasks:

- replace current `RootView`, `ProjectListView`, `ProjectView`, and settings structure with the target shell
- move to a coherent design system instead of isolated visual tweaks
- preserve existing `SweKittyClient` integration while swapping the presentation layer

### Workstream C: Pairing + Server Management

Tasks:

- support multiple saved servers, not just one remembered endpoint
- keep photo-library QR import and camera scan
- never destroy pairing state on transient errors
- improve remote server editing, switching, and status visibility

### Workstream D: Release Automation

Tasks:

- create release orchestrator workflow
- make website deploy fully automatic after asset success
- optionally add a local watcher script for operators

## Proposed Order of Execution

1. Decide licensing path: direct derivative vs clean-room reference-based rebuild.
2. Audit upstream `litter` files and produce a file-by-file port matrix.
3. Build automated release orchestration so website/release drift stops happening.
4. Replace the iOS shell structure with the target product shell.
5. Fill the missing shared-core state needed by the richer app shell.
6. Bring Android to parity.

## Risks

### Licensing risk

Direct code import from `litter` may force repo-wide licensing consequences inconsistent with current expectations.

### Architecture drift risk

If we keep layering improvements onto the current shell instead of replacing it, we will spend time and still end up with the wrong app shape.

### Scope risk

Upstream `litter` contains product areas we may not want:

- voice/realtime
- upstream-specific server flows
- broader platform integrations

So the migration must be selective, not blind.

## Immediate Next Step

The next concrete action should be:

- create the upstream audit/port matrix first

That gives us the real answer to:

- which files we can import or mirror
- which files we must rewrite
- how much of the current `apps/ios` and `apps/android` trees should be replaced instead of incrementally edited
