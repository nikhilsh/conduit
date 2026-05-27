# PLAN — device-test bug triage (v0.0.29) + isolation-model question

> **Archived 2026-05-27 — shipped; see [`docs/ROADMAP.md`](../ROADMAP.md).** The
> triaged bugs were fixed and the isolation-model question was decided in favour
> of the bare-box (no-Docker) model — see `ROADMAP.md` "Direction & decisions".
> Preserved for the on-device findings.

Date: 2026-05-24
Source: first real on-device test of v0.0.29 (OAuth v2 build). Four bugs
found, plus a product question about whether the broker box needs Docker.

## Severity-ordered findings

| # | Bug | Layer | Root cause | Fix | Verifiable here? |
|---|-----|-------|-----------|-----|------------------|
| 1 | claude crash-loops | broker (Go) | `--dangerously-skip-permissions` is refused under root; broker ran as root | `IS_SANDBOX=1` in agent env | **yes** (live-verified) |
| 3a | chat send never reaches agent | broker + iOS | text written to PTY but not *submitted* / mangled with TUI; for claude the agent was simply dead (=#1) | re-test after #1; then fix submission (trailing CR) + output scrape | broker yes, e2e no |
| 2 | composer hidden by keyboard | iOS | `.safeAreaInset(.bottom)` on the scroll view, but a parent `.ignoresSafeArea()` / NavigationStack defeats keyboard-inset propagation | keyboard-safe-area at the right level | CI compile only |
| 3b | terminal can't scroll fully | iOS | `WKTerminalView.swift:114` disables the native scrollView; `terminal.js` manual touch-scroll is unreliable | fix JS scroll accumulation / re-enable native momentum | CI compile only |
| 4 | Ghostty renders blank | iOS | **by design** — Stage 4 is a skeleton: `snapshot()` returns empty cells, surface created at 0×0 (the promised re-`attach()` in `layoutSubviews` was never written), no Metal renderer (Stage 5), no display link | gate the toggle off until Stage 5; plan Stage 5 properly | CI compile only |

### #1 — claude crash-loop (FIX LANDED IN THIS PR)
`broker/cmd/swe-kitty-broker/embedded-agents/claude.toml:4` ships
`args = ["--dangerously-skip-permissions"]`. Claude Code hard-refuses that
flag under root/sudo. The Docker image runs as non-root `app` uid 1000
(`AGENT-ADAPTERS.md:37`) — *which is exactly what lets claude accept the
flag* — but the bare-VPS deploy runs the broker as **root**, so claude dies
instantly and the WS reconnect path respawns it in a loop.

**Fix:** set `IS_SANDBOX=1` in `commandEnv` (`broker/internal/session/lifecycle.go`).
This is Claude Code's documented escape hatch: it asserts a constrained
sandbox, which holds (per-session ephemeral `$HOME` + dedicated PTY).
Live-verified on this box as root: with the env var, `claude
--dangerously-skip-permissions` runs; without it, it refuses. No-op for codex.

### #3a — chat→agent input (HIGH, next)
Path exists: `LitterChatView` send → `SessionStore.sendChat` →
`SweKittyClient.sendChat` → broker `handleText` "chat" → `c.sess.Write()`
(`server.go:583`) → PTY. The write errors are swallowed (`_, _ =`). Two
suspects: (a) for claude the agent was dead (=#1), so re-test first; (b) the
bytes reach the codex TUI but aren't *submitted* (no trailing CR) or collide
with the TUI's own prompt redraw (matches the garbled echo seen on device).
Needs a focused trace of how the broker turns a `chat` frame into agent
stdin and how the scraper reads replies back (`chatScraper`, PR #124).

### #2 / #3b — iOS terminal/composer polish (MEDIUM)
Both are CI-compile-only on this box (no Mac); fixes need on-device confirm.

### #4 — Ghostty (LOW / expected)
Blank is the documented Stage-4 state, not a regression. **Immediate:** gate
the `experimentalNativeTerminal` toggle so users don't select a blank
terminal. **Later:** Stage 5 = attach a real Metal layer + feed the surface
its actual pixel size (re-`attach()` on `layoutSubviews`) + a render tick.

## What we learn from the references
- **swe-swe** (the harness we grew from) bridges chat↔PTY by writing the
  prompt to the PTY *with a submit keystroke* and scraping structured output
  — our `chat` path writes raw bytes and swallows errors. #3a should mirror
  swe-swe's submit + readback discipline.
- **litter** has no terminal tab; its composer is a UIKit `UITextView`
  (`ConversationComposerContentView`) that gets keyboard avoidance for free
  from UIKit's first-responder inset. Our SwiftUI `.safeAreaInset` approach
  is more fragile (#2).
- **ghostty / libghostty-spm** — the surface must be created with a real
  drawable size and ticked on a display link; our Stage 4 skeleton does
  neither (#4).

## Architecture question: does the broker box need Docker?

**Short answer: no, not for swe-kitty's self-hosted single-operator model.**
Docker was assumed for two reasons: (1) blast-radius containment for an
agent running with `--dangerously-skip-permissions` (full autonomy), and
(2) the non-root `app` uid that lets claude accept that flag. Bug #1 is the
seam where that assumption leaked — the real deploy is a bare root box.

The simpler flow the user proposes — **"on first launch, pick a directory
and run the agent/terminal there, on the box"** — is viable and largely
already supported: the broker already takes a per-session `cwd`
(`serveWS` → `GetOrCreateWithOptions{CWD}`) and a per-session ephemeral
`$HOME`. "Pick a directory" is mostly a client-side affordance over existing
broker support, not new isolation machinery.

**Trade-off to decide (not blocking the bug fixes):**
- *Bare-box (proposed):* minimal first-launch friction; the agent runs with
  the broker's privileges in the chosen dir. Acceptable for the "my box, my
  agent, I trust it" posture swe-kitty targets — but it should **not run as
  root**. Recommend: broker drops to / runs as a non-root user, and the YOLO
  flag + `IS_SANDBOX=1` confine intent rather than enforce a sandbox.
- *Docker (current docs):* stronger containment, but requires Docker
  installed + an image pull at setup — real friction for a phone-first
  "paste a deeplink and go" UX.

**Recommendation:** make Docker **optional hardening**, not a requirement;
make the default path "run on the box in a user-picked directory" (which the
broker already does), and document the security posture (ideally non-root).
This matches what the user actually wants and what bug #1's fix already
enables. A follow-up should: (a) add the directory-picker to first-launch,
(b) make the broker refuse to run agents as root *or* document the trust
model explicitly, (c) keep Docker as a documented opt-in.

## v0.0.30 re-test findings (2026-05-24, 22:35)

### #5 — stale "connected" status: app shows green when broker is down (MEDIUM)

After the broker was brought down, the app still rendered the saved server
chip (`103.107.51.48:1977`) with the **green** connected dot — no listener
was on the port at all. So the indicator is not driven by live WS health.

**Hypothesis (to confirm in code):** the dot reflects "saved/selected
server" or an optimistic/cached state rather than the transport's real
connection state, and a WS close / TCP RST / failed reconnect attempt does
not flip it to a disconnected colour. The auto-reconnect worker
(`notify_network_change` + reconnect loop, shared core) may also be marking
it green optimistically while retrying.

**Fix direction:** drive the status colour from the actual transport state
(`disconnected` / `connecting` / `connected`), detect dead sockets via a
ping/pong heartbeat (or surface the WS close/error), and only show green
once a frame round-trips. Must land on **iOS + Android** together. Tracked
as task #23.

### Confirmed FIXED in v0.0.30 (on device)
- **#1 claude crash-loop under root** — claude *and* codex both launch and
  run (`IS_SANDBOX=1` works; bypass-permissions accepted). 
- **#4 blank terminal** — terminal renders via xterm.js. Ghostty stays
  gated (Stage-5); the user-facing toggle is gone by design.

### #6 — Chat ↔ agent: chat scrapes the TUI, no structured channel (HIGH — biggest gap)

The Chat tab is unreliable for **both** directions because there is no
structured chat channel — `ws/server.go`'s `"chat"` handler writes
`msg + "\r"` to the agent's PTY stdin and a scraper (`MarkUserChatSent`)
tries to lift the reply out of raw terminal bytes. `AGENT_CHAT_PORT` is
declared in `claude.toml`/`codex.toml` but **no agent connects to it**.

Observed:
1. **claude send didn't submit** — typed "Hi" in Chat (optimistic echo
   shown), but it sat in claude's prompt until the user switched to Terminal
   and pressed Return. The injected `\r` doesn't reliably submit claude's
   Ink TUI (likely needs bracketed-paste / a real key event).
2. **claude reply not in Chat** — the response rendered only in Terminal.
3. **codex interactive prompt not in Chat** — the "trust this directory?"
   prompt appeared only in Terminal.
4. **codex reply garbled** — Chat bubble showed
   `Higpt-5.5 default · /root/.swe-kitty/sessions/5d0…`: the scraper merged
   the echoed input with codex's status/header line (TUI chrome leaking in).

**Fix direction:** wire a real structured channel (MCP `chat_event` bridge
over `AGENT_CHAT_PORT`) so agents emit clean messages + reliable submit,
*or* make the scraper robust to TUI chrome and fix submit. Supersedes the
chat half of #20. Tracked as task #24.

### #7 — Settings version ≠ released tag (MEDIUM, easy)
The version in Settings/About doesn't match the released git tag (v0.0.30).
`release.yml` likely isn't stamping `CFBundleShortVersionString` / build
number (iOS) and `versionName` (Android) from the tag. Tracked as task #25.

### #8 — mic button is a no-op (MEDIUM)
The mic icon (bottom-left of the session list) does nothing on tap. Voice
rail A is nominally shipped but the entry point isn't wired here. Task #26.

### #9 — per-session status dot semantics (MEDIUM)
Both claude + codex sessions are `running`, but only the active/attached one
(codex) shows green; claude shows grey. The dot reads as "active session"
not "running". Unify with #23's server-chip dot into clear semantics
(running / attached / stopped). Task #27.

### #10 — main-menu buttons missing iOS 26 glass material (LOW/polish)
Buttons don't look flat and don't pick up the Liquid Glass material — look
"weird". Apply glass tokens to the session-list controls; folds into
`PLAN-LITTER-VISUAL-PARITY.md`. Task #28.
