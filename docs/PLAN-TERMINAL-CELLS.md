# Stage F · Terminal Cell Emulator Plan

Owner: harness/internal/session
Status: Phase 1 wired (this PR); Phases 2–4 pending.

## 1. Problem

The harness today stores the last 256 KB of raw PTY bytes in a circular
ring (`harness/internal/session/manager.go`: `ring`, `ringPos`, `ringFull`,
`Snapshot`, `restoreSnapshot`). When a client connects, the server ships
those raw bytes to the iOS/Android terminal view. SwiftTerm (iOS) and the
Android renderer each interpret the snapshot as if they were a fresh
terminal hearing the stream from the very beginning.

That assumption breaks whenever the snapshot does not begin at a clean
state:

- **Mid-stream start.** The ring rolls over, so the first byte the
  client decodes can be in the middle of a CSI parameter or right after
  an SGR change. Cursor position and graphic rendition are guesses.
- **Alt screen.** Agents (Claude Code, gemini-cli, codex) enter the
  alternate screen via `CSI ?1049h` early. If that byte is no longer in
  the ring when a client attaches, the renderer never switches and the
  scrollback gets stomped on top of the agent UI.
- **Split sequences.** Wide glyphs (CJK, emoji), CSI/OSC strings, and
  DCS payloads can straddle the ring boundary; the first half is
  truncated, the second half is parsed as garbage.

### Observed symptom

iOS app, fresh `attach` to a long-running Codex session — the terminal
view shows vertical stripes of yellow + copper text where SwiftTerm has
placed glyphs into a grid that is half-misaligned because the cursor
never homed and the wrap mode never settled. Reproduces 100% on
sessions older than ~30 seconds of dense output.

## 2. Goal

Move the terminal model to the **server**. The harness keeps an actual
VT100 emulator state (cell grid, cursor, scroll region, modes) per
session. `Snapshot()` becomes a self-contained, replay-safe byte
stream: any fresh xterm-256color terminal that receives the snapshot
ends up with the same grid the server has.

This decouples the iOS/Android renderers from history quirks: the
client always boots from a "RIS + minimal redraw" prelude, never from
mid-stream bytes.

## 3. Library survey

| Library | Cell grid? | Maintained | License | Notes |
|---|---|---|---|---|
| `github.com/hinshun/vt10x` | **Yes** — `View.Cell(x,y)`, `Cursor()`, `Mode() ModeFlag` (incl. `ModeAltScreen`) | Stable; few changes but used by Charm + others | MIT | Forks `st` parser. Pure Go, no cgo. Exposes locking, glyph FG/BG color, attributes (`Mode int16`), wrap mode. **Picked.** |
| `github.com/charmbracelet/x/ansi` | No — parser/encoder only (sequences, SGR, OSC). No grid. | Very active | MIT | Useful adjunct for building the snapshot serializer (encode SGR back to bytes), not a replacement. |
| `github.com/leaanthony/go-ansi-parser` | No — tokenizer for styled text. | Active | MIT | Same shape as Charm's parser. Not a full emulator. |
| `github.com/aymanbagabas/go-vt100` | Partial — minimal VT100 state, no alt screen, no scroll region | Light maintenance | MIT | Too thin for our needs (alt screen is mandatory). |
| `golang.org/x/term` | No — terminal mode helpers (raw, size). | Active (Go team) | BSD-3 | Wrong layer. |

**Choice: `github.com/hinshun/vt10x`.**

Rationale:

1. Full emulator with addressable cell grid (`Cell(x, y) Glyph`) and
   cursor (`Cursor()`).
2. Exposes `Mode()` so we can detect alt screen and re-issue
   `CSI ?1049h` at snapshot boot.
3. Stable API, MIT-licensed, pure Go, zero cgo — fits our cross-compile
   posture (Linux harness, dev macOS).
4. Already vetted by upstream tooling (charm uses it in
   `charmbracelet/vhs`).

Risks / known caveats (recorded for Phase 2 review):

- vt10x predates true-color SGR (`CSI 38;2;r;g;bm`) — its `Glyph.FG`
  is a 16-bit color, not full RGB. Snapshot serializer will downgrade
  24-bit colors to the nearest 256-palette index. Acceptable for an
  initial cut; revisit if agents start emitting heavy truecolor.
- `Glyph.Mode` packs SGR attrs into bitflags; we'll need a mapping
  table back to `CSI <n>m` codes. Trivial but tedious.
- No public "is dirty" hook, so the snapshot serializer always walks
  the full grid. At 40×120 that's 4800 cells per checkpoint — fine.

## 4. Architecture

```
                   +--------------------+
   PTY read loop   |  Session.drain     |
   (manager.go)    +----------+---------+
                              |
                              v
                  +-----------+-----------+
                  | bytes []byte chunk    |
                  +-----------+-----------+
                              |
              +---------------+---------------+
              v                               v
       s.ring (legacy ring)         s.term.Write(chunk)  <-- Phase 1 NEW
       s.ringPos++                  (vt10x.Terminal)
                                              |
                                              v
                                    cell grid + cursor + modes
```

