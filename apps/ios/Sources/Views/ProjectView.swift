import SwiftUI

enum ProjectTab: String, CaseIterable, Identifiable {
    case terminal, chat, browser
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var systemImage: String {
        switch self {
        case .terminal: return "terminal"
        case .chat:     return "bubble.left.and.bubble.right"
        case .browser:  return "safari"
        }
    }
}

struct ProjectView: View {
    @Environment(SessionStore.self) private var store
    @Environment(AppearanceStore.self) private var appearance
    let session: ProjectSession

    @State private var tab: ProjectTab = .terminal
    @State private var browserMode: BrowserMode = .preview
    @State private var showInfo: Bool = false
    @State private var showAgentPicker: Bool = false
    @State private var showThreadSwitcher: Bool = false
    @State private var showVoice: Bool = false
    /// Alt entry into the rename sheet: long-press the nav title in the
    /// toolbar. Mirrors the pencil affordance on the Info sheet — same
    /// `RenameSessionSheet` is presented either way.
    @State private var showRename: Bool = false
    @State private var renameDraft: String = ""
    /// Transient "Voice not wired here" capsule rendered above the
    /// in-session dock when the user taps the FAB on a tab whose route
    /// doesn't accept text (browser today). Cleared after a short
    /// delay so the bar returns to its resting three-icon state.
    @State private var voiceToast: String? = nil

