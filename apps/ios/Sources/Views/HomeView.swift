import SwiftUI

/// Compact (iPhone) home surface — the litter-style stack layout:
///   ┌─────────────────────────────┐
///   │ ⚙  ·  SweKitty  ·  ☰        │
///   │ [server pill] [server] [+]  │
///   │  ○ session-a   1h · ip       │
///   │  ● session-b   3m · ip       │
///   │             …                │
///   │     [🎙]  [+]  [🔍]           │
///   └─────────────────────────────┘
/// Regular-class (iPad) keeps `NavigationSplitView` in `RootView`.
struct HomeView: View {
    @Environment(SessionStore.self) private var store
    @Environment(\.colorScheme) private var colorScheme

    @State private var showSettings = false
    @State private var showAddServer = false
    @State private var showSearch = false
    @State private var showVoice = false
    @State private var showAgentPicker = false
    @State private var selectedSessionID: String?
    /// Long-lived LAN browser so discovered servers stream into the
    /// home pill row as a litter-style "what's around me" affordance.
    /// Lifetime is bound to the HomeView's presence on screen: started
    /// in `.onAppear` and stopped in `.onDisappear` so we don't keep
    /// the NetService browser open while the user is deep in a
    /// session. Results dedupe against `savedServers` by host:port
    /// inside `ServerPillRow` so the same advertiser doesn't show up
    /// twice when the user has already saved it.
    @State private var lanBrowser = LANDiscoveryBrowser()

    var body: some View {
        @Bindable var store = store

        NavigationStack {
            ZStack {
                SweKittyTheme.backgroundGradient(for: colorScheme)
                    .ignoresSafeArea()

                VStack(spacing: 14) {
                    topRow
                    ServerPillRow(
                        discovered: lanBrowser.results,
                        showAddServer: $showAddServer
                    )
                    if let err = store.sessionCreationError {
                        InlineErrorBanner(message: err, onDismiss: { store.sessionCreationError = nil })
                            .padding(.horizontal, 14)
                    }
                    sessionList
                    BottomActionBar(
                        onVoice: { showVoice = true },
                        onPlus: {
                            if store.harness.canIssueCommands {
                                showAgentPicker = true
                            } else {
                                showAddServer = true
                            }
                        }
                    )
                }
                .padding(.top, 8)
                .navigationDestination(item: $selectedSessionID) { id in
                    if let session = store.sessions.first(where: { $0.id == id }) {
                        ProjectView(session: session)
                    } else {
                        Color.clear
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsSheet()
            }
            .sheet(isPresented: $showAddServer) {
                AddServerSheet().environment(store)
            }
            .sheet(isPresented: $showAgentPicker) {
                AgentPickerSheet(headerNote: nil).environment(store)
            }
            .sheet(isPresented: $showSearch) {
                SessionSearchView().environment(store)
            }
            .sheet(isPresented: $showVoice) {
                VoiceDictationSheet { transcript in
                    // If a session is already selected, push the transcript
                    // into it as a chat message. Otherwise spin up a new
                    // claude session with the transcript as its first
                    // prompt — this matches the litter "speak to start"
                    // flow rather than dumping the transcript on the floor.
                    if let id = store.selectedSessionID {
                        store.sendChat(sessionID: id, message: transcript)
                    } else if store.harness.canIssueCommands {
                        store.createSession(assistant: "claude", initialPrompt: transcript)
                    }
                }
            }
            .onChange(of: store.selectedSessionID) { _, new in
                selectedSessionID = new
            }
            .onAppear {
                if !store.endpoint.isComplete {
                    showSettings = true
                } else if store.harness == .disconnected {
                    store.connect()
                }
                // Stream mDNS results into the home pill row so the
                // user discovers nearby brokers without having to
                // open the dedicated DiscoveryView first.
                lanBrowser.start()
            }
            .onDisappear {
                lanBrowser.stop()
            }
            .tint(SweKittyTheme.accentStrong)
        }
    }

    private var topRow: some View {
        HStack(spacing: 14) {
            iconButton(systemImage: "gearshape.fill", action: { showSettings = true })
            Spacer()
            Image("KittyMark")
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 32, height: 32)
                .cornerRadius(7)
                .accessibilityLabel("SweKitty")
            Spacer()
            iconButton(systemImage: "list.bullet", action: { showSearch = true })
        }
        .padding(.horizontal, 16)
    }

    private func iconButton(systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(SweKittyTheme.textPrimary)
                .frame(width: 40, height: 40)
                .glassCircle(tint: SweKittyTheme.surface.opacity(0.65))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var sessionList: some View {
        let entries = store.visibleSessions
        if entries.isEmpty {
            VStack(spacing: 10) {
                Spacer(minLength: 24)
                Image(systemName: store.harness.canIssueCommands ? "sparkles" : "cloud.slash")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(SweKittyTheme.textSecondary)
                Text(store.harness.canIssueCommands ? "No sessions yet" : "Waiting for harness")
                    .font(.headline)
                    .foregroundStyle(SweKittyTheme.textPrimary)
                Text(store.harness.canIssueCommands
                    ? "Tap + to spin up a new conversation."
                    : "Once we can reach the harness, your sessions appear here.")
                    .font(.footnote)
                    .foregroundStyle(SweKittyTheme.textMuted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 36)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(entries) { entry in
                        HomeSessionRow(entry: entry)
                            .onTapGesture {
                                if case .real(let s) = entry {
                                    store.selectedSessionID = s.id
                                    selectedSessionID = s.id
                                }
                            }
                    }
                }
                .padding(.horizontal, 14)
            }
        }
    }
}

private struct HomeSessionRow: View {
    @Environment(SessionStore.self) private var store
    let entry: VisibleSession

    var body: some View {
        HStack(spacing: 12) {
            indicator
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName)
                    .font(.system(.title3, design: .monospaced).weight(.bold))
                    .foregroundStyle(SweKittyTheme.textPrimary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(SweKittyTheme.textMuted)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }

    private var status: SessionStatus? {
        if case .real(let s) = entry { return store.statusBySession[s.id] }
        return nil
    }

    @ViewBuilder
    private var indicator: some View {
        switch entry {
        case .creating:
            ProgressView().controlSize(.small)
        case .real:
            Image(systemName: isSelected ? "circle.fill" : "circle")
                .font(.subheadline)
                .foregroundStyle(isSelected ? SweKittyTheme.accentStrong : SweKittyTheme.textMuted.opacity(0.5))
        }
    }

    private var isSelected: Bool {
        if case .real(let s) = entry { return store.selectedSessionID == s.id }
        return false
    }

    private var displayName: String {
        switch entry {
        case .real(let s): return store.displayName(for: s)
        case .creating:    return "Starting session…"
        }
    }

    private var subtitle: String {
        switch entry {
        case .real(let s):
            // ProjectSession has no createdAt/lastTouchedAt yet, so the
            // relative-time slot falls back to "{assistant} · {phase}" while
            // still appending the endpoint host so each row tells you which
            // harness it belongs to (matches the Litter "now · ip" cadence).
            let phase = status?.phase ?? "ready"
            let host = store.endpoint.isComplete ? store.endpoint.displayHost : "local"
            return "\(s.assistant) · \(phase) · \(host)"
        case .creating(let placeholderID):
            if case .failed(let msg) = store.sessionLifecycle[placeholderID] { return msg }
            return "asking harness…"
        }
    }
}
