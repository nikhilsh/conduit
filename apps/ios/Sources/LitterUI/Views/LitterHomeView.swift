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
        /// Voice dictation (bottom mic). On a transcript we stash it here
        /// and open the agent picker seeded with it as the first prompt.
        @State private var showVoiceDictation = false
        @State private var voicePrompt: String?
        @State private var selectedSessionID: String?
        /// Confirmation alert state for the session-row swipe-to-delete.
        /// `.alert(item:)` needs an Identifiable, so we wrap the target
        /// session id (`Identifiable` via the inner struct).
        @State private var pendingDelete: PendingSessionDelete?

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
                .sheet(isPresented: $showAgentPicker, onDismiss: { voicePrompt = nil }) {
                    LitterUI.AgentPickerSheet(initialPrompt: voicePrompt)
                }
                .sheet(isPresented: $showVoiceDictation, onDismiss: {
                    // Chain into the agent picker (seeded with the transcript)
                    // only if we actually captured something.
                    if voicePrompt?.isEmpty == false { showAgentPicker = true }
                }) {
                    VoiceDictationSheet(onTranscript: { text in
                        voicePrompt = text
                        showVoiceDictation = false
                    })
                }
                .sheet(isPresented: $showSearch) {
                    // Search is a legacy view for now.
                    SessionSearchView().environment(store)
                }
                .alert(
                    "Delete session?",
                    isPresented: Binding(
                        get: { pendingDelete != nil },
                        set: { if !$0 { pendingDelete = nil } }
                    ),
                    presenting: pendingDelete
                ) { target in
                    Button("Delete", role: .destructive) {
                        store.exit(sessionID: target.id)
                        pendingDelete = nil
                    }
                    Button("Cancel", role: .cancel) {
                        pendingDelete = nil
                    }
                } message: { target in
                    Text("This ends \(target.title) on the harness. The conversation history stays available under Sessions.")
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
            // Litter parity (audit §A.1.6) put settings behind a hidden
            // long-press on the brand mark — undiscoverable in practice
            // (user feedback 2026-05-23). Restore a visible gear in the
            // leading slot; the long-press stays as a secondary path so
            // accessibility hints continue to work. Trailing drops the
            // search icon because the bottom action bar already carries
            // a 44pt search button — having both was a duplicate.
            LitterUI.Header(
                leading: {
                    LitterUI.HeaderIconButton(systemImage: "gearshape",
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
                        .accessibilityHint("Press and hold for settings")
                        .onLongPressGesture(minimumDuration: 0.4) {
                            showSettings = true
                        }
                },
                trailing: {
                    LitterUI.HeaderIconButton(systemImage: "clock.arrow.circlepath",
                                              accessibilityLabel: "Sessions history") {
                        showSessionsHistory = true
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
                // Promoted from ScrollView+VStack to a `List` so each row
                // can carry `.swipeActions` for the delete affordance —
                // SwiftUI only honours swipe gestures on List/Form rows.
                // `listStyle(.plain)` + clear backgrounds preserve the
                // litter-faithful flat look from the prior layout.
                List {
                    ForEach(rows) { row in
                        HomeRowView(row: row)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 0, leading: 14, bottom: 0, trailing: 14))
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if case .session(let id) = row.kind {
                                    store.selectedSessionID = id
                                    selectedSessionID = id
                                }
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                if case .session(let id) = row.kind {
                                    Button(role: .destructive) {
                                        pendingDelete = PendingSessionDelete(id: id, title: row.title)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                            .contextMenu {
                                if case .session(let id) = row.kind {
                                    Button(role: .destructive) {
                                        pendingDelete = PendingSessionDelete(id: id, title: row.title)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }

        private var bottomBar: some View {
            // PLAN-LITTER-VISUAL-PARITY PR 3, audit §A.1.5: litter wraps
            // the bottom bar in TWO `GlassMorphContainer`s so the `+`
            // can morph into a composer without the surrounding
            // mic / search merging into the same glass blob. All three
            // controls drop to a single 44pt — the prior 56pt copper-
            // outlined plus was over-built relative to litter.
            HStack(spacing: 14) {
                LitterUI.GlassMorphContainer(spacing: 14) {
                    LitterUI.PillButton(systemImage: "mic.fill", size: 44) {
                        showVoiceDictation = true
                    }
                }
                Spacer()
                LitterUI.GlassMorphContainer(spacing: 14) {
                    LitterUI.PillButton(
                        systemImage: "plus",
                        size: 44,
                        tint: LitterUI.Palette.brand.color,
                        isProminent: true
                    ) {
                        if store.harness.canIssueCommands {
                            showAgentPicker = true
                        } else {
                            showAddServer = true
                        }
                    }
                }
                Spacer()
                LitterUI.GlassMorphContainer(spacing: 14) {
                    LitterUI.PillButton(systemImage: "magnifyingglass", size: 44) {
                        showSearch = true
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 4)
        }
    }
}

/// Carrier for the alert-driven delete confirmation on the home
/// sessions list. `Identifiable` so the `.alert(presenting:)` overload
/// can key the presentation off the pending target, ensuring a stale
/// id from a previous swipe doesn't survive into the next prompt.
private struct PendingSessionDelete: Identifiable, Equatable {
    let id: String
    let title: String
}

/// Row metrics extracted as named constants so `LitterHomeRowGeometry
/// Tests` can pin them. Changing any of these silently re-grows / re-
/// shrinks the home list, which is exactly the drift the rebuild PR
/// is trying to stop. Values are taken from litter's
/// `SessionCanvasLine.swift` (audit §A.1.1 / §A.1.2 / §A.1.7).
enum HomeRowMetrics {
    static let titlePointSize: CGFloat = 13
    static let subtitlePointSize: CGFloat = 11
    static let leadingPadding: CGFloat = 1
    static let trailingPadding: CGFloat = 8
    static let verticalPadding: CGFloat = 5
    static let indicatorSize: CGFloat = 7
    static let activeRowCornerRadius: CGFloat = 6
    static let activeRowOpacity: Double = 0.55
}

private struct HomeRowView: View {
    let row: LitterUI.HomeRow

    var body: some View {
        HStack(spacing: 10) {
            indicator
                .frame(width: HomeRowMetrics.indicatorSize, height: HomeRowMetrics.indicatorSize)
            VStack(alignment: .leading, spacing: 1) {
                // Title shrunk from .title3 (~20pt) bold mono to footnote-
                // sized 13pt semibold per audit §A.1.1. Subtitle drops
                // to caption2-sized 11pt mono (audit §A.1.1).
                Text(row.title)
                    .font(.system(size: HomeRowMetrics.titlePointSize, weight: .semibold))
                    .foregroundStyle(LitterUI.Palette.textPrimary.color)
                    .lineLimit(1)
                Text(row.subtitle)
                    .font(.system(size: HomeRowMetrics.subtitlePointSize, weight: .regular, design: .monospaced))
                    .foregroundStyle(LitterUI.Palette.textMuted.color)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.leading, HomeRowMetrics.leadingPadding)
        .padding(.trailing, HomeRowMetrics.trailingPadding)
        .padding(.vertical, HomeRowMetrics.verticalPadding)
        .background(
            // Active-row fill per audit §A.1.3 — litter selects a row
            // by painting a 6pt rounded rect at 55% surfaceLight,
            // not by swapping an SF Symbol.
            RoundedRectangle(cornerRadius: HomeRowMetrics.activeRowCornerRadius, style: .continuous)
                .fill(LitterUI.Palette.surfaceLight.color.opacity(row.isSelected ? HomeRowMetrics.activeRowOpacity : 0))
        )
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var indicator: some View {
        switch row.kind {
        case .creatingPlaceholder:
            // ProgressView is bigger than 7pt natively; clip into the
            // indicator frame so the row vertical rhythm doesn't break.
            ProgressView()
                .controlSize(.mini)
        case .session:
            // 7pt filled circle per audit §A.1.7 — accent for live
            // status (selected → pulse-able later), muted for idle.
            Circle()
                .fill(row.isSelected
                      ? LitterUI.Palette.accentStrong.color
                      : LitterUI.Palette.textMuted.color.opacity(0.5))
        }
    }
}
