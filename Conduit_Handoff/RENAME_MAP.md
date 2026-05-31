# RENAME_MAP — retiring "SWE Kitty / KittyLitter"

Apply these renames across the **entire** codebase (app + website + repo metadata + comments +
filenames + asset names). The goal: **no trace** of the old codename or the cat mascot.

> Work case-sensitively where noted. After applying, run the **Verification** grep at the
> bottom — it must return **zero** matches in shipped code.

## 1. Literal string replacements

| Find (case-sensitive)        | Replace with        | Notes |
|------------------------------|---------------------|-------|
| `SWE Kitty`                  | `Conduit`           | Product name in copy, titles, meta |
| `SWE\u00a0Kitty` (nbsp)           | `Conduit`           | Non-breaking-space variant |
| `swe·kitty`                  | `conduit`           | Lowercase wordmark (middot) |
| `swe-kitty`                  | `conduit`           | Repo name, CLI, package id, slugs |
| `swekitty` / `SWEKitty`      | `conduit` / `Conduit` | Any squashed variant |
| `KittyLitter` / `kittylitter`| `Conduit` / `conduit` | Old project / broker codename |
| `Kitty` (standalone)         | `Conduit`           | e.g. "Paper Kitty" theme → "Paper" |
| `kitty` (standalone)         | `conduit`           | mind word-boundaries (not "kit.jsx") |
| `litter`                     | (reword)            | rewrite the sentence; no 1:1 token |

## 2. Identifier / symbol renames (code)

| Find                 | Replace            | Where |
|----------------------|--------------------|-------|
| `CatMark`            | `ConduitMark`      | React component — the in-UI vector mark |
| `catMark` / `cat_mark` | `conduitMark`    | any camel/snake variants |
| eyes glyph `>\|>\|`    | `>` `<` squint + smile | the daemon face (see BRAND.md) |

> ⚠️ **Do not** blindly replace the substring `cat` — it appears in `concatenate`,
> `category`, `indicator`, etc. Only rename the **whole-word** `Cat`/`cat` identifiers and the
> `CatMark` symbol. Use word-boundary regex: `\bCatMark\b`, `\bkitty\b`, `\bKitty\b`.

## 3. Asset / file renames

| Old                                   | New |
|---------------------------------------|-----|
| `icon-192.png` (cat basket)           | `AppIcon-*.png` / `favicon-*.png` (in `assets/`) |
| any `*kitty*` / `*cat*` asset filename| `conduit-*` |
| repo / package name `swe-kitty`       | `conduit` |
| iOS bundle id `*.swekitty`            | `*.conduit` |
| Android applicationId `*.swekitty`    | `*.conduit` |
| deep-link scheme `swekitty://`        | `conduit://` |

## 4. Things that are CORRECT and must NOT change

- The names of the **AI agents**: `Claude`, `Codex` — these are real third-party agents, keep them.
- The broker port `:1977`, the demo host `mac-studio`, demo repo/branch names — these are sample
  data, rename only if they contain the old brand (`swe-kitty` repo → `conduit`).
- Generic words containing the substring (`concatenate`, `category`, `application`, `kit.jsx`,
  `toolkit`) — leave untouched.

## 5. Verification (must pass before shipping)

```bash
# From repo root. Each of these must return NOTHING in shipped src
# (exclude the old reference handoff folder and this handoff bundle):
grep -rinE '\b(swe[ ·-]?kitty|kittylitter|kitten|litter)\b' \
  --exclude-dir=design_handoff_swe_kitty --exclude-dir=Conduit_Handoff .
grep -rinE '\bcat\s*mark\b|\bCatMark\b' \
  --exclude-dir=design_handoff_swe_kitty --exclude-dir=Conduit_Handoff .
grep -rin '>|>|' --exclude-dir=Conduit_Handoff .   # old eyes glyph
```
