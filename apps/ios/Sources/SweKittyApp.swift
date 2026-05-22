import SwiftUI

@main
struct SweKittyApp: App {
    @State private var store = SessionStore()
    @State private var appearance = AppearanceStore()

    // Streaming render plumbing (litter audit A.5):
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
    /// The controller is functionally a no-op until the widget target
    /// lands in the follow-up PR; see TurnLiveActivityController for the
    /// scope split.
    private let liveActivity = TurnLiveActivityController.shared

    init() {
        Telemetry.configure()
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                RootView()
                    .environment(store)
                    .environment(appearance)
                    .environment(StreamingRendererCoordinator.shared)
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
                        // Drive an initial liveActivity ingest so any
                        // session already in-flight at launch gets a
                        // chance to surface on the lock screen.
                        feedActiveSessionToLiveActivity()
                    }
                    .onChange(of: store.selectedSessionID) { _, _ in
                        feedActiveSessionToLiveActivity()
                    }
                    .onChange(of: store.conversationLog) { _, _ in
                        feedActiveSessionToLiveActivity()
                    }
                    .onChange(of: store.sessionLifecycle) { _, _ in
                        feedActiveSessionToLiveActivity()
                    }
                    .onOpenURL { url in
                        applyPairingURL(url)
                    }
                    .sheet(item: hostKeyBinding) { prompt in
                        HostKeyPromptSheet(prompt: prompt) { accepted in
                            store.resolveHostKeyPrompt(accept: accepted)
                        }
                        .presentationDetents([.medium])
                    }
                    .sheet(item: agentPickBinding) { pick in
                        AgentPickerSheet(headerNote: pick.hostNote)
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

    /// Push the active session's latest tool/command frame into the Live
    /// Activity controller. The controller is responsible for deciding
    /// whether anything actually changes — this is a fire-and-forget
    /// signal from the view layer.
    @MainActor
    private func feedActiveSessionToLiveActivity() {
        guard let sessionID = store.selectedSessionID else { return }
        let session = store.sessions.first(where: { $0.id == sessionID })
        let agentName = session?.assistant
            ?? store.statusBySession[sessionID]?.assistant
            ?? "agent"
        let latest = TurnLiveActivityMapping.latestRelevantItem(
            from: store.conversationLog[sessionID] ?? []
        )
        let phase: String?
        switch store.sessionLifecycle[sessionID] {
        case .exited(let code): phase = "exited(\(code))"
        default: phase = store.statusBySession[sessionID]?.phase
        }
        liveActivity.ingest(
            sessionID: sessionID,
            agentName: agentName,
            latestItem: latest,
            sessionPhase: phase
        )
    }

    /// Handle a `swekitty://host[:port]?token=…` deep link by re-pointing
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
