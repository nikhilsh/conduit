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
    /// The controller is functionally a no-op on the simulator (where
    /// `Activity.request` silently fails). The bridge keeps polling
    /// regardless so the *moment* a device or a registered widget
    /// target ships, the lifecycle is already correct.
    private let liveActivity = TurnLiveActivityController.shared
    /// Observer that drives `liveActivity` off the store's typed
    /// events. Wired up in `onAppear` so we have a live `store`
    /// reference; tear-down at app exit is implicit (App-scoped).
    @State private var liveActivityBridge: TurnLiveActivityBridge?

    init() {
        Telemetry.configure()
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                LitterUI.RootView()
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
                        }
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
                        LitterUI.AgentPickerSheet(headerNote: pick.hostNote)
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
            let dark: Bool
            switch appearance.themeMode {
            case .system: dark = systemScheme == .dark
            case .light:  dark = false
            case .dark:   dark = true
            }
            let theme = NeonTheme.resolve(
                palette: appearance.neonPalette.neonPalette,
                dark: dark,
                glow: appearance.neonGlow
            )
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
