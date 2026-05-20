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
        }
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
