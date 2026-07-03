# PLAN: Per-session observability decomposition (iOS + Android)

Status: **design only. No production code in this PR.**

The problem this fixes is a **fan-out invalidation** in both mobile apps: every
per-session field lives in one observable object keyed by session id, so a
streaming token or a status frame for **any** session invalidates **every**
SwiftUI view / Compose collector that ever read that field — the whole home
list, the tablet rail, every visible row. With many live sessions the apps
visibly lag. The structural fix is to give **each session its own observable
node** so a write for session X only invalidates views bound to X, and to split
**membership** (which sessions exist, in what order) from **content** (what any
one session is doing right now) so a content tick never re-evaluates the list.

A parallel PR (branch `perf/surgical-lag-fixes`) is already gating the O(N)
conversation re-fetch on status deltas, pausing off-screen animations, and
debouncing persistence. **This plan is the structural layer that lands after
it** and is deliberately orthogonal: this touches *observability granularity*,
that PR touches *work volume per tick*. Neither depends on the other to compile.

Mobile is **CI-compile-only on the dev box** (no simulator/emulator). Every
stage below must be trustable from `xcodebuild test` + `:app:testDebugUnitTest`
+ code review, and each carries its own on-device verification checklist because
CI green here means *compiles + unit tests pass*, not *renders correctly*.

---

## 1. Root cause (precise, with code anchors)

### 1.1 iOS — `@Observable` tracks at stored-property granularity

`SessionStore` (`apps/ios/Sources/SessionStore.swift:903`) is one
`@Observable @MainActor final class`. Its per-session state is a bank of
dictionaries keyed by session id (`apps/ios/Sources/SessionStore.swift:1020-1196`):

```
var statusBySession:          [String: SessionStatus]     // L1023
var chatLog:                  [String: [ChatEvent]]       // L1044
var conversationLog:          [String: [ConversationItem]]// L1046
var streamingMessage:         [String: String]            // L1097
var streamingTurnTs:          [String: String]            // L1104
var turnPhaseBySession:       [String: String]            // L1109
var thinkingBySession:        [String: String]            // L1115
var connectionHealthBySession:[String: ConnectionHealth]  // L1165
var quickReplies / credentialSource / preview / subagentRosters / …
```

Swift's Observation framework registers a dependency on the **whole stored
property**, not on a dictionary subscript. When `ConduitChatView.transcript`
reads `store.conversationLog[session.id]`
(`apps/ios/Sources/ConduitUI/Views/ConduitChatView.swift:350`) it takes a
dependency on the entire `conversationLog` property. When `ingestChatStreaming`
does `streamingMessage[Y] = content`
(`apps/ios/Sources/SessionStore.swift:5132`) that mutates the whole
`streamingMessage` property → **every** view that read `store.streamingMessage`
for **any** session is invalidated.

The two worst readers:

- **`ConduitUI.HomeView.snapshot`**
  (`apps/ios/Sources/ConduitUI/Views/ConduitHomeView.swift:458-526`) maps over
  `store.sessions` and, per session, reads `store.statusBySession[s.id]`,
  `lastMessageTimestamp` → `store.conversationLog[…].last`,
  `latestActivityPreview` → `store.conversationLog[…]` + `store.chatLog[…]`,
  `store.isConfirmedLive` (reads `sessionLifecycle` + `statusBySession`). So the
  home list body depends on `statusBySession`, `conversationLog`, `chatLog`,
  `sessionLifecycle` **globally**. One streaming token for one background
  session re-runs `snapshot` (a full O(N) map), `HomeViewModel.rows` (sort +
  build), and re-diffs the whole `List`.
- **`ConduitChatView`** reads `conversationLog`, `chatLog`,
  `statusBySession[…]?.turnActive` (L494), `turnPhaseBySession` (L502),
  `streamingMessage` (L509), `thinkingBySession` (L515) — all as whole-property
  dependencies, so a **different** session's turn invalidates the open chat.

