# Conduit — Rebrand & Re-skin Handoff

This bundle moves the product from its retired cat-mascot codename **"SWE Kitty / KittyLitter"**
to its real identity, **Conduit** — a mobile + tablet client for driving coding agents (Claude,
Codex) running on your own dev box.

## Start here
1. **`CLAUDE_CODE_PROMPT.md`** — copy the fenced block into Claude Code as your first message.
   It points Claude Code at everything below and makes it work phase-by-phase with your review.
2. **`BRAND.md`** — the final brand: name, the "terminal daemon" mark, exact color tokens,
   typography, voice. Source of truth.
3. **`RENAME_MAP.md`** — exact find/replace table, what must NOT change, and a verification grep.
4. **`MIGRATION_PLAN.md`** — phased plan to rebrand the **app** and the **website**.
5. **`APP_PLATFORMS.md`** — iOS **and** Android specifics (bundle id, icons, splash, OTA/APK install, native strings).
6. **`COPY_DECK.md`** — every user-facing copy change, app + website, with the new tagline.

## What's in this bundle
```
Conduit_Handoff/
├── README.md               ← you are here
├── CLAUDE_CODE_PROMPT.md   ← paste-ready prompt for Claude Code
├── BRAND.md                ← brand spec (tokens, type, mark, voice)
├── RENAME_MAP.md           ← old→new renames + verification grep
├── MIGRATION_PLAN.md       ← phased app + website migration
├── APP_PLATFORMS.md        ← iOS + Android platform-specific steps
├── COPY_DECK.md            ← all user-facing copy changes
├── assets/                 ← FINAL icons (use these)
│   ├── AppIcon-1024.png  AppIcon-512.png  AppIcon-256.png
│   ├── favicon-64.png  favicon-32.png  favicon-16.png
│   └── LogoMark.png
└── design-reference/       ← HTML/React PROTOTYPES (intended look, not prod code)
    ├── Conduit.html        ← run this to see the whole app prototype
    ├── *.jsx               ← the screen/component reference files
    └── website/            ← near-ship-ready marketing site
        ├── index.html      ← the site
        ├── version.json    ← live release data (OTA url, APK url, version, sizes)
        └── assets/         ← site images + icons
```

## About the design files
The files in `design-reference/` are **design references built in HTML/React** — they show the
intended look and behavior. They are **not** production code to paste into your app. Recreate
their look in your app's real environment (React Native / SwiftUI / Kotlin / etc.) using its
existing component library and patterns. The **website** in `design-reference/website/` is the
exception — it's plain HTML and is essentially ship-ready; host it, then wire the real install
URLs in `version.json`.

## Fidelity
**High-fidelity.** Colors, typography, spacing, radii, and glow are final — match them exactly
using the values in `BRAND.md` (don't eyedrop the screenshots).

## Distribution model (important)
Conduit ships **outside the app stores**: **iOS over-the-air install** (`itms-services` manifest →
signed `.ipa`) and a **direct Android APK** download. The website already implements both and reads
live release data from `version.json`. There is **no** App Store / Play Store badge and **no**
`brew install` line — do not reintroduce them.
