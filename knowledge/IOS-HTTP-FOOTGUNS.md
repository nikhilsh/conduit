---
title: iOS HTTP footguns — URLComponents encoding and stale-callback guard
tags: [ios, swift, http, urlcomponents, networking, concurrency]
scope: repo
source: ios-getjson-url-query-bug, stale-client-callback-guard
status: active
---

# iOS HTTP footguns

## URLComponents.path percent-encodes the query string

Assigning a path-with-query to `URLComponents.path` percent-encodes the `?`
into `%3F`, breaking every GET with a query parameter.

**Root cause:** `SessionStore.getJSON(endpoint:path:)` did
`components?.path = path`. When `path` contained a query
(e.g. `/api/sessions/discovered?limit=20`), the `?` became `%3F` → the broker
received `/api/sessions/discovered%3F...` → 404 (route not found).

**Compounding issue:** setting `comps.queryItems = []` (empty array, not nil)
produces `comps.query == ""` → `.map{"?\($0)"}` prepends a stray `?` even with
no query → `%3F` → 404. Android was unaffected (it builds raw URL strings,
no `URLComponents.path` encoding).

**Fix (PR #614, v0.0.163):**
- Split `path` at the first `?` and set `components.percentEncodedQuery`
  (callers' query parts are already percent-encoded) instead of cramming it
  into `.path`.
- Only set `queryItems` when non-empty (no stray `?`).

**Rule:** never assign a path-with-query to `URLComponents.path`. Either split
at the `?` and assign query and path separately, or build the full URL string
and use `URL(string:)`.

**Diagnostic technique (packet capture):** the broker does not log HTTP requests
to journald (`StandardOutput` is not journal). To see what the device sends:
```sh
tcpdump -i any -A -s0 'tcp port 1977'
```
on the box while the user triggers the request. This shows the raw HTTP path
and reveals percent-encoding issues immediately.

## Stale-callback guard — use generation, not reachability

When switching the active box, the old `ConduitClient`'s already-queued
`onDisconnected` can fire AFTER the new client reaches `.linked` and clobber
state — causing a visible connected→disconnected→connected flash.

**Wrong fix:** gating the callback on `if (current.isReachable) return`. This
ALSO swallows a genuine disconnect of the live client (network drop while
linked → `isReachable` true → callback dropped → UI stuck on "connected"
forever).

**Correct fix (v0.0.156):** per-client GENERATION guard.
- iOS: `StoreDelegate` is a separate object per client, stamped with a
  `clientGeneration` at connect; callbacks drop when
  `generation != store.clientGeneration`.
- Android: `GenerationGuardedDelegate` inner class passed to `c.connect(...)`;
  forwards each of the 9 `ConduitDelegate` methods only while its generation
  is current.

**iOS compile footguns shipping this:**
- A `private` stored property read by a same-file nested type (`StoreDelegate`)
  needs `fileprivate`.
- A `nonisolated` delegate helper that reads a `@MainActor` property fails with
  "main actor-isolated property can not be referenced from a nonisolated context"
  — mark the helper `@MainActor` (call sites are already inside
  `Task { @MainActor in }`).

Gate on generation/client identity, never on "are we currently reachable".
