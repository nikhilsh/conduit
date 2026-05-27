# Mobile Port Matrix

> **Archived 2026-05-27 — shipped; see [`docs/ROADMAP.md`](../ROADMAP.md).** The
> file-level port audit it drove is complete. Preserved for reference.

Date: 2026-05-18

## Purpose

This is the first concrete audit deliverable for replacing the current `swe-kitty` mobile skeleton with the product shell shape referenced by upstream `litter`.

This document answers:

- what we built
- what upstream `litter` actually contains
- what should be replaced vs kept
- what the migration order should be

## Why The Current App Is A Skeleton

This was a deliberate task-scope outcome, not a misunderstanding.

- [Task 003](/root/developer/projects/kitty-swe/.swe-kitty/tasks/003-ios-shell.md:1) scoped iOS to a minimal shell with terminal-first behavior.
- [Task 004](/root/developer/projects/kitty-swe/.swe-kitty/tasks/004-android-shell.md:1) scoped Android the same way.
- The fuller product shape is described in [docs/PLAN.md](/root/developer/projects/kitty-swe/docs/PLAN.md:263), but those shell tasks were what actually got implemented first.

So the right fix is not "keep polishing the shell."

The right fix is:

- replace the shell structure with the intended product structure
- borrow the upstream app’s architecture and flow shape aggressively
- keep only the `swe-kitty`-specific protocol and broker behavior where needed

## Upstream `litter` vs Current `swe-kitty`

### iOS

Current `swe-kitty` iOS tree:

- [apps/ios/Sources](/root/developer/projects/kitty-swe/apps/ios/Sources:1)
  - one app entrypoint
  - one `SessionStore`
  - one keychain helper
  - a handful of views:
    - `RootView`
    - `ProjectListView`
    - `ProjectView`
    - `TerminalTab`
    - `ChatTab`
    - `BrowserTab`
    - `SettingsSheet`
    - `QRScannerSheet`

Upstream `litter` iOS tree:

- `apps/ios/project.yml`
- `apps/ios/Sources/Litter/`
  - `LitterApp.swift`
  - `Bridge/`
  - `Models/`
  - `Views/`
  - `Resources/`
  - `Assets.xcassets`
  - `CarPlay/`
  - Catalyst-specific plist/entitlements
- `apps/ios/Sources/LitterLiveActivity/`
- `apps/ios/Sources/LitterWatch/`
- `apps/ios/Sources/LitterWatchComplications/`
- `apps/ios/Tests/`
- `apps/ios/fastlane/`

Interpretation:

- Upstream is a real product app tree.
- Our current app is a thin first milestone shell.
- The size gap is structural, not cosmetic.

### Android

Current `swe-kitty` Android tree:

- [apps/android/app/src/main](/root/developer/projects/kitty-swe/apps/android/app/src/main:1)
  - `MainActivity.kt`
  - `SessionStore.kt`
  - `PairingURL.kt`
  - UI files:
    - `AppRoot.kt`
    - `ProjectListScreen.kt`
    - `ProjectScreen.kt`
    - `TerminalPage.kt`
    - `ChatPage.kt`
    - `BrowserPage.kt`
    - `SettingsScreen.kt`
    - QR scanner contract

Upstream `litter` Android tree:

- `apps/android/app/`
- `apps/android/core/`
- `apps/android/docs/`
- `apps/android/fastlane/`
- richer source root under `app/src/main/java`
- richer manifest/resources/deploy structure

Interpretation:

- Android is in the same situation as iOS.
- We have the shell slice, not the full app product structure.

### Shared Rust Core

Current `swe-kitty-core`:

- [core/src/lib.rs](/root/developer/projects/kitty-swe/core/src/lib.rs:1)
- [core/src/transport.rs](/root/developer/projects/kitty-swe/core/src/transport.rs:1)
- [core/src/session.rs](/root/developer/projects/kitty-swe/core/src/session.rs:1)
- [core/src/views.rs](/root/developer/projects/kitty-swe/core/src/views.rs:1)
- UniFFI surface in [core/src/swe_kitty_core.udl](/root/developer/projects/kitty-swe/core/src/swe_kitty_core.udl:1)

