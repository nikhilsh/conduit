import SwiftUI

// MARK: - ConduitBoxHealthView  (handoff §B.7 — "Box health")
//
// Per-box detail surface. The redesign reference (`images/08-box-health.png`)
// shows CPU / MEM / DISK rings + load / uptime / agent-runtime, the sessions
// running on the box, and a Reconnect · SSH · Wake action row.
//
// ── Data honesty ───────────────────────────────────────────────────────────
// There is **NO host-metrics source** anywhere in the stack. Grepped
// `core/src` (`SessionStatus` in `core/src/views.rs`, `ProjectSession` in
// `core/src/session.rs`) and `broker/internal` for cpu / mem / disk / load /
// uptime / loadavg / sysinfo — zero hits. So the design's percentage rings and
// the load/uptime/runtime readouts have no data to bind to. Rather than
// fabricate numbers, the health section renders an **honest unavailable
// state**: dimmed rings showing "—" plus a one-line note ("metrics not
// reported by this box").
//
// What IS real and shown:
//   • Box identity      — `SavedServer.name` + `endpoint.displayHost`.
//   • Connection status — derived exactly like Home's boxRow:
//                          `store.endpoint == server.endpoint` (is this the
//                          active box) && `store.harness` (connected / offline).
//   • Sessions on box   — `store.sessions` are the live sessions of the
//                          *connected* endpoint, so they belong to this box
//                          only when it is the active one. For a non-active box
//                          we show a "reconnect to view" hint (we can't list a
//                          machine's sessions without being connected to it).
//
// ── Per-box quota rule (handoff "Data model") ────────────────────────────────
// Plan limits are **per account**, never per box. This screen therefore shows
// NO quota — just a hairline pointer to Settings ("limits are account-wide").
//
// ── Presentation / entry suggestion ──────────────────────────────────────────
// Present as a sheet (or push) opened by tapping a box row in Home's Boxes list
// (`ConduitHomeView.boxRow`). Caller passes the tapped `SavedServer` plus the
// real reconnect action and (optional) SSH / Wake closures:
//
//     .sheet(item: $selectedBox) { server in
//         ConduitUI.BoxHealthView(
//             server: server,
//             onReconnect: { store.selectSavedServer(server.id, autoConnect: true) }
//         )
//     }
//
// `onReconnect` defaults to a no-op so the view compiles standalone; the real
// reconnect path is `store.reconnect()` (current endpoint) or
// `store.selectSavedServer(_:autoConnect:)` (switch + connect). SSH and Wake
// have NO backing action in the store today, so they default to no-ops and the
// row reads as caller-supplied affordances.

extension ConduitUI {

    struct BoxHealthView: View {
        @Environment(SessionStore.self) private var store
        @Environment(\.neonTheme) private var neon
        @Environment(\.dismiss) private var dismiss

        /// The box this screen describes. The boxes list on Home is keyed on
        /// `SavedServer` (`store.savedServers`), so that is the entry type.
        let server: SavedServer

        /// Real reconnect/connect path supplied by the caller (e.g.
        /// `store.selectSavedServer(server.id, autoConnect: true)`).
        var onReconnect: () -> Void = {}
        /// No backing action in the store today — caller-supplied / no-op.
        var onSSH: () -> Void = {}
        /// No backing action in the store today — caller-supplied / no-op.
        var onWake: () -> Void = {}

        /// Hosted inline (e.g. a tablet right-pane tab) rather than a sheet →
        /// drop the "Done" affordance.
        var embedded: Bool = false

        // Is this the currently-active (connected-to) endpoint?
        private var isActive: Bool { store.endpoint == server.endpoint }
        private var connected: Bool { isActive && store.harness.canIssueCommands }

        // Sessions belong to the connected endpoint; only the active box can
        // enumerate them.
        private var sessionsOnBox: [ProjectSession] {
            isActive ? store.sessions : []
        }

