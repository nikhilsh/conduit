import SwiftUI

@main
struct ConduitApp: App {
    /// APNs token delivery + notification tap routing (Package WS-P.3).
    /// The `@UIApplicationDelegateAdaptor` bridges the UIKit delegate
    /// callbacks (didRegisterForRemoteNotificationsWithDeviceToken, etc.)
    /// into our SwiftUI lifecycle. We inject `store` into it once the
    /// App body has a live store reference.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @State private var store = SessionStore()
    @State private var appearance = AppearanceStore()
    /// App-wide feature flags + the chat-shell-v2 A/B assignment (handoff
    /// §2/§3). Injected so the new-session sheet and the chat shell read the
    /// same resolved state, and the Debug/Labs surfaces can mutate it.
    @State private var flags = FeatureFlags()

    // Streaming render plumbing (upstream audit A.5):
    //   - `StreamingRendererCoordinator.shared` is `@Observable`, so it's
    //     injected through `.environment(...)` below — that's what
    //     subscribes the SwiftUI view tree to per-id state changes.
    //   - `MessageRenderCache.shared` is *not* `@Observable` on purpose
    //     (the cache mutates on every render — making it Observable
    //     would invalidate the view tree on every cache hit). The view
    //     reads it directly as a singleton.
    // `SessionStore.streamingCoordinator` is wired on `onAppear` below
    // so `ingestChat` can drive render-state transitions on the same
    // instance the view tree observes.

    /// App-lifetime owner for `NWPathMonitor`. Posts
    /// `.networkBecameReachable` / `.networkInterfaceChanged` on
    /// transitions; SessionStore subscribes and asks the Rust core
    /// to drop+redial instead of waiting for the heartbeat timeout.
    @State private var reachability = NetworkReachabilityObserver()
    @State private var showSplash: Bool = true
    /// Bridges the store's typed conversation stream into ActivityKit's
    /// `TurnLiveActivity`. Initialized eagerly so the lock-screen card
    /// can fire on the first tool call of the very first session — even
    /// if the user backgrounds the app before opening the chat tab.
    /// The controller is functionally a no-op on the simulator (where
    /// `Activity.request` silently fails). The bridge keeps polling
    /// regardless so the *moment* a device or a registered widget
    /// target ships, the lifecycle is already correct.
    private let liveActivity = TurnLiveActivityController.shared
    /// Observer that drives `liveActivity` off the store's typed
    /// events. Wired up in `onAppear` so we have a live `store`
    /// reference; tear-down at app exit is implicit (App-scoped).
    @State private var liveActivityBridge: TurnLiveActivityBridge?
    /// Round-3 §2: every scene-phase transition is "a scrap of execution
    /// time" — used to re-stamp live activities (fresh `syncedAt` +
    /// `staleDate`) so the lock-screen card degrades honestly instead of
    /// presenting stale data as live.
    @Environment(\.scenePhase) private var scenePhase

