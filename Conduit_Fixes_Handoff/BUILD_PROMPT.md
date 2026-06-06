# Conduit — Round-2 Fixes (one-shot build prompt)

**You are implementing five focused UI/IA fixes to the Conduit iOS + Android app.**
Conduit drives coding agents (**Claude**, **Codex**) running on the user's own "box" over a
broker. Users open a session against a repo + branch and watch the agent plan / run / diff /
approve — from phone or tablet.

This folder is the **single source of truth** for these five changes. Each one ships as a
**BEFORE** and an **AFTER** reference image in `images/`. **Build to the AFTER images** — match
their layout, hierarchy, spacing, and states. The BEFORE images are the *current shipped build*
and are included only so you can locate what to replace.

Pull **exact tokens** (color, type, radii, glow) from `reference/BRAND.md` — do **not** eyedrop
the PNGs. Native specifics in `reference/APP_PLATFORMS.md`, copy/voice in `reference/COPY_DECK.md`.

> These are **presentation + IA changes only.** Preserve all existing functionality, navigation,
> data flow, and APIs. No new screens — you are editing surfaces that already exist.

**Theme in every image:** dark · ice palette · glow on — `#22D3EE` cyan primary, `#3EF0A0` green;
agent tints `claude #FF9D4D` / `codex #22D3EE`. Type: **JetBrains Mono** for labels / numbers /
code / paths / wordmark, **Space Grotesk** for prose & UI.

---

## Data-model facts these fixes depend on
- **A session is bound to exactly one agent** (claude *or* codex). The in-session header and its
  menu describe *that* session's agent — never both.
- **Accounts are per agent.** The user can be signed in to Claude **and** Codex simultaneously,
  each on its own plan. Settings → Account must reflect both independently.
- **Plan limits are per account, per agent, with two rolling windows** (a 5-hour window and a
  weekly cap), each with its own % and reset. **Always show both windows, each with its %** —
  never drop the number and leave only a reset caption.
- **A "box" is one machine = one row.** The user's signed-in local device is itself a box and
  must appear in the list; remote boxes are paired over the broker.

---

## The five fixes

### 1 · In-session top bar — declutter
**Refs:** `images/01-header-before.png` → `images/02-header-after.png`

The shipped chat header crams in a back chevron, a **fat truncated title pill**
("New Co…ion …" with a dropdown caret), **three trailing circular buttons** (Fork · Refresh · ⓘ),
*and* a redundant full-width path line (`/root/developer/projects/PaperTrail`) underneath.

Rebuild the header as a single row:
- **Back** chevron (plain, no circle).
- **One identity title block** — the whole block is the menu trigger (caret on the right):
  - agent avatar (glow),
  - line 1: real session name in Space Grotesk 16/700 (`Fix auth refresh loop`) + a small chevron-down,
  - line 2: JetBrains Mono 11, one line — live dot · `claude` (agent-tinted) · `PaperTrail · fix/auth`.
    This folds the old path line into the identity; **delete the separate path row.**
- **One trailing ⓘ** circle → opens **Session Info**.
- **Remove Fork and Refresh from the header.** Fork and Refresh already live inside Session Info /
  the title menu — the header must not duplicate them. **Fork is a full-screen flow, not a header
  affordance.**

Keep the segmented `Chat · Terminal · Browser` tab bar directly below, unchanged.

### 2 · Title menu — give it an identity
**Refs:** `images/03-menu-before.png` → `images/04-menu-after.png`

Tapping the title opens a popover. The shipped popover led with **"Agent: claude / Model: claude"**
— the same word twice, no real model name, no branch — then listed **Fork** again.

Rebuild the popover:
- **Identity header** at top: agent avatar + **agent name** (`Claude`) + **real model**
  (`Sonnet 4.5`), and a mono sub-line with the branch (`PaperTrail · fix/auth`). No "claude / claude".