Both sinks stay alive in Phase 1. `Snapshot()` continues to return raw
ring bytes; the emulator runs in parallel for warm-up and diagnostics.

In Phase 2 (next PR), `Snapshot()` consults
`SWE_KITTY_CELL_SNAPSHOT` (env). When set, it serializes the cell grid
into a self-contained byte stream; otherwise it returns the ring.

### Snapshot serialization format (Phase 2 spec)

A snapshot is an xterm-256color byte stream. Clients pipe it into a
fresh terminal exactly as they do today. The bytes are:

1. `ESC c` — RIS (Reset to Initial State). Forces the receiver to drop
   any inherited cursor, SGR, wrap, or scroll region state.
2. If `term.Mode() & ModeAltScreen != 0`:
   `CSI ? 1 0 4 9 h` — enter alternate screen buffer (and save cursor).
3. For each row `r` in `[0, rows)` that contains at least one
   non-default cell:
   1. `CSI <r+1> ; <c+1> H` where `c` is the column of the first
      non-default cell on this row.
   2. Walk cells left-to-right. When the cell's SGR attributes change,
      emit `CSI 0 m` followed by the new attribute set
      (`CSI 1m` bold, `CSI 22m` not-bold, `CSI 38;5;<n>m` fg256,
      `CSI 48;5;<n>m` bg256, etc.). Use a tiny diff encoder so we don't
      re-emit attributes that already match the running state.
   3. Emit the glyph (`rune`) UTF-8 encoded. Honor wide cells: the
      paired right-half cell on the next column is skipped (vt10x stores
      a width hint on `Glyph`).
4. Final `CSI 0 m` to clear SGR.
5. Final `CSI <cursorRow+1> ; <cursorCol+1> H` to place the cursor.
6. If cursor is hidden (`term.CursorVisible() == false`):
   `CSI ? 2 5 l`; else `CSI ? 2 5 h`.

Properties of this format:

- Self-contained — RIS at the head means the receiver's prior state is
  irrelevant.
- Deterministic — same grid produces the same byte sequence (we emit
  rows in order, and the SGR diff state machine is fixed).
- Idempotent under replay — applying the snapshot to a terminal that
  already matches yields the same grid.
- Compact — typical 40×120 grid with sparse output is 1–4 KB versus the
  current 256 KB ring tail.

### Feature flag

`SWE_KITTY_CELL_SNAPSHOT` env var, read at the top of `Snapshot()`:

- Unset / `"0"` / `"false"` → return ring bytes (current behaviour).
- `"1"` / `"true"` → return cell-based serialization.

This lets us roll out per-harness, and lets the QA harness compare
both outputs side-by-side against a real terminal.

## 5. Test strategy

`harness/internal/session/cells_test.go` and (Phase 2)
`cells_snapshot_test.go`. Each test:

1. Construct a fresh `vt10x.New(WithSize(cols, rows))`.
2. Write a fixed byte sequence (the "scenario").
3. Capture `Snapshot()`.
4. Construct a second fresh terminal of the same size.
5. Replay the snapshot bytes into it.
6. Compare grids cell-by-cell, plus cursor position, plus
   `ModeAltScreen`. Test fails on first mismatch with row/col context.

Scenarios:

- **alt-screen-midstream** — write a long pre-amble that overflows the
  ring, then `CSI ?1049h`, then a TUI frame. Snapshot must produce a
  terminal in alt screen with the frame visible.
- **wrapped-lines** — write a string longer than `cols` with autowrap
  on; assert wrap point and that the wrap-marker cell flag survives.
- **sgr-persistence** — set bold + red, write text, set blue, write
  more text, snapshot. Replayed grid must have the same per-cell SGR.
- **cursor-restore** — move cursor to (5, 17), hide cursor, snapshot.
  Replayed terminal: cursor at (5, 17) and hidden.

Golden files (raw byte snapshots) live under
`harness/internal/session/testdata/cells/`.

## 6. Phased rollout

| Phase | Scope | Risk |
|---|---|---|
| **1 (THIS PR)** | Wire vt10x alongside ring. PTY read loop calls both. `Resize()` forwards to emulator. No behaviour change for clients. | Low — emulator is write-only sink. |
| 2 | Implement cell-based `Snapshot()` behind `SWE_KITTY_CELL_SNAPSHOT`. Golden-file tests. Flag default off. | Medium — new code path, but gated. |
| 3 | Flip flag default on after one release cycle of dogfooding. Keep ring as fallback. | Medium — depends on phase 2 coverage. |
| 4 | Retire ring + `restoreSnapshot`. Persisted scrollback on disk becomes the cell-based stream. Bump scrollback file format version. | Low after phase 3 bake. |

## 7. Open items (revisit at Phase 2)

- True-color downgrade — confirm visual delta on a Claude Code session
  that uses 24-bit greys.
- `vt10x.View.Cell` returns by value; we walk row-by-row under the
  emulator's `Lock()` to keep the snapshot consistent against the
  drain goroutine.
- Persisted on-disk scrollback (`scrollback.bin`) — keep raw bytes for
  Phase 1/2. Phase 4 swaps to cell-stream and the loader sniffs the
  first 2 bytes (`ESC c`) to decide format.
