// sidecar.js — long-running Node process spawned by the Go harness.
//
// Maintains one headless xterm.js Terminal per session so the harness
// can reflow + serialize the grid at the attaching client's viewport
// size. The PTY byte ring in Go remains the streaming source-of-truth;
// this sidecar is only consulted for size-correct snapshots on attach.
//
// Wire format: line-delimited JSON over stdin/stdout. Each input line is
// one request object; each output line is one response object.
//
// Request:  { "id": <number|string>, "cmd": "<verb>", ...fields }
// Response: { "id": <same>, "ok": true,  ...fields }
//        or { "id": <same>, "ok": false, "error": "<string>" }
//
// Commands:
//   create   { sid, cols, rows }            -> {ok}
//   write    { sid, b64 }                   -> {ok}
//   resize   { sid, cols, rows }            -> {ok}
//   serialize{ sid }                        -> {ok, data: "<ANSI string>"}
//   delete   { sid }                        -> {ok}
//   ping     {}                             -> {ok, pong: <epoch_ms>}
//
// Bad JSON: logged to stderr, dropped. Don't crash. Crash recovery is
// Go's job — if this process dies, Go re-spawns it and re-creates
// sessions from the ring on demand.

import pkgHeadless from "@xterm/headless";
import pkgSerialize from "@xterm/addon-serialize";
import { createInterface } from "node:readline";

// Both packages ship as CommonJS; pull named exports off the default.
const { Terminal } = pkgHeadless;
const { SerializeAddon } = pkgSerialize;

const sessions = new Map();
let pending = 0;
let stdinClosed = false;

function maybeExit() {
  if (stdinClosed && pending === 0) process.exit(0);
}

function send(obj) {
  process.stdout.write(JSON.stringify(obj) + "\n");
}

function reply(id, fields) {
  send({ id, ...fields });
}

function err(id, message) {
  send({ id, ok: false, error: message });
}

function handle(msg) {
  const { id, cmd } = msg;
  switch (cmd) {
    case "ping": {
      reply(id, { ok: true, pong: Date.now() });
      return;
    }
    case "create": {
      const { sid, cols, rows } = msg;
      if (!sid || !cols || !rows) {
        err(id, "create: sid, cols, rows required");
        return;
      }
      if (sessions.has(sid)) {
        // Idempotent re-create: drop the old grid first.
        try { sessions.get(sid).term.dispose(); } catch {}
        sessions.delete(sid);
      }
      const term = new Terminal({
        cols,
        rows,
        allowProposedApi: true,
        scrollback: 10000,
      });
      const serializer = new SerializeAddon();
      term.loadAddon(serializer);
      sessions.set(sid, { term, serializer });
      reply(id, { ok: true });
      return;
    }
    case "write": {
      const { sid, b64 } = msg;
      const entry = sessions.get(sid);
      if (!entry) {
        err(id, "unknown_sid");
        return;
      }
      try {
        const bytes = Buffer.from(b64 || "", "base64");
        // term.write() is async (writes are queued and processed on a
        // microtask). Ack after the callback fires so that a subsequent
        // serialize() call sees the bytes in the grid.
        pending++;
        entry.term.write(bytes, () => {
          pending--;
          reply(id, { ok: true });
          maybeExit();
        });
      } catch (e) {
        err(id, String(e && e.message || e));
      }
      return;
    }
    case "resize": {
      const { sid, cols, rows } = msg;
      const entry = sessions.get(sid);
      if (!entry) {
        err(id, "unknown_sid");
        return;
      }
      if (!cols || !rows) {
        err(id, "resize: cols, rows required");
        return;
      }
      try {
        entry.term.resize(cols, rows);
        reply(id, { ok: true });
      } catch (e) {
        err(id, String(e && e.message || e));
      }
      return;
    }
    case "serialize": {
      const { sid } = msg;
      const entry = sessions.get(sid);
      if (!entry) {
        err(id, "unknown_sid");
        return;
      }
      try {
        // Force any queued writes to drain by enqueueing an empty write
        // and serializing inside its callback. xterm.js processes its
        // write queue in order, so this resolves once everything before
        // it has been applied to the grid.
        pending++;
        entry.term.write("", () => {
          pending--;
          try {
            const data = entry.serializer.serialize();
            reply(id, { ok: true, data });
          } catch (e) {
            err(id, String(e && e.message || e));
          }
          maybeExit();
        });
      } catch (e) {
        err(id, String(e && e.message || e));
      }
      return;
    }
    case "delete": {
      const { sid } = msg;
      const entry = sessions.get(sid);
      if (entry) {
        try { entry.term.dispose(); } catch {}
        sessions.delete(sid);
      }
      reply(id, { ok: true });
      return;
    }
    default: {
      err(id, "unknown_cmd");
      return;
    }
  }
}

const rl = createInterface({ input: process.stdin });

rl.on("line", (line) => {
  const trimmed = line.trim();
  if (!trimmed) return;
  let msg;
  try {
    msg = JSON.parse(trimmed);
  } catch (e) {
    process.stderr.write(`sidecar: bad json: ${String(e && e.message || e)}\n`);
    return;
  }
  try {
    handle(msg);
  } catch (e) {
    // Last-ditch — should never reach here, but never crash the loop.
    try {
      err(msg && msg.id, String(e && e.message || e));
    } catch {}
    process.stderr.write(`sidecar: handler threw: ${String(e && e.stack || e)}\n`);
  }
});

rl.on("close", () => {
  // Stdin closed — parent went away. Defer exit until pending xterm.js
  // write callbacks have drained so any in-flight serialize() responses
  // still get flushed; otherwise exit immediately.
  stdinClosed = true;
  maybeExit();
});

// Announce readiness on stderr so the parent can sanity-check the spawn.
process.stderr.write("sidecar: ready\n");
