import SwiftUI

// MARK: - ConduitHomeView
//
// Conduit-faithful home screen. Mirrors upstream's HomeDashboardView in
// structure (top row with chrome icons, server pill row, sessions list,
// bottom action bar with mic/+/search) but uses our own data layer.
//
// Visual decisions:
//   - Top row: 36pt glass-circle icon buttons left/right, centered
//     ConduitMark daemon logo.
//   - Server pill row: horizontal scroll of capsule pills, ending in
//     a "+" pill. Selected pill carries the brand tint.
//   - Sessions list: flat rows (no card chrome), separator-less.
//     A solid status circle replaces the bubble. Title in body
//     weight, subtitle in mono caption.
//   - Bottom action bar: anchored at the bottom-safe-area, three
//     controls (mic / + / search). "+" is the prominent FAB.

extension ConduitUI {

    struct HomeView: View {
        @Environment(SessionStore.self) private var store
        @Environment(AppearanceStore.self) private var appearance
        @Environment(\.colorScheme) private var colorScheme
        @Environment(\.neonTheme) private var neon

        @State private var showSettings = false
        @State private var showAddServer = false
        @State private var showSearch = false
        @State private var showAgentPicker = false
        @State private var showSessionsHistory = false
        /// Command palette (⌘K) opened from the bottom action-bar search.
        @State private var showCommandPalette = false
        /// Fan-out surface, launched from the command palette.
        @State private var showFanOut = false
        /// Pipeline builder, launched from the command palette.
        @State private var showPipelineBuilder = false
        /// Approvals inbox, opened from the needs-you banner's Review.
        @State private var showApprovals = false
        /// Box selected from the Boxes list → Box health detail sheet.
        @State private var selectedBox: SavedServer?
        /// WS-H.2: SSH re-bootstrap sheet triggered from the broker-update banner.
        @State private var showSshReBoot = false
        /// Voice dictation (bottom mic). On a transcript we stash it here
        /// and open the agent picker seeded with it as the first prompt.
        /// Also reused by the command-palette "Run on box" action (same seed-prompt path).
        @State private var showVoiceDictation = false
        @State private var voicePrompt: String?
        /// Set to true when the command palette's "Run on box" action fires so
        /// we can defer presenting the agent picker until AFTER the palette
        /// sheet fully dismisses (avoids the iOS double-sheet race).
        @State private var pendingRunOnBox = false
        @State private var selectedSessionID: String?
        /// Confirmation alert state for the session-row swipe-to-delete.
        /// `.alert(item:)` needs an Identifiable, so we wrap the target
        /// session id (`Identifiable` via the inner struct).
        @State private var pendingDelete: PendingSessionDelete?
        /// Shows the onboarding guide (re-opened from the no-boxes CTA or
        /// Settings "How it works" row).
        @State private var showOnboarding = false

