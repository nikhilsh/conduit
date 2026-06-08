import SwiftUI

@main
struct ConduitApp: App {
    @State private var store = SessionStore()
    @State private var appearance = AppearanceStore()

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
                        ConduitApprovalBridge.handler = { sessionID in
                            await Self.approvePendingInput(
                                store: store, controller: liveActivity, sessionID: sessionID
                            )
                        }
                    }
                    .onOpenURL { url in
                        if !applySessionURL(url) {
                            applyPairingURL(url)
                        }
                    }
                    .onChange(of: scenePhase) { _, _ in
                        // Foreground, background, inactive — any wake is
                        // execution time; re-stamp the live activities.
                        liveActivity.refreshAll()
                    }
                    .sheet(item: hostKeyBinding) { prompt in
                        HostKeyPromptSheet(prompt: prompt) { accepted in
                            store.resolveHostKeyPrompt(accept: accepted)
                        }
                        .presentationDetents([.medium])
                    }
                    .sheet(item: agentPickBinding) { pick in
                        ConduitUI.AgentPickerSheet(headerNote: pick.hostNote)
                            .environment(store)
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

    private var hostKeyBinding: Binding<HostKeyPrompt?> {
        Binding(
            get: { store.pendingHostKey },
            set: { next in
                // SwiftUI may set this to nil if the user swipes the sheet
                // away — treat that as a rejection so the bridge unblocks.
                if next == nil, store.pendingHostKey != nil {
                    store.resolveHostKeyPrompt(accept: false)
                }
            }
        )
    }

    /// Approve the latest pending-input card of a session from the lock
    /// screen (round-3 §2 follow-up). Mirrors the in-app card: the reply
    /// is the FIRST option's text (option 1 is the affirmative by
    /// convention — same numbering the card shows). Runs headless via
    /// `ApproveSessionIntent`, possibly in a cold background launch, so
    /// it bounded-waits for the transport before sending.
    @MainActor
    static func approvePendingInput(
        store: SessionStore,
        controller: TurnLiveActivityController,
        sessionID: String
    ) async {
        Telemetry.breadcrumb("live_activity", "approve intent", data: ["session": sessionID])
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
                "live_activity", "approve failed: no transport",
                data: ["session": sessionID, "state": store.harness.badgeLabel]
            )
            return
        }
        let pending = (store.conversationLog[sessionID] ?? [])
            .last(where: { $0.kind == "pending_input" })
        let reply = pending?.pendingOptions.first ?? "yes"
        store.sendChat(sessionID: sessionID, message: reply)
        Telemetry.breadcrumb(
            "live_activity", "approve sent",
            data: ["session": sessionID, "reply": reply]
        )
        // Re-stamp the card; the status flips to running once the
        // agent's next item flows through the normal pipeline.
        controller.refreshAll()
    }

    /// Handle the Live Activity's `conduit://session/<id>[?action=…]`
    /// deep links (round-3 §2). Returns false when the URL isn't a
    /// session link so the pairing path can have a look.
    ///
    /// Actions:
    ///   - `refresh` — the stale card's "Tap to refresh": opening the app
    ///     IS the refresh (execution time → `refreshAll()` re-stamps).
    ///   - `reply` / `diff` — focus the session so the user lands on the
    ///     pending-input card to PICK the answer (a question is usually
    ///     multiple-choice, not a yes/no, so the lock screen can't answer
    ///     it in place) / can open the diff from there.
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
        store.endpoint = next
        store.upsertSavedServer(name: next.displayHost, endpoint: next, makeDefault: true)
        store.disconnect()
        store.connect()
        // After dialling in, drop the user straight onto the agent
        // picker so a deep-link tap is a single user motion: tap →
        // (paired) → pick Claude/Codex → in.
        store.pendingAgentPick = PendingAgentPick(hostNote: next.displayHost)
    }
}
