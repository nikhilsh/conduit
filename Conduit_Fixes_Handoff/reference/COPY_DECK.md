# COPY_DECK — all user-facing copy changes

Every place the product speaks to the user. Apply alongside `RENAME_MAP.md` (which covers code
identifiers/assets); this file is the **human-readable copy** layer for app **and** website.

Voice: confident, terse, developer-native. Lowercase mono accents (`>conduit`). Never cute, never
mascot-voiced. Talk about *driving your coding agents on your own machine.*

---

## 1. Naming & wordmark (global)
| Context | Old | New |
|---------|-----|-----|
| Product name in prose | "SWE Kitty" | "Conduit" |
| Lowercase wordmark | `swe·kitty` / `swe-kitty` | `>conduit` (prompt + lowercase) |
| Home-screen / store label | "SWE Kitty" | "Conduit" |
| One-liner / tagline | "Codex in your pocket" | **"Your agents, in your pocket."** |
| Possessive / casual | "Kitty", "the cat" | "Conduit" (never an animal) |

> Tagline note: the old hero said *"Codex in your pocket"* — it names only one agent. Use
> **"Your agents, in your pocket."** everywhere (hero, CTA, store blurb) so it covers Claude **and**
> Codex. Already applied on the website.

## 2. App — screen-by-screen copy

### Onboarding / first run
- Title: **Conduit** + tagline "Your agents, in your pocket."
- Body: "Pair a machine, start a session, and drive Claude or Codex from anywhere."
- Remove any cat/litter metaphor ("herd your kittens", "litter of sessions", etc.) → plain
  language ("your sessions", "your machines").

### Home / sessions
- Header wordmark: `>conduit`.
- Empty state: "No sessions yet — pair a machine to begin." (was any kitty-themed empty copy).
- Connected-server pill, "New session", "Active sessions" — unchanged wording, just de-brand.

### Live session (Chat / Terminal / Browser)
- Segmented control labels: **Chat · Terminal · Browser** (unchanged).
- Approval prompts: keep the safe action as the primary button; copy stays literal
  ("Allow this command?", "Apply 3 changes?").
- Agent names **Claude** / **Codex** stay verbatim.

### Settings
- The CLI/theme line that read `swe-kitty --theme …` → `conduit --theme …`.
- "About" / version row: "Conduit" + `versionName`; remove any "SWE Kitty" credit.
- Theme name "Paper Kitty" → "Paper".

### Notifications / system
- Channel names, push titles, share-sheet text: "SWE Kitty" → "Conduit".
- iOS install-profile name + Android notification-channel name → "Conduit".

## 3. Website copy (already applied — listed for parity)
| Location | New copy |
|----------|----------|
| `<title>` | "Conduit — your coding agents, in your pocket" |
| Meta description | "Conduit is a mobile + tablet client for coding agents…" |
| Nav | Conduit · Remote · Terminal · Browser · Everything · **Get the app** |
| Eyebrow | "Open beta · v0.9" |
| Hero H1 | "Your agents, in your pocket._" |
| Hero lead | "Conduit drives **Claude** and **Codex** on your dev box…" |
| Agent strip | "Works with — Claude (Anthropic) · Codex (OpenAI) · your Mac Studio, over a broker" |
| Feature 1 — Remote servers | "Your dev machine. Anywhere." |
| Feature 2 — Real terminal | "A real shell, in your thumb." |
| Feature 3 — Live preview | "See the build, as it builds." |
| Capabilities | terminal · live preview browser · subagent handoffs · approvals · command palette · usage & limits |
| Install buttons | **Install on iPhone** (OTA) · **Download for Android** (APK) — no App Store / Play badges |
| Release meta line | driven by `version.json` (version, channel, date, sizes, min-OS) |
| Footer | "© 2026 Conduit · made for people who ship from the couch." · `>_ conduit` |

> The website **removed** the old "Codex in your pocket" hero, the App Store / Google Play badges,
> and the `brew install swe-kitty` line. Do not reintroduce them.

## 4. Forbidden copy (never ship)
- Any "cat", "kitty", "kitten", "litter", "paw", "meow", "purr", "basket" metaphor.
- "SWE Kitty", "swe-kitty", "swe·kitty", "KittyLitter".
- "Codex in your pocket" as the sole tagline (excludes Claude).
- App Store / Google Play badges or "Download on the App Store" copy.
- `brew install …` (there is no Homebrew formula).

## 5. Things to keep verbatim
- Agent names: **Claude**, **Codex**, and model names (e.g. "gpt-5.4").
- Technical nouns: broker, session, repo, branch, diff, exit code, hot reload, command palette.
- Sample data (`mac-studio`, port `:1977`) — rename only if it embeds the old brand.
