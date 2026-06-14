# PLAN — Push-to-Start Live Activity (G1)

**Goal (G1):** Start the Turn Live Activity from a remote push when the iOS app
is backgrounded/closed, so an approval/choice request that arrives while the app
is not foregrounded surfaces a lock-screen card. Today `Activity.request` is
hard-guarded to the foreground (`applicationState == .active`,
`TurnLiveActivityController.swift:223`) because the background call throws
`ActivityAuthorizationError.visibility` (Code 7). Update/end already work via
push (per-activity update token). We add ActivityKit **push-to-start**
(iOS 17.2+).

This is DESIGN ONLY. Three executors (broker-engineer, app-engineer, relay
change) should each be able to run their section without re-discovering wiring.

---

## 0. Ground truth (verified against `origin/main` @ a5ee1268)

What already exists (do NOT rebuild it):

- **Per-activity UPDATE/END push works.** `Activity.request(..., pushType:
  .token)` is already used (controller:242). The resulting
  `activity.pushTokenUpdates` are POSTed to `POST /api/push/register` with
  `platform:"apns-liveactivity"` + `session_id`
  (`PushNotificationManager.registerLAToken`, :296). Broker stores them in an
  **in-memory** `push.LARegistry` keyed by `(identity, session_id)`
  (`push.go:81`), and `emitLAUpdateImmediate` (`push_notify.go:340`) sends
  `event:"update"|"end"` via the relay.
- **Relay LA path works.** `relay/src/apns.ts buildBody` (:56) emits
  `aps.{timestamp,event,content-state}`; topic
  `sh.nikhil.conduit.push-type.liveactivity`; `apns-push-type: liveactivity`;
  `apns-priority: 5` (:101,107,114). The relay forwards `content_state`
  verbatim. `relayInner` (`relay.go:55`) carries `Event` + `ContentState`.
- **Content-state is already push-decodable.** `TurnActivityAttributes`
  (`TurnActivityAttributes.swift:21`) is the ActivityKit attributes type; its
  `ContentState` Codable uses epoch-millis Int keys `startedAtMs`/`syncedAtMs`
  exactly matching the broker's `cs` map (`push_notify.go:357`). **The
  attributes themselves (`agentName`, `sessionID`, `sessionName`) currently have
  NO custom Codable** — push-to-start will require them to decode from APNs JSON
  (see §1.4).
- **Device-global alert token registration works.** `AppDelegate
  didRegisterForRemoteNotificationsWithDeviceToken` → `PushNotificationManager
  didRegisterDeviceToken` → fan-out `POST /api/push/register`
  `{platform:"apns", token}` to all endpoints (`PushNotificationManager.swift:382`).
  This is the device APNs token, NOT the push-to-start token. The
  push-to-start token is a SEPARATE ActivityKit token (see §1.1).

The single missing seam: **there is no push-to-start token, and the broker's LA
emit only fires when a per-(identity,session) UPDATE token already exists**
(`emitLAUpdateImmediate` returns early if `reg.GetLA(...) == ""`,
`push_notify.go:349-353`). A backgrounded approval has no update token (the app
never foregrounded to call `Activity.request`), so today nothing is sent — the
exact gap G1 closes.

### Deployment-target facts

- Host app `deploymentTarget iOS "26.0"` (`project.yml:6`). Push-to-start needs
  17.2; **17.2+ is therefore universally satisfied** — no `#available` runtime
  guard is needed on the host for the API itself, but the `<17.2` fallback path
  in §4.3 is moot for this app. Still keep the `if #available(iOS 17.2, *)`
  compile guard (defensive + documents intent; the compiler requires it for
  `pushToStartTokenUpdates`).
- Widget extension target `deploymentTarget "17.0"` (`project.yml:214`) — only
  compiles the attributes/intents; not the push-to-start observer. No change.
- Bundle id `sh.nikhil.conduit` (`project.yml:187`); LA topic
  `sh.nikhil.conduit.push-type.liveactivity` (already built in apns.ts:101).
- `aps-environment: production` in `Sources/Conduit.entitlements`
  (`project.yml:195`); relay defaults `env:"production"` (index.ts:76). Matches.

### Contradictions / corrections to the task brief

1. The brief says `Activity.request` is "~line 219/236" — confirmed at 223
   (guard) / 236 (request). Correct.