        var body: some View {
            @Bindable var store = store

            NavigationStack {
                ZStack {
                    GlassAppBackground()
                    VStack(spacing: 12) {
                        topRow
                        homeList
                        bottomBar
                    }
                    .padding(.top, 8)
                    .navigationDestination(item: $selectedSessionID) { id in
                        if let session = store.sessions.first(where: { $0.id == id }) {
                            ConduitUI.ProjectView(session: session)
                        } else {
                            Color.clear
                        }
                    }
                    .navigationDestination(isPresented: $showSessionsHistory) {
                        // Sessions-history surface is the legacy
                        // `SessionsScreen` (now in `Sources/Shared/`).
                        // A upstream-faithful rebuild is a follow-up;
                        // for now we expose the existing one as a
                        // navigation push so the affordance keeps
                        // working post-cutover.
                        SessionsScreen().environment(store)
                    }
                }
                .sheet(isPresented: $showSettings) {
                    ConduitUI.SettingsView(onOpenOnboarding: {
                        showSettings = false
                        showOnboarding = true
                    })
                    .presentationDetents([.medium, .large])
                }
                .sheet(isPresented: $showAddServer) {
                    ConduitUI.AddServerSheet()
                        .presentationDetents([.medium, .large])
                }
                .sheet(isPresented: $showAgentPicker, onDismiss: { voicePrompt = nil }) {
                    ConduitUI.AgentPickerSheet(initialPrompt: voicePrompt)
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
                    // Drive navigation through the same local
                    // `selectedSessionID` a home-row tap uses; setting
                    // only `store.selectedSessionID` races the sheet
                    // dismissal and the push never fires on iPhone.
                    SessionSearchView(onSelect: { id in
                        showSearch = false
                        store.selectedSessionID = id
                        selectedSessionID = id
                    })
                    .environment(store)
                }
                .sheet(isPresented: $showCommandPalette, onDismiss: {
                    // "Run on box" defers opening the agent picker until the
                    // palette sheet finishes dismissing to avoid the iOS
                    // double-sheet presentation race.
                    if pendingRunOnBox {
                        pendingRunOnBox = false
                        showAgentPicker = true
                    }
                }) {
                    // ⌘K quick switcher. Reuses the same new-session /
                    // add-server / select-session paths the rest of Home uses.
                    // "Fan out a task" chains into the Fan-out surface.
                    // "Run on box" seeds a new session with the typed text as
                    // the first message, via the agent picker (same path as
                    // voice dictation).
                    ConduitUI.CommandPaletteSheet(
                        onNewSession: {
                            if store.harness.canIssueCommands { showAgentPicker = true } else { showAddServer = true }
                        },
                        onPairBox: { showAddServer = true },
                        onOpenSession: { id in
                            store.selectedSessionID = id
                            selectedSessionID = id
                        },
                        onRunOnBox: { text in
                            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !t.isEmpty else { return }
                            Telemetry.breadcrumb("palette", "run_on_box_tapped", data: ["has_text": "true"])
                            if store.harness.canIssueCommands {
                                voicePrompt = t      // reuse the shared seed-prompt state
                                pendingRunOnBox = true
                            } else {
                                showAddServer = true
                            }
                        },
                        onFanOut: { showFanOut = true },
                        onNewPipeline: { showPipelineBuilder = true }
                    )
                    .environment(store)
                    .presentationDetents([.medium, .large])
                }
                .sheet(isPresented: $showFanOut) {
                    // One task → N parallel sessions, one per branch. Launch is
                    // real: createSession per branch (no fan-out backend).
                    ConduitUI.FanOutView(
                        onLaunch: { task, branches in
                            for branch in branches {
                                store.createSession(assistant: "claude", branch: branch, initialPrompt: task)
                            }
                        }
                    )
                    .environment(store)
                    .presentationDetents([.medium, .large])
                }
                .sheet(isPresented: $showPipelineBuilder) {
                    // Multi-step pipeline builder. Navigates internally to
                    // PipelineMonitorView on success.
                    ConduitUI.PipelineBuilderView()
                        .environment(store)
                        .presentationDetents([.large])
                }
                .sheet(isPresented: $showApprovals) {
                    // Approvals inbox — every action opens the session's chat
                    // (no programmatic approve endpoint), so wire onOpenSession
                    // to select + dismiss.
                    ConduitUI.ApprovalsView(
                        onOpenSession: { id in
                            showApprovals = false
                            store.selectedSessionID = id
                            selectedSessionID = id
                        }
                    )
                    .environment(store)
                    .presentationDetents([.medium, .large])
                }
                .sheet(item: $selectedBox) { server in
                    // Per-box health detail. Reconnect reuses the same
                    // select-server path a box-row tap used before.
                    // onOpenedSession: dismiss the box-health sheet so the
                    // user lands directly on the adopted session's chat.
                    ConduitUI.BoxHealthView(
                        server: server,
                        onReconnect: { store.selectSavedServer(server.id, autoConnect: true) },
                        onOpenedSession: { selectedBox = nil }
                    )
                    .environment(store)
                    .presentationDetents([.medium, .large])
                }
                // WS-H.2: SSH re-bootstrap sheet, triggered from the broker-update banner.
                .sheet(isPresented: $showSshReBoot) {
                    SSHLoginSheet()
                        .environment(store)
                        .presentationDetents([.medium, .large])
                }
                // Onboarding guide — re-opened from the no-boxes CTA or Settings.
                .fullScreenCover(isPresented: $showOnboarding) {
                    ConduitUI.OnboardingView(onFinish: { showOnboarding = false })
                        .environment(store)
                }
                .alert(
                    "Archive session?",
                    isPresented: Binding(
                        get: { pendingDelete != nil },
                        set: { if !$0 { pendingDelete = nil } }
                    ),
                    presenting: pendingDelete
                ) { target in
                    Button("Archive") {
                        store.archive(sessionID: target.id)
                        pendingDelete = nil
                    }
                    Button("Cancel", role: .cancel) {
                        pendingDelete = nil
                    }
                } message: { target in
                    Text("Ends \(target.title) on the server and keeps it in History (read-only). Delete it permanently from History.")
                }
                .alert(
                    "Session failed to start",
                    isPresented: Binding(
                        get: { store.sessionCreationError != nil },
                        set: { if !$0 { store.sessionCreationError = nil } }
                    )
                ) {
                    Button("OK", role: .cancel) {
                        store.sessionCreationError = nil
                    }
                } message: {
                    if let err = store.sessionCreationError {
                        Text(err)
                    }
                }
                .onChange(of: store.selectedSessionID) { _, new in
                    selectedSessionID = new
                }
                .onAppear {
                    if !store.endpoint.isComplete {
                        // Fresh install (no paired brokers): the onboarding fullScreenCover
                        // owns first-run. Opening Settings here collides with that cover and
                        // dismisses it, landing the user on Settings instead of onboarding.
                        // Only auto-open Settings for an already-paired device whose active
                        // endpoint is somehow incomplete (e.g. corrupted keychain entry).
                        if !store.savedServers.isEmpty { showSettings = true }
                    } else if store.harness == .disconnected {
                        store.connect()
                    }
                }
                .tint(neon.accent)
            }
            // Keyboard opt-out at the NAVIGATION-CONTAINER level. Device
            // feedback round 3 (screen recording): on the Terminal tab the
            // soft keyboard still pushed the WHOLE app up (~the accessory-bar
            // height) — header clipped under the Dynamic Island — even though
            // ProjectView's own root already ignores `.keyboard` (v0.0.106).
            // The residual shift comes from the NavigationStack's hosting
            // layer, which performs its own keyboard avoidance on the pushed
            // destination; a destination-level `.ignoresSafeArea` can't reach
            // it. Opting out on the stack itself pins the chrome. Safe
            // because no inline editor relies on implicit avoidance: the chat
            // composer manual-lifts (`keyboardInset`), the terminal reserves
            // its own overlap (`sizeLayer`), History's search field is
            // top-anchored, and every other editor lives in a sheet (separate
            // presentation layer, unaffected by this modifier).
            .ignoresSafeArea(.keyboard, edges: .bottom)
        }

        // MARK: Subviews

