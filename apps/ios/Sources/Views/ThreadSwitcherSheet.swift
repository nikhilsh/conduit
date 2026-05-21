import SwiftUI

/// Pure-data view-model for the ThreadSwitcherSheet. Lifts the list
/// derivation out of the SwiftUI view so the tests in
/// `ThreadSwitcherTests` can pin (a) same-server filtering, (b) the
/// empty-state CTA, and (c) the multi-thread pill strip without
/// hosting a SwiftUI view tree.
///
/// **Server identity in iOS today:** `ProjectSession` doesn't carry
/// a `serverID` field on the wire — the harness only ever speaks to
/// one endpoint at a time, so every `store.sessions` entry is, by
/// construction, on the currently-connected server. The model takes
/// `currentServerID` for symmetry with litter's `ConversationThreadSwitcher`
/// (where multi-server is real) and so a future Rust core surface
/// that exposes `serverID` plugs in without a model rewrite.
struct ThreadSwitcherModel: Equatable {
    /// Sessions on the same server as the active session, excluding
    /// the active session itself. Render order = wire order.
    let sameServerSessions: [ProjectSession]
    /// Every session the client knows about (current server only on
    /// iOS today — see note above). Powers the multi-thread peek pill
    /// strip across the top of the sheet.
    let allSessions: [ProjectSession]
    /// The currently active session — used for highlight + skip in
    /// the same-server list.
    let activeSessionID: String

    /// True when the same-server list has no other sessions. Drives
    /// the empty-state "No other sessions on this server" view + CTA.
    var sameServerIsEmpty: Bool { sameServerSessions.isEmpty }

    /// Build a model from the live store. Mirrors the spec selector
    /// `store.sessions.filter { $0.serverID == session.serverID && $0.id != session.id }`
    /// with the iOS reality that all known sessions live on the
    /// current endpoint (so the filter collapses to `id != session.id`).
    static func from(allSessions: [ProjectSession],
                     activeSessionID: String,
                     currentServerID: String?) -> ThreadSwitcherModel {
        // Same-server filter: drop the active session. `currentServerID`
        // is informational for now; once a wire-side `serverID` lands
        // we'll switch this to `$0.serverID == currentServerID`.
        _ = currentServerID
        let others = allSessions.filter { $0.id != activeSessionID }
        return ThreadSwitcherModel(
            sameServerSessions: others,
            allSessions: allSessions,
            activeSessionID: activeSessionID
        )
    }
}

/// Sheet presented from `InSessionBottomBar`'s leading `square.stack`
/// button. Shows other sessions on the same server as the active
/// session, plus a horizontal pill strip across the top that peeks at
/// every parallel thread the client knows about. Tapping a session
/// switches the navigation root to it; the empty state CTA opens the
/// shared `AgentPickerSheet` to spin one up.
///
/// Visual reference: litter's `ConversationThreadSwitcher` in
/// `apps/ios/Sources/Litter/Views/`. We don't import any code from
/// there — the structure (pill strip → list → empty CTA) is the part
/// that matters.
struct ThreadSwitcherSheet: View {
    @Environment(SessionStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    let activeSession: ProjectSession

    @State private var showAgentPicker: Bool = false

    var body: some View {
        NavigationStack {
            ZStack {
                SweKittyTheme.backgroundGradient(for: colorScheme)
                    .ignoresSafeArea()

                VStack(spacing: 14) {
                    // Multi-thread peek — small chips of every session
                    // the client knows about. Tap to switch. Renders
                    // first so the user always has a one-tap path to
                    // any parallel thread, even on the empty state.
                    if !model.allSessions.isEmpty {
                        peekPillStrip
                    }

                    if model.sameServerIsEmpty {
                        emptyState
                    } else {
                        sessionList
                    }
                    Spacer(minLength: 0)
                }
                .padding(.top, 8)
            }
            .navigationTitle("Threads")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showAgentPicker) {
                AgentPickerSheet(headerNote: nil).environment(store)
            }
            .tint(SweKittyTheme.accentStrong)
        }
        .presentationDetents([.medium, .large])
    }

    /// Server identity for "this server" — derived from the saved-server
    /// list since the wire model doesn't carry one yet. nil when the
    /// current endpoint isn't in `savedServers` (e.g. first launch).
    private var currentServerID: String? {
        store.savedServers.first(where: { $0.endpoint == store.endpoint })?.id
    }

