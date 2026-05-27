# Stage F' — xterm.js terminal renderer

> **Archived 2026-05-23.** xterm.js path shipped and was the production
> renderer through the LitterUI cutover; the active terminal track is
> now the Ghostty-backed CoreText renderer in
> [`PLAN-TERMINAL-REWRITE.md`](PLAN-TERMINAL-REWRITE.md). xterm.js
> remains as the fallback; this doc kept for the original rationale.

## Why

The SwiftTerm-backed `TerminalTab` produced "vertical stripe" garbage
when a session was attached mid-stream: the ring-buffer snapshot
arriving on connect frequently lands inside an alt-screen region, a
half-parsed CSI sequence, or with SGR state already shifted. SwiftTerm
ships a workaround for some of these (and we already inject `ESC c`
before each snapshot replace), but the long tail of mid-stream
ANSI/VT edge cases isn't worth re-implementing in Swift.

[xterm.js][xtermjs] is the renderer behind VSCode, Hyper, and Tabby —
its VT emulator has been hammered by years of real-world TUI output.
Pairing it with `@xterm/addon-serialize` lets us cheaply snapshot the
current screen as ANSI for cross-attach replay, and `@xterm/addon-fit`
gives us correct cell-grid sizing in response to layout changes.

Stage F (PR #8 — Go `vt10x` emulator on the server, then ship cells
to the client) was cancelled because it required deep changes to the
broker ring buffer and broke the snapshot-replay contract. Stage F'
keeps the wire protocol untouched (still raw bytes, still per-session
ring) and only swaps the local renderer.

[xtermjs]: https://xtermjs.org

## Resources vendored

All hosted under `apps/ios/Sources/Resources/terminal/` (registered in
`apps/ios/project.yml` as `type: folder` so the directory is preserved
in the .app bundle).

| File                   | Source                                                    | Version  |
| ---------------------- | --------------------------------------------------------- | -------- |
| `xterm.js` / `xterm.css` | unpkg `@xterm/xterm`                                    | 5.5.0    |
| `addon-fit.js`         | unpkg `@xterm/addon-fit`                                  | 0.10.0   |
| `addon-serialize.js`   | unpkg `@xterm/addon-serialize`                            | 0.13.0   |
| `addon-webgl.js`       | unpkg `@xterm/addon-webgl`                                | 0.18.0   |
| `terminal.html`        | hand-written; loads the above + `terminal.js`             | —        |
| `terminal.js`          | hand-written; wires Terminal + addons + Swift bridge      | —        |

## JS ↔ Swift bridge

The page registers a single user-content message handler called
`term`. All cross-boundary traffic flows through it.

### JS → Swift (`webkit.messageHandlers.term.postMessage(...)`)

| Message                                  | Meaning                                            |
| ---------------------------------------- | -------------------------------------------------- |
| `{ type: "ready" }`                      | xterm has mounted; safe to start calling `feedBytes`. Sent once after `term.open`. |
| `{ type: "input", data: "<utf8>" }`      | User keystroke; xterm hands us a UTF-8 string. Swift forwards as `Data` to `SessionStore.sendInput`. |
| `{ type: "resize", cols, rows }`         | Fit addon resized the grid. Swift forwards to `SessionStore.resize` (rows then cols, matching the existing wire signature). |

### Swift → JS (`webView.evaluateJavaScript`)

| Call                          | Effect                                                                                  |
| ----------------------------- | --------------------------------------------------------------------------------------- |
| `window.feedBytes('<b64>')`   | Swift base64-encodes the new tail of the ring buffer; JS `atob`s and `term.write`s the bytes. Base64 avoids escaping headaches for arbitrary binary in a JS string literal. |
| `window.serializeState()`     | Returns an ANSI string capturing the current screen + scrollback via `SerializeAddon`. Used for snapshot/restore (deferred). |
| `window.reset()`              | `term.reset()` — used when the ring buffer shrinks (snapshot replaced) to avoid piling new bytes on top of stale state. |

Bytes flow in the same direction as before — only the renderer changed:

```
broker ring buffer → WS → SessionStore.terminalBuffer[id] →
  delta → base64 → window.feedBytes → xterm.write
```

## SerializeAddon

Wired but not yet persisted. The intended flow:

1. On app background or session detach, Swift calls
   `window.serializeState()` and stashes the resulting string in
   `SessionStore` (in-memory today, on-disk in a follow-up).
2. On re-attach, Swift feeds the stashed snapshot first, then resumes
   the live byte stream.

This gives us fast warm-resume independent of the broker ring-buffer
size, and is the migration path for persisting the rendered grid
across cold launches.

## Deferred

The following are intentionally out of scope for this PR and will land
separately:

- iOS keyboard accessory bar (Esc / Tab / arrow keys / Ctrl mode).
- Android port (Android still uses its own native terminal view).
- Paste handling and link-tap (xterm.js has hooks; we need to wire
  them to UIPasteboard / `UIApplication.shared.open`).
- Persistence of serialized state across cold launches.
- Removal of the SwiftTerm SPM dependency. `TerminalTab.swift` is
  kept compiled-but-unused as a one-release fallback. Once Stage F'
  is verified on real devices, a follow-up PR drops both.
- Mouse reporting passthrough. The legacy view explicitly disabled
  it; the xterm-based view will need an equivalent setting once we
  decide on the UX trade-off (scroll vs. TUI mouse).
