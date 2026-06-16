import SwiftUI

// MARK: - ConduitBoxHealthView  (handoff §B.7 — "Box health")
//
// Per-box detail surface. The redesign reference (`images/08-box-health.png`)
// shows CPU / MEM / DISK rings + load / uptime / agent-runtime, the sessions
// running on the box, and a Reconnect · SSH action row.
//
// ── Data honesty ───────────────────────────────────────────────────────────
// Host metrics are real as of broker v0.0.111: `GET /api/host/metrics`
// (broker/internal/hostmetrics) serves CPU / MEM / DISK / load / uptime,
// advertised by the `host_metrics` capability. The screen probes the box on
// open; when the box does NOT report (older broker, non-Linux, unreachable)
// the entire health section is hidden — device feedback explicitly asked for
// hide-over-dashes, replacing the earlier "—" placeholder rings.
//
// SSH is real too: brokers advertising `shell_sessions` carry a hidden
// `shell` adapter (bash in the session PTY), so the button creates a plain
// terminal session on the box and opens it (ProjectView lands shell
// sessions on the Terminal tab). The broker runs ON the box, so a local
// shell IS the box shell — no ssh hop. Wake was removed: there is no
// wake-on-LAN path to a WAN box, so the button could never act.
//
// What else is real and shown:
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
// real reconnect action:
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
// `store.selectSavedServer(_:autoConnect:)` (switch + connect). SSH is
// self-contained: `store.createSession(assistant: "shell")` on the active
// box, shown only when the box advertises `shell_sessions` and is connected.

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

        /// Probe results for THIS box (fetched on open). nil = probe not
        /// finished or box doesn't answer — dependent UI stays hidden.
        @State private var metrics: SessionStore.HostMetrics?
        @State private var features: SessionStore.BoxFeatures?

        /// Found-sessions entry card state
        @State private var showFoundSessions = false
        @State private var foundSessionsSnapshot: ConduitUI.FoundSessionsSnapshot = .empty

        /// Hosted inline (e.g. a tablet right-pane tab) rather than a sheet →
        /// drop the "Done" affordance.
        var embedded: Bool = false

        // Is this the currently-active (connected-to) endpoint?
        private var isActive: Bool { store.endpoint == server.endpoint }
        private var connected: Bool { isActive && store.harness.canIssueCommands }

        // Sessions belong to this specific box, stamped by their sessionBox map
        // entry (SavedServer.id). Only the active box can have live sessions;
        // filter by stamp to exclude sessions from other boxes that were connected
        // before (Fix 2 — cross-box sessions appeared under wrong box header).
        private var sessionsOnBox: [ProjectSession] {
            guard isActive else { return [] }
            return store.sessions.filter { store.sessionBox[$0.id] == server.id }
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
                        // Hidden (not dashed) when the box doesn't report —
                        // device feedback round 4.
                        if let metrics {
                            healthSection(metrics)
                        }
                        sessionsSection
                        if features?.sessionDiscovery == true {
                            foundSessionsSection
                        }
                        limitsPointer
                        actionRow
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 18)
                }
            }
            .task(id: server.id) {
                Telemetry.breadcrumb("box_health", "open", data: ["host": server.endpoint.displayHost])
                features = await store.fetchBoxFeatures(endpoint: server.endpoint)
                if features?.hostMetrics == true {
                    metrics = await store.fetchHostMetrics(endpoint: server.endpoint)
                }
                // Probe found sessions if the box advertises discovery. This is a
                // plain HTTP call to the broker (like host-metrics above), so it
                // must NOT be gated on the WS harness being linked -- otherwise on
                // a box that hasn't finished connecting the instant this screen
                // opens, the probe is skipped and the "Started outside Conduit"
                // card never appears even after the box goes connected.
                await probeFoundSessions()
            }
            .onChange(of: connected) { _, nowConnected in
                // A box that finishes connecting (e.g. an SSH-tunnel box whose
                // HTTP API only becomes reachable once the tunnel is up) after
                // this screen opened: re-run discovery so the card recovers from
                // an early, pre-connect attempt that came back offline/empty.
                if nowConnected, features?.sessionDiscovery == true,
                   foundSessionsSnapshot.discoveryState != .loaded {
                    Task { await probeFoundSessions() }
                }
            }
            .sheet(isPresented: $showFoundSessions) {
                ConduitUI.FoundSessionsSheet(server: server, initialSnapshot: foundSessionsSnapshot)
            }
        }

        /// Fetch the box's externally-started sessions over HTTP and fold the
        /// result into `foundSessionsSnapshot`. Safe to call repeatedly (on open
        /// and again when the box connects). No-op unless the box advertises
        /// `session_discovery`.
        @MainActor
        private func probeFoundSessions() async {
            guard features?.sessionDiscovery == true else { return }
            foundSessionsSnapshot.boxID = server.id
            foundSessionsSnapshot.boxName = server.name
            foundSessionsSnapshot.discoveryState = .scanning
            let result = await store.fetchDiscoveredSessions(endpoint: server.endpoint)
            if let result {
                foundSessionsSnapshot.sessions = result.sessions
                foundSessionsSnapshot.totalOnDisk = result.totalOnDisk
                foundSessionsSnapshot.discoveryState = result.sessions.isEmpty ? .empty : .loaded
            } else if !connected {
                foundSessionsSnapshot.discoveryState = .offline
            } else {
                foundSessionsSnapshot.discoveryState = .error("Could not reach box")
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
                    // Fix 1: for SSH-tunneled boxes the endpoint is a loopback
                    // address; show the real ssh host:port instead.
                    if let ssh = server.ssh {
                        Text("\(ssh.host):\(ssh.port)")
                            .font(neon.mono(11))
                            .foregroundStyle(neon.textFaint)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Text(server.endpoint.displayHost)
                            .font(neon.mono(11))
                            .foregroundStyle(neon.textFaint)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
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

        // MARK: Health — live CPU / MEM / DISK rings
        //
        // Rendered only when the box reported a snapshot (the section is
        // hidden otherwise — see `content`). Ring color escalates with
        // pressure: accent → yellow ≥ 75 → red ≥ 90.

        private func healthSection(_ metrics: SessionStore.HostMetrics) -> some View {
            VStack(alignment: .leading, spacing: 10) {
                Text("Health")
                    .font(neon.mono(11).weight(.bold))
                    .foregroundStyle(neon.textDim)
                    .textCase(.uppercase)
                    .tracking(1.2)
                HStack(spacing: 12) {
                    metricRing(label: "CPU", pct: metrics.cpuPct)
                    metricRing(label: "MEM", pct: metrics.memPct)
                    metricRing(label: "DISK", pct: metrics.diskPct)
                }
                if let load = metrics.load1, let up = metrics.uptimeSecs {
                    HStack(spacing: 7) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 11))
                            .foregroundStyle(neon.textFaint)
                        Text("load \(String(format: "%.2f", load)) · up \(Self.uptimeText(up))")
                            .font(neon.mono(11))
                            .foregroundStyle(neon.textFaint)
                    }
                    .padding(.top, 2)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .neonCardSurface(neon, fill: neon.surface, cornerRadius: 14)
        }

        // A live ring — same arc idiom as the Session Info context ring
        // (`ConduitUsageCard.contextRing`): two stacked `Circle`s, the
        // trimmed arc rotated -90° so it grows clockwise from 12 o'clock.
        private func metricRing(label: String, pct: Double) -> some View {
            let clamped = min(max(pct, 0), 100)
            let color: Color = clamped >= 90 ? neon.red : (clamped >= 75 ? neon.yellow : neon.accent)
            return VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .stroke(neon.border, lineWidth: 7)
                    Circle()
                        .trim(from: 0, to: clamped / 100)
                        .stroke(color, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Text("\(Int(clamped.rounded()))%")
                        .font(neon.mono(15).weight(.bold))
                        .foregroundStyle(neon.text)
                }
                .frame(width: 64, height: 64)
                Text(label)
                    .font(neon.mono(10).weight(.semibold))
                    .foregroundStyle(neon.textFaint)
                    .tracking(1.0)
            }
            .frame(maxWidth: .infinity)
        }

        /// "3d 4h" / "5h 12m" / "9m" — coarse box uptime.
        static func uptimeText(_ secs: Int64) -> String {
            let mins = secs / 60
            let hours = mins / 60
            let days = hours / 24
            if days > 0 { return "\(days)d \(hours % 24)h" }
            if hours > 0 { return "\(hours)h \(mins % 60)m" }
            return "\(mins)m"
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

        // MARK: Found sessions entry card (screen 01)

        private var foundSessionsSection: some View {
            let scanning = foundSessionsSnapshot.discoveryState == .scanning
            let count = foundSessionsSnapshot.sessions.count
            let offline = !connected
            let show = scanning || count > 0

            return Group {
                if show || offline {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("STARTED OUTSIDE CONDUIT")
                            .font(neon.mono(11).weight(.bold))
                            .foregroundStyle(neon.textDim)
                            .textCase(.uppercase)
                            .tracking(1.2)

                        Button {
                            if offline {
                                onReconnect()
                            } else {
                                showFoundSessions = true
                            }
                        } label: {
                            HStack(spacing: 11) {
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(neon.accent.opacity(0.12))
                                    .frame(width: 38, height: 38)
                                    .overlay(
                                        Image(systemName: "terminal")
                                            .font(.system(size: 16))
                                            .foregroundStyle(neon.accent)
                                    )
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Continue a session")
                                        .font(neon.sans(14).weight(.semibold))
                                        .foregroundStyle(offline ? neon.textFaint : neon.text)
                                        .lineLimit(1)
                                    if offline {
                                        Text("offline — can't scan")
                                            .font(neon.mono(11))
                                            .foregroundStyle(neon.textFaint)
                                    } else if scanning {
                                        Text("scanning...")
                                            .font(neon.mono(11))
                                            .foregroundStyle(neon.textFaint)
                                    } else {
                                        Text("\(count) found on this box — pick one up or branch a copy")
                                            .font(neon.mono(11))
                                            .foregroundStyle(neon.textFaint)
                                            .lineLimit(2)
                                    }
                                }
                                Spacer(minLength: 6)
                                if scanning && !offline {
                                    ProgressView()
                                        .tint(neon.accent)
                                        .controlSize(.small)
                                } else if !offline && count > 0 {
                                    Text("\(count)")
                                        .font(neon.mono(12).weight(.bold))
                                        .foregroundStyle(neon.bg)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Capsule().fill(neon.accent))
                                } else if !offline {
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(neon.textFaint)
                                }
                            }
                            .padding(13)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .neonCardSurface(
                            neon,
                            fill: offline ? neon.surface.opacity(0.4) : neon.accent.opacity(neon.dark ? 0.06 : 0.04),
                            cornerRadius: 12,
                            border: offline ? neon.border : neon.accent.opacity(0.3),
                            glowTint: offline ? nil : neon.accent.opacity(0.1)
                        )
                        .opacity(offline ? 0.6 : 1.0)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .neonCardSurface(neon, fill: neon.surface, cornerRadius: 14)
                }
            }
        }

        private var foundSessionsFootnote: some View {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "asterisk")
                    .font(.system(size: 9))
                    .foregroundStyle(neon.textFaint)
                    .padding(.top, 2)
                Text("Claude & Codex sessions you launched by hand in your terminal. Conduit can pick up where they left off — it doesn't drive a session that's live.")
                    .font(neon.mono(10))
                    .foregroundStyle(neon.textFaint)
            }
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

        // MARK: Actions — Reconnect · SSH
        //
        // SSH shows only when this box's broker advertises `shell_sessions`
        // AND the box is the connected one (session create rides the live
        // WS client, which is bound to the active endpoint). Wake is gone:
        // no backend can wake a WAN box, and dead buttons read as bugs
        // (device feedback round 4).

        private var actionRow: some View {
            HStack(spacing: 12) {
                actionButton(systemImage: "arrow.clockwise", label: "Reconnect", action: onReconnect)
                if features?.shellSessions == true && connected {
                    actionButton(systemImage: "terminal", label: "Shell", action: openShell)
                }
            }
        }

        /// Open a plain terminal on the box: create a `shell` session (the
        /// broker's hidden bash adapter) — `createSession` self-selects it,
        /// and ProjectView lands `shell` sessions on the Terminal tab.
        private func openShell() {
            Telemetry.breadcrumb("box_health", "shell open", data: ["host": server.endpoint.displayHost])
            store.createSession(assistant: "shell")
            dismiss()
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
