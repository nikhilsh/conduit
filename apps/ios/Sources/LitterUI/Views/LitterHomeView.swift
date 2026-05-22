import SwiftUI

// MARK: - LitterHomeView
//
// Litter-faithful home screen. Mirrors litter's HomeDashboardView in
// structure (top row with chrome icons, server pill row, sessions list,
// bottom action bar with mic/+/search) but uses our own data layer.
//
// Visual decisions:
//   - Top row: 36pt glass-circle icon buttons left/right, centered
//     KittyMark logo.
//   - Server pill row: horizontal scroll of capsule pills, ending in
//     a "+" pill. Selected pill carries the brand tint.
//   - Sessions list: flat rows (no card chrome), separator-less.
//     A solid status circle replaces the bubble. Title in body
//     weight, subtitle in mono caption.
//   - Bottom action bar: anchored at the bottom-safe-area, three
//     controls (mic / + / search). "+" is the prominent FAB.

extension LitterUI {

    struct HomeView: View {
        @Environment(SessionStore.self) private var store
        @Environment(AppearanceStore.self) private var appearance
        @Environment(\.colorScheme) private var colorScheme

        @State private var showSettings = false
        @State private var showAddServer = false
        @State private var showSearch = false
        @State private var showAgentPicker = false
        @State private var showSessionsHistory = false
        @State private var selectedSessionID: String?

        var body: some View {
            @Bindable var store = store

            NavigationStack {
                ZStack {
                    LitterUI.Palette.surface.color.ignoresSafeArea()
                    VStack(spacing: 12) {
                        topRow
                        serverPillStrip
                        sessionsList
                        Spacer(minLength: 0)
                        bottomBar
                    }
                    .padding(.top, 8)
                    .navigationDestination(item: $selectedSessionID) { id in
                        if let session = store.sessions.first(where: { $0.id == id }) {
                            LitterUI.ProjectView(session: session)
                        } else {
                            Color.clear
                        }
                    }
                    .navigationDestination(isPresented: $showSessionsHistory) {
                        // Sessions-history surface is the legacy
                        // `SessionsScreen` (now in `Sources/Shared/`).
                        // A litter-faithful rebuild is a follow-up;
                        // for now we expose the existing one as a
                        // navigation push so the affordance keeps
                        // working post-cutover.
                        SessionsScreen().environment(store)
                    }
                }
                .sheet(isPresented: $showSettings) {
                    LitterUI.SettingsView()
                }
                .sheet(isPresented: $showAddServer) {
                    LitterUI.AddServerSheet()
                }
                .sheet(isPresented: $showAgentPicker) {
                    LitterUI.AgentPickerSheet()
                }
                .sheet(isPresented: $showSearch) {
                    // Search is a legacy view for now.
                    SessionSearchView().environment(store)
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
                }
                .tint(LitterUI.Palette.brand.color)
            }
        }

        // MARK: Subviews

        private var topRow: some View {
            LitterUI.Header(
                leading: {
                    LitterUI.HeaderIconButton(systemImage: "gearshape.fill",
                                              accessibilityLabel: "Settings") {
                        showSettings = true
                    }
                },
                center: {
                    Image("KittyMark")
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 32, height: 32)
                        .cornerRadius(7)
                        .accessibilityLabel("SweKitty")
                },
                trailing: {
                    HStack(spacing: 8) {
                        LitterUI.HeaderIconButton(systemImage: "clock.arrow.circlepath",
                                                  accessibilityLabel: "Sessions history") {
                            showSessionsHistory = true
                        }
                        LitterUI.HeaderIconButton(systemImage: "magnifyingglass",
                                                  accessibilityLabel: "Search") {
                            showSearch = true
                        }
                    }
                }
            )
        }

        @ViewBuilder
        private var serverPillStrip: some View {
            // Litter renders saved servers as a horizontal capsule
            // row. We render the same shape from `store.savedServers`
            // plus a trailing "+" pill that opens the add-server
            // sheet.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(store.savedServers) { server in
                        let isActive = store.endpoint == server.endpoint
                        Button {
                            store.selectSavedServer(server.id, autoConnect: true)
                        } label: {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(isActive ? LitterUI.Palette.accentStrong.color : LitterUI.Palette.textMuted.color)
                                    .frame(width: 6, height: 6)
                                Text(server.name)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(LitterUI.Palette.textPrimary.color)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .litterGlassCapsule(
                                tint: isActive ? LitterUI.Palette.brand.color.opacity(0.4) : nil,
                                config: .pill
                            )
                        }
                        .buttonStyle(.plain)
                    }