        private var topRow: some View {
            // Conduit parity (audit §A.1.6) put settings behind a hidden
            // long-press on the brand mark — undiscoverable in practice
            // (user feedback 2026-05-23). Restore a visible gear in the
            // leading slot; the long-press stays as a secondary path so
            // accessibility hints continue to work. Trailing drops the
            // search icon because the bottom action bar already carries
            // a 44pt search button — having both was a duplicate.
            ConduitUI.Header(
                leading: {
                    ConduitUI.HeaderIconButton(systemImage: "gearshape",
                                              accessibilityLabel: "Settings") {
                        showSettings = true
                    }
                },
                center: {
                    // Brand lockup: daemon mark + `>conduit` wordmark
                    // (mono 700, `>` tinted with the accent), per BRAND.md §1
                    // and the design-reference home header.
                    HStack(spacing: 8) {
                        ConduitUI.AnimatedBrandMark(size: 26)
                        (Text(">").foregroundStyle(neon.glow ? neon.accent : neon.textDim)
                            + Text("conduit").foregroundStyle(neon.text))
                            .font(neon.mono(15).weight(.bold))
                            .tracking(1)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Conduit")
                    .accessibilityHint("Press and hold for settings")
                    .onLongPressGesture(minimumDuration: 0.4) {
                        showSettings = true
                    }
                },
                trailing: {
                    ConduitUI.HeaderIconButton(systemImage: "clock.arrow.circlepath",
                                              accessibilityLabel: "Sessions history") {
                        showSessionsHistory = true
                    }
                }
            )
        }

        // MARK: Boxes (design-reference home)

        /// Mono uppercase section label (cyan) with an optional trailing action,
        /// matching the design's `ACTIVE SESSIONS` / `BOXES` headers.
        private func sectionHeader(_ title: String, actionIcon: String, actionLabel: String, actionTint: Color, action: @escaping () -> Void) -> some View {
            HStack {
                Text(title.uppercased())
                    .font(neon.mono(12).weight(.semibold))
                    .tracking(2)
                    .foregroundStyle(neon.accent)
                    .neonTextGlow(neon.glow ? neon.textGlow : nil)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 8)
                Button(action: action) {
                    HStack(spacing: 5) {
                        Image(systemName: actionIcon).font(.system(size: 12, weight: .semibold))
                        Text(actionLabel).font(neon.sans(12.5).weight(.semibold))
                    }
                    .foregroundStyle(actionTint)
                    // Round-3 §4: pad the hit area to ≥44pt tall without
                    // moving the layout (negative outer padding cancels
                    // the visual growth).
                    .padding(.vertical, 13)
                    .padding(.horizontal, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, -13)
                .padding(.horizontal, -8)
            }
            .textCase(nil)
            .listRowInsets(EdgeInsets(top: 14, leading: 14, bottom: 6, trailing: 14))
            .listRowBackground(Color.clear)
        }

        /// A paired-machine ("box") row: tinted server glyph, name, endpoint sub,
        /// and a status word. The active (connected) machine is pinned first and
        /// styled active — an `ACTIVE` badge + `connected` and a green-tinted
        /// surface — folding in what used to be a separate connection card
        /// (design handoff §3a). Per-box rows never show quota: plan limits are
        /// per-account, surfaced ambiently elsewhere (§3b).
        private func boxRow(_ server: SavedServer) -> some View {
            let isActive = store.endpoint == server.endpoint
            let connected = isActive && store.harness.canIssueCommands
            // store.sessions is a MIXED list (it retains other-box rows as
            // dimmed history), so a plain .count over-counts. Count only THIS
            // box's live sessions via the per-box stamp — correct for the
            // active box AND for non-active boxes (their stamps persist).
            let sessionCount = store.liveSessionCount(forBox: server.id)
            let (statusText, statusColor): (String, Color) = {
                guard isActive else { return ("tap to connect", neon.textFaint) }
                // Use visibleHarness for display: suppresses "reconnecting..." during
                // the 4s post-foreground grace window (Change 4).
                switch store.visibleHarness {
                case .live, .linked:
                    let plural = sessionCount == 1 ? "session" : "sessions"
                    return ("connected · \(sessionCount) \(plural)", neon.green)
                case .connecting:      return ("connecting…", neon.yellow)
                case .reconnecting:    return ("reconnecting…", neon.yellow)
                case .disconnected, .failed: return ("offline", neon.textFaint)
                }
            }()
            let glyphColor = connected ? neon.green : (isActive ? neon.accent : neon.textFaint)
            return HStack(spacing: 11) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(glyphColor.opacity(0.12))
                    .frame(width: 30, height: 30)
                    .overlay(
                        Image(systemName: "server.rack")
                            .font(.system(size: 14))
                            .foregroundStyle(glyphColor)
                    )
                VStack(alignment: .leading, spacing: 1) {
                    Text(server.name)
                        .font(neon.sans(13).weight(.semibold))
                        .foregroundStyle(connected ? neon.green : neon.text)
                        .lineLimit(1)
                    // Show the real SSH host:port for SSH-tunnelled boxes;
                    // loopback address is the tunnel, not the actual machine.
                    if let ssh = server.ssh {
                        Text("\(ssh.host):\(ssh.port)")
                            .font(neon.mono(10.5))
                            .foregroundStyle(neon.textFaint)
                            .lineLimit(1)
                    } else {
                        Text(server.endpoint.displayHost)
                            .font(neon.mono(10.5))
                            .foregroundStyle(neon.textFaint)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                if isActive {
                    Text("ACTIVE")
                        .font(neon.mono(9).weight(.bold))
                        .tracking(0.8)
                        .foregroundStyle(neon.green)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(neon.green.opacity(0.14)))
                }
                HStack(spacing: 5) {
                    Circle().fill(statusColor).frame(width: 6, height: 6)
                        .neonGlowBox(connected && neon.glow ? neon.glowBox?.tinted(neon.green) : nil)
                    Text(statusText)
                        .font(neon.mono(11))
                        .foregroundStyle(statusColor)
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 9)
            .neonCardSurface(
                neon,
                fill: connected ? neon.green.opacity(neon.dark ? 0.07 : 0.05) : neon.surface,
                cornerRadius: 12,
                border: connected ? neon.green.opacity(0.27) : neon.border,
                glowTint: connected && neon.glow ? neon.green : nil
            )
        }

        private var snapshot: ConduitUI.HomeSnapshot {
            let endpointHost = store.endpoint.isComplete ? store.endpoint.displayHost : nil
            let harness: ConduitUI.HomeSnapshotHarness = {
                // Use visibleHarness so the snapshot suppresses "reconnecting"
                // during the post-foreground grace window (Change 4).
                switch store.visibleHarness {
                case .disconnected: return .disconnected
                case .connecting:   return .connecting
                case .linked, .live: return .live
                case .reconnecting: return .reconnecting
                case .failed(let reason): return .failed(reason)
                }
            }()
            // Only badge session rows with their box name when more than one
            // box is configured — a single box has nothing to disambiguate.
            let hasMultipleBoxes = store.savedServers.count > 1
            let sessions = store.sessions.map { s in
                let status = store.statusBySession[s.id]
                // Last-ACTIVITY timestamp for the relative stamp + row sort.
                // Priority (most-trustworthy "last message" first):
                //   1. the last live conversation-log item's `ts` (the real
                //      last-message time);
                //   2. the session's own `lastActivityAt` / `startedAt`
                //      (broker-stamped session metadata that survives
                //      reboot);
                //   3. only as a LAST RESORT the status'
                //      `lastActivityAt` / `startedAt` — on a cold-boot
                //      reconnect this is the CONNECTION time, not a real
                //      message, so it must not win (it made every row read
                //      "just now" and broke the sort).
                let lastActivity = lastMessageTimestamp(for: s.id)
                    ?? s.lastActivityAt
                    ?? s.startedAt
                    ?? status?.lastActivityAt
                    ?? status?.startedAt
                let cwd = status?.cwd ?? s.cwd
                let isCurrentBox = store.isSessionOnCurrentBox(s.id)
                return ConduitUI.HomeSnapshotSession(
                    id: s.id,
                    displayName: store.displayName(for: s),
                    assistant: s.assistant,
                    phase: status?.phase,
                    lastActivityAt: lastActivity,
                    // Drop the ephemeral per-session work dir; only a real
                    // user-picked cwd surfaces in the row.
                    workingDir: SessionNaming.meaningfulWorkingDir(cwd),
                    lastActivityPreview: latestActivityPreview(for: s.id),
                    // Amber "starting" until the broker confirms the session
                    // is interactive (~30s cold-boot window).
                    isConfirmedLive: store.isConfirmedLive(sessionID: s.id),
                    isCurrentBox: isCurrentBox,
                    // Badge EVERY row with its box name when more than one box
                    // exists, so attribution is always visible (the previous
                    // `isCurrentBox ? nil` suppression hid the current box's
                    // name and made multi-box lists ambiguous). With a single
                    // box there's nothing to disambiguate, so stay nil.
                    boxName: hasMultipleBoxes ? store.boxDisplayName(for: s.id) : nil
                )
            }
            let placeholders = store.visibleSessions.compactMap { v -> ConduitUI.HomeSnapshotPlaceholder? in
                guard case .creating(let id) = v else { return nil }
                return ConduitUI.HomeSnapshotPlaceholder(id: id, label: "Starting session...")
            }
            return ConduitUI.HomeSnapshot(
                harness: harness,
                sessions: sessions,
                placeholders: placeholders,
                selectedSessionID: store.selectedSessionID,
                endpointDisplayHost: endpointHost
            )
        }

        /// The Home "needs you" banner state, or nil when no session is
        /// awaiting the user. Routes through `store.hasPendingAsk` (the same
        /// resolution-aware gate used for answer routing) so a resolved
        /// pending_input no longer keeps the banner up. Pure string-based
        /// `HomeViewModel.isAwaitingInput`/`needsYouBanner` are kept for
        /// unit tests; here we use the richer store gate.
        private var needsYouBanner: ConduitUI.NeedsYouBanner? {
            let items = store.sessions.compactMap { s -> ConduitUI.NeedsYouBanner.Item? in
                guard store.hasPendingAsk(sessionID: s.id) else { return nil }
                return ConduitUI.NeedsYouBanner.Item(
                    id: s.id,
                    title: store.displayName(for: s),
                    agent: s.assistant
                )
            }
            let banner = ConduitUI.NeedsYouBanner(sessions: items)
            return banner.count > 0 ? banner : nil
        }

        /// One-line preview of the latest activity in a session for the
        /// home card. Pulls the most recent NON-user transcript item from
        /// `store.conversationLog` (assistant reply or tool action) — the
        /// first user message is already the card title, so this surfaces
        /// "what's happening" instead. Returns nil when the log carries
        /// nothing but the user's prompts (or is empty), so the card simply
        /// drops the line. Condensing lives in the pure view-model so it's
        /// unit-testable.
        ///
        /// When the typed conversation log is empty but the raw chatLog
        /// carries a system install-progress message (the broker emits
        /// "Installing <agent>..." before the session is interactive), that
        /// message is surfaced so the row shows real progress instead of
        /// sitting blank while the user waits.
        private func latestActivityPreview(for sessionID: String) -> String? {
            if let log = store.conversationLog[sessionID], !log.isEmpty,
               let latest = log.last(where: { $0.role.lowercased() != "user" }) {
                return ConduitUI.HomeViewModel.activityPreview(
                    role: latest.role,
                    kind: latest.kind,
                    toolName: latest.toolName,
                    command: latest.command,
                    content: latest.content
                )
            }
            // Fallback: surface an on-demand install progress message from the
            // raw chatLog so the row is never blank during a slow install.
            if let chatEvents = store.chatLog[sessionID],
               let sysEvent = chatEvents.last(where: { $0.role.lowercased() == "system" }),
               !sysEvent.content.isEmpty {
                return sysEvent.content
            }
            return nil
        }

        /// The broker-stamped `ts` of the most recent item in this session's
        /// live conversation log — the real "last message" time. nil when
        /// the log is empty (e.g. a freshly-reattached session whose
        /// transcript hasn't replayed yet), so the snapshot falls back to
        /// the session's own metadata rather than the reconnect-set status
        /// timestamp. Items are appended in broker-clock order, so `.last`
        /// is the freshest; its `ts` is a non-optional broker timestamp.
        private func lastMessageTimestamp(for sessionID: String) -> String? {
            guard let last = store.conversationLog[sessionID]?.last else { return nil }
            let ts = last.ts
            return ts.isEmpty ? nil : ts
        }

        /// The design-reference home body as one sectioned, scrollable List:
        /// "Active sessions" → "Boxes" (the connected box is pinned first and
        /// styled active — no separate connection card). Session rows keep
        /// swipe-to-archive / tap-to-open; box rows tap to connect.
        @ViewBuilder
        private var homeList: some View {
            let snap = snapshot
            let rows = ConduitUI.HomeViewModel.rows(snap)
            List {
                // Ambient account-usage strip (design handoff §B.10) — per-agent
                // plan headroom (`claude 62% · codex 28%`) at a glance, above the
                // session list. Self-hides when no agent carries usage data yet.
                if store.accountUsageByAgent.contains(where: { $0.hasData }) {
                    Section {
                        ConduitUI.HomeUsageStrip()
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 6, leading: 14, bottom: 2, trailing: 14))
                    }
                }

                // "Needs you" banner (handoff §B.5 / §B.10) — surfaces ONLY when a
                // real signal exists: a session whose last transcript item is an
                // unanswered agent `pending_input` (approval prompt / options
                // menu). Never a fabricated "1 waiting"; hidden when none.
                if let banner = needsYouBanner, banner.count > 0 {
                    Section {
                        NeedsYouBannerCard(banner: banner) {
                            // Review opens the Approvals inbox (the queue of
                            // blocked sessions) rather than jumping straight
                            // into the first session.
                            showApprovals = true
                        }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 4, leading: 14, bottom: 4, trailing: 14))
                    }
                }

