# Conduit — Brand Specification

This is the single source of truth for the **Conduit** brand. Everything below is final and
ships as-is. Where this document and any older asset disagree, **this document wins**.

> ⚠️ The product was previously prototyped under the codename **"SWE Kitty" / "KittyLitter"**
> with a cat mascot. That identity is **retired**. There must be **zero** "cat", "kitty",
> "litter", "kitten", "paw", "swe-kitty" or "swe·kitty" references anywhere in the shipped
> app, website, repo, package names, comments, or assets. See `RENAME_MAP.md`.

---

## 1. Name & wordmark

- **Product name:** `Conduit` (always capitalized, one word).
- **One-liner:** *Your coding agents, in your pocket.*
- **Wordmark in UI:** lowercase `conduit`, rendered in **JetBrains Mono 700**, preceded by a
  terminal prompt glyph: `>conduit`. The `>` is tinted with the cyan accent; `conduit` is in
  the primary text color. Letter-spacing ~1px.
- **Never** abbreviate to "Cdt", never add a tagline lockup inside the wordmark.

## 2. The mark (app icon / logo)

An original mascot we call the **terminal daemon** — a friendly creature that lives in a
terminal. It is a **rounded-square** "head" with a neon outline that runs **cyan at the
top-left → green at the bottom-right**, a face made of monospace glyphs, and two small
connector "pills" centered on the top and bottom edges (with faint circuit-trace dots).

- **Eyes:** two `>` `<` squint chevrons (a happy, friendly squint) in bright white-cyan.
- **Mouth:** a small upward smile curve in white-cyan.
- **Expression:** warm, eager, helpful. Never angry, never neutral.
- **Do NOT** add legs, dangling cables, tendrils, wavy lines, ears, whiskers, paws, or any
  animal feature. The connector pills on the top/bottom edge are the only appendages.

Provided raster assets (in `assets/`):

| File | Size | Use |
|------|------|-----|
| `AppIcon-1024.png` | 1024² | App store / large hero |
| `AppIcon-512.png`  | 512²  | In-app logo, website nav/footer/CTA |
| `AppIcon-256.png`  | 256²  | apple-touch-icon |
| `favicon-64.png`   | 64²   | favicon |
| `favicon-32.png`   | 32²   | favicon |
| `favicon-16.png`   | 16²   | favicon |
| `LogoMark.png`     | 512²  | Standalone mark on dark surfaces |

A scalable **in-UI vector version** of the mark (for nav bars, list avatars, etc.) is
implemented in the design reference as the `ConduitMark` React component — see
`design-reference/kit.jsx`. It accepts a `size` and an optional flat `color` (when tinting an
avatar to an agent color); with no color it uses the cyan→green gradient. Reuse this approach
in the target codebase.

## 3. Color tokens

Dark is the **only** theme that ships first. Hex values are canonical.

| Token            | Hex          | Role |
|------------------|--------------|------|
| `--bg`           | `#04050A`    | App / page background (near-black navy) |
| `--bg-elevated`  | `#0A1120`    | Solid raised panels |
| `--panel`        | `rgba(16,24,42,0.55)` | Glassy card fill |
| `--line`         | `rgba(34,211,238,0.14)` | Hairline border (cyan-tinted) |
| `--line-soft`    | `rgba(160,184,224,0.10)` | Neutral hairline |
| `--text`         | `#EAF3FF`    | Primary text |
| `--text-dim`     | `rgba(196,214,244,0.64)` | Secondary text |
| `--text-faint`   | `rgba(160,184,224,0.40)` | Tertiary / mono labels |
| `--cyan`         | `#22D3EE`    | **Primary accent** (links, focus, glow) |
| `--green`        | `#3EF0A0`    | Secondary accent (success, CTAs, "connected") |
| `--blue`         | `#4F8CFF`    | Support accent |
| `--amber`        | `#FFB627`    | Warning / "paused" / spark |
| `--orange`       | `#FF7847`    | Codex agent tint |
| `--claude`       | `#FF9D4D`    | Claude agent tint |
| white-cyan       | `#EAFCFF`    | Glyphs on the mark, glowing strokes |

**Gradient (brand signature):** `linear-gradient(135deg, #22D3EE → #3EF0A0)` (cyan → green).
Used on the mark outline, primary CTA fills, and progress rings.

**Glow:** accent strokes/text get a soft same-color outer glow
(`box-shadow`/`text-shadow`/`drop-shadow`, ~0–18px blur). Restrained — premium, not arcade.

## 4. Typography

- **Display & UI headings:** `JetBrains Mono` (weights 400/500/600/700/800). All hero
  headlines, the wordmark, eyebrows, labels, numbers, code.
- **Body & prose:** `Space Grotesk` (weights 400/500/600/700).
- Both loaded from Google Fonts in the reference. In a native app, bundle equivalents
  (JetBrains Mono; Space Grotesk).
- **Type rules:** headlines are mono, tight letter-spacing (`-0.02em`). Eyebrows/labels are
  mono, uppercase, wide tracking (`0.24em`). Body is Space Grotesk, `line-height ~1.55`.
- Minimum on-screen text 12px; hero scales `clamp(40px,6.4vw,78px)`.

## 5. Voice & tone

- Confident, terse, developer-native. Lowercase mono accents (`>conduit`, `brew`-style lines).
- Talk about **driving agents on your own machine** — Claude (Anthropic) + Codex (OpenAI) over
  a broker. Pillars: **remote sessions, real terminal, live preview browser, voice, generative
  UI, approvals, command palette, usage/limits.**
- Never cute, never mascot-voiced. The daemon is seen, not heard.

## 6. Iconography

- Inline **stroke** icons, 1.7px stroke, rounded caps/joins, on a 24px grid (see the `I` map
  in `design-reference/kit.jsx`).
- Agent presence shown as a glowing dot in the agent's tint + a mono label.
