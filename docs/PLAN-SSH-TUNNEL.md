# PLAN-SSH-TUNNEL — keep the bootstrap SSH session alive and forward the broker port

Status: core implemented (this PR). App wiring is a follow-up (checklist at the
bottom). Architecture decision: **localhost `TcpListener` proxied byte-for-byte
into a russh `direct-tcpip` channel** — the existing WebSocket transport dials
`ws://127.0.0.1:<local_port>` unchanged.

---

## 0. Why this exists (flow-1 keystone)

Today the mobile flow is:

1. App SSHes to the user's box (russh, `core/src/ssh/`), runs
   `scripts/remote-bootstrap.sh`, gets back `{port, token}`.
2. App **tears the SSH session down** and reconnects WS/HTTP **directly** to the
   public `host:1977` with the bearer token in an `Authorization: Bearer` header
   / `?token=` query param, over **plaintext HTTP** unless the user fronts it
   with TLS.

That requires a publicly reachable `:1977` and puts the bearer on the wire in
the clear. The reference app (litter, `DEVELOPMENT.md`: "the SSH flow is the
supported path", local-forward of `127.0.0.1:8390`) instead **keeps the SSH
connection and port-forwards** the broker port through it. We want the same:
the broker never needs a public port, and the token + all traffic ride inside
the SSH-encrypted channel.

### What's already here

`core/src/ssh/` already contains the bones of this:

- `ssh_bootstrap()` (`mod.rs`) connects, runs the remote bootstrap, then
  **already** binds a random localhost `TcpListener` and spawns an accept loop
  that opens a `channel_open_direct_tcpip` to `127.0.0.1:<remote_port>` per
  accepted connection (`port_forward.rs::proxy_connection`).
- The returned `SshBootstrapResult.local_port` is what the app dials.

So the *happy-path byte plumbing* exists. **What's missing — and what this PR
adds — is lifecycle ownership and robustness:**

- **No handle is returned to the app.** The `SshClient` (which owns the russh
  `Handle`) is dropped when `ssh_bootstrap()` returns; only the spawned
  accept-loop task keeps an `Arc<Mutex<Handle>>` alive. There is **no way to
  stop the tunnel** or to abort the accept loop → the listener + SSH session
  **leak** for the process lifetime, even after the app calls
  `ConduitClient.disconnect()`.
- **No tunnel-drop detection.** If the SSH session dies (network flap, server
  reboot, idle kill), the accept loop keeps `accept()`ing and every new
  connection silently fails `channel_open_direct_tcpip` and is dropped on the
  floor. The app's WS reconnect logic dials a dead localhost port forever.
- **No clean teardown.** No `disconnect` of the SSH session, no abort of the
  accept loop or its per-connection children.
- **The proxy loop is coupled to russh `Channel`** so it can't be unit-tested
  without a real SSH server.

This PR closes those gaps and exposes a proper tunnel-handle API.

---

## 1. russh capability check (pinned version)

`core/Cargo.toml` pins `russh = "0.45"`; `Cargo.lock` resolves
**`russh 0.45.0`**. Verified directly against the locked source in
`~/.cargo/registry/.../russh-0.45.0/`:

- **`Handle::channel_open_direct_tcpip<A: Into<String>, B: Into<String>>(&self,
  host_to_connect: A, port_to_connect: u32, originator_address: B,
  originator_port: u32) -> Result<Channel<Msg>, russh::Error>`**
  (`src/client/mod.rs:502`). This is the local-forward primitive — it asks the
  server to open a TCP connection to `host_to_connect:port_to_connect` and
  returns a `Channel<Msg>` we pump bytes through. Takes `&self` (not `&mut`),
  so multiple channels can be opened from a shared `Handle` behind a mutex
  held only for the open call. Matches the existing call site exactly.
- **`Handle::is_closed(&self) -> bool`** (`src/client/mod.rs:225`) — proxies
  `self.sender.is_closed()`. This is our **tunnel-drop detection primitive**:
  once the russh I/O loop has terminated (disconnect, transport error, EOF) the
  command sender is closed and this flips to `true`. Cheap, non-blocking.
- **`Handle::disconnect(&self, reason: Disconnect, description: &str,
  language_tag: &str) -> Result<(), russh::Error>`** (`src/client/mod.rs:600`) —
  clean SSH-level teardown for `stop()`.
- **`Channel::make_writer(&self) -> impl AsyncWrite`** (`src/channels/mod.rs:362`)
  and **`Channel::wait(&mut self) -> Option<ChannelMsg>`**
  (`src/channels/mod.rs:329`) — the read/write halves we already use in
  `proxy_connection`.
- `client::Config { keepalive_interval: Some(_) , .. }` — already set to 30s in
  `connect.rs`. russh sends SSH keepalive (global requests) on that cadence; if
  N consecutive keepalives go unanswered russh tears the session down, which is
  exactly what flips `is_closed()` to `true`. (russh 0.45 has no separate
  "keepalive max count" knob; the TCP/keepalive timeout is what bounds
  detection latency — see Unknowns.)

No newer/renamed API is needed; the version in tree is sufficient.

---

## 2. Architecture decision — localhost listener vs in-process stream

**Decision: localhost `TcpListener` that proxies bytes into a `direct-tcpip`
channel.** Justification from the actual transport code:

`core/src/transport.rs` dials the broker via
`tokio_tungstenite::connect_async(request)` where `request` is built from a
`url::Url` (`open_ws` → `build_initial_ws_url` → `ws://…/ws/{id}?…`). The WS
client owns its own TCP dial; it expects a real `ws://host:port` URL and does
TLS/redirect handling on it. To feed it an in-process `AsyncRead + AsyncWrite`
we'd have to fork `tokio-tungstenite`'s connect path to accept a pre-made
stream (`client_async` over a custom stream) and thread that all the way
through `open_ws`, `reconnect`, the redirect loop, and the
`MaybeTlsStream<TcpStream>` type alias (`WsStream`). That's invasive and
couples the transport to the SSH layer.

A localhost listener keeps the two layers fully decoupled: the SSH layer hands
back a `u16` local port, and `transport.rs` dials `ws://127.0.0.1:<port>`
**with zero changes** — which is exactly what the app already does today with
`result.local_port`. The cost is one extra in-kernel TCP hop on loopback
(negligible) and the bytes are already plaintext-WS *inside* loopback before
they enter the SSH channel, which is fine because loopback never leaves the
device. This is also the shape litter ships.

So we keep the listener approach but wrap it in an owned, stoppable handle.

---

## 3. Architecture (as implemented)

```
            ┌─────────────────────── mobile device ───────────────────────┐
            │                                                              │
 transport  │  connect_async("ws://127.0.0.1:<local_port>")                │
 (unchanged)│        │                                                     │
            │        ▼                                                     │
            │   TcpListener 127.0.0.1:<local_port>   (owned by SshTunnel)  │
            │        │  accept()                                           │
            │        ▼                                                     │
            │   per-conn task: pump_bidirectional(tcp <-> ssh_channel)     │
            │        │                                                     │
            │   Handle.channel_open_direct_tcpip("127.0.0.1", remote_port) │
            │        │   (russh session kept ALIVE post-bootstrap)         │
            └────────┼─────────────────────────────────────────────────────┘
                     │  SSH-encrypted
                     ▼
            ┌──────── user's box ────────┐
            │  sshd → 127.0.0.1:<broker> │  broker bound to loopback only —
            │         (broker / :1977)   │  NO public port required
            └────────────────────────────┘
```

New type: **`SshTunnel`** (UniFFI `interface`, i.e. an `Arc`-backed object the
app holds). It owns:

- `Arc<AsyncMutex<Handle<RusshClientHandler>>>` — the live russh session.
- the accept-loop `JoinHandle` (aborted on `stop`/drop).
- a `tokio_util`-free cancellation flag (`Arc<Notify>` + `AtomicBool`) so the
  accept loop and a lightweight liveness watcher exit promptly.
- `local_port: u16`, `remote_port: u16`.

Methods exposed to the app:

- `local_port() -> u16`
- `is_alive() -> bool` — `!handle.is_closed() && !stopped`
- `stop()` — best-effort SSH `disconnect`, abort accept loop, drop listener.

`ssh_bootstrap()` now returns the `SshTunnel` **in addition to** the existing
`SshBootstrapResult` fields. To keep the apps compiling unchanged (see the
no-app-change rule) we add a **second** entry point and leave the existing
`ssh_bootstrap` dictionary-returning function in place:

- `ssh_bootstrap(...) -> SshBootstrapResult` — **unchanged signature**, still
  returns `{remote_port, local_port, token, host_key_fingerprint, reused}` and
  still spawns a fire-and-forget tunnel (back-compat; the apps keep working
  exactly as before this PR).
- `ssh_bootstrap_tunneled(...) -> SshTunnelBootstrap` — new. Returns a
  `dictionary { SshBootstrapResult result; SshTunnel tunnel; }` so the app can
  hold the handle, observe `is_alive()`, and call `stop()` on logout. **This is
  the path the app follow-up migrates to.**

(UniFFI 0.28 cannot embed an `interface` object as a field of a plain
`dictionary` that's also used elsewhere, so `SshTunnelBootstrap` is a dedicated
dictionary whose `tunnel` field is the object type — that is allowed.)

---

## 4. Connection lifecycle

- **Keepalive:** unchanged — `client::Config.keepalive_interval = 30s`
  (`connect.rs`). Bounds how fast a silently-dead session is noticed.
- **Drop detection:** `SshTunnel::is_alive()` consults `Handle::is_closed()`.
  A tiny watcher task also polls `is_closed()` on a slow cadge and, on first
  `true`, fires the cancellation `Notify` so the accept loop stops binding new
  doomed channels and the listener is released. The watcher then exits — no
  busy loop.
- **What the app sees when the tunnel drops mid-session:** the localhost
  listener closes (or each new dial gets connection-refused once the listener
  is dropped). The **existing** per-session reconnect worker in `transport.rs`
  (`reconnect()` / `park_until_nudge()` — `RECONNECT_MAX_ATTEMPTS` with
  backoff, then a parked slow-retry) already handles "the socket went away":
  it surfaces `ConnectionHealth::Reconnecting` then `Disconnected`. **The core
  tunnel does NOT itself re-establish SSH** — re-bootstrapping is a user-visible
  action (host-key TOFU, possible re-`docker run`) so it belongs to the app
  layer, which re-invokes `ssh_bootstrap_tunneled` and points the transport at
  the new `local_port`. The plan's app-follow-up checklist covers wiring
  `is_alive() == false` → "tunnel lost, re-pair" UX. (Rationale: silently
  re-SSHing under the app would bypass the host-key acceptance sheet — a
  security regression.)
- **Teardown:** `stop()` is idempotent: sets the stopped flag, notifies the
  accept loop, aborts the accept `JoinHandle`, best-effort
  `Handle::disconnect(ByApplication, "client stop", "")`. `Drop` for
  `SshTunnel` also aborts the accept task so a dropped handle never leaks the
  loop. Per-connection child tasks are short-lived (they end when either TCP
  half closes); we don't track them individually, but they cannot outlive the
  SSH `Handle` (a closed channel ends `proxy_connection` promptly).

---

## 5. UniFFI surface changes

`core/src/conduit_core.udl` additions:

```
interface SshTunnel {
    u16 local_port();
    boolean is_alive();
    void stop();
};

dictionary SshTunnelBootstrap {
    SshBootstrapResult result;
    SshTunnel tunnel;
};

namespace conduit_core {
    // existing ssh_bootstrap unchanged …

    [Async, Throws=SshError]
    SshTunnelBootstrap ssh_bootstrap_tunneled(
        SshCredentials credentials,
        string pre_allocated_token,
        string anthropic_api_key,
        string openai_api_key,
        string? image_ref,
        SshHostKeyDelegate host_key_delegate
    );
};
```

`SshTunnel` is a `#[derive(uniffi::Object)]`-style object (via the UDL
`interface`), so it crosses the FFI as an opaque `Arc`-backed handle. `stop()`
is synchronous (fire the cancel + abort; the SSH `disconnect` is best-effort,
spawned). `local_port()` / `is_alive()` are cheap synchronous getters.

Bindings regenerated with `make bindings` (Swift + Kotlin) and committed under
`core/generated/`. No app source is changed in this PR.

---

## 6. Security win

- **Token never leaves the SSH channel.** With the tunnelled path the WS dials
  loopback; the `Authorization: Bearer` bytes are encrypted by SSH before they
  cross the network. No plaintext bearer on a public port.
- **No public broker port required.** The broker can bind `127.0.0.1:<port>`
  on the box; the only externally reachable port is `sshd`. This shrinks the
  attack surface to "whoever already has SSH" — i.e. nothing new.
- **Host-key TOFU already enforced** (`connect.rs::check_server_key` →
  `SshHostKeyDelegate`); the tunnel rides the same authenticated session, so a
  MITM would have to defeat SSH host-key verification, not just TLS.

---

## 7. Tests (this PR)

- `pump_bidirectional` is factored out of `proxy_connection` as a generic
  `async fn pump_bidirectional<A, B>(a: A, b: B)` over `AsyncRead + AsyncWrite +
  Unpin` (the two ends). The russh `Channel` is split into reader/writer via
  `make_writer()` + a `wait()` adapter; the TCP socket via `into_split()`.
- Unit tests use **two real localhost TCP sockets** (a `tokio` echo server on
  one end, a client on the other) to exercise the byte-pump in both directions,
  half-close semantics, and large payloads — **no russh / no real SSH needed**.
- Existing `bind_random_local` test retained.
- `SshTunnel::stop()` idempotency + accept-loop abort are tested with a stub
  listener (no SSH) where the "open channel" step is a closure, verifying the
  loop exits on cancel and the port is released.

### On-device only (cannot be CI-verified)

- A **real SSH hop to the box**: connect → bootstrap → forward → WS handshake
  over the channel → live session. Requires a Mac/Android device + the actual
  server (the dev box is CI-compile-only for the apps, and there's no SSH
  loopback fixture in CI).
- **Mid-session SSH drop** (kill sshd / network flap) → `is_alive()` flips →
  app re-pair UX. Needs a device + server.
- Keepalive-driven detection latency under real network conditions.

---

## 8. Per-platform app follow-up checklist (SEPARATE PR — not this one)

iOS (`apps/ios/Sources/SessionStore.swift`):

- [ ] Call `sshBootstrapTunneled(...)` instead of `sshBootstrap(...)` in the
      bootstrap path (~line 1039).
- [ ] Store the returned `SshTunnel` on the `SessionStore` (strong ref) so it
      isn't deallocated — dealloc would drop the SSH session.
- [ ] Build the endpoint from `bootstrap.result.localPort` (unchanged shape).
- [ ] On logout / endpoint change / app teardown: call `tunnel.stop()` before
      releasing.
- [ ] Poll / observe `tunnel.isAlive()`; on `false` surface a "connection to
      your server was lost — reconnect" state and re-run the bootstrap (TOFU
      sheet may re-appear). Wire to `HarnessState`.
