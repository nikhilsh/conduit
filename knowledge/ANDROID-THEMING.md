---
title: Android Material colorScheme — neon mapping
tags: [android, theming, material, compose, ui]
scope: repo
source: android-material-colorscheme
status: active
---

# Android Material colorScheme — neon mapping

## The bug (pre-v0.0.175)

The Android app passed stock `darkColorScheme()` / `lightColorScheme()` to
`MaterialTheme` with zero customization. Most screens paint neon backgrounds
manually, so the gap went unnoticed — but Material components that read a
colorScheme slot without an explicit override inherited Material's default
purple/lavender:

- `FilledTonalButton` (`secondaryContainer` slot)
- `FilterChip`
- Default menu / dialog / dropdown surfaces
- `Switch`, `Slider`, `ProgressIndicator` (`primary` slot)

Users saw off-theme purple on both claude and codex sessions, confirming it
was agent-independent (agent themes are `neon.codex` = cyan, `neon.claude` =
orange — both are NOT purple).

## Fix (v0.0.175, PR #669)

`Theme.kt` now has `conduitColorScheme(neon)` / `conduitDarkColorScheme` /
`conduitLightColorScheme` that map the neon palette into every accent/surface
slot (each with a contrasting `on*` color). The input is the already-resolved
`NeonTheme` object — NOT `LocalNeonTheme` (a `CompositionLocal` that only exists
inside `MaterialTheme`). `MainActivity` calls:

```kotlin
MaterialTheme(colorScheme = conduitColorScheme(neonTheme))
```

## How to apply for new components

- New Material components now inherit neon automatically — no need to re-add
  stock defaults.
- If something still looks purple, check whether it is constructing its own
  `darkColorScheme()` directly.
- A `FilledTonalButton` that needs a SPECIFIC tint (e.g. a Resume button in
  neon green) must still set
  `ButtonDefaults.filledTonalButtonColors(containerColor=…, contentColor=…)` —
  the scheme default `secondaryContainer` is a neutral neon surface, not green.

## iOS note

iOS (SwiftUI) does not have an equivalent global tonal-default leak. No
corresponding change is needed there.

This is a visual change; on-device verification across menus/dialogs/chips/
switches in all four neon palettes was pending at ship time.