2. The brief implies start-token plumbing should mirror the **device** APNs
   token registration. **It must NOT** — push-to-start tokens are minted by
   ActivityKit (`Activity<Attrs>.pushToStartTokenUpdates`), are
   attributes-TYPE-scoped (one per Activity type per device), and are distinct
   from both the device APNs token and the per-activity update token. Plumb via
   a NEW broker endpoint (§2.1), not the device-token path.
3. `NSSupportsLiveActivitiesFrequentUpdates` is genuinely absent
   (`project.yml`). Add it (§1.5) — without it Apple aggressively throttles
   priority-5 LA pushes; a start push that lands minutes late defeats the
   feature.

---

## 1. iOS app

### 1.1 Obtain the push-to-start token

`Activity<TurnActivityAttributes>.pushToStartTokenUpdates` is an `AsyncSequence<Data>`
(iOS 17.2+). Each emitted `Data` is the push-to-start token; hex-encode with the
existing `Data.apnsTokenHex` (`PushNotificationManager.swift:428`).

**Where to observe:** app launch, once, for the app's lifetime — NOT per session
(the token is attributes-type-scoped, not session-scoped). Add a
`startObservingPushToStartToken()` to `TurnLiveActivityController` and call it
from `ConduitApp` init / `AppDelegate didFinishLaunchingWithOptions` (same place
the bridge is started). Guard `if #available(iOS 17.2, *)`.

```
// TurnLiveActivityController (new method)
func startObservingPushToStartToken() {
  #if canImport(ActivityKit)
  guard #available(iOS 17.2, *) else { return }
  guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
  pushToStartTask?.cancel()
  pushToStartTask = Task { @MainActor in
    for await tokenData in Activity<TurnActivityAttributes>.pushToStartTokenUpdates {
      let hex = tokenData.apnsTokenHex
      Telemetry.breadcrumb("push_la", "push-to-start token received",
        data: ["hexLen": "\(hex.count)"])
      lastPushToStartTokenHex = hex
      registerPushToStartToken(hex: hex)  // §1.3
    }
  }
  #endif
}
```

Store `lastPushToStartTokenHex` + `pushToStartTask: Task<Void, Never>?` on the
controller. The sequence yields immediately on first launch (if activities are
enabled) and again on every OS rotation.

### 1.2 Authorization timing

`pushToStartTokenUpdates` only yields once Live Activities are enabled
(`areActivitiesEnabled`). It does NOT require notification authorization — but it
DOES require the app to have called `UIApplication.registerForRemoteNotifications`
at least once so APNs is live, which the existing push flow already does after
the first session (`requestAuthorizationIfNeeded`, :98). Start the observer
unconditionally at launch; it idles harmlessly until activities are enabled and
re-yields when they become enabled.

### 1.3 Register the start token with the broker — NEW endpoint (recommended)