- [ ] Telemetry breadcrumbs: tunnel-open, tunnel-stop, tunnel-lost.

Android (`apps/android/.../SessionStore.kt`):

- [ ] Switch `ffiSshBootstrap` → `sshBootstrapTunneled`.
- [ ] Hold the `SshTunnel` in the `SessionStore` (it's an AutoCloseable-style
      object; keep a field, `stop()` in `onCleared`/logout).
- [ ] Endpoint from `bootstrap.result.localPort`.
- [ ] Observe `isAlive()` → `HarnessState.Disconnected` + re-pair affordance.
- [ ] Telemetry breadcrumbs mirroring iOS.

Both:

- [ ] Decide the re-pair policy when `is_alive()` is false: auto re-bootstrap
      (re-prompt host key only if the fingerprint changed) vs. manual. Keep the
      host-key acceptance gate — never silently re-accept.
- [ ] Remove the old direct-public-port path once the tunnelled path is the
      default (keep it behind a FeatureFlag for one release for fallback).

---

## 9. Honest unknowns

- **Detection latency.** `is_closed()` flips only once russh's I/O loop
  actually ends. On a hard network partition with no RST, that can wait for
  TCP/keepalive timeouts (tens of seconds to minutes depending on OS defaults
  and the 30s SSH keepalive). The app's WS reconnect will usually notice the
  dead loopback dial first. We have not measured real-world latency — flagged
  for on-device.