        private var statusText: (String, Color) {
            guard isActive else { return ("tap reconnect", neon.textFaint) }
            switch store.harness {
            case .live, .linked:         return ("connected", neon.green)
            case .connecting:            return ("connecting…", neon.yellow)
            case .reconnecting:          return ("reconnecting…", neon.yellow)
            case .disconnected, .failed: return ("offline", neon.textFaint)
            }
        }

        var body: some View {
            Group {
                if embedded {
                    content
                } else {
                    NavigationStack {
                        content
                            .navigationTitle("Box health")
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar {
                                ToolbarItem(placement: .confirmationAction) {
                                    Button("Done") { dismiss() }
                                }
                            }
                            .tint(neon.accent)
                    }
                }
            }
            .appearanceColorScheme()
        }

        private var content: some View {
            ZStack {
                GlassAppBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        header
                        healthSection
                        sessionsSection
                        limitsPointer
                        actionRow
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 18)
                }
            }
        }

        // MARK: Header — name · host · status chip

        private var header: some View {
            let (text, color) = statusText
            return HStack(spacing: 11) {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill((connected ? neon.green : neon.accent).opacity(0.12))
                    .frame(width: 38, height: 38)
                    .overlay(
                        Image(systemName: "server.rack")
                            .font(.system(size: 17))
                            .foregroundStyle(connected ? neon.green : neon.accent)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(server.name)
                        .font(neon.sans(17).weight(.bold))
                        .foregroundStyle(neon.text)
                        .neonTextGlow(neon.textGlow)
                        .lineLimit(1)
                    Text(server.endpoint.displayHost)
                        .font(neon.mono(11))
                        .foregroundStyle(neon.textFaint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                HStack(spacing: 5) {
                    Circle().fill(color).frame(width: 7, height: 7)
                        .neonGlowBox(connected && neon.glow ? neon.glowBox?.tinted(neon.green) : nil)
                    Text(text)
                        .font(neon.mono(11).weight(.semibold))
                        .foregroundStyle(color)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Capsule().fill(color.opacity(0.12)))
                .overlay(Capsule().strokeBorder(color.opacity(0.28), lineWidth: 1))
            }
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .neonCardSurface(
                neon,
                fill: connected ? neon.green.opacity(neon.dark ? 0.06 : 0.04) : neon.surface,
                cornerRadius: 14,
                border: connected ? neon.green.opacity(0.27) : neon.border
            )
        }

        // MARK: Health — HONEST "metrics not reported" state
        //
        // The reference shows CPU / MEM / DISK rings. We keep the three-ring
        // layout (so the surface matches the design) but render each ring
        // dimmed at 0 with a "—" value, because no host-metrics frame exists.

        private var healthSection: some View {
            VStack(alignment: .leading, spacing: 10) {
                Text("Health")
                    .font(neon.mono(11).weight(.bold))
                    .foregroundStyle(neon.textDim)
                    .textCase(.uppercase)
                    .tracking(1.2)
                HStack(spacing: 12) {
                    unavailableRing(label: "CPU")
                    unavailableRing(label: "MEM")
                    unavailableRing(label: "DISK")
                }
                HStack(spacing: 7) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(neon.textFaint)
                    Text("metrics not reported by this box")
                        .font(neon.mono(11))
                        .foregroundStyle(neon.textFaint)
                }
                .padding(.top, 2)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .neonCardSurface(neon, fill: neon.surface, cornerRadius: 14)
        }

        // A dimmed ring — same arc idiom as the Session Info context ring
        // (`ConduitUsageCard.contextRing`): two stacked `Circle`s, the
        // trimmed accent arc rotated -90°. Here the arc is empty (no data)
        // and rendered in the faint border color, value shown as "—".
        private func unavailableRing(label: String) -> some View {
            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .stroke(neon.border, lineWidth: 7)
                    Circle()
                        .trim(from: 0, to: 0)
                        .stroke(neon.textFaint, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Text("—")
                        .font(neon.mono(18).weight(.bold))
                        .foregroundStyle(neon.textFaint)
                }
                .frame(width: 64, height: 64)
                .opacity(0.8)
                Text(label)
                    .font(neon.mono(10).weight(.semibold))
                    .foregroundStyle(neon.textFaint)
                    .tracking(1.0)
            }
            .frame(maxWidth: .infinity)
        }

        // MARK: Sessions on this box

        private var sessionsSection: some View {
            VStack(alignment: .leading, spacing: 10) {
                Text("Sessions here")
                    .font(neon.mono(11).weight(.bold))
                    .foregroundStyle(neon.textDim)
                    .textCase(.uppercase)
                    .tracking(1.2)
                if !isActive {
                    emptyHint("reconnect to view this box's sessions")
                } else if sessionsOnBox.isEmpty {
                    emptyHint("no sessions running on this box")
                } else {
                    VStack(spacing: 8) {
                        ForEach(sessionsOnBox, id: \.id) { session in
                            sessionRow(session)
                        }
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .neonCardSurface(neon, fill: neon.surface, cornerRadius: 14)
        }

        private func sessionRow(_ session: ProjectSession) -> some View {
            let tint = neon.agentTint(forAgent: session.assistant)
            let phase = store.statusBySession[session.id]?.phase
            return HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(tint.opacity(0.14))
                    .frame(width: 26, height: 26)
                    .overlay(Circle().fill(tint).frame(width: 7, height: 7))
                VStack(alignment: .leading, spacing: 1) {
                    Text(store.displayName(for: session))
                        .font(neon.sans(13).weight(.semibold))
                        .foregroundStyle(neon.text)
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        Text(session.assistant.lowercased())
                            .font(neon.mono(10.5))
                            .foregroundStyle(tint)
                        if let phase, !phase.isEmpty {
                            Text("· \(phase)")
                                .font(neon.mono(10.5))
                                .foregroundStyle(neon.textFaint)
                                .lineLimit(1)
                        }
                    }
                }
                Spacer(minLength: 6)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(neon.textFaint)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .neonCardSurface(
                neon,
                fill: tint.opacity(neon.dark ? 0.06 : 0.04),
                cornerRadius: 11,
                border: tint.opacity(0.22)
            )
        }

        private func emptyHint(_ text: String) -> some View {
            Text(text)
                .font(neon.mono(11.5))
                .foregroundStyle(neon.textFaint)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
        }

        // MARK: Account-wide limits pointer (NO per-box quota — data-model rule)

        private var limitsPointer: some View {
            HStack(spacing: 8) {
                Image(systemName: "gauge.with.dots.needle.33percent")
                    .font(.system(size: 12))
                    .foregroundStyle(neon.textFaint)
                Text("Plan limits are account-wide, not per box — see Settings.")
                    .font(neon.mono(11))
                    .foregroundStyle(neon.textFaint)
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .neonCardSurface(neon, fill: neon.surface, cornerRadius: 12)
        }

        // MARK: Actions — Reconnect · SSH · Wake

        private var actionRow: some View {
            HStack(spacing: 12) {
                actionButton(systemImage: "arrow.clockwise", label: "Reconnect", action: onReconnect)
                actionButton(systemImage: "terminal", label: "SSH", action: onSSH)
                actionButton(systemImage: "power", label: "Wake", action: onWake)
            }
        }

        private func actionButton(systemImage: String, label: String, action: @escaping () -> Void) -> some View {
            Button(action: action) {
                HStack(spacing: 7) {
                    Image(systemName: systemImage)
                        .font(.system(size: 14, weight: .semibold))
                    Text(label)
                        .font(neon.sans(13).weight(.semibold))
                }
                .foregroundStyle(neon.accent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .neonCardSurface(neon, fill: neon.surface, cornerRadius: 12, border: neon.borderStrong)
            }
            .buttonStyle(.plain)
        }
    }
}
