import SwiftUI

// MARK: - ConduitSessionsRail
//
// Sidebar variant of `ConduitHomeView` used by the iPad/regular split
// view. Narrower than the iPhone home, no bottom action bar (those
// affordances live on the detail toolbar on iPad) — just the
// server-pill row + the sessions list. Tapping a row drives selection
// via `SessionStore.switchTo(sessionID:)`.
//
// The pure-data layout decisions live in `ConduitSessionsRailModel`
// so the test layer can pin row count + active-session highlight
// without standing up a view tree.

extension ConduitUI {

    struct SessionsRail: View {
        @Environment(SessionStore.self) private var store
        @Environment(AppearanceStore.self) private var appearance
        @Environment(\.neonTheme) private var neon

        @State private var showSettings = false
        @State private var showAddServer = false

        var body: some View {
            @Bindable var store = store

            ZStack {
                ConduitUI.Palette.surface.color.ignoresSafeArea()
                VStack(spacing: 12) {
                    header
                    serverPillStrip
                    sessionsList
                    Spacer(minLength: 0)
                }
                .padding(.top, 8)
            }
            .sheet(isPresented: $showSettings) {
                ConduitUI.SettingsView()
            }
            .sheet(isPresented: $showAddServer) {
                ConduitUI.AddServerSheet()
            }
            .neonAccentTint()
        }

        // MARK: Subviews

        private var header: some View {
            ConduitUI.Header(
                leading: {
                    ConduitUI.HeaderIconButton(systemImage: "gearshape.fill",
                                              accessibilityLabel: "Settings") {
                        showSettings = true
                    }
                },
                center: {
                    ConduitUI.ConduitMark(size: 28)
                        .accessibilityLabel("Conduit")
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
                                    .fill(isActive ? ConduitUI.Palette.accentStrong.color : ConduitUI.Palette.textMuted.color)
                                    .frame(width: 6, height: 6)
                                Text(server.name)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(ConduitUI.Palette.textPrimary.color)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .conduitGlassCapsule(
                                tint: isActive ? neon.accent.opacity(0.4) : nil,
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
                        .foregroundStyle(ConduitUI.Palette.textPrimary.color)
                        .conduitGlassCapsule(config: .pill)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }
            .frame(height: 36)
        }

        private var snapshot: ConduitUI.HomeSnapshot {
            let endpointHost = store.endpoint.isComplete ? store.endpoint.displayHost : nil
            let harness: ConduitUI.HomeSnapshotHarness = {
                switch store.harness {
                case .disconnected: return .disconnected
                case .connecting:   return .connecting
                case .linked, .live: return .live
                case .reconnecting: return .reconnecting
                case .failed(let reason): return .failed(reason)
                }
            }()
            let sessions = store.sessions.map { s in
                ConduitUI.HomeSnapshotSession(
                    id: s.id,
                    displayName: store.displayName(for: s),
                    assistant: s.assistant,
                    phase: store.statusBySession[s.id]?.phase
                )
            }
            return ConduitUI.HomeSnapshot(
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
            let rows = ConduitUI.SessionsRailModel.rows(snap)
            if rows.isEmpty {
                VStack(spacing: 8) {
                    Spacer(minLength: 24)
                    Image(systemName: ConduitUI.HomeViewModel.emptySymbol(snap))
                        .font(.system(size: 32, weight: .light))
                        .foregroundStyle(ConduitUI.Palette.textSecondary.color)
                    Text(ConduitUI.HomeViewModel.emptyTitle(snap))
                        .font(.subheadline)
                        .foregroundStyle(ConduitUI.Palette.textPrimary.color)
                    Text(ConduitUI.HomeViewModel.emptyBody(snap))
                        .font(.caption)
                        .foregroundStyle(ConduitUI.Palette.textMuted.color)
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
    let row: ConduitUI.HomeRow
    @Environment(\.neonTheme) private var neon

    var body: some View {
        HStack(spacing: 10) {
            indicator
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title)
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundStyle(ConduitUI.Palette.textPrimary.color)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(ConduitUI.Palette.textMuted.color)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(row.isSelected
                      ? neon.accent.opacity(0.18)
                      : Color.clear)
        )
        .contentShape(Rectangle())
    }

    /// Compact rail subtitle reassembled from the structured `HomeRow`
    /// fields (the old single `subtitle` string is gone): agent + status,
    /// plus a relative time when we have one.
    private var subtitle: String {
        switch row.kind {
        case .creatingPlaceholder:
            return row.statusText
        case .session:
            var parts: [String] = []
            if !row.agent.isEmpty { parts.append(row.agent) }
            parts.append(row.statusText)
            if !row.relativeTime.isEmpty { parts.append(row.relativeTime) }
            return parts.joined(separator: " · ")
        }
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
                                 ? neon.accent
                                 : ConduitUI.Palette.textMuted.color.opacity(0.5))
        }
    }
}

// MARK: - Pure-data model
//
// Mirrors `ConduitUI.HomeViewModel.rows` but exposed under a dedicated
// namespace so the rail's contract (row count + active highlight) is
// the thing tests pin. Today the body forwards to the home model —
// keeping the indirection makes the rail safe to evolve (e.g. recent-
// session truncation, pinned sessions) without dragging the home
// screen's row contract along.

extension ConduitUI {

    enum SessionsRailModel {
        static func rows(_ snap: HomeSnapshot) -> [HomeRow] {
            HomeViewModel.rows(snap)
        }
    }
}