    var body: some View {
        VStack(spacing: 10) {
            header
            tabContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .glassRoundedRect()
                .clipShape(RoundedRectangle(cornerRadius: SweKittyTheme.cardCornerRadius, style: .continuous))
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 0)
        // Persistent in-session dock — visible across Terminal / Chat /
        // Browser tabs. `safeAreaInset` parks it above the keyboard so
        // it slides up with focus rather than getting buried. The
        // ChatTab composer's own `safeAreaInset` stacks above this
        // dock when chat is active, so both stay visible together.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            InSessionBottomBar(
                context: InSessionContext(tab),
                onThreads: { showThreadSwitcher = true },
                onVoice: { showVoice = true },
                onNewSession: { showAgentPicker = true },
                transientNote: voiceToast
            )
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Single-line title only — the prior "claude · Remote control"
            // subtitle duplicated the agent pill ("claude medium") that
            // already sits one row below in the header card. Dropping it
            // saves a row of vertical chrome and removes redundant text.
            ToolbarItem(placement: .principal) {
                Text(navTitle)
                    .font(.headline)
                    .foregroundStyle(SweKittyTheme.textPrimary)
                    .lineLimit(1)
                    .contentShape(Rectangle())
                    .onLongPressGesture(minimumDuration: 0.4) {
                        renameDraft = store.displayName(for: session)
                        showRename = true
                    }
                    .accessibilityHint("Long-press to rename this session")
            }
        }
        .tint(SweKittyTheme.accentStrong)
        .sheet(isPresented: $showInfo) {
            SessionInfoView(session: session)
                .environment(store)
                .presentationDetents([.large])
        }
        .sheet(isPresented: $showAgentPicker) {
            AgentPickerSheet(headerNote: nil).environment(store)
        }
        .sheet(isPresented: $showThreadSwitcher) {
            ThreadSwitcherSheet(activeSession: session).environment(store)
        }
        .sheet(isPresented: $showVoice) {
            VoiceDictationSheet { transcript in
                routeVoice(transcript: transcript)
            }
        }
        .sheet(isPresented: $showRename) {
            RenameSessionSheet(
                sessionID: session.id,
                draft: renameDraft
            )
            .environment(store)
            .presentationDetents([.medium])
        }
    }

    /// Per-tab voice routing. Stage 5: chat → `sendChat`, terminal →
    /// `sendInput` (LF-terminated stdin write), browser → "not wired
    /// here" toast. The routing matrix lives on `InSessionBottomBarModel`
    /// so the SwiftUI body has nothing to decide and tests can pin it
    /// without a host controller.
    private func routeVoice(transcript: String) {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let context = InSessionContext(tab)
        switch InSessionBottomBarModel.voiceRoute(for: context) {
        case .chat:
            store.sendChat(sessionID: session.id, message: trimmed)
        case .terminalInput:
            // Feed the transcript as a line-terminated stdin write so
            // the agent CLI in the PTY sees a complete command rather
            // than a partial line waiting for Enter. LF matches the
            // existing `cd … && pwd` seed in `createSession`.
            let line = trimmed.hasSuffix("\n") ? trimmed : trimmed + "\n"
            store.sendInput(sessionID: session.id, bytes: Data(line.utf8))
        case .browserToast:
            // No browser surface accepts text input today — surface
            // the "not wired here" toast so the user gets feedback
            // instead of a no-op.
            let msg = InSessionBottomBarModel.voiceUnsupportedMessage(for: context)
            withAnimation(.easeInOut(duration: 0.15)) {
                voiceToast = msg
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_800_000_000)
                withAnimation(.easeInOut(duration: 0.2)) {
                    voiceToast = nil
                }
            }
        }
    }

    private var status: SessionStatus? { store.statusBySession[session.id] }

    /// Friendly first-line title. Prefer the user-supplied
    /// `displayName` (set via `rename_session`, protocol §3.3, or by
    /// the local rename map for un-synced labels); fall back to
    /// `session.name` (typically the workspace folder); fall back
    /// further to the agent label so a fresh UUID-named session still
    /// reads like a project, not internal plumbing.
    private var navTitle: String {
        let candidates: [String?] = [
            session.displayName,
            store.displayNames[session.id],
        ]
        for raw in candidates {
            if let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
               !trimmed.isEmpty {
                return trimmed
            }
        }
        let trimmed = session.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == session.id {
            return "swe-kitty"
        }
        return trimmed
    }

    private var lifecycle: SessionLifecycle? { store.sessionLifecycle[session.id] }

    /// Litter Stage 2 header — three explicit rows.
    ///
    /// Row 1 (`controlsRow`): centered compound agent dropdown (status dot ·
    ///   agent name · reasoning effort · chevron.down) with two glass-capsule
    ///   icon circles (refresh + info) trailing. Back button stays in the
    ///   NavigationStack toolbar so the leading slot is intentionally empty
    ///   in the ZStack and the pill reads as the visual center.
    /// Row 2 (`pathRow`): one-line `path · branch · running` mono caption
    ///   (built from `captionLabel`), middle-truncated, muted — keeps PR A's
    ///   single-line tightening inside the new three-row factoring.
    /// Row 3 (`tabPickerRow`): Terminal / Chat / Browser segmented picker
    ///   wrapped in a subtle glass surface and heightened so it reads as
    ///   the primary affordance — this is "the main idea per chat window."
    private var header: some View {
        VStack(spacing: 4) {
            controlsRow
            pathRow
            tabPickerRow
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxHeight: ProjectHeaderModel.maxHeight)
        .glassRoundedRect()
    }

    /// Row 1 — control bar. ZStack so the compound agent dropdown is
    /// truly centered regardless of trailing icon width, matching litter.
    ///
    /// The trailing cluster carries a `ViewerCountBadge` ahead of the
    /// refresh + info circles. The badge is invisible at `nil` / `0` /
    /// `1` (gated inside `ViewerCountBadgeModel`), so rendering it
    /// unconditionally is safe — it only reserves space once a second
    /// viewer is actually attached and the broker emits the count.
    private var controlsRow: some View {
        ZStack {
            agentPill
            HStack(spacing: 6) {
                Spacer()
                ViewerCountBadge(count: viewerCount)
                refreshButton
                infoButton
            }
        }
    }

    /// Bridge the UniFFI-typed `viewers: UInt32?` field on `SessionStatus`
    /// to the `Int?` the badge model takes. `nil` here means the broker
    /// hasn't broadcast a count yet (older harness or first frame not
    /// arrived); the badge stays hidden in that case.
    private var viewerCount: Int? {
        status?.viewers.map { Int($0) }
    }

    /// Row 2 — single mono caption combining `path · branch · running`
    /// (and any lifecycle label). Preserves PR A's tightening inside the
    /// new three-row factoring: one line, middle-truncated, muted.
    private var pathRow: some View {
        Text(captionLabel)
            .font(.caption2.monospaced())
            .foregroundStyle(SweKittyTheme.textMuted)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    /// Row 3 — tab picker. Wrapped in a glass surface and side-padded so
    /// it reads as the dominant affordance in the header.
    private var tabPickerRow: some View {
        tabPicker
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .glassRoundedRect(cornerRadius: SweKittyTheme.smallCornerRadius)
    }

    private var pathLabel: String {
        // Real cwd now threads from the harness status frame. Fall back
        // to the session name (typically the workspace folder) when
        // the harness hasn't emitted one yet (older builds).
        if let cwd = session.cwd?.trimmingCharacters(in: .whitespaces), !cwd.isEmpty {
            return cwd
        }
        return session.name
    }

    /// One-line `path · branch · running` caption used directly beneath
    /// the agent pill. Replaces the prior split (icon + path on its own
    /// row, then subtitle on a second row) so the header sheds vertical
    /// chrome and the tab picker climbs closer to the top.
    private var captionLabel: String {
        let parts: [String] = [
            pathLabel,
            session.branch.flatMap { $0.isEmpty ? nil : $0 } ?? "no branch",
            status?.phase ?? "ready",
            lifecycleLabel,
        ].compactMap { $0 }
        return parts.joined(separator: " · ")
    }

    private var lifecycleLabel: String? {
        switch lifecycle {
        case .exited(let c): return "exited(\(c))"
        case .failed(let m): return m
        case .creating, .live, .none: return nil
        }
    }

    /// Litter-style centered agent pill: health dot, agent name,
    /// reasoning effort, then a small chevron.down. Tapping opens the
    /// shared AgentPickerSheet (same surface used from Home).
    private var agentPill: some View {
        Button {
            showAgentPicker = true
        } label: {
            HStack(spacing: 6) {
                HealthDot(health: status?.health ?? "unknown", size: 8)
                Text(session.assistant)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(SweKittyTheme.textPrimary)
                Text(reasoningEffort)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(SweKittyTheme.textSecondary)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(SweKittyTheme.textSecondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .glassCapsule(interactive: true, tint: SweKittyTheme.accent(forAgent: session.assistant).opacity(0.32))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Switch agent")
    }

    /// Reasoning effort surfaced by the harness status frame. Falls
    /// back to "medium" when the harness hasn't emitted one (older
    /// builds) so the pill always reads something.
    private var reasoningEffort: String {
        if let raw = session.reasoningEffort?.trimmingCharacters(in: .whitespaces), !raw.isEmpty {
            return raw
        }
        return "medium"
    }

    /// Trailing icon button — glass-capsule circle to match litter's
    /// per-icon container treatment. Reused by both refresh + info.
    private func headerIconButton(systemImage: String, accessibility: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(SweKittyTheme.accentStrong)
                .frame(width: 32, height: 32)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassCircle()
        .accessibilityLabel(accessibility)
    }

    private var refreshButton: some View {
        // Note: SessionStore has no `refresh(sessionID:)` method, so
        // we fall back to `reconnect()` which re-establishes the
        // harness stream and re-emits the session snapshot.
        headerIconButton(systemImage: "arrow.clockwise", accessibility: "Reconnect") {
            store.reconnect()
        }
    }

    private var infoButton: some View {
        headerIconButton(systemImage: "info.circle", accessibility: "Session info") {
            showInfo = true
        }
    }

    /// The Terminal / Chat / Browser segmented picker. Plan calls for this
    /// to be visually heightened — it's the per-session "main idea" for
    /// SweKitty (we keep it where litter only has a single chat surface).
    private var tabPicker: some View {
        Picker("View", selection: $tab) {
            ForEach(ProjectTab.allCases) { t in
                Label(t.label, systemImage: t.systemImage).tag(t)
            }
        }
        .pickerStyle(.segmented)
        .controlSize(.large)
    }

    @ViewBuilder
    private var tabContent: some View {
        switch tab {
        case .terminal:
            // Stage 0 of the terminal-renderer rewrite: the
            // `experimentalNativeTerminal` flag swaps the xterm.js path
            // for the Ghostty-libghostty scaffold. Off by default;
            // xterm.js remains the production renderer. See
            // docs/PLAN-TERMINAL-REWRITE.md.
            if appearance.experimentalNativeTerminal {
                GhosttyTerminalTab(session: session)
            } else {
                TerminalTabXterm(session: session)
            }
        case .chat:     ChatTab(session: session)
        case .browser:  BrowserTab(session: session, mode: browserMode)
        }
    }
}

/// Pure-data description of the litter Stage 2 header. Lifted out of
/// the SwiftUI view so unit tests can assert the three-row structure
/// and the compound-dropdown contents without standing up a host
/// controller. The view body references the same computed values, so
/// drift between the model and the rendered surface is loud.
struct ProjectHeaderModel: Equatable {
    /// Three rows, in render order. Matches the litter reference and
    /// the spec in `docs/PLAN-LITTER-UI.md` Stage 2.
    enum Row: String, CaseIterable {
        case controls
        case path
        case tabPicker
    }

    static let rows: [Row] = Row.allCases

    /// Cap on the header VStack's vertical footprint, in points. Each row
    /// (compound agent pill, mono caption, segmented tab picker) has its
    /// own intrinsic height; 120pt is enough for the three plus internal
    /// padding without letting a long branch label or future row balloon
    /// the chrome and push the tab content offscreen.
    static let maxHeight: CGFloat = 120

    /// Centered compound-dropdown payload: status dot color key,
    /// agent name, reasoning-effort label, plus a chevron flag so the
    /// "this is a dropdown" affordance is asserted in tests.
    struct AgentPill: Equatable {
        let healthKey: String
        let agentName: String
        let reasoningEffort: String
        let showsChevron: Bool
    }

    let agentPill: AgentPill
    let pathLabel: String
    let pathSubtitle: String
    /// Pure-data backing for the trailing `ViewerCountBadge`. Mirrors
    /// the visibility rules so a test can assert "two viewers shows
    /// the pill" without standing up a SwiftUI host.
    let viewerBadge: ViewerCountBadgeModel

    static func from(session: ProjectSession,
                     status: SessionStatus?,
                     lifecycleLabel: String?) -> ProjectHeaderModel {
        let pathLabel: String = {
            // Path label still tracks the real cwd when present, but a
            // user-supplied display name (rename_session, protocol §3.3)
            // wins over both — keeps the renamed label visible in the
            // header even when the cwd is set. Mirrors Android's
            // ProjectHeaderModel.from precedence.
            if let raw = session.displayName?.trimmingCharacters(in: .whitespaces),
               !raw.isEmpty {
                return raw
            }
            if let cwd = session.cwd?.trimmingCharacters(in: .whitespaces), !cwd.isEmpty {
                return cwd
            }
            return session.name
        }()

        let reasoning: String = {
            if let raw = session.reasoningEffort?.trimmingCharacters(in: .whitespaces), !raw.isEmpty {
                return raw
            }
            return "medium"
        }()

        let subtitleParts: [String] = [
            session.branch.flatMap { $0.isEmpty ? nil : $0 } ?? "no branch",
            status?.phase ?? "ready",
            lifecycleLabel,
        ].compactMap { $0 }

        return ProjectHeaderModel(
            agentPill: AgentPill(
                healthKey: status?.health ?? "unknown",
                agentName: session.assistant,
                reasoningEffort: reasoning,
                showsChevron: true
            ),
            pathLabel: pathLabel,
            pathSubtitle: subtitleParts.joined(separator: " · "),
            viewerBadge: ViewerCountBadgeModel(count: status?.viewers.map { Int($0) })
        )
    }
}
