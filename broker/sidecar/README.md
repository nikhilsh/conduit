# swe-kitty sidecar

Long-running Node process the swe-kitty harness spawns to maintain
[`@xterm/headless`](https://www.npmjs.com/package/@xterm/headless) grids
per session. Communicates with the Go harness over stdin/stdout
line-delimited JSON-RPC.

See `../../docs/PLAN-TERMINAL-SIDECAR.md` for the architecture and
protocol.

## Install

```sh
cd harness/sidecar && npm install --omit=dev
```

Requires Node.js 20+.

## Why

The PTY emits bytes at whatever rows×cols the session has — but the
attaching client's viewport may be different. Replaying raw ring bytes
gets cursor positioning, line wrapping, and alt-screen state wrong.
Tabby-Web / ttyd / Hyper-Cloud all solve this by keeping the grid on
the server and serializing on attach at the client's size, using the
same xterm.js engine the client renders with. This sidecar is that
grid.