Upstream `codex-mobile-client`:

- large Rust source tree including:
  - `conversation.rs`
  - `hydration.rs`
  - `discovery.rs`
  - `reconnect.rs`
  - `preferences.rs`
  - `saved_apps.rs`
  - `pair/`
  - `session/`
  - `store/`
  - `transport/`
  - `types/`
  - multiple platform integration modules

Interpretation:

- upstream mobile UX relies on a much richer shared-state core
- our current shared core is enough for terminal sessions and basic views
- it is not yet equivalent to the product shell expectations upstream

## Replace / Keep Matrix

### Replace Heavily

These areas should be treated as replacement targets, not incremental polish targets.

#### iOS app shell

- [apps/ios/project.yml](/root/developer/projects/kitty-swe/apps/ios/project.yml:1)
- [apps/ios/Sources/SweKittyApp.swift](/root/developer/projects/kitty-swe/apps/ios/Sources/SweKittyApp.swift:1)
- [apps/ios/Sources/Views/RootView.swift](/root/developer/projects/kitty-swe/apps/ios/Sources/Views/RootView.swift:1)
- [apps/ios/Sources/Views/ProjectListView.swift](/root/developer/projects/kitty-swe/apps/ios/Sources/Views/ProjectListView.swift:1)
- [apps/ios/Sources/Views/ProjectView.swift](/root/developer/projects/kitty-swe/apps/ios/Sources/Views/ProjectView.swift:1)
- [apps/ios/Sources/Views/SettingsSheet.swift](/root/developer/projects/kitty-swe/apps/ios/Sources/Views/SettingsSheet.swift:1)

Reason:

- these define the product shell and currently encode the scaffold-era information architecture

#### Android app shell

- `MainActivity.kt`
- `AppRoot.kt`
- `ProjectListScreen.kt`
- `ProjectScreen.kt`
- `SettingsScreen.kt`

Reason:

- same issue as iOS: shell-first structure rather than product-first structure

### Keep But Evolve

These pieces are useful and should survive, but likely under different surrounding app structure.

#### `swe-kitty` shared core concept

- Rust + UniFFI shared client model
- transport/session/view state direction
- swe-kitty-specific WebSocket protocol compatibility

Reason:

- this is the project’s main differentiator and ties directly to our broker/server contracts

#### Terminal rendering adapters

- iOS `SwiftTerm`
- Android terminal rendering integration

Reason:

- these are the right platform choices already

#### Pairing basics

- QR pairing flow
- persisted server credentials

Reason:

- the concept is correct; the surrounding server-management UX needs to become richer

### Add New `swe-kitty`-Specific Product Layers

These do not come directly from upstream and should remain our own product-specific work.

- broker multi-agent semantics
- memory / handoff views
- preview routing tied to our broker
- session swap / `switch_agent`
- release website / self-host distribution model

## File-Level Direction

### iOS Direction

#### Likely replace wholesale

- `RootView.swift`
- `ProjectListView.swift`
- `ProjectView.swift`
- major portions of app entry/state wiring around them

#### Likely keep but refit

- `TerminalTab.swift`
- `QRScannerSheet.swift`
- `Keychain.swift`
- parts of `SessionStore.swift`

#### Likely add

- richer models/view models under a `Models/` or app-domain grouping
- richer `Views/` hierarchy
- app resources/assets structure
- more complete project/server/session surfaces

### Android Direction

#### Likely replace heavily

- `AppRoot.kt`
- `ProjectListScreen.kt`
- `ProjectScreen.kt`
- current settings/navigation flow

#### Likely keep but refit

- terminal page integration
- QR scanner contract
- pairing URL parser
- parts of `SessionStore.kt`

#### Likely add

- richer modularization closer to upstream app/core split
- more structured state and navigation layers

### Rust Direction

#### Keep

- current `SweKittyClient` concept
- transport integration with our server
- current frozen protocol surface

#### Expand materially

- discovery
- reconnect/resume
- preferences / saved servers
- hydration
- richer session store semantics

## Migration Sequence

### Step 1: Release Automation

Do this first because it removes release drift while the mobile rewrite is underway.