A per-row `Equatable`/memo (the `transcriptFingerprint` at
`ConduitChatView.swift:335`, the parallel perf PR's row-equatable work) reduces
the *cost* of each invalidation but does not stop the invalidation from firing —
the body still re-evaluates on every cross-session tick. Granularity is the only
thing that stops the fire.

### 1.2 Android — `MutableStateFlow<Map<String, T>>` replaces the whole map

`SessionStore.kt` mirrors the shape with one flow per field
(`apps/android/.../SessionStore.kt:594-682`):

```
_statusBySession:   MutableStateFlow<Map<String, SessionStatus>>       // L594
_conversationLog:   MutableStateFlow<Map<String, List<ConversationItem>>> // L654
_streamingMessage:  MutableStateFlow<Map<String, String>>              // L663
_turnPhaseBySession / _thinkingBySession / _streamingTurnTs / …
```

Every write copies the whole map (`_conversationLog.value = _conversationLog.value
+ (id to items)` / `.toMutableMap().also{…}` — e.g.
`SessionStore.kt:865, 976`), which re-emits to **all** collectors. Consumers
`collectAsState()` the **entire map** at screen scope: `ChatPage`
(`ui/ChatPage.kt:398-414` collects conversationLog, statusBySession,
streamingMessage, turnPhase, thinking), `NeonTabletHome`
(`ui/NeonTabletHome.kt:78-79`), `NeonTabletRail` (`ui/NeonTabletRail.kt:72-77`),
`ProjectListScreen` (`ui/ProjectListScreen.kt:51-57`). So a token for session X
recomposes every screen collecting that map.

### 1.3 The one-line statement of the bug

> Per-session content is stored in **process-global** observable slots, so the
> observation graph has one node per *field* instead of one node per
> *(session, field)*. Fan-out is inherent to the storage shape, not the views.

---

## 2. Target architecture — iOS

### 2.1 `SessionNode`: one `@Observable` per session

Introduce a per-session observable that owns the **content** fields:

```swift
@Observable @MainActor
final class SessionNode {
    let id: String
    var status: SessionStatus?
    var lifecycle: SessionLifecycle?           // moved from sessionLifecycle
    var conversation: [ConversationItem] = []
    var chatLog: [ChatEvent] = []
    var streaming: String?                     // was streamingMessage[id]
    var streamingTurnTs: String?
    var turnPhase: String?
    var thinking: String?
    var connectionHealth: ConnectionHealth?
    var quickReplies: AIQuickReplies?
    var credentialSource: String?
    var preview: PreviewInfo?
    var subagentRoster: [SubagentEntry] = []
    // pagination + hydration bookkeeping stay INTERNAL to the node:
    var hasMoreHistory = false
    fileprivate var oldestLoadedTs: Int64 = 0
    fileprivate var isLoadingOlder = false
    fileprivate var hydratedChat: [ConversationItem] = []
    fileprivate var answeredPending: [String: String] = [:]
}
```

The store keeps a **registry** and everything that is genuinely cross-session:

```swift
@Observable @MainActor final class SessionStore {
    private var nodes: [String: SessionNode] = [:]   // NOT observed by row views
    var sessions: [ProjectSession] = []              // membership (see §2.3)
    var harness / savedServers / selectedSessionID / endpoint …
    // pendingChats, sessionBox routing, box connections, SSH tunnel, demo …
}
```

**Why a class, not a struct-in-dictionary:** a class instance is a *stable
observation identity*. A view captures `let node = store.node(session.id)` once;
thereafter its body depends only on the properties of *that* node. A write to
`otherNode.streaming` touches a different object → the view is not invalidated.
This is the entire fix, and it is exactly how Observation is designed to scope.

### 2.2 The invalidation contract (be precise about what invalidates what)

- Reading `node.streaming` in a body registers a dependency on **that node's
  `streaming` property only**. `otherNode.streaming = …` does not invalidate it.
- `store.nodes` itself is a **non-observed** private var (or an untracked
  `@ObservationIgnored` store) — views must **never** read `store.nodes` in a
  body. They get their node via an accessor that returns the class reference
  without registering the dictionary as a dependency (see §2.4). Node *creation*
  drives membership through `sessions` (§2.3), not through the dictionary.
- A view bound to node X re-renders iff a property of X it read changed. Cross-
  session ticks are now silent for X. This is verified structurally by the
  Observation semantics — not something we can observe on CI, so §6 lists the
  device check.

### 2.3 Home list: membership vs content

The list must react to **membership** changes (session added / removed / order)
without re-evaluating on **content** ticks. Split it:

1. **Membership** is `store.sessions` (already `[ProjectSession]`) plus a
   **derived, debounced order signal**. The home `List`'s `ForEach` iterates a
   `[HomeRowIdentity]` = `{ id, kind }` — the *identity and order only*, with no
   per-session content in it. Adding/removing a session or reordering changes
   this array; a streaming token does not.
2. **Order** depends on per-session `lastActivity` (today `sortedSessions` in
   `ConduitHomeViewModel.swift:282` sorts on `lastActivityAt`, which is derived
   from `conversationLog.last.ts`). Recomputing order on every token is the
   trap. Introduce a **`HomeOrderPublisher`**: a small `@Observable` holding
   `orderedSessionIDs: [String]`, recomputed on a **debounce** (250–400ms
   trailing) whenever any node's `lastActivity` changes or membership changes.
   The list binds to `orderedSessionIDs`; nodes push "my activity changed" into
   a coalescing recompute. Result: the visible order settles a beat after a
   burst instead of thrashing per token. (Owner-visible tradeoff: a newly-active
   session jumps to top up to ~400ms late. That is imperceptible and is the
   price of not re-sorting the whole list per token — call it out in the PR.)
3. **Row content** — each row view captures its `SessionNode` and reads
   `node.status`, `node.conversation.last` (preview), `node.lifecycle`
   (confirmed-live). Only that row invalidates when its session ticks.
   `HomeRowView` (`ConduitHomeView.swift:1025`) is refactored to take a
   `SessionNode` (or a tiny per-node `@Observable` row VM) instead of a
   pre-baked `HomeRow` value struct built in the parent `snapshot`.

So the parent `homeList` body depends on: `orderedSessionIDs` (membership+order,
debounced), `store.harness`, `store.savedServers` — **not** on any content
dictionary. The `snapshot`/`rows` value-type pipeline
(`ConduitHomeView.swift:458`, `ConduitHomeViewModel.rows`) is **retained for
unit tests** but no longer the live render path for row content; the pure
`HomeViewModel.statusText/relativeTime/activityPreview/sortedSessions` helpers
are reused inside the per-node row VM so their tests keep covering the logic.

The **"needs you" banner** (`ConduitHomeView.swift:534`) and the **usage strip**
depend on a cross-session fold. Give them the same treatment as order: a
debounced derived signal (`store.needsYouSessionIDs`) recomputed off node
`conversation` changes, not read inline in the parent body.

### 2.4 Backward-compatibility shims (migrate view-by-view)

The store keeps **the exact old accessor surface**, forwarding to nodes, so no
call site outside a migrated view changes in the same PR:

```swift
extension SessionStore {
    // Read shims — computed, forward to the node. NOT stored properties, so
    // reading them from a not-yet-migrated view still works, but such a view
    // takes a dependency on the COMPUTED accessor which reads node props;
    // Observation propagates node-level changes through the computed read.
    var streamingMessage: [String: String] {
        Dictionary(uniqueKeysWithValues: nodes.map { ($0.key, $0.value.streaming ?? "") }
                     .filter { !$0.1.isEmpty })
    }
    func streaming(for id: String) -> String? { nodes[id]?.streaming }
    // …one per field: conversation(for:), status(for:), turnPhase(for:), …
}
```

Important subtlety and the honest tradeoff: **a whole-dictionary shim
(`var streamingMessage`) re-introduces the fan-out for any view still using it**
— rebuilding the dictionary reads every node's property, so that view depends on
all nodes again. That is acceptable *during migration* because the shims exist
only to keep un-migrated views compiling; the perf win is realized per view as
it moves to `node.streaming`. The **mutation** side already funnels through the
`ingest*` methods, so writers move to nodes in Stage 1 with zero call-site
churn. The dictionary-shaped *read* shims are deleted in the final stage once
every view is migrated (the compiler enforces this — deleting the shim breaks
any straggler). Prefer the **`func x(for:)`** shims over the dictionary shims for
any view touched in an intermediate stage, since those are per-id and don't
fan out.

### 2.5 The ingest path (writers) — Stage 1, invisible to views

Every `ingest*` in `SessionStore.swift` rewrites to fetch-or-create the node and
mutate it:

- `ingestStatus` (`:5632`) → `node(status.session).status = status` (+ the
  turn-phase mirror L5645, lifecycle promotion L5688, streaming-clear L5675).
  **Crucially preserve the read-BEFORE-write of `priorTurnActive` (L5636)** — it
  now reads `node.status?.turnActive` before assigning `node.status`.
- `ingestChatStreaming` (`:5130`) → `node.streaming = content;
  node.streamingTurnTs = turnTs`.
- `ingestTurnPhase` (`:5147`), `ingestThinkingStreaming` (`:5155`),
  `ingestChat` (`:5162`), `ingestConnectionHealth` (`:5981`),
  `ingestQuickReplies` (`:5107`), etc. → their node fields.
- The streaming-clear block in `ingestChat` (L5205-5215) and the
  turn-complete safety net (L5675-5682) mutate the **same node's** fields — the
  ordering and the `shouldClearStreaming` ts-comparison (L5190-5204) are
  unchanged, only the storage moves.

Because writers are internal, Stage 1 changes zero view files and is fully
covered by the existing `SessionStoreRustParity` / ingest unit tests (which call
`ingestStatus`/`ingestChat` directly — see the "`internal` not `fileprivate`"
notes at `:5080` and `:5099`) plus new node-scoped assertions.

---

## 3. Target architecture — Android

### 3.1 Per-session flows in a `ConcurrentHashMap`

Mirror value-for-value. Replace the `MutableStateFlow<Map<String, T>>` bank with
a per-session node holding per-field flows, kept in a `ConcurrentHashMap`:

```kotlin
class SessionNode(val id: String) {
    val status         = MutableStateFlow<SessionStatus?>(null)
    val lifecycle      = MutableStateFlow<SessionLifecycle?>(null)
    val conversation   = MutableStateFlow<List<ConversationItem>>(emptyList())
    val chatLog        = MutableStateFlow<List<ChatEvent>>(emptyList())
    val streaming      = MutableStateFlow<String?>(null)
    val streamingTurnTs= MutableStateFlow<String?>(null)
    val turnPhase      = MutableStateFlow<String?>(null)
    val thinking       = MutableStateFlow<String?>(null)
    val connectionHealth = MutableStateFlow<ConnectionHealth?>(null)
    val quickReplies   = MutableStateFlow<AIQuickReplies?>(null)
    // hydratedChat / pagination stay as plain fields guarded by the node
}

private val nodes = java.util.concurrent.ConcurrentHashMap<String, SessionNode>()
private fun node(id: String) = nodes.getOrPut(id) { SessionNode(id) }
```

A write is now `node(id).streaming.value = content` — it re-emits **only** that
node's `streaming` flow, so only collectors of that flow recompose.

### 3.2 Row-level collection

- **Membership** is a single `_orderedSessionIds: MutableStateFlow<List<String>>`
  (debounced, §3.4), collected once at list scope. The `LazyColumn`'s `items(...)`
  keys on `id`.
- **Row content**: each row composable takes `store.node(id)` and does
  `val status by node.status.collectAsStateWithLifecycle()` etc. — so a token for
  another session doesn't recompose this row. `collectAsStateWithLifecycle` also
  pauses collection when the row scrolls off (screens: `NeonTabletHome:78`,
  `ProjectListScreen:51`, `NeonTabletRail:72` move from map-collect to node-collect).
- **`ChatPage`** (`ui/ChatPage.kt:398-414`) collects its **single** node's flows
  instead of five whole maps.

### 3.3 Backward-compat facade

Keep the old public `StateFlow<Map<String, T>>` names as **derived facades** so
un-migrated screens compile:

```kotlin
val statusBySession: StateFlow<Map<String, SessionStatus>> =
    // combine over nodes, or a maintained aggregate updated on each node write.
```

Same honest tradeoff as iOS: a screen still collecting the whole-map facade keeps
its fan-out until migrated; the facade is deleted last. The cleanest Kotlin
implementation of the facade is a **maintained aggregate** `MutableStateFlow<Map>`
updated inside the same `node(id).x.value = …` setter (one extra map write) —
this keeps the facade cheap and exact without a `combine` over N flows. Delete the
aggregate write when the last consumer of the facade is gone.

### 3.4 Invariants #684 and #680 are preserved by construction

- **#684 "never overwrite hydrated chat with empty FFI result"**: today
  `hydratedChat` (`SessionStore.kt:704`) and the sticky-merge live in the store;
  move `hydratedChat` **into the node** and keep the exact merge guard — a fresh
  FFI clone that is empty must not replace a non-empty `node.conversation`. The
  merge helper (iOS `mergeConversation`, `SessionStore.swift:5439/5529`; Android
  equivalent) is unchanged; only the map lookup becomes a node field.
- **#680 `reconcileLiveSessions`**: it rebuilds the **membership** list
  (`SessionStore.swift:5010/5056`) and stamps `sessionBox`. Under the new shape
  it (a) ensures a node exists per listed session (`node(id)` get-or-create), (b)
  updates `sessions` + `orderedSessionIds`, (c) fans out
  `refreshConversationOffMain` which writes `node.conversation` via the sticky
  merge. It must **not** delete a node whose session is other-box history — node
  lifetime follows the same rule the list already uses (kept as dimmed history).

---

## 4. Invariants that must not break (enumerated from the code)

Each must have a regression test and a device-verify line.

1. **#865 stale turn-active cleared on disconnect.** `ingestDisconnected`
   (`SessionStore.swift:5913`) and the block at `:5969` flip
   `status.turnActive = false` so a broker-restart send un-sticks. Node port:
   read-modify-write `node.status` in place; keep the "only when turnActive was
   true" guard.
2. **#866 queued-next idle-flush.** `ingestStatus` computes
   `turnJustCompleted = priorTurnActive && !newTurnActive` from the **prior**
   status (`:5636-5638`) and the level-triggered flush-on-idle (`:5652-5670`).
   The prior read **must** happen before `node.status = status`. The
   `flushQueuedOnReply` path in `ingestChat` (`:5215`) and
   `flushQueuedOnTurnComplete` (`:4266`) touch `pendingChats` (cross-session,
   stays on the store) — they read `node.status?.turnActive` where they used the
   dictionary.
3. **Stale-callback generation guard (v0.0.156).** `StoreDelegate.isCurrent`
   (`SessionStore.swift:7351`) drops callbacks from a superseded client by
   `clientGeneration` (`:1248`). Unchanged — it gates *before* any node write.
   Node creation must not happen for a dropped callback (guard stays at the top
   of each `ingest*`, as today it's enforced by the `StoreDelegate` wrapper).
4. **Sticky hydration (#684).** §3.4 / iOS `spliceHydratedChat`
   (`SessionStore.swift:5529`): never replace non-empty `node.conversation` with
   an empty clone.
5. **`pendingChats` durability.** The outbox is cross-session and **stays on the
   store** (not a node): `ingestChatDelivered` (`:5120`),
   `drainSentNormal`/`markDelivered`. Do not move it into a node — a node may be
   GC'd as history while an ack is still in flight.
6. **Demo-mode seeding.** `activateDemo`/`deactivateDemo`
   (`SessionStore.swift:922-945`) seed `conversationLog`/`statusBySession`/
   `sessionLifecycle`. Reroute to `node(id).conversation/status/lifecycle`;
   `deactivateDemo` removes the nodes for demo ids. Android mirror at
   `SessionStore.kt:554-569`.
7. **Box-switch flicker guard.** `reconcileLiveSessions` other-box merge
   (`:5052-5056`) and the boxID-scoped `onDisconnected`
   (`StoreDelegate.onDisconnected` `:7393`, `ingestBoxDisconnected` `:1682`)
   must keep working: node existence is per-session, box ownership stays in
   `sessionBox`; switching boxes changes **membership/order**, never wipes a
   node's content mid-flight.
8. **`isConfirmedLive` semantics** (`:6384`) read `sessionLifecycle` +
   `statusBySession`. Port to `node.lifecycle` + `node.status` verbatim — the
   cold-boot "starting" (amber) window (`HomeViewModel.statusText` confirmedLive
   arg) depends on it.

---

## 5. Migration plan — small, revertable, PR-sized stages

Each stage compiles, ships behind its own review, and is independently
revertable. Ordered so the highest-risk hot-spots move under test first while
views stay on shims.

### Stage 1 — Introduce `SessionNode` + reroute writers; NO view changes
- Add `SessionNode` (iOS + Android). Add `nodes` registry + `node(id)` accessor.
- Reroute **all `ingest*`** and demo seeding to write node fields.
- Add the **read shims** (§2.4 / §3.3) so every existing view compiles unchanged.
- **Riskiest hot-spot:** the `priorTurnActive` read-before-write in `ingestStatus`
  (#866) and the streaming-clear ts-comparison in `ingestChat`. New unit tests:
  drive `ingestStatus`/`ingestChat` and assert node fields + that
  `turnJustCompleted` still fires and flushes the queue.
- Net behavior: **identical** to today (shims fan out exactly as before). This
  stage buys zero perf; it establishes the storage seam under test.
- Revert = delete the node type + restore dictionary writes (one file each side).

### Stage 2 — Chat screen reads its node
- `ConduitChatView` captures `let node = store.node(session.id)` and reads
  `node.conversation/chatLog/status.turnActive/turnPhase/streaming/thinking`.
  Android `ChatPage` collects the node's flows.
- **Riskiest:** the `transcript` memo (`ConduitChatView.swift:349`) +
  `isAgentWorking` (`:481`) — verify the fingerprint still keys off the same
  fields and that `serverTurnActive` reads `node.status?.turnActive`.
- Win: an open chat stops recomposing on other sessions' turns. Immediately
  device-verifiable (open chat on A, drive B, confirm A is quiet).
- Revert = point the six accessors back at the shims.

### Stage 3 — Home rows + rail read their nodes; add order/needs-you publishers
- Add `HomeOrderPublisher` (`orderedSessionIDs`, debounced) + `needsYouSessionIDs`.
- `HomeRowView` takes a `SessionNode`; the parent `homeList` binds to
  `orderedSessionIDs` + `harness` + `savedServers` only. Android
  `NeonTabletHome`/`NeonTabletRail`/`ProjectListScreen` move to per-node collect
  + ordered-id list.
- **Riskiest:** the debounce could make order/badges feel laggy, and the
  membership `ForEach` must key on identity so SwiftUI doesn't recreate rows.
  Keep the pure `HomeViewModel` helpers as the per-row computation.
- Win: the home list stops re-sorting/re-evaluating on content ticks — the main
  visible lag. Highest-value device check.
- Revert = restore the `snapshot`/`rows` inline path (kept intact through Stage 3).

### Stage 4 — Delete the dictionary read shims/facades
- Remove `var streamingMessage`/`conversationLog`/… whole-map shims (iOS) and the
  aggregate facades (Android). The compiler flags any straggler view; migrate or
  fix it. Remove the now-dead `snapshot`/`rows` live path (keep the tests
  pointing at the pure helpers).
- **Riskiest:** a straggler outside the four hot screens (Approvals, Search,
  SessionInfo, Recap, DiffReview all collect `conversationLog` — see
  `ui/*.kt` grep). Each is small; migrate to `node(id)` or a per-id func shim.
- Revert = re-add the shim (trivial).

---

## 6. On-device verification checklist (per stage — CI cannot see render)

- **Stage 1:** with ≥3 live sessions, everything behaves exactly as before
  (regression-only): send/queue-next after a broker restart still flushes (#866);
  disconnect un-sticks turn-active (#865); demo mode still seeds; box switch
  still shows the target box. No perf claim.
- **Stage 2:** open A's chat, drive a long streaming turn on B → A's chat does
  not stutter/scroll-jump; A's own streaming/thinking/turn-phase still render
  live; steer/stop button state (`isAgentWorking`) correct.
- **Stage 3:** home list + tablet rail with many sessions while several stream →
  scrolling stays smooth, status dots/badges update within the debounce window,
  needs-you banner appears/clears correctly, order settles correctly after a
  burst, no row identity flicker.
- **Stage 4:** full sweep of every screen that read a content map (Approvals,
  Search, SessionInfo, Recap, DiffReview, FanOut, CommandPalette) — content
  still shows; no blank transcripts (#684) after reconnect.

Instrument each stage with `Telemetry.breadcrumb("perf", …)` at node create and
at list-order recompute so a device regression is self-diagnosing from Sentry.

---

## 7. Non-goals and rejected alternatives

- **One publisher per property on the monolith** (e.g. iOS `ObservableObject` +
  N `@Published` dictionaries, or splitting each dictionary into its own tiny
  observable). Rejected: still one node per *field*, not per *(session, field)* —
  the fan-out is unchanged. The whole point is per-session identity.
- **TCA / Redux-style store rewrite.** Rejected: a total re-architecture of a
  7000-line store + every view, un-reviewable on a CI-compile-only platform, for
  a problem that per-session observation solves surgically. Violates Simplicity
  First and Surgical Changes.
- **Move per-session state into the Rust core and observe from there.** Rejected:
  the core has no SwiftUI/Compose observation to offer; the FFI boundary would
  need a per-session change-notification channel we don't have, and #684/#680
  already exist *because* the core's maps are authoritative-but-not-sticky. This
  is more surface, not less.
- **Manual `objectWillChange`/hand-rolled diffing per row.** Rejected: fragile,
  exactly the drift Observation/StateFlow exist to remove; a missed notify is a
  silent stale-row bug.
- **Debounce-only (no node split).** Rejected as a *fix*: debouncing the list
  order (§2.3) is necessary but insufficient — the chat screen and each row still
  fan out per token. Debounce is a component of the design, not a substitute.
- **Making `store.nodes` observed and iterating it in the list body.** Rejected:
  that re-creates a global dependency (any node add/remove or any read of the
  dict invalidates the list). Membership must flow through `sessions` /
  `orderedSessionIDs`, and node content must be read only through a captured node
  reference.

---

## 8. File-by-file map (for the implementing PRs)

| Stage | File | Change |
|-------|------|--------|
| 1 | `apps/ios/Sources/SessionStore.swift` | Add `SessionNode`; `nodes` registry + `node(id)`; reroute `ingest*` (`:5107-5981`), demo seeding (`:922-945`); add read shims. Move `sessionLifecycle`/pagination/`hydratedChat`/`answeredPendingBySession` into the node. |
| 1 | `apps/android/.../SessionStore.kt` | Add `SessionNode` + `ConcurrentHashMap` nodes; reroute writers (`:554-976` region); maintained-aggregate facades for `statusBySession`/`conversationLog`/… |
| 1 | `apps/ios/Tests/.../SessionStore*Tests`, `apps/android/.../*Test` | Node-scoped ingest assertions; #865/#866 edge tests. |
| 2 | `apps/ios/Sources/ConduitUI/Views/ConduitChatView.swift` | `:349-516` read from `node`; keep `transcriptFingerprint`. |
| 2 | `apps/android/.../ui/ChatPage.kt` | `:398-414` collect node flows. |
| 3 | `apps/ios/Sources/ConduitUI/Views/ConduitHomeView.swift` | `:458-793,1025-1223` — row VM takes `SessionNode`; parent binds `orderedSessionIDs`. |
| 3 | `apps/ios/Sources/ConduitUI/Views/ConduitSessionsRail.swift`, `ConduitTabletHome.swift` | per-node rows. |
| 3 | `apps/ios/Sources/SessionStore.swift` | Add `HomeOrderPublisher` (`orderedSessionIDs`) + `needsYouSessionIDs`, debounced off node `lastActivity`/`conversation`. |
| 3 | `apps/android/.../ui/{NeonTabletHome,NeonTabletRail,ProjectListScreen}.kt` | ordered-id list + per-node collect. |
| 4 | both stores + straggler screens (`Approvals`, `Search`, `SessionInfo`, `Recap`, `DiffReview`, `FanOut`, `CommandPalette`) | delete shims/facades; migrate stragglers. |

Keep `apps/ios/Sources/ConduitUI/Models/ConduitHomeViewModel.swift` and
`ConduitChatViewModel.swift` (the pure helpers) as the per-row/per-node
computation and their tests — they are the safety net that survives the whole
migration.

---

## 9. References (code anchors)

- `apps/ios/Sources/SessionStore.swift`: class `:903`; per-session dicts
  `:1020-1196`; `ingestStatus` `:5632` (prior-turnActive `:5636`, idle-flush
  `:5652`, streaming-clear `:5675`); `ingestChat` `:5162` (clear `:5205`);
  `ingestChatStreaming` `:5130`; `ingestTurnPhase` `:5147`;
  `ingestThinkingStreaming` `:5155`; `ingestConnectionHealth` `:5981`;
  `ingestDisconnected` `:5913`/`:5969`; `flushQueued*` `:4266`/`:4286`;
  `isConfirmedLive` `:6384`; `hasPendingAsk` `:3943`; `clientGeneration` `:1248`;
  `StoreDelegate.isCurrent` `:7351`; demo `:922-945`; reconcile `:5000-5077`.
- `apps/ios/Sources/ConduitUI/Views/ConduitHomeView.swift`: `snapshot` `:458`;
  `latestActivityPreview` `:561`; `HomeRowView` `:1025`.
- `apps/ios/Sources/ConduitUI/Views/ConduitChatView.swift`: `transcript` `:349`;
  `isAgentWorking` `:481`; per-session reads `:494-516`.
- `apps/ios/Sources/ConduitUI/Models/ConduitHomeViewModel.swift`: `rows` `:224`,
  `sortedSessions` `:282`.
- `apps/android/.../SessionStore.kt`: flow bank `:594-682`; hydratedChat `:704`;
  demo `:554-569`; conversation writes `:865,976`.
- `apps/android/.../ui/ChatPage.kt` `:398-414`; `NeonTabletHome.kt` `:78`;
  `NeonTabletRail.kt` `:72`; `ProjectListScreen.kt` `:51`.
