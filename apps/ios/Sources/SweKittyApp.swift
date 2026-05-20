import SwiftUI

@main
struct SweKittyApp: App {
    @State private var store = SessionStore()

    init() {
        Telemetry.configure()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .onOpenURL { url in
                    applyPairingURL(url)
                }
                .sheet(item: hostKeyBinding) { prompt in
                    HostKeyPromptSheet(prompt: prompt) { accepted in
                        store.resolveHostKeyPrompt(accept: accepted)
                    }
                    .presentationDetents([.medium])
                }
        }
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
    }
}