Target:

- tagged release triggers IPA/APK/broker builds
- orchestration waits for all three
- if all succeed:
  - regenerate site release metadata
  - deploy website to Fyra automatically
- if any fail:
  - fail one orchestrator surface with direct pointers to the broken jobs

### Step 2: Shared-Core Gap Audit

Before rewriting the iOS shell fully, identify which upstream-style product surfaces need richer shared state.

Likely gaps:

- multiple saved servers
- richer connection/session lifecycle
- hydration/resume semantics
- stronger project/session identity modeling

### Step 3: iOS Shell Replacement

Target:

- replace the current shell structure with the full product shell structure
- do not keep iterating on the current top-level view hierarchy

Success criteria:

- server management feels product-grade
- session/project navigation matches the intended app
- glass/material visual language is systemic, not patched on

### Step 4: Android Convergence

Target:

- follow the same product model as iOS
- preserve platform-specific feel, but align structure and capabilities

### Step 5: Optional Upstream Feature Triage

Upstream includes more than we currently need.

Likely exclude or defer:

- CarPlay
- Watch
- Live Activities
- voice / realtime-specific surfaces
- Catalyst/Mac extras

## Proposed Work Packages

### Package A: Release Orchestrator

Deliverables:

- release watcher/orchestrator workflow
- automated website deploy workflow
- runbook update

### Package B: iOS Structural Rewrite

Deliverables:

- new app shell hierarchy
- richer models/state layout
- server/session management UX
- reused terminal/chat/browser integration inside the new shell

### Package C: Shared-Core Expansion

Deliverables:

- saved servers
- reconnect/hydration improvements
- state model support for richer app shell

### Package D: Android Structural Rewrite

Deliverables:

- new navigation/state shell
- parity with iOS core flows

## Recommended Immediate Next Action

Start with **Package A + shared-core gap audit + iOS structural rewrite planning**.

In practical terms:

1. implement release orchestration so deployments stop depending on manual rebuilds
2. audit which upstream-style app flows need shared-core changes
3. replace the iOS shell structure before spending more time on visual tweaks

That is the shortest path from "test scaffold" to "actual KittyLitter-shaped product shell."

## Package B Sub-Plan: iOS Visual Language Port (2026-05-18)

The audit above names the *what*. This section pins down the *how* for the iOS visual language — specifically: stop hand-rolling glass with `.ultraThinMaterial`, adopt litter's iOS 26 Liquid Glass primitives, and rewrite the shell screens against them.

### Concrete Gap

| Concern | Current (`apps/ios/Sources/Views/DesignSystem.swift`) | Upstream (`litter/apps/ios/Sources/Litter/Extensions.swift:390-487` + `Models/LitterPalette.swift`) |
|---|---|---|
| Glass primitives | `glassPane()` / `glassChip()` using `.ultraThinMaterial` + bespoke stroke | `GlassRectModifier`, `GlassRoundedRectModifier`, `GlassCapsuleModifier`, `GlassCircleModifier` — each gated `if #available(iOS 26.0, *)` with `glassEffect(.regular[.tint][.interactive()], in: …)` and a material fallback |
| Morph between states | None — chips fade in/out | `GlassMorphContainer` (`GlassEffectContainer` on iOS 26) + `glassMorphID(_:in:)` (`glassEffectID` / `matchedGeometryEffect` fallback) |
| Palette | Hardcoded dark-only gradient (`GlassAppBackground`) | `LitterPalette` light/dark pairs, resolved via App Group; `LitterTheme.backgroundGradient` is adaptive |
| Typography | Default `Font.system` everywhere | `LitterFont` + `FontFamilyOption.mono/.system`, Berkeley Mono with SFMono fallback |
| Status pill | `BrokerBadge` glass chip | Same idea, but uses real `glassEffect` capsule + tint that maps to status colour |

### File-Level Port Plan

Execute strictly in this order — each step compiles on its own and the app stays runnable.