- **iOS background suspension.** When iOS suspends the app the SSH TCP socket
  and the russh runtime are frozen; on resume the session may be silently dead.
  `notify_network_change()` already nudges WS reconnect, but the **SSH tunnel**
  has no equivalent "re-validate on foreground" hook yet. Likely the app
  follow-up needs to check `is_alive()` on foreground and re-bootstrap. Not
  solved in core.
- **Per-connection child-task accounting.** We rely on "a closed SSH channel
  ends `proxy_connection`" rather than tracking each child task in a
  `JoinSet`. Believed correct (channel close → `wait()` yields
  `Close`/`None` → loop ends; TCP close → read returns 0), but a pathological
  half-open where neither side closes could park a task until the `Handle`
  drops. Acceptable because `stop()`/drop kills the `Handle`, which closes all
  channels.
- **Multiple concurrent sessions over one tunnel.** The broker multiplexes all
  sessions over the one WS to `local_port`, so one tunnel suffices today. If a
  future design opens multiple independent WS connections, the single accept
  loop already handles N concurrent accepts (one channel each) — untested at
  scale.
- **Does the broker actually bind loopback-only on the box?** This PR assumes
  the broker is reachable at `127.0.0.1:<remote_port>` from inside the SSH
  session (it is — that's what bootstrap returns and what the existing forward
  uses). Whether we *also* close the public `:1977` is a broker/bootstrap-script
  change, not core — tracked separately.