    init() {
        Telemetry.configure()
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                ConduitUI.RootView()
                    .environment(store)
                    .environment(appearance)
                    .environment(flags)
                    .environment(StreamingRendererCoordinator.shared)
                    // Resolve + inject the Neon Terminal theme. The
                    // effective dark/light is `themeMode` resolved
                    // against the live \.colorScheme (System → follow
                    // OS), so the injected tokens stay in sync with the
                    // `.preferredColorScheme` override below. Lives in a
                    // small wrapper because `App` can't read
                    // \.colorScheme itself — only a View can.
                    .modifier(NeonThemeInjector(appearance: appearance))
                    .preferredColorScheme(appearance.themeMode.colorScheme)
                    .onAppear {
                        // Windows usually aren't connected when
                        // AppearanceStore.init runs, so reapply the
                        // persisted choice once SwiftUI has mounted.
                        appearance.applyToWindows()
                        // Hand the streaming coordinator to the store so
                        // its `ingestChat` path can drive render state
                        // transitions. Module-scope singleton so the
                        // coordinator's identity matches the one
                        // injected into the view tree above.
                        store.streamingCoordinator = StreamingRendererCoordinator.shared
                        // Stand up the Live Activity observer once we
                        // have a stable `store` reference. The bridge
                        // owns its own observation loop + idle timer
                        // — view-layer .onChange handlers would only
                        // see the *selected* session and miss tool
                        // calls in background tabs.
                        if liveActivityBridge == nil {
                            let bridge = TurnLiveActivityBridge(store: store, controller: liveActivity)
                            bridge.start()
                            liveActivityBridge = bridge
                            // Fresh launch: any lock-screen activity left
                            // over from the previous run is an orphan
                            // (this process holds no handle to it) — end
                            // them all before new turns request anew.
                            liveActivity.reapOrphanActivities()
                        }
                        // Lock-screen Approve (LiveActivityIntent) runs in
                        // this process; hand it the store-backed approval.
                        let store = store
                        let liveActivity = liveActivity
                        ConduitApprovalBridge.handler = { sessionID, decision in
                            await Self.respondPendingInput(
                                store: store, controller: liveActivity,
                                sessionID: sessionID, decision: decision
                            )
                        }
                        // WS-P.3: hand the live store reference to the
                        // AppDelegate so tap-routing can set selectedSessionID.
                        appDelegate.sessionStore = store
                        // Probe push capabilities once we have a connected
                        // endpoint. If the broker already has a token
                        // registered (app restart), settingsState reflects it.
                        Task { @MainActor in
                            await PushNotificationManager.shared.probeCapabilities(
                                endpoint: store.endpoint)
                        }
                        // Re-check push auth status in case the user changed
                        // it in Settings while the app was suspended.
                        PushNotificationManager.shared.refreshAuthStatus()
                    }
                    .onOpenURL { url in
                        if !applySessionURL(url) {
                            applyPairingURL(url)
                        }
                    }
                    .onChange(of: scenePhase) { _, newPhase in
                        // Foreground, background, inactive — any wake is
                        // execution time; re-stamp the live activities.
                        liveActivity.refreshAll()
                        // Re-check push auth status on every foreground — the
                        // user might have changed it in iOS Settings.
                        PushNotificationManager.shared.refreshAuthStatus()
                        // Prompt existing-session users who were never asked:
                        // the 0->1 session-count trigger fires only on first
                        // session creation; users who already had sessions at
                        // install / upgrade silently fell through with
                        // .notDetermined. On the FIRST .active foreground,
                        // request if we have >= 1 session and are still
                        // notDetermined. requestAuthorizationIfNeeded() is
                        // guarded — it no-ops if auth != .notDetermined, so
                        // this cannot re-show a prompt the user already acted on.
                        if newPhase == .active,
                           !store.sessions.isEmpty,
                           PushNotificationManager.shared.settingsState.auth == .notDetermined {
                            Telemetry.breadcrumb("push", "active with existing sessions — requesting authorization")
                            PushNotificationManager.shared.requestAuthorizationIfNeeded()
                        }
                    }
                    // WS-P.3: request push permission after the user's FIRST
                    // session exists — onboarding is accounts-free by design,
                    // so we never prompt there. The moment `sessions` goes from
                    // empty to non-empty is the right time: the user has
                    // demonstrated intent (they started a session) and a push
                    // from a future session would be useful to them immediately.
                    .onChange(of: store.sessions.count) { old, new in
                        if old == 0, new > 0 {
                            Telemetry.breadcrumb("push", "first session exists — requesting authorization")
                            PushNotificationManager.shared.requestAuthorizationIfNeeded()
                        }
                    }
                    // Re-register with ALL paired boxes when the active endpoint
                    // changes (box switch). The token may have rotated or a
                    // server may have lost its registration.
                    .onChange(of: store.endpoint) { _, newEndpoint in
                        let allEndpoints = store.savedServers.map { $0.endpoint }
                        PushNotificationManager.shared.endpointChanged(
                            to: newEndpoint,
                            allEndpoints: allEndpoints
                        )
                        Task { @MainActor in
                            await PushNotificationManager.shared.probeCapabilities(
                                endpoint: newEndpoint)
                        }
                    }
                    // Unregister push from any server that was removed from
                    // savedServers (best-effort: one Task per removed box).
                    .onChange(of: store.savedServers) { old, new in
                        let removed = old.filter { prev in
                            !new.contains(where: { $0.id == prev.id })
                        }
                        for server in removed {
                            PushNotificationManager.shared.unregisterFromServer(
                                endpoint: server.endpoint
                            )
                        }
                    }
                    .alert(
                        "Unknown SSH Host Key",
                        isPresented: hostKeyIsPresented,
                        presenting: store.pendingHostKey
                    ) { prompt in
                        Button("Trust & Connect") {
                            store.resolveHostKeyPrompt(accept: true)
                        }
                        Button("Cancel", role: .cancel) {
                            store.resolveHostKeyPrompt(accept: false)
                        }
                    } message: { prompt in
                        Text("\(prompt.host):\(prompt.port)\nFingerprint:\n\(prompt.fingerprint)\n\nTrust this host and continue connecting?")
                    }
                    .sheet(item: agentPickBinding) { pick in
                        ConduitUI.AgentPickerSheet(headerNote: pick.hostNote)
                            .environment(store)
                            .environment(flags)
                    }
                if showSplash {
                    AnimatedSplashView { showSplash = false }
                        .environment(store)
                        .environment(appearance)
                        .preferredColorScheme(appearance.themeMode.colorScheme)
                        .transition(.opacity)
                        .zIndex(1)
                }
            }
            .animation(
                .easeOut(duration: AnimatedSplashModel.crossFadeDuration),
                value: showSplash
            )
        }
    }

    /// Resolves `AppearanceStore` (neon palette + glow) and the
    /// effective dark/light into a `NeonTheme` and injects it via
    /// `\.neonTheme`. A `ViewModifier` (rather than inline in the App
    /// body) so it can read the live `\.colorScheme` — needed to resolve
    /// `themeMode == .system` to the OS appearance, matching how
    /// `.preferredColorScheme(themeMode.colorScheme)` drives the tree.
    private struct NeonThemeInjector: ViewModifier {
        let appearance: AppearanceStore
        @Environment(\.colorScheme) private var systemScheme

        func body(content: Content) -> some View {
            // Shared resolve rule (see `NeonTheme.resolve(appearance:
            // colorScheme:)`) so the app root and the per-sheet
            // `AppearanceColorSchemeModifier` stay in lockstep.
            let theme = NeonTheme.resolve(appearance: appearance, colorScheme: systemScheme)
            return content.neonTheme(theme)
        }
    }

    /// Auto-binding the `pendingAgentPick` to a sheet so SwiftUI clears
    /// the store flag when the user dismisses without picking.
    private var agentPickBinding: Binding<PendingAgentPick?> {
        Binding(
            get: { store.pendingAgentPick },
            set: { store.pendingAgentPick = $0 }
        )
    }

    /// Bool binding used by the host-key TOFU alert. The `set:` path fires
    /// when the user dismisses the alert without choosing a button (e.g. by
    /// swiping away) — treat that as a rejection so the bridge unblocks.
    private var hostKeyIsPresented: Binding<Bool> {
        Binding(
            get: { store.pendingHostKey != nil },
            set: { showing in
                if !showing, store.pendingHostKey != nil {
                    store.resolveHostKeyPrompt(accept: false)
                }
            }
        )
    }

    /// Answer a session's pending PERMISSION gate from the lock screen
    /// (handoff Part B). Headless via `ApproveSessionIntent` /
    /// `RejectSessionIntent` — possibly in a cold background launch — so it
    /// bounded-waits for the transport before sending. Only a binary
    /// permission gate routes here; an n-way choice opens the app instead.
    ///
    /// The reply text is picked from the pending item's `pendingOptions` to
    /// match what the in-app card would send: the affirmative option for
    /// Approve (option 1 by convention), the negative option for Reject
    /// (the first option whose text reads as a "no"), falling back to the
    /// literal "yes" / "no".
    @MainActor
    static func respondPendingInput(
        store: SessionStore,
        controller: TurnLiveActivityController,
        sessionID: String,
        decision: ConduitApprovalBridge.Decision
    ) async {
        Telemetry.breadcrumb(
            "live_activity", "permission intent",
            data: ["session": sessionID, "decision": decision.rawValue]
        )
        if !store.harness.canIssueCommands {
            // Cold/background launch: dial in first. Bounded so the
            // intent never hangs the system's intent runner.
            switch store.harness {
            case .disconnected, .failed: store.connect()
            default: break  // already connecting/reconnecting — just wait
            }
            for _ in 0..<16 where !store.harness.canIssueCommands {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        guard store.harness.canIssueCommands else {
            Telemetry.breadcrumb(
                "live_activity", "permission failed: no transport",
                data: ["session": sessionID, "state": store.harness.badgeLabel]
            )
            return
        }
        let pending = (store.conversationLog[sessionID] ?? [])
            .last(where: { $0.kind == "pending_input" })
        let options = pending?.pendingOptions ?? []
        let reply = Self.permissionReply(decision: decision, options: options)
        store.sendChat(sessionID: sessionID, message: reply)
        store.resolvePendingInput(sessionID: sessionID)
        Telemetry.breadcrumb(
            "live_activity", "permission sent",
            data: ["session": sessionID, "decision": decision.rawValue, "reply": reply]
        )
        // Re-stamp the card; the status flips to running once the
        // agent's next item flows through the normal pipeline.
        controller.refreshAll()
    }

    /// Map an Approve / Reject decision onto the pending item's options.
    /// Approve → the first option (the affirmative by convention).
    /// Reject  → the first option whose text reads as a negative; if none
    /// matches, the literal "no".
    static func permissionReply(
        decision: ConduitApprovalBridge.Decision, options: [String]
    ) -> String {
        switch decision {
        case .approve:
            return options.first ?? "yes"
        case .reject:
            let negatives = ["reject", "deny", "no", "skip", "cancel", "disallow"]
            if let match = options.first(where: { opt in
                let lower = opt.lowercased()
                return negatives.contains(where: { lower == $0 || lower.hasPrefix($0 + " ") })
            }) {
                return match
            }
            return "no"
        }
    }

    /// Handle the Live Activity's `conduit://session/<id>[?action=…]`
    /// deep links (round-3 §2). Returns false when the URL isn't a
    /// session link so the pairing path can have a look.
    ///
    /// Actions:
    ///   - `refresh` — the stale card's "Tap to refresh": opening the app
    ///     IS the refresh (execution time → `refreshAll()` re-stamps).
    ///   - `choose` — the choice card's "Open to choose": focus the session
    ///     so the user lands on the pending-input picker (an n-way question
    ///     needs real UI; the lock screen can't answer it in place).
    ///   - `reply` / `diff` — focus the session so the user lands on the
    ///     pending-input card to PICK the answer / open the diff from there.
    /// (A permission gate's Approve / Reject never deep-links — it runs in
    /// the background via `ApproveSessionIntent` / `RejectSessionIntent`.)
    private func applySessionURL(_ url: URL) -> Bool {
        guard url.scheme == "conduit", url.host == "session" else { return false }
        let sessionID = url.lastPathComponent
        guard !sessionID.isEmpty, sessionID != "session" else { return false }
        let action = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "action" })?.value
        Telemetry.breadcrumb(
            "live_activity", "deep link",
            data: ["session": sessionID, "action": action ?? "open"]
        )
        store.selectedSessionID = sessionID
        // Any wake is execution time — re-stamp the cards.
        liveActivity.refreshAll()
        return true
    }

    /// Handle a `conduit://host[:port]?token=…` deep link by re-pointing
    /// the SessionStore at the new endpoint, persisting it, and dialling.
    /// Registered scheme lives in `apps/ios/project.yml`'s
    /// CFBundleURLTypes block.
    private func applyPairingURL(_ url: URL) {
        guard let parsed = PairingURL.parse(url.absoluteString) else { return }
        let next = StoredEndpoint(url: parsed.endpoint, token: parsed.token)
        Telemetry.breadcrumb("onboarding", OnboardingStep.pairingSucceeded,
            data: ["transport": "deep_link", "host": next.displayHost])
        store.endpoint = next
        store.upsertSavedServer(name: next.displayHost, endpoint: next, makeDefault: true)
        store.disconnect()
        store.connect()
        // After dialling in, drop the user straight onto the agent
        // picker so a deep-link tap is a single user motion: tap ->
        // (paired) -> pick Claude/Codex -> in.
        store.pendingAgentPick = PendingAgentPick(hostNote: next.displayHost)
    }
}