                Section {
                    if rows.isEmpty {
                        // Distinguish "still loading the broker's live set" from
                        // "genuinely no sessions" so we don't flash the empty
                        // state on launch before reconcile lands.
                        Group {
                            if store.isLoadingSessions {
                                loadingSessionsView()
                            } else {
                                emptySessionsView(snap)
                            }
                        }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14))
                    } else {
                        ForEach(rows) { row in
                            HomeRowView(row: row)
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(
                                    top: HomeRowMetrics.interRowSpacing / 2,
                                    leading: 14,
                                    bottom: HomeRowMetrics.interRowSpacing / 2,
                                    trailing: 14
                                ))
                                .opacity(row.isCurrentBox ? 1.0 : 0.55)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    if case .session(let id) = row.kind {
                                        if row.isCurrentBox {
                                            store.selectedSessionID = id
                                            selectedSessionID = id
                                        } else {
                                            // Cross-box session: switch to its
                                            // box first, then open the chat.
                                            Telemetry.breadcrumb("session",
                                                "cross_box_tap_switch",
                                                data: ["session": id,
                                                       "box": row.boxName ?? "?"])
                                            if let server = store.server(for: id) {
                                                store.selectSavedServer(server.id, autoConnect: true)
                                                store.selectedSessionID = id
                                                selectedSessionID = id
                                            }
                                        }
                                    }
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    if case .session(let id) = row.kind {
                                        Button {
                                            pendingDelete = PendingSessionDelete(id: id, title: row.title)
                                        } label: {
                                            Label("Archive", systemImage: "archivebox")
                                        }
                                        .tint(neon.textDim)
                                    }
                                }
                                .contextMenu {
                                    if case .session(let id) = row.kind {
                                        Button {
                                            pendingDelete = PendingSessionDelete(id: id, title: row.title)
                                        } label: {
                                            Label("Archive", systemImage: "archivebox")
                                        }
                                    }
                                }
                        }
                    }
                } header: {
                    sectionHeader("Active sessions", actionIcon: "plus", actionLabel: "New session", actionTint: neon.accent) {
                        if store.harness.canIssueCommands { showAgentPicker = true } else { showAddServer = true }
                    }
                }

                // No-boxes CTA: surface the onboarding guide for first-run
                // users who land here without any paired boxes.
                if store.savedServers.isEmpty {
                    Section {
                        noBoxesCTA
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 4, leading: 14, bottom: 8, trailing: 14))
                    } header: {
                        sectionHeader("Boxes", actionIcon: "wifi", actionLabel: "Pair box", actionTint: neon.textDim) {
                            showAddServer = true
                        }
                    }
                }

                if !store.savedServers.isEmpty {
                    // One machine = one row. Connected box styled active
                    // (ACTIVE badge + `connected`), then other saved boxes.
                    let boxes = store.savedServers.filter { $0.endpoint == store.endpoint }
                        + store.savedServers.filter { $0.endpoint != store.endpoint }
                    Section {
                        ForEach(boxes) { server in
                            boxRow(server)
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 4, leading: 14, bottom: 4, trailing: 14))
                                .contentShape(Rectangle())
                                .onTapGesture { selectedBox = server }
                        }
                        // WS-H.2 (session-safe): broker-update banner.
                        // SSH boxes: show when `pendingBrokerUpdate` is set for
                        // the active box (the auto-update was deferred due to
                        // live sessions) OR when the broker is stale with 0
                        // live sessions (silent update already in flight — show
                        // nothing). Token boxes: show whenever broker is stale
                        // vs the app version.
                        let appVer = BuildInfo.marketingVersion
                        if let pending = store.pendingBrokerUpdate,
                           pending.boxID == store.savedServers.first(where: { $0.endpoint == store.endpoint })?.id {
                            // SSH box, deferred update — user must confirm.
                            ConduitUI.BrokerUpdateBanner(
                                brokerVersion: pending.brokerVersion,
                                isSshPaired: true,
                                liveCount: pending.liveCount,
                                onRebootstrap: { store.confirmAndUpdateBroker() }
                            )
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 4, leading: 14, bottom: 4, trailing: 14))
                        } else if let bv = store.brokerReadiness?.brokerVersion,
                                  case .updateAvailable = brokerVersionStatus(
                                      brokerVersion: bv,
                                      minimumVersion: appVer
                                  ),
                                  store.savedServers.first(where: { $0.endpoint == store.endpoint })?.ssh == nil {
                            // Token-paired box: no auto-update path, show copy banner.
                            let liveCount = store.liveSessionCount(
                                forBox: store.savedServers.first(where: { $0.endpoint == store.endpoint })?.id ?? ""
                            )
                            ConduitUI.BrokerUpdateBanner(
                                brokerVersion: bv,
                                isSshPaired: false,
                                liveCount: liveCount,
                                onRebootstrap: {}
                            )
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 4, leading: 14, bottom: 4, trailing: 14))
                        }
                    } header: {
                        sectionHeader("Boxes", actionIcon: "wifi", actionLabel: "Pair box", actionTint: neon.textDim) {
                            showAddServer = true
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .refreshable {
                store.reconcileLiveSessions()
                while store.isLoadingSessions {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
        }

        /// No-boxes CTA card: shown under BOXES when the user has no paired
        /// machine yet. A prominent prompt to open the onboarding guide.
        private var noBoxesCTA: some View {
            Button {
                Telemetry.breadcrumb("home", "no_boxes_cta_tapped")
                showOnboarding = true
            } label: {
                HStack(spacing: 11) {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(neon.accent.opacity(0.12))
                        .frame(width: 34, height: 34)
                        .overlay(
                            Image(systemName: "sparkles")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(neon.accent)
                        )
                    VStack(alignment: .leading, spacing: 2) {
                        Text("New here? See how it works")
                            .font(neon.sans(13).weight(.semibold))
                            .foregroundStyle(neon.text)
                            .lineLimit(1)
                        Text("Add a box to start running agents on your machines")
                            .font(neon.mono(10.5))
                            .foregroundStyle(neon.textDim)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 6)
                    Text("Open guide")
                        .font(neon.sans(12).weight(.semibold))
                        .foregroundStyle(neon.accentText)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(neon.accent))
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 9)
                .neonCardSurface(
                    neon,
                    fill: neon.accent.opacity(neon.dark ? 0.07 : 0.05),
                    cornerRadius: 12,
                    border: neon.accent.opacity(0.27),
                    glowTint: neon.glow ? neon.accent : nil
                )
            }
            .buttonStyle(.plain)
        }

        @ViewBuilder
        private func emptySessionsView(_ snap: ConduitUI.HomeSnapshot) -> some View {
            VStack(spacing: 10) {
                Image(systemName: ConduitUI.HomeViewModel.emptySymbol(snap))
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(neon.accent)
                    .neonTextGlow(neon.textGlow)
                Text(ConduitUI.HomeViewModel.emptyTitle(snap))
                    .font(neon.sans(16).weight(.semibold))
                    .foregroundStyle(neon.text)
                Text(ConduitUI.HomeViewModel.emptyBody(snap))
                    .font(neon.sans(13))
                    .foregroundStyle(neon.textDim)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
        }

        /// Shown in place of the empty state while the broker's live-session
        /// set is being fetched + reattached on launch, so a session-having
        /// user sees "Restoring sessions…" rather than a misleading "No
        /// sessions yet" that then pops into a populated list.
        private func loadingSessionsView() -> some View {
            VStack(spacing: 12) {
                ProgressView()
                    .tint(neon.accent)
                Text("Restoring sessions…")
                    .font(neon.sans(13))
                    .foregroundStyle(neon.textDim)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        }

        private var bottomBar: some View {
            // PLAN-CONDUIT-VISUAL-PARITY PR 3, audit §A.1.5: upstream wraps
            // the bottom bar in TWO `GlassMorphContainer`s so the `+`
            // can morph into a composer without the surrounding
            // mic / search merging into the same glass blob. All three
            // controls drop to a single 44pt — the prior 56pt copper-
            // outlined plus was over-built relative to upstream.
            HStack(spacing: 14) {
                ConduitUI.GlassMorphContainer(spacing: 14) {
                    ConduitUI.PillButton(systemImage: "mic.fill", size: 44, tint: neon.accent) {
                        showVoiceDictation = true
                    }
                }
                Spacer()
                ConduitUI.GlassMorphContainer(spacing: 14) {
                    ConduitUI.PillButton(
                        systemImage: "plus",
                        size: 44,
                        tint: neon.accent,
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
                ConduitUI.GlassMorphContainer(spacing: 14) {
                    ConduitUI.PillButton(systemImage: "magnifyingglass", size: 44, tint: neon.accent) {
                        showCommandPalette = true
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 4)
        }
    }
}

/// The Home "needs you" banner (design handoff §B.10, image 12): an
/// amber-tinted card that appears ONLY when a real signal exists — one or
/// more sessions whose agent is blocked on the user (an unanswered
/// `pending_input`). Title counts the waiting sessions; the sub names the
/// agent/session; `Review` opens the first one. Hidden entirely when no
/// session is waiting (gated by the caller), so it never shows a fake count.
private struct NeedsYouBannerCard: View {
    let banner: ConduitUI.NeedsYouBanner
    let onReview: () -> Void
    @Environment(\.neonTheme) private var neon

    private var titleText: String {
        banner.count == 1 ? "1 session waiting on you" : "\(banner.count) sessions waiting on you"
    }

    private var subText: String {
        if banner.count == 1, let first = banner.sessions.first {
            return "\(first.agent) needs your input on \(first.title)"
        }
        return "agents are blocked on your input"
    }

    var body: some View {
        Button(action: onReview) {
            HStack(spacing: 11) {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(neon.claude.opacity(0.14))
                    .frame(width: 34, height: 34)
                    .overlay(
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(neon.claude)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(titleText)
                        .font(neon.sans(13).weight(.semibold))
                        .foregroundStyle(neon.text)
                        .lineLimit(1)
                    Text(subText)
                        .font(neon.mono(10.5))
                        .foregroundStyle(neon.textDim)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 6)
                Text("Review")
                    .font(neon.sans(12.5).weight(.semibold))
                    .foregroundStyle(neon.bg)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(neon.claude))
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 9)
            .neonCardSurface(
                neon,
                fill: neon.claude.opacity(neon.dark ? 0.07 : 0.05),
                cornerRadius: 12,
                border: neon.claude.opacity(0.27),
                glowTint: neon.glow ? neon.claude : nil
            )
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(titleText)
        .accessibilityHint("Opens the session waiting on you")
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

/// Row metrics extracted as named constants so `ConduitHomeRowGeometry
/// Tests` can pin them. Changing any of these silently re-grows / re-
/// shrinks the home list, which is exactly the drift the rebuild PR
/// is trying to stop. Typography (title/subtitle) stays upstream-faithful
/// (audit §A.1.1); the row chrome is a contained glass card (styling
/// polish — the prior flat row left the status dot floating outside the
/// row's content to the left and read as tall/empty).
enum HomeRowMetrics {
    static let titlePointSize: CGFloat = 13
    static let subtitlePointSize: CGFloat = 11
    static let indicatorSize: CGFloat = 7
    /// Leading daemon-avatar (ConduitMark tinted per agent) box size.
    static let avatarSize: CGFloat = 38
    /// The selected row gets a brand-tinted card; an unselected row keeps
    /// the neutral glass surface. Both share `cardCornerRadius`.
    static let cardCornerRadius: CGFloat = 12
    /// Internal card padding — the status dot + text live INSIDE this, so
    /// nothing floats against the screen gutter.
    static let cardHorizontalPadding: CGFloat = 12
    static let cardVerticalPadding: CGFloat = 9
    /// Gap between the leading status dot and the text column.
    static let dotTextSpacing: CGFloat = 10
    /// Vertical gap between stacked cards in the list.
    static let interRowSpacing: CGFloat = 6
    /// Brand tint opacity on the selected card.
    static let selectedTintOpacity: Double = 0.22
}

private struct HomeRowView: View {
    let row: ConduitUI.HomeRow
    @Environment(\.neonTheme) private var neon

    /// Agent-tinted leading rail / glow for the row.
    private var agentTint: Color { neon.agentTint(forAgent: row.agent) }

    var body: some View {
        HStack(alignment: .top, spacing: HomeRowMetrics.dotTextSpacing) {
            // Per-design (screens.jsx SessionRow): the leading element is a
            // daemon avatar — the ConduitMark tinted with the agent color —
            // in a soft tinted rounded-square, with a small run-state dot.
            avatar
            VStack(alignment: .leading, spacing: 3) {
                // Prominent friendly name. 13pt semibold per audit §A.1.1
                // (upstream-faithful density); single line, truncating.
                Text(row.title)
                    .font(neon.sans(HomeRowMetrics.titlePointSize).weight(.semibold))
                    .foregroundStyle(neon.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                secondaryLine
                activityPreviewLine
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, HomeRowMetrics.cardHorizontalPadding)
        .padding(.vertical, HomeRowMetrics.cardVerticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .neonCardSurface(
            neon,
            fill: row.isSelected ? agentTint.opacity(neon.dark ? 0.18 : 0.12) : neon.surface,
            cornerRadius: HomeRowMetrics.cardCornerRadius,
            border: row.isSelected ? agentTint.opacity(0.55) : neon.borderStrong,
            glowTint: row.isSelected ? agentTint : nil
        )
        .contentShape(RoundedRectangle(cornerRadius: HomeRowMetrics.cardCornerRadius, style: .continuous))
    }

    /// Secondary line: agent chip · status (tinted by run state) ·
    /// relative time, with an optional real cwd. Caption2-sized (11pt)
    /// per audit §A.1.1. Replaces the old `"agent · phase · host"` mono
    /// string — the host wasn't useful and the row never carried a
    /// meaningful path.
    @ViewBuilder
    private var secondaryLine: some View {
        switch row.kind {
        case .creatingPlaceholder:
            Text(row.statusText)
                .font(neon.mono(HomeRowMetrics.subtitlePointSize))
                .foregroundStyle(neon.textFaint)
                .lineLimit(1)
        case .session:
            HStack(spacing: 5) {
                if !row.agent.isEmpty {
                    Text(row.agent)
                        .font(neon.mono(HomeRowMetrics.subtitlePointSize).weight(.semibold))
                        .foregroundStyle(agentTint)
                }
                statusDot
                    .frame(width: 5, height: 5)
                Text(row.statusText)
                    .font(neon.sans(HomeRowMetrics.subtitlePointSize))
                    .foregroundStyle(statusColor)
                if !row.relativeTime.isEmpty {
                    Text("·")
                        .font(neon.sans(HomeRowMetrics.subtitlePointSize))
                        .foregroundStyle(neon.textFaint)
                    Text(row.relativeTime)
                        .font(neon.mono(HomeRowMetrics.subtitlePointSize))
                        .foregroundStyle(neon.textFaint)
                }
                if let dir = row.workingDir {
                    Text("·")
                        .font(neon.sans(HomeRowMetrics.subtitlePointSize))
                        .foregroundStyle(neon.textFaint)
                    Text(dirLeaf(dir))
                        .font(neon.mono(HomeRowMetrics.subtitlePointSize))
                        .foregroundStyle(neon.textFaint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                // Box badge: shows which box owns this session. Set on EVERY
                // row (including the current box) when more than one box exists
                // so attribution is always unambiguous; nil for single-box.
                if let boxName = row.boxName {
                    Spacer(minLength: 0)
                    Text(boxName)
                        .font(neon.mono(HomeRowMetrics.subtitlePointSize - 0.5).weight(.semibold))
                        .foregroundStyle(neon.accent)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(neon.accent.opacity(0.12)))
                        .lineLimit(1)
                }
            }
            .lineLimit(1)
        }
    }

    /// Third line: a one-line preview of the latest activity (most recent
    /// assistant reply / tool action) so the user can tell active sessions
    /// apart and see "what's happening" at a glance. The title is the
    /// FIRST user message; this complements it. Muted, single-line,
    /// truncating; renders nothing when there's no preview (placeholder
    /// rows, or a transcript with only the user's prompt).
    @ViewBuilder
    private var activityPreviewLine: some View {
        if case .session = row.kind, !row.lastActivityPreview.isEmpty {
            Text(row.lastActivityPreview)
                .font(neon.sans(HomeRowMetrics.subtitlePointSize))
                .foregroundStyle(neon.textDim)
                .lineLimit(2)
                .truncationMode(.tail)
        }
    }

    /// Final path component of a cwd, for the compact dir label.
    private func dirLeaf(_ path: String) -> String {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        return trimmed.split(separator: "/").last.map(String.init) ?? trimmed
    }

    /// Run-state tint shared by the status word and its inline dot.
    /// Green when confirmed-live, amber while the broker is still bringing
    /// the session up ("starting" — the ~30s cold-boot window where the
    /// chat composer is gated), muted otherwise (idle / exited).
    private var statusColor: Color {
        if row.isRunning { return neon.green }
        if row.isStarting { return neon.yellow }
        return neon.textFaint
    }

    private var statusDot: some View {
        Circle().fill(statusColor)
    }

    /// Daemon avatar: the ConduitMark tinted with the agent color in a soft
    /// tinted rounded-square, with a small bottom-trailing run-state dot.
    /// Matches the design-reference SessionRow leading element.
    @ViewBuilder
    private var avatar: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(agentTint.opacity(neon.dark ? 0.14 : 0.10))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(agentTint.opacity(0.35), lineWidth: 1)
            )
            .frame(width: HomeRowMetrics.avatarSize, height: HomeRowMetrics.avatarSize)
            .overlay {
                switch row.kind {
                case .creatingPlaceholder:
                    ProgressView().controlSize(.small).tint(agentTint)
                case .session:
                    ConduitUI.ConduitMark(size: HomeRowMetrics.avatarSize - 14, color: agentTint, glow: neon.glow)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if case .session = row.kind {
                    Circle()
                        .fill(dotColor)
                        .frame(width: 8, height: 8)
                        .overlay(Circle().stroke(neon.surface, lineWidth: 1.5))
                        .offset(x: 3, y: 3)
                }
            }
    }

    @ViewBuilder
    private var indicator: some View {
        switch row.kind {
        case .creatingPlaceholder:
            // ProgressView is bigger than 7pt natively; clip into the
            // indicator frame so the row vertical rhythm doesn't break.
            ProgressView()
                .controlSize(.mini)
                .tint(neon.accent)
        case .session:
            // 7pt filled circle per audit §A.1.7 — green when the agent
            // is confirmed-live (with a neon glow), amber while it's still
            // starting up (cold-boot window), muted once it has exited.
            // Driven by run state, not selection (device bug #9): every
            // running session shows green, not just the attached one.
            // Selection is conveyed by the row's background fill. The glow
            // is reserved for the confirmed-live (green) state only.
            Circle()
                .fill(dotColor)
                .neonGlowBox(row.isRunning && neon.glow ? neon.glowBox?.tinted(neon.green) : nil)
        }
    }

    /// Status-dot fill shared by the avatar badge and the trailing
    /// indicator: green (live) / amber (starting) / dim (idle / exited).
    private var dotColor: Color {
        if row.isRunning { return neon.green }
        if row.isStarting { return neon.yellow }
        return neon.textFaint.opacity(0.5)
    }
}
