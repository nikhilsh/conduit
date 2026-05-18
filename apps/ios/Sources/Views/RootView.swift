import SwiftUI

struct RootView: View {
    @Environment(SessionStore.self) private var store
    @State private var showSettings = false

    var body: some View {
        @Bindable var store = store

        ZStack {
            GlassAppBackground()

            NavigationSplitView {
                ProjectListView(showSettings: $showSettings)
            } detail: {
                if let id = store.selectedSessionID,
                   let session = store.sessions.first(where: { $0.id == id }) {
                    ProjectView(session: session)
                } else {
                    DetailEmptyState(
                        harness: store.harness,
                        endpoint: store.endpoint,
                        onConfigure: { showSettings = true },
                        onReconnect: { store.reconnect() }
                    )
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheet()
        }
        .onAppear {
            // First launch: open settings if endpoint is unconfigured.
            if !store.endpoint.isComplete {
                showSettings = true
            } else if store.harness == .disconnected {
                store.connect()
            }
        }
    }
}

/// Empty detail pane. Replaces the bare `ContentUnavailableView` so the
/// user has a single place that explains harness state + actionable next
/// step at any given moment.
private struct DetailEmptyState: View {
    let harness: HarnessState
    let endpoint: StoredEndpoint
    let onConfigure: () -> Void
    let onReconnect: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: icon)
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(SweKittyTheme.textSecondary)
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(SweKittyTheme.textPrimary)
            Text(message)
                .font(.callout)
                .foregroundStyle(SweKittyTheme.textMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            actionButtons
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
        .tint(SweKittyTheme.accentStrong)
    }

    private var icon: String {
        switch harness {
        case .disconnected:   return endpoint.isComplete ? "antenna.radiowaves.left.and.right.slash" : "wifi.slash"
        case .connecting:     return "antenna.radiowaves.left.and.right"
        case .reconnecting:   return "antenna.radiowaves.left.and.right"
        case .linked:         return "terminal"
        case .live:           return "terminal"
        case .failed:         return "exclamationmark.triangle"
        }
    }

    private var title: String {
        switch harness {
        case .disconnected: return endpoint.isComplete ? "Disconnected" : "Welcome to SweKitty"
        case .connecting:   return "Connecting to harness"
        case .reconnecting: return "Reconnecting…"
        case .linked:       return "No session selected"
        case .live:         return "No session selected"
        case .failed:       return "Harness unreachable"
        }
    }

    private var message: String {
        switch harness {
        case .disconnected:
            return endpoint.isComplete
                ? "We're not currently linked to the harness."
                : "Pair this device with a running swe-kitty harness in Settings to begin."
        case .connecting:
            return "Establishing a websocket link to \(endpoint.displayHost)."
        case let .reconnecting(attempt, maxAttempts):
            return "Lost link to \(endpoint.displayHost). Reconnecting (attempt \(attempt) of \(maxAttempts))."
        case .linked, .live:
            return "Tap + in the sidebar to start a session against \(endpoint.displayHost)."
        case .failed(let reason):
            return reason
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        HStack(spacing: 12) {
            if !endpoint.isComplete {
                Button {
                    onConfigure()
                } label: {
                    Label("Pair server", systemImage: "qrcode.viewfinder")
                }
                .buttonStyle(.borderedProminent)
            } else {
                switch harness {
                case .disconnected, .failed:
                    Button {
                        onReconnect()
                    } label: {
                        Label("Reconnect", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                    Button {
                        onConfigure()
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                    .buttonStyle(.bordered)
                default:
                    Button {
                        onConfigure()
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(.top, 6)
    }
}
