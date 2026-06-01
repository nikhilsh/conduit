import SwiftUI

// MARK: - ConduitSessionsRail
//
// The unified tablet left rail (tablet.jsx → TabletRail), mirroring the
// Android `NeonTabletRail`. It folds in the navigation that used to live
// in the separate icon "activity bar": brand + connected-server chip +
// an overflow menu (Settings / Boxes), a Search button (covers History
// via the search sheet), the sessions list, and a pinned "New session"
// button. Tapping a row drives selection via
// `SessionStore.switchTo(sessionID:)`.
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
        @State private var showBoxes = false
        @State private var showSearch = false
        @State private var showAgentPicker = false

        var body: some View {
            @Bindable var store = store

            ZStack {
                ConduitUI.Palette.surface.color.ignoresSafeArea()
                VStack(spacing: 12) {
                    header
                    searchButton
                    sessionsList
                    Spacer(minLength: 0)
                    newSessionButton
                }
                .padding(.top, 8)
            }
            .sheet(isPresented: $showSettings) {
                ConduitUI.SettingsView()
            }
            .sheet(isPresented: $showAddServer) {
                ConduitUI.AddServerSheet()
            }
            .sheet(isPresented: $showBoxes) {
                ConduitUI.DiscoveryView()
            }
            .sheet(isPresented: $showSearch) {
                SessionSearchView(
                    onSelect: { id in store.switchTo(sessionID: id) },
                    embedded: false
                )
            }
            .sheet(isPresented: $showAgentPicker) {
                ConduitUI.AgentPickerSheet(initialPrompt: nil)
            }
            .neonAccentTint()
        }

        // MARK: Header (brand + server chip + overflow)

        private var header: some View {
            HStack(spacing: 9) {
                ConduitUI.ConduitMark(size: 24)
                    .accessibilityLabel("Conduit")
                wordmark
                Spacer(minLength: 6)
                serverChip
                overflowMenu
            }
            .padding(.horizontal, 14)
        }

        private var wordmark: some View {
            (Text(">").foregroundStyle(neon.accent)
                + Text("conduit").foregroundStyle(neon.text))
                .font(.system(size: 15, weight: .bold, design: .monospaced))
                .accessibilityHidden(true)
        }

        /// Single connected-server chip — reuses `TabletHome.connectionChip`
        /// styling (host + status dot: green live/linked, yellow
        /// connecting/reconnecting, muted offline).
        private var serverChip: some View {
            let (label, color): (String, Color) = {
                switch store.harness {
                case .live, .linked:
                    return (store.endpoint.isComplete ? store.endpoint.displayHost : "online", neon.green)
                case .connecting, .reconnecting:
                    return ("connecting", neon.yellow)
                case .disconnected, .failed:
                    return ("offline", neon.textFaint)
                }
            }()
            return HStack(spacing: 6) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(label)
                    .font(neon.mono(11))
                    .foregroundStyle(color)
                    .lineLimit(1)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(neon.surface)
                    .overlay(Capsule().stroke(neon.border, lineWidth: 1))
            )
        }

        private var overflowMenu: some View {
            Menu {
                Button {
                    showSettings = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                Button {
                    showBoxes = true
                } label: {
                    Label("Boxes", systemImage: "externaldrive")
                }
            } label: {
                // A gear, not a `•••`: the dim ellipsis was undiscoverable as
                // the route to Settings on tablet — a user on the 3-pane layout
                // couldn't find Settings at all (device feedback 2026-06-01).
                // Settings is the primary item, so the trigger reads as a gear;
                // Boxes stays as the menu's secondary entry.
                Image(systemName: "gearshape")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(neon.textDim)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Settings and more")
        }

        // MARK: Search (covers History)

        private var searchButton: some View {
            Button {
                showSearch = true
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(neon.accent)
                    Text("Search…")
                        .font(neon.sans(12.5))
                        .foregroundStyle(neon.textFaint)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(neon.surface)
                        .overlay(
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .stroke(neon.border, lineWidth: 1)
                        )
                )
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
        }

        // MARK: New session (pinned bottom)

        private var newSessionButton: some View {
            Button {
                if store.harness.canIssueCommands {
                    showAgentPicker = true
                } else {
                    showAddServer = true
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .bold))
                    Text("New session")
                        .font(neon.sans(13.5).weight(.bold))
                }
                .foregroundStyle(neon.accentText)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(neon.accent)
                )
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
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