    private var model: ThreadSwitcherModel {
        ThreadSwitcherModel.from(
            allSessions: store.sessions,
            activeSessionID: activeSession.id,
            currentServerID: currentServerID
        )
    }

    // MARK: - Multi-thread peek strip

    /// Small horizontal pill strip across the top. Each pill shows
    /// the assistant's first letter inside a glass capsule, tinted by
    /// the agent accent so threads with different agents are visually
    /// distinct at a glance. Same affordance for switching as the
    /// full row list below.
    private var peekPillStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.allSessions, id: \.id) { s in
                    peekPill(s)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 2)
        }
        .accessibilityIdentifier("ThreadSwitcher.peekStrip")
    }

    private func peekPill(_ session: ProjectSession) -> some View {
        let isActive = session.id == activeSession.id
        let initial = String(session.assistant.prefix(1)).uppercased()
        let tint = SweKittyTheme.accent(forAgent: session.assistant)
        return Button {
            switchTo(session: session)
        } label: {
            Text(initial)
                .font(.caption2.monospaced().weight(.bold))
                .foregroundStyle(isActive ? SweKittyTheme.textPrimary : SweKittyTheme.textSecondary)
                .frame(width: 28, height: 28)
                .glassCapsule(
                    interactive: true,
                    tint: isActive ? tint.opacity(0.48) : tint.opacity(0.22)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Switch to \(store.displayName(for: session))")
    }

    // MARK: - Same-server list

    private var sessionList: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(model.sameServerSessions, id: \.id) { s in
                    sessionRow(s)
                }
            }
            .padding(.horizontal, 14)
        }
    }

    private func sessionRow(_ session: ProjectSession) -> some View {
        let status = store.statusBySession[session.id]
        return Button {
            switchTo(session: session)
        } label: {
            HStack(spacing: 12) {
                HealthDot(health: status?.health ?? "unknown", size: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.displayName(for: session))
                        .font(.system(.body, design: .monospaced).weight(.semibold))
                        .foregroundStyle(SweKittyTheme.textPrimary)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(session.assistant)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(SweKittyTheme.textSecondary)
                        Text("·")
                            .font(.caption)
                            .foregroundStyle(SweKittyTheme.textMuted)
                        Text(lastActivityLabel(session))
                            .font(.caption.monospaced())
                            .foregroundStyle(SweKittyTheme.textMuted)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(SweKittyTheme.textMuted)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .glassRect(cornerRadius: SweKittyTheme.smallCornerRadius)
        }
        .buttonStyle(.plain)
    }

    /// Best-effort relative-time label. The harness emits an ISO-8601
    /// `last_activity_at`; we render it as `HH:mm` when we can parse
    /// it, falling back to the session phase (matches the cadence of
    /// `HomeSessionRow.subtitle`).
    private func lastActivityLabel(_ session: ProjectSession) -> String {
        if let raw = session.lastActivityAt,
           let date = ISO8601DateFormatter().date(from: raw)
        {
            let f = DateFormatter()
            f.dateFormat = "HH:mm"
            return f.string(from: date)
        }
        return store.statusBySession[session.id]?.phase ?? "ready"
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 24)
            Image(systemName: "square.stack")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(SweKittyTheme.textSecondary)
            Text("No other sessions on this server")
                .font(.headline)
                .foregroundStyle(SweKittyTheme.textPrimary)
            Text("Spin one up to work on something else in parallel — your current session keeps running.")
                .font(.footnote)
                .foregroundStyle(SweKittyTheme.textMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button {
                showAgentPicker = true
            } label: {
                Label("New session", systemImage: "plus")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(SweKittyTheme.accentStrong)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(
                        Capsule()
                            .stroke(SweKittyTheme.accentStrong, lineWidth: 1.5)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("ThreadSwitcher.emptyCTA")

            Spacer()
        }
        .padding(.horizontal, 18)
    }

    // MARK: - Switch

    private func switchTo(session: ProjectSession) {
        guard session.id != activeSession.id else {
            dismiss()
            return
        }
        store.switchTo(sessionID: session.id)
        dismiss()
    }
}