- Actions, hairline-separated: **Rename · Refresh · Export transcript**.
- **Remove Fork from this menu** (it is its own flow).
- A final destructive **End session** row in red, separated by a hairline.

### 3 · Settings · Account — show I'm already signed in
**Refs:** `images/05-signin-before.png` → `images/06-signin-after.png`

Settings → Account showed a single opaque row: **"Sign in to agent — OAuth for Claude / ChatGPT
(v2)"**, even when the user is already authenticated on both agents. It reads as "you are signed
out" when they are not.

Rebuild as an **Accounts** group:
- Keep the paired-box row at top (`103.107.51.48:1977 · Paired · 8ms`).
- **AGENT ACCOUNTS** label with a live **`● both connected`** status on the right.
- One row **per agent**, each: agent avatar, name (`Claude`, `Codex`), a **plan badge**
  (`MAX 20×`, `PRO`), a **`● signed in`** status line, and a **Manage ›** affordance
  (re-auth / switch plan / sign out per agent).
- A final **`+ Add another account`** row.
- Caption: per-agent management, "no more guessing whether you're connected."

If an agent is genuinely signed out, that single row shows a `Sign in ›` CTA instead of
`Manage ›` — but the default authenticated state is the one in the AFTER image.

### 4 · Home · usage limits — show the % on every window row
**Refs:** `images/07-strip-before.png` → `images/08-strip-after.png`

The Home usage strip collapsed header shows `claude 26% · codex 1%`. But when **expanded**, each
agent's window rows showed only a reset caption (`5h window · resetting…`, `weekly · resets in
5d 8h`) — **the % vanished**, so the expanded view had less information than the collapsed one.

Rebuild each expanded window row to carry **all three**: a **meter bar**, the **% used**, and its
**reset**. Per agent, two rows — `5h` and `weekly` — agent-tinted. Layout per row:
`label (5h / weekly) · meter · NN% · reset`. Keep the collapsed header summary as-is.

### 5 · Home · Boxes — list my own machine
**Refs:** `images/09-boxes-before.png` → `images/10-boxes-after.png`

The Boxes list only showed the **remote broker** (`103.107.51.48:1977 · ACTIVE · connected`).
Once the user is signed in, **their local device is a box too** and should be listed.

Rebuild the list:
- Pin a **This device** row first: Conduit mark, `localhost:1977 · on-device`, a **`LOCAL`** badge
  (accent), and a `● ready` status.
- Keep the connected remote box below it, styled active: `mac-studio` / `103.107.51.48:1977`,
  **`ACTIVE`** badge (green), `● connected`.
- One machine = one row. Caption: "your local box is auto-listed once you're signed in."

---

## Acceptance checklist
- [ ] Header is a single row: back · identity-title (name + status·agent·repo·branch) · one ⓘ.
- [ ] No Fork or Refresh button in the header; no separate full-width path line.
- [ ] Title menu opens with an identity header (agent · real model · branch); Fork is gone; End is red.
- [ ] Settings → Account lists **both** agents with plan badge + `signed in` + per-agent Manage.
- [ ] Every expanded usage window row shows meter **and** % **and** reset (both 5h and weekly, both agents).
- [ ] Boxes lists **This device** (LOCAL) pinned above the connected remote box.
- [ ] Tokens pulled from `reference/BRAND.md`; JetBrains Mono for labels/paths/numbers, Space Grotesk for prose.
- [ ] No regressions to navigation, data flow, or APIs. iOS + Android both honor safe-area insets.

---

### Files in this handoff
- `images/01–02` — top bar (before → after)
- `images/03–04` — title menu (before → after)
- `images/05–06` — Settings Account (before → after)
- `images/07–08` — usage strip (before → after)
- `images/09–10` — Boxes (before → after)
- `reference/BRAND.md` — canonical tokens, type, glow, mark
- `reference/APP_PLATFORMS.md` — native build specifics
- `reference/COPY_DECK.md` — voice & copy