                    Button {
                        showAddServer = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "plus")
                                .font(.system(size: 11, weight: .bold))
                            Text("server")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .foregroundStyle(LitterUI.Palette.textPrimary.color)
                        .litterGlassCapsule(config: .pill)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
            }
            .frame(height: 36)
        }

        private var snapshot: LitterUI.HomeSnapshot {
            let endpointHost = store.endpoint.isComplete ? store.endpoint.displayHost : nil
            let harness: LitterUI.HomeSnapshotHarness = {
                switch store.harness {
                case .disconnected: return .disconnected
                case .connecting:   return .connecting
                case .linked, .live: return .live
                case .reconnecting: return .reconnecting
                case .failed(let reason): return .failed(reason)
                }
            }()
            let sessions = store.sessions.map { s in
                LitterUI.HomeSnapshotSession(
                    id: s.id,
                    displayName: store.displayName(for: s),
                    assistant: s.assistant,
                    phase: store.statusBySession[s.id]?.phase
                )
            }
            return LitterUI.HomeSnapshot(
                harness: harness,
                sessions: sessions,
                placeholders: [],
                selectedSessionID: store.selectedSessionID,
                endpointDisplayHost: endpointHost
            )
        }

        @ViewBuilder
        private var sessionsList: some View {
            let snap = snapshot
            let rows = LitterUI.HomeViewModel.rows(snap)
            if rows.isEmpty {
                VStack(spacing: 10) {
                    Spacer(minLength: 24)
                    Image(systemName: LitterUI.HomeViewModel.emptySymbol(snap))
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(LitterUI.Palette.textSecondary.color)
                    Text(LitterUI.HomeViewModel.emptyTitle(snap))
                        .font(.headline)
                        .foregroundStyle(LitterUI.Palette.textPrimary.color)
                    Text(LitterUI.HomeViewModel.emptyBody(snap))
                        .font(.footnote)
                        .foregroundStyle(LitterUI.Palette.textMuted.color)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 36)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(rows) { row in
                            HomeRowView(row: row)
                                .onTapGesture {
                                    if case .session(let id) = row.kind {
                                        store.selectedSessionID = id
                                        selectedSessionID = id
                                    }
                                }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 100)
                }
            }
        }

        private var bottomBar: some View {
            HStack(spacing: 16) {
                LitterUI.PillButton(systemImage: "mic.fill") {
                    // Voice is wired in a follow-up. Falls back to
                    // the legacy in-chat voice path for now.
                }
                Spacer()
                LitterUI.PillButton(
                    systemImage: "plus",
                    size: 56,
                    tint: LitterUI.Palette.brand.color,
                    isProminent: true
                ) {
                    if store.harness.canIssueCommands {
                        showAgentPicker = true
                    } else {
                        showAddServer = true
                    }
                }
                Spacer()
                LitterUI.PillButton(systemImage: "magnifyingglass") {
                    showSearch = true
                }
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 4)
        }
    }
}

private struct HomeRowView: View {
    let row: LitterUI.HomeRow

    var body: some View {
        HStack(spacing: 12) {
            indicator
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(.system(.title3, design: .monospaced).weight(.bold))
                    .foregroundStyle(LitterUI.Palette.textPrimary.color)
                    .lineLimit(1)
                Text(row.subtitle)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(LitterUI.Palette.textMuted.color)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var indicator: some View {
        switch row.kind {
        case .creatingPlaceholder:
            ProgressView().controlSize(.small)
        case .session:
            Image(systemName: row.isSelected ? "circle.fill" : "circle")
                .font(.subheadline)
                .foregroundStyle(row.isSelected
                                 ? LitterUI.Palette.brand.color
                                 : LitterUI.Palette.textMuted.color.opacity(0.5))
        }
    }
}
