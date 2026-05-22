import SwiftUI

// MARK: - LitterSessionsRail
//
// Sidebar variant of `LitterHomeView` used by the iPad/regular split
// view. Narrower than the iPhone home, no bottom action bar (those
// affordances live on the detail toolbar on iPad) — just the
// server-pill row + the sessions list. Tapping a row drives selection
// via `SessionStore.switchTo(sessionID:)`.
//
// The pure-data layout decisions live in `LitterSessionsRailModel`
// so the test layer can pin row count + active-session highlight
// without standing up a view tree.

extension LitterUI {

    struct SessionsRail: View {
        @Environment(SessionStore.self) private var store
        @Environment(AppearanceStore.self) private var appearance

        @State private var showSettings = false
        @State private var showAddServer = false

        var body: some View {
            @Bindable var store = store

            ZStack {
                LitterUI.Palette.surface.color.ignoresSafeArea()
                VStack(spacing: 12) {
                    header
                    serverPillStrip
                    sessionsList
                    Spacer(minLength: 0)
                }
                .padding(.top, 8)
            }
            .sheet(isPresented: $showSettings) {
                LitterUI.SettingsView()
            }
            .sheet(isPresented: $showAddServer) {
                LitterUI.AddServerSheet()
            }
            .tint(LitterUI.Palette.brand.color)
        }

        // MARK: Subviews

        private var header: some View {
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
                        .frame(width: 28, height: 28)
                        .cornerRadius(6)
                        .accessibilityLabel("SweKitty")
                },
                trailing: {
                    EmptyView()
                }
            )
        }

        @ViewBuilder
        private var serverPillStrip: some View {
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
                .padding(.horizontal, 12)
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
            let rows = LitterUI.SessionsRailModel.rows(snap)
            if rows.isEmpty {
                VStack(spacing: 8) {
                    Spacer(minLength: 24)
                    Image(systemName: LitterUI.HomeViewModel.emptySymbol(snap))
                        .font(.system(size: 32, weight: .light))
                        .foregroundStyle(LitterUI.Palette.textSecondary.color)
                    Text(LitterUI.HomeViewModel.emptyTitle(snap))
                        .font(.subheadline)
                        .foregroundStyle(LitterUI.Palette.textPrimary.color)
                    Text(LitterUI.HomeViewModel.emptyBody(snap))
                        .font(.caption)
                        .foregroundStyle(LitterUI.Palette.textMuted.color)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(rows) { row in
                            RailRowView(row: row)
                                .onTapGesture {
                                    if case .session(let id) = row.kind {
                                        store.switchTo(sessionID: id)
                                    }
                                }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 16)
                }
            }
        }
    }
}

// MARK: - Row view

private struct RailRowView: View {
    let row: LitterUI.HomeRow

    var body: some View {
        HStack(spacing: 10) {
            indicator
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title)
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundStyle(LitterUI.Palette.textPrimary.color)
                    .lineLimit(1)
                Text(row.subtitle)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(LitterUI.Palette.textMuted.color)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(row.isSelected
                      ? LitterUI.Palette.brand.color.opacity(0.18)
                      : Color.clear)
        )
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var indicator: some View {
        switch row.kind {
        case .creatingPlaceholder:
            ProgressView().controlSize(.small)
        case .session:
            Image(systemName: row.isSelected ? "circle.fill" : "circle")
                .font(.caption)
                .foregroundStyle(row.isSelected
                                 ? LitterUI.Palette.brand.color
                                 : LitterUI.Palette.textMuted.color.opacity(0.5))
        }
    }
}

// MARK: - Pure-data model
//
// Mirrors `LitterUI.HomeViewModel.rows` but exposed under a dedicated
// namespace so the rail's contract (row count + active highlight) is
// the thing tests pin. Today the body forwards to the home model —
// keeping the indirection makes the rail safe to evolve (e.g. recent-
// session truncation, pinned sessions) without dragging the home
// screen's row contract along.

extension LitterUI {

    enum SessionsRailModel {
        static func rows(_ snap: HomeSnapshot) -> [HomeRow] {
            HomeViewModel.rows(snap)
        }
    }
}