**Decision: add a dedicated endpoint, do not overload `/api/push/register`.**
Rationale (the conduit invariant: a wrong abstraction here is silent — a start
token misrouted into the session-scoped LARegistry would never fire and we'd
never know): the push-to-start token is **device-scoped, not session-scoped**.
`/api/push/register` with `apns-liveactivity` REQUIRES a `session_id`
(`api.go:449-451`) and stores per `(identity, session_id)`. Push-to-start has no
session yet (that's the point). Forcing a sentinel session_id pollutes the
update-token registry and risks an update emit picking the start token.

New endpoint, mirroring the existing handler's shape and auth:

```
POST /api/push/register-start
Authorization: Bearer <token>
{ "platform": "apns-liveactivity-start", "token": "<hex>" }
→ 200 { "registered": true }
```

`PushNotificationManager` gains `registerPushToStartToken(hex:)` that fans out to
**all** complete endpoints (same fan-out shape as `registerWithAllServers`,
:345 — each box needs the token so whichever box owns the pending session can
start the LA). Store the active-endpoint result for the Settings honest-state
row if desired (optional; not required for G1).

Re-register triggers (all already have hooks):
- on token rotation (the `for await` loop re-fires),
- on endpoint/box change — extend `endpointChanged` (:165) to also re-POST
  `lastPushToStartTokenHex` to the new endpoint set,
- on box add — same path the device token uses.

### 1.4 Make `TurnActivityAttributes` push-decodable

For `event:"start"`, APNs delivers `aps.attributes` as JSON that ActivityKit
decodes into `TurnActivityAttributes` (the static attributes). The broker will
send `{ "agentName", "sessionID", "sessionName" }` (§2.3). The struct's
synthesized `Codable` already uses those exact property names, so **no custom
CodingKeys are strictly required** — but pin the contract explicitly:
add a brief doc comment to `TurnActivityAttributes` (:134) stating these three
keys are the push-to-start `attributes` wire contract and MUST stay in sync with
`emitLAStart` in the broker. (No code change beyond the comment unless a key is
renamed.) The `ContentState` Codable is already push-ready (§0).

### 1.5 Entitlement / Info.plist additions

In `project.yml` under the host app `info.properties` (next to
`NSSupportsLiveActivities: true`, :183):

```
NSSupportsLiveActivitiesFrequentUpdates: true
```

No new entitlements file change: push-to-start rides the existing
`aps-environment: production` APNs entitlement. The LA push topic
(`.push-type.liveactivity`) is derived by APNs from the bundle id; no separate
capability. (Human step already done for normal push — confirm in the Apple
Developer portal that the App ID has Push Notifications enabled; it does, since
update/end pushes work on device.)

### 1.6 Reconcile an OS-started activity on foreground (dedup — critical)

When the OS starts the activity from a push and the user later foregrounds, the
app must ADOPT that activity rather than start a second one or orphan it.

Two existing mechanisms collide and must be reconciled:

1. `reapOrphanActivities()` (:340) ends EVERY system activity not in
   `activeActivityIDs`. After a push-start the app relaunches with an empty
   `activeActivityIDs`, so the push-started card would be **reaped on launch** —
   a regression we must prevent.
2. The bridge's `evaluate()` re-derives state from the store and may emit
   `.start`, which `startActivity` (:200) would turn into a SECOND
   `Activity.request` — a duplicate card.

**Adoption step — add `adoptPushStartedActivities()`** called at launch BEFORE
`reapOrphanActivities()` and on `pushToStartTokenUpdates` startup:

```
func adoptPushStartedActivities() {
  guard #available(iOS 17.2, *) else { return }
  for activity in Activity<TurnActivityAttributes>.activities {
    let sid = activity.attributes.sessionID
    // Adopt: register the id so reap won't kill it and update routes to it.
    if activeActivityIDs[sid] == nil {
      activeActivityIDs[sid] = activity.id
      seedModelFromActivity(activity)   // mark model active so bridge won't re-.start
      observeUpdateToken(for: activity, sessionID: sid) // §1.7
      Telemetry.breadcrumb("push_la", "adopted push-started activity",
        data: ["session": sid, "activityID": activity.id])
    }
  }
}
```

`seedModelFromActivity` sets `models[sid]` to an active model whose
`contentState` mirrors the activity's current `content.state` and whose
`attributes` are set, so `TurnActivityModel.apply` takes the UPDATE branch (it
checks `isActive`, :236) instead of `.start`. This is the dedup invariant:
**`activeActivityIDs[sid] != nil` ⟺ a card exists for that session, regardless
of who started it.** Reap (:342) already keys off `activeActivityIDs.values`, so
adoption automatically protects the push-started card.

Sequencing at launch: `adoptPushStartedActivities()` → `reapOrphanActivities()`
→ `bridge.start()`.

### 1.7 Observe the update token for an adopted activity

A push-STARTED activity still needs its UPDATE token registered so the broker can
push `update`/`end` to it (otherwise the card freezes after start). On adoption,
iterate `activity.pushTokenUpdates` (same loop as the foreground start path,
:251-265) and POST via the existing `registerLAToken` (`platform:
"apns-liveactivity"`, session-scoped). This reuses the entire existing
update/end path — no new broker work for updates after a push-start.

**This is the clean seam:** push-to-start only handles the FIRST frame (the
start). Everything after (tool changes, the actual approve/deny resolution that
ends the card) flows through the already-shipped update/end path.

### 1.8 iOS files touched

- `apps/ios/Sources/Models/TurnLiveActivityController.swift` — observer, adopt,
  seed, start-token registration call.
- `apps/ios/Sources/Models/PushNotificationManager.swift` —
  `registerPushToStartToken(hex:)` + `endpointChanged` extension.
- `apps/ios/Sources/Models/TurnActivityAttributes.swift` — doc comment pinning
  the attributes wire keys (no logic change).
- `apps/ios/project.yml` — `NSSupportsLiveActivitiesFrequentUpdates: true`.
- `apps/ios/Sources/ConduitApp.swift` / `AppDelegate.swift` — call
  `startObservingPushToStartToken()` + `adoptPushStartedActivities()` at launch.

---

## 2. Broker

### 2.1 Store the push-to-start token (device-scoped, persisted)

The existing `LARegistry` is in-memory and `(identity, session_id)`-keyed — wrong
shape twice over (push-to-start is session-LESS and must survive a broker
restart, because a backgrounded approval may need a start push minutes/hours
after the last broker bounce).

**Add a push-to-start token store.** Two viable shapes; recommend the minimal
one:

- **Recommended:** store ONE push-to-start token per identity on the existing
  persisted alert `Registry` as a new platform `apns-liveactivity-start`
  (`push.go:28` add the const + `ValidPlatform`). It already persists to disk
  (`NewRegistryWithPersistence`, :152) and is identity-keyed. A new
  `DeviceToken{Platform: "apns-liveactivity-start", Token: hex}` rides the same
  store; retrieve via `TokensFor(identity)` filtered by platform, or add a thin
  `StartTokenFor(identity) string` helper. This gets persistence for free and
  keeps the registry count at one extra token per device.
  - Invariant protected: **the start token outlives a broker restart**, so a
    pending approval after a redeploy still raises a card.

- Alternative (more code, no benefit): a parallel persisted `LAStartRegistry`.
  Reject — duplicates the persistence machinery for one token.

New handler `POST /api/push/register-start` (`api.go`, mirror `servePushRegister`
:426): require auth, accept `{platform:"apns-liveactivity-start", token}`,
`s.Push.Register(pushIdentity, DeviceToken{...})`. Reject empty token. If
`s.Push == nil` return 200 (forward-compat with old clients, same as the LA
no-registry branch :454). Register the route in `server.go` next to
`/api/push/register` (:242).

### 2.2 The rule for emitting `event:"start"` (dedup / known-running)

Emit a start push when **a turn first needs the LA AND no card is known to be
running for this session.** "Known running" = a per-(identity,session) UPDATE
token exists in the `LARegistry` (`reg.GetLA(identity, sid) != ""`). That token
is registered ONLY after a card exists (foreground `Activity.request` OR an
adopted push-started activity registers its update token, §1.7). So:

Refactor `emitLAUpdateImmediate` (`push_notify.go:340`). Today it early-returns
when `GetLA == ""`. New logic:

```
updateToken := reg.GetLA(identity, sid)
if updateToken != "" {
    // existing path: send update/end to the live card
    sendLAUpdate(event, updateToken, contentState)
    return
}
// No live card. Only START is meaningful here.
if event == "end" { return }   // nothing to end
startToken := reg.StartTokenFor(identity)   // §2.1
if startToken == "" { return }              // device has no push-to-start token
if s.SubscriberCount() > 0 { return }       // app is attached/foreground — it will
                                            // call Activity.request itself; do NOT
                                            // double (the foreground/start contract)
emitLAStart(startToken, attributes, contentState)   // §2.3
```

**Dedup state, made explicit:**
- `GetLA != ""` ⟹ card exists ⟹ never start, only update/end.
- `GetLA == "" && SubscriberCount > 0` ⟹ app is foreground/attached ⟹ it owns
  the start via `Activity.request`; broker stays silent. (Matches the iOS
  foreground guard at controller:223 — exactly one party starts the card.)
- `GetLA == "" && SubscriberCount == 0 && startToken != ""` ⟹ backgrounded, no
  card ⟹ **emit start**. This is the new path G1 adds.
- After a start push, the iOS app adopts the activity (§1.6) and registers its
  update token, so the next `emitLAUpdateImmediate` sees `GetLA != ""` and flows
  through the normal update path. No "did I already start?" latch is needed —
  the update-token presence IS the latch. (Edge: a second start-needing event
  in the ~1-2s before the device registers its update token could double-start.
  Guard with a short per-session `lastLAStart` debounce latch in `laPushState`,
  same pattern as `lastLA` :329 / `idlePushWindow` :38. One debounce field, one
  check.)

**Which events trigger a start?** The pending-input path
(`notifyLAPendingInput`/`maybeNotifyPendingInput`, :102/272) — an approval/choice
arriving while backgrounded is the headline use case. Also the
tool/command-running path (`SetLACurrentTool`/`SetLACurrentCommand`) so a
long-running backgrounded turn raises a card. Both already funnel through
`emitLAUpdateImmediate`, so the refactor above covers all of them with no
new call sites. Apply the `maxStartAge` spirit (iOS model :193, 10 min): the
broker need not replicate it because the broker only emits on LIVE transitions,
not on history replay — but note it so a future replay path doesn't start stale
cards.

### 2.3 The start payload (what the broker hands the relay)

`emitLAStart` builds the same `content_state` map as today (`cs`,
:357-404) PLUS the start-only fields. Extend `push.Payload` (`push.go:59`) and
`relayInner` (`relay.go:55`) with:

```
AttributesType string         // "TurnActivityAttributes"
Attributes     map[string]any // { agentName, sessionID, sessionName }
Alert          map[string]any // { title, body } — REQUIRED by APNs for start
```

Payload for a start:
```
push.Payload{
  Title: displayName, Body: "Needs your input" (or "Turn in progress"),
  SessionID: s.ID,
  Category: "liveactivity",
  Event:    "start",
  AttributesType: "TurnActivityAttributes",
  Attributes: { "agentName": assistant, "sessionID": s.ID, "sessionName": displayName },
  ContentState: cs,   // same shape as update
  Alert: { "title": displayName, "body": <pending prompt or "is working"> },
}
```

`AttributesType` MUST equal the iOS type name `TurnActivityAttributes`
(`TurnActivityAttributes.swift:21`) — Apple uses it to route the start to the
right Activity type. `Attributes` keys MUST equal the struct's stored-property
names (`agentName`, `sessionID`, `sessionName`, §1.4). These two are the silent
footguns: a typo means the OS rejects the start with no client-visible error.
Pin both in a shared comment referencing this doc.

### 2.4 Difference from the update/end path

| | update/end (exists) | start (new) |
|---|---|---|
| token source | `LARegistry.GetLA(id,sid)` | `Registry.StartTokenFor(id)` |
| token scope | per (identity, session) | per identity (device) |
| event | `update` / `end` | `start` |
| extra fields | none | `attributes-type`, `attributes`, `alert` |
| gating | always (LA tracks even if attached) | only when `GetLA==""` AND `SubscriberCount==0` |
| persistence need | no (re-registered each turn) | YES (survive restart) |

### 2.5 Broker files touched

- `broker/internal/push/push.go` — `PlatformAPNsLiveActivityStart` const +
  `ValidPlatform`; `Payload` adds `AttributesType`/`Attributes`/`Alert`;
  optional `StartTokenFor` helper.
- `broker/internal/push/relay.go` — `relayInner` adds the three fields
  (omitempty), pass-through in `Send`.
- `broker/internal/session/push_notify.go` — refactor
  `emitLAUpdateImmediate` to branch start-vs-update; add `emitLAStart`; add
  `lastLAStart` debounce field to `laPushState`.
- `broker/internal/ws/api.go` — `servePushRegisterStart` handler.
- `broker/internal/ws/server.go` — register `/api/push/register-start` route.
- Tests: extend `push_notify_test.go` (start emitted only when no update token +
  no subscribers), `push_test.go` (new platform valid + persisted),
  `push_api_test.go` (register-start handler).

Backend-abstraction discipline: the session package change touches only its own
files; the push package is the shared seam (intended); ws gains one handler +
one route. Acceptable.

---

## 3. Relay

`buildBody` (`apns.ts:56`) currently only handles `update`/`end`. Add the
`start` branch.

```
if (isLiveActivity) {
  const event = payload.event ?? "update";
  const contentState = payload.content_state ?? { ... };
  if (event === "start") {
    return JSON.stringify({
      aps: {
        timestamp: Math.floor(Date.now() / 1000),
        event: "start",
        "content-state": contentState,
        "attributes-type": payload.attributes_type,   // "TurnActivityAttributes"
        attributes: payload.attributes,                // { agentName, sessionID, sessionName }
        alert: payload.alert ?? { title: payload.title, body: payload.body },
      },
      session_id: payload.session_id,
      box: payload.box,
    });
  }
  // existing update/end branch unchanged
  return JSON.stringify({ aps: { timestamp, event, "content-state": contentState },
                          session_id, box });
}
```

Request headers (`sendApns`, :91-119) are **already correct for start**:
- `apns-push-type: liveactivity` (:114) ✓
- `apns-topic: sh.nikhil.conduit.push-type.liveactivity` (:101) ✓ (start uses
  the SAME topic as update — confirmed by Apple's spec)
- `apns-priority`: **start should be `10`**, not 5. Update/end stay 5
  (throttle-friendly), but the START is a user-facing alert-equivalent and must
  land immediately. Change `apnsPriority` to `event === "start" ? "10" : "5"`.
  The header is set in `sendApns`, so thread `payload.event` into the priority
  decision there (it's already on `payload`). No `apns-collapse-id` needed for
  start; omit.

Type + validation changes:
- `relay/src/types.ts PushPayload` (:4): add `event?: "update"|"end"|"start"`;
  add `attributes_type?: string`; `attributes?: Record<string, unknown>`;
  `alert?: { title: string; body: string }`.
- `relay/src/index.ts validPayload` (:40): allow `event === "start"`; light
  type-checks on the new optional fields (object/string).

Broker→relay field names: the broker sends snake_case in `relayInner`
(`content_state`). Match: `attributes_type`, `attributes`, `alert`. Add the
corresponding `json:"attributes_type,omitempty"` tags in `relay.go`.

Diff vs current `buildBody`: current emits `{aps:{timestamp,event,content-state},
session_id,box}` for ALL LA events. New: for `event==="start"`, ADD
`attributes-type`, `attributes`, `alert` inside `aps`. Update/end unchanged.

Relay files touched: `relay/src/apns.ts`, `relay/src/types.ts`,
`relay/src/index.ts` (+ tests: assert the start body shape + priority 10 +
topic).

---

## 4. Lifecycle & failure modes

### 4.1 Token rotation
`pushToStartTokenUpdates` re-yields on rotation; the `for await` loop re-POSTs
to `/api/push/register-start`, overwriting the per-identity start token. The
alert `Registry` keys on `key(t)` = platform+token (`push.go:251`), so a rotated
token ADDS a second entry — the stale one lingers. **Reap on send failure:**
when the relay returns 410/`ErrTokenGone` for a start push, `Unregister` the
stale start token (same as alert tokens). Document this; otherwise stale start
tokens accumulate. (For a single-token-per-platform shape, prefer a
`SetStartToken` that replaces rather than adds — cleaner than reap-on-410.)

### 4.2 Stale tokens
A 410 on a start push ⟹ broker drops the start token ⟹ no further start pushes
until the app re-registers (next launch yields a fresh token). Acceptable —
matches alert-token behavior.

### 4.3 Push-to-start unsupported (<17.2)
N/A for this app (min target 26.0). The `if #available(iOS 17.2, *)` guard
short-circuits the observer; with no start token registered, the broker's
`StartTokenFor` returns "" and `emitLAStart` no-ops — the app silently falls back
to **today's foreground-only behavior**. No crash, no error path. (Kept for
defensiveness / future min-target drops.)

### 4.4 Dedup between push-started and foreground-started
The single invariant (§1.6, §2.2): **at most one card per session**, enforced on
BOTH sides:
- Broker: never start if a per-session update token exists OR a subscriber is
  attached.
- iOS: never `Activity.request` if `activeActivityIDs[sid] != nil`
  (`startActivity` :209 already ends a prior one first); adoption seeds that map
  from OS-running activities before the bridge can emit `.start`.
- Race: app foregrounds at the same instant the broker emits a start. Window is
  small; outcomes: (a) broker start lands first → app adopts on foreground, no
  dup. (b) app starts first, registers update token → broker's next emit sees
  `GetLA!=""`, won't start. (c) both fire in the gap → two cards briefly; the
  app's `adoptPushStartedActivities` + `reapOrphanActivities` on the NEXT
  foreground/refresh collapses to one (reap ends the un-owned one). The
  `lastLAStart` debounce (§2.2) bounds broker-side double-starts.

### 4.5 Approve/deny resolution still ends the pushed card
The existing approve/deny path is unchanged: the `ApproveSessionIntent` /
lock-screen action posts to `/api/session/approval` (AppDelegate:218); the agent
unblocks, the turn ends, `maybeNotifyTurnEnd` → `notifyLATurnEnd` →
`emitLAUpdateImmediate("end")`. Because the app adopted the push-started activity
and registered its update token (§1.7), `GetLA != ""` ⟹ the END routes to the
live card and dismisses it. **Verify on device** that a push-STARTED (never
foregrounded) card still receives the end — this is the riskiest seam (if the
update-token registration on adoption fails, the card would freeze "pending"
forever; the 15-min `doneLingerInterval` does not apply because end never
arrives — instead the 9-min `staleInterval` only dims it). Mitigation: breadcrumb
the adoption update-token registration and capture an error if it never fires
within N seconds of adoption.

### 4.6 areActivitiesEnabled = false
User disabled Live Activities in Settings → `pushToStartTokenUpdates` yields
nothing → no start token → broker no-ops. Honest degradation.

---

## 5. Deploy + verify

### Deploy order (BOTH required; relay BEFORE broker)
Per the relay-category-deploy-order memory: the relay validates payloads and
will 400 an unknown shape. The new `event:"start"` + `attributes` fields fail
`validPayload` on the OLD relay. So:

1. **Relay first:** `gh workflow run relay-deploy` (CF token lives only in GH
   secrets) — deploy the `event:"start"` + attributes-aware relay.
2. **Broker next:** redeploy per `docs/BROKER-REDEPLOY.md` (atomic `mv` +
   `systemctl restart`, token pinned). Tagging does NOT deploy the broker.
3. **iOS:** ship a TestFlight/device build (CI-compile-only on the dev box;
   device verify only).

If broker ships before relay, start pushes 400 at the relay and silently fail
(broker logs `push relay: HTTP 400`); no crash, but the feature is dark until
the relay catches up.

### On-device verification steps (device-only; CI green ≠ behaves)
1. Fresh launch, Live Activities enabled, push authorized. Confirm Sentry
   breadcrumb `push_la "push-to-start token received"` and a 200 from
   `/api/push/register-start` (broker log `registered apns-liveactivity-start`).
2. Start a session, trigger an approval-requiring action (e.g. a tool the agent
   must ask to run), then **background or lock the device** before the ask
   arrives.
3. Confirm a lock-screen Live Activity APPEARS while backgrounded (the G1
   success criterion) showing the permission/choice card.
4. Tap **Approve** on the lock screen (background App Intent / action) → confirm
   the agent unblocks AND the card transitions to done/dismisses (verifies §4.5
   adopt+update-token end).
5. Foreground the app → confirm exactly ONE card (no duplicate), and that
   subsequent tool updates flow into the SAME card (verifies adoption + update
   token, §1.6/1.7).
6. Foreground-only regression: with the app in the FOREGROUND, trigger a turn →
   confirm the card still starts via `Activity.request` and the broker did NOT
   also push a start (no duplicate; verifies the §2.2 `SubscriberCount>0`
   contract).
7. Kill the app entirely, trigger a backgrounded approval → confirm the card
   still appears (push-to-start works app-not-running).
8. Rotate/reinstall to force a token change → confirm re-registration and that
   old token 410s are reaped (broker log).

### Pipeline docs
- Move the ROADMAP backlog item → IN-PROGRESS with branch + PR# when build
  starts; → VERIFY-CHECKLIST under its release on merge; → DONE only after the
  on-device steps above pass. Flag every iOS item "needs on-device
  verification."

---

## Summary of seams & the invariant each protects

- **New `/api/push/register-start` (device-scoped, persisted):** start tokens
  are session-less and must survive a broker restart. Keeps the
  session-scoped update registry uncontaminated (a misrouted start token is a
  SILENT failure).
- **`emitLAUpdateImmediate` start-vs-update branch keyed on update-token
  presence + subscriber count:** exactly one party starts the card (app when
  foreground, broker when backgrounded). The update-token IS the
  "already-running" latch — no separate flag to drift.
- **iOS adoption before reap:** `activeActivityIDs[sid] != nil ⟺ a card exists`,
  so reap never kills a push-started card and the bridge never double-starts.
- **`attributes-type` / `attributes` wire contract pinned on both sides:** a typo
  is rejected by the OS with no client error — the one truly silent failure mode,
  so it's documented in three places (iOS struct, broker payload, this doc).