**Step B.1 — Glass primitives + theme (no UI change yet).** Land the infrastructure other screens will consume.
- New `apps/ios/Sources/Theme/SweKittyPalette.swift` — port of `LitterPalette` shape, but bake our own light/dark hex values (no App Group yet; that's a v2 concern). Keep it minimal: `accent`, `accentStrong`, `surface`, `surfaceLight`, `border`, `separator`, `danger`, `success`, `warning`, `textPrimary/secondary/muted/body/onAccent`.
- New `apps/ios/Sources/Theme/SweKittyTheme.swift` — wraps the palette into `Color` resolvers + `backgroundGradient(for: ColorScheme)`. Replaces `SweKittyTheme` enum in `DesignSystem.swift`.
- New `apps/ios/Sources/Theme/Glass.swift` — port of `GlassRectModifier`, `GlassRoundedRectModifier`, `GlassCapsuleModifier`, `GlassCircleModifier`, `GlassMorphContainer`, and the `glassMorphID(_:in:)` extension. Direct copy with name swap (`LitterTheme` → `SweKittyTheme`).
- Delete the old `glassPane()` / `glassChip()` modifiers and `GlassAppBackground` from `DesignSystem.swift`. Keep `HealthDot`, `InlineErrorBanner`, `BrokerBadge` but reskin them to use the new modifiers.

**Step B.2 — Background + RootView reskin.** First visible change.
- Replace the hardcoded dark `GlassAppBackground` with a `SweKittyTheme.backgroundGradient(for: colorScheme)` that respects light/dark. Light mode must work — the screenshot proves this is a current gap.
- `RootView.swift` keeps its responsibilities (connect / pair / show project list) but its empty-state and reconnect affordances become `glassEffect`-backed cards.

**Step B.3 — Home screen rewrite (`ProjectListView` → `HomeDashboardView`-shape).** This is what the user is looking at in the screenshot. The current "one server card + start-a-session card" layout becomes a real dashboard:
- Title row with adaptive header, settings + new-session glass capsules (replaces top gear / + icons).
- Server card uses `GlassRoundedRectModifier`. Status pill uses `GlassCapsuleModifier` tinted by `BrokerState` (refused → `danger`, linked → `accent`, live → `success`).
- "Start a session" becomes a hero glass card with `GlassMorphContainer` so the Claude/Codex chips morph into a session row when tapped — using `glassMorphID` keyed by session UUID.
- Use `LitterPalette.accentStrong` (`#00FF9C`) as our agent-tint while we hold onto the neon-cat brand.

**Step B.4 — Settings + add-server sheet (`SettingsSheet` → `AlleycatAddServerSheet`-shape).** The current `SettingsSheet` is a `Form` — replace with litter's section-card pattern using `GlassRoundedRectModifier` per group. Bring over field/row styling from `AlleycatAddServerSheet.swift`.

**Step B.5 — In-session shell (`ProjectView`, terminal/chat/browser tabs).** The bottom tab bar becomes a `HomeBottomBar`-shape glass dock. Terminal tab keeps SwiftTerm but its toolbar uses glass capsules. Quick-replies (planned, see [project memory](../.swe-kitty/memory/)) drop into this shell as a `GlassEffectContainer` chip rail.

**Step B.6 — Optional polish.** `AnimatedSplashView` port if we want a real launch experience; `AppearanceSettingsView` port if we expose theme + font preferences.

### Out of Scope For Package B

Defer (matches the "Likely exclude or defer" list above):
- CarPlay, Watch, Live Activities — no broker use case yet.
- App Group / theme-store — single-app for now; revisit when watch lands.
- Berkeley Mono shipping — use system mono until licence story is settled.

### Success Criteria

- Every glass surface in the app is one of the four `Glass*Modifier`s or `GlassMorphContainer` — zero remaining `.ultraThinMaterial` calls.
- Light mode is functional (no hardcoded dark backgrounds).
- On iOS 26 device, glass refracts correctly and chips morph when state changes.
- Screenshot-equivalent state (idle, error, mid-session) reads as a litter-quality screen, not a scaffold.

### Verification

After each step, run on iPhone 16 simulator (iOS 26 + iOS 17 fallback) and visually diff against `AppsListView` / `HomeDashboardView` screenshots from litter. Track regressions in a small sub-document if needed.
