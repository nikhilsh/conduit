# CLAUDE_CODE_PROMPT

Copy everything in the fenced block below and paste it as your **first message** to Claude Code,
run from the root of your app/website repo **with this `Conduit_Handoff/` folder placed inside
that repo** (so Claude Code can read these files).

---

```text
You are rebranding and re-skinning this project from its old codename "SWE Kitty" / "KittyLitter"
(a cat-mascot prototype) to its real identity: CONDUIT. Read the handoff bundle in
./Conduit_Handoff/ FIRST and treat it as the source of truth:

- Conduit_Handoff/BRAND.md          → final brand: name, the "terminal daemon" mark, color
                                       tokens (exact hex), typography, voice.
- Conduit_Handoff/RENAME_MAP.md     → exact find/replace table + what NOT to change + a
                                       verification grep that must pass.
- Conduit_Handoff/MIGRATION_PLAN.md → the phased plan for the app AND the website.
- Conduit_Handoff/APP_PLATFORMS.md   → iOS + Android specifics (bundle id, icons, splash, OTA/APK,
                                       native strings) — do BOTH platforms.
- Conduit_Handoff/COPY_DECK.md       → every user-facing copy change + the new tagline.
- Conduit_Handoff/design-reference/ → HTML/React PROTOTYPES showing the intended look & behavior
                                       (NOT production code to paste). The website there is
                                       essentially ship-ready.
- Conduit_Handoff/assets/           → the real app icons + favicons + logo mark. Use these.

GROUND RULES
1. This is a visual rebrand, not a behavior change. Preserve all existing app functionality,
   navigation, data flow, and APIs. Only identity, theme, icon, type, copy, and screen styling
   change.
2. Recreate the look of the design references using THIS repo's existing framework, component
   library, and patterns — do not import HTML/React prototype files wholesale, and do not add new
   UI dependencies without asking. If a surface has no framework yet, ask me before choosing one.
3. Pull every color/spacing/type value from BRAND.md (exact hex), not from the screenshots.
4. ZERO traces of the old identity may remain in shipped code: no "cat", "kitty", "litter",
   "kitten", "paw", "swe-kitty", "swe·kitty", or "CatMark". BUT do not blind-replace the
   substring "cat" — only whole-word identifiers (use \bCatMark\b, \bkitty\b, etc.), so you don't
   break "concatenate", "category", "kit.jsx", etc. Follow RENAME_MAP.md precisely.
5. Keep the names of the AI agents Claude and Codex — those are real and correct.

HOW TO WORK
- Start by reading the four .md files and listing every file in this repo that touches: app
  display name, bundle id / applicationId, deep-link scheme, app icon set, splash, theme/color
  tokens, font registration, and the logo component. Show me that inventory and your plan before
  editing.
- Then execute MIGRATION_PLAN.md phase by phase, applying APP_PLATFORMS.md for the native iOS and
  Android changes (bundle id, icons, splash, deep-link scheme, OTA/APK install, native strings)
  and COPY_DECK.md for all user-facing copy. After each phase: run the RENAME_MAP.md verification
  grep, report matches, and pause for my review before continuing.
- Wire the app icons from Conduit_Handoff/assets/ into the platform icon sets (iOS asset catalog,
  Android adaptive icon on #04050A, web favicons + apple-touch-icon + PWA manifest).
- Implement the in-UI mark as a vector component named ConduitMark (rounded-square daemon, ">" "<"
  squint eyes, smile, cyan→green gradient stroke, top/bottom connector pills) — reference
  design-reference/kit.jsx → ConduitMark. Use it in headers and as tinted session avatars.
- For the website: host design-reference/website/ as-is, then set the real iOS OTA manifest URL
  and Android APK URL in website/version.json, and replace the three placeholder feature
  screenshots with fresh shots of the rebranded app (retitle any row that doesn't map to a real
  screen).

DELIVERABLES
- A rebrand/conduit branch with the full rename + re-skin.
- The RENAME_MAP.md verification grep returning zero matches in shipped src.
- App icon, splash, in-UI mark, colors, and fonts all matching BRAND.md on phone, tablet, and web.
- The website live-ready with working OTA + APK install wiring.

Begin with the inventory + plan. Do not start editing until you've shown it to me.
```

---

## How to use this

1. Put the whole `Conduit_Handoff/` folder at the root of your repo (or commit it on the
   `rebrand/conduit` branch).
2. Open Claude Code in that repo.
3. Paste the block above as the first message.
4. Claude Code will read the bundle, show you an inventory + plan, and proceed phase-by-phase,
   pausing for your review after each.

## If your app and website live in separate repos
Run the prompt once per repo. The app repo only needs Phases 0–3 + 5; the website repo only needs
Phase 4 (the `design-reference/website/` folder is self-contained and nearly ship-ready).
