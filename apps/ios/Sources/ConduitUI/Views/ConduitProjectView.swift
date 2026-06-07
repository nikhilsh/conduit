import SwiftUI
import UIKit

// MARK: - ConduitProjectView
//
// Session detail in the ConduitUI tree. Conduit's reference has a single
// chat surface per session; we keep our Terminal / Chat / Browser
// trio (per the user's direction in the brief) but collapse the tab
// strip into a slim segmented control directly under the title so it
// reads as sub-nav rather than chrome.
//
// Header layout (Round-2 fix 1, Conduit_Fixes_Handoff images 01→02):
//   ONE row: ← back · [identity block: agent avatar · session name ▾ ·
//            mono `● agent · repo · branch` status line] · ⓘ info
//   The identity block is the title-menu trigger (fix 2: a popover with
//   an identity header — agent · model · branch — then Rename / Refresh /
//   Export transcript and a destructive End session). Fork and Refresh
//   are NOT header buttons (Fork is its own flow, reached from Session
//   Info; Refresh lives in the title menu), and the old full-width path
//   row is folded into the identity block's repo · branch line.
//   row 2: Terminal | Chat | Browser segmented picker
// Below: tab content (ConduitChatView for the chat tab, legacy
// TerminalTabXterm + BrowserTab for the others — the ConduitUI rebuild
// scope was the conversation + nav, not the terminal/browser
// renderers).

extension ConduitUI {

    enum ProjectTab: String, CaseIterable, Identifiable {
        case terminal
        case chat
        case browser

        var id: String { rawValue }
        var label: String {
            switch self {
            case .terminal: return "Terminal"
            case .chat:     return "Chat"
            case .browser:  return "Browser"
            }
        }
        var systemImage: String {
            switch self {
            case .terminal: return "terminal"
            case .chat:     return "bubble.left.and.bubble.right"
            case .browser:  return "globe"
            }
        }
    }

    struct ProjectView: View {
        @Environment(SessionStore.self) private var store
        @Environment(\.neonTheme) private var neon
        @Environment(\.dismiss) private var dismiss

        let session: ProjectSession
        /// Tablet 3-pane centre: render chat only (no tab strip) — the
        /// Terminal / Browser / Info surfaces live in the sibling right
        /// pane (`ConduitUI.TabletRightPane`). Phone / default = full tabs.
        var chatOnly: Bool = false

        @State private var tab: ProjectTab = .chat
        // Lazy-mount gate for the native terminal. The libghostty surface is
        // built in GhosttyTerminalView's mount; #294 made the terminal
        // ALWAYS-mounted (opacity) to keep it warm, which moved that surface
        // creation into the session-CREATE CoreAnimation commit → the
        // terminal-mount EXC_BAD_ACCESS (it crashes while you're still on the
        // Chat tab). Gate the mount until the Terminal tab is first opened:
        // session-create never touches libghostty, and once opened the
        // terminal stays mounted (opacity) so #294's no-rebuild warmth holds.
        @State private var terminalActivated = false

        /// `shell` sessions (Box health → Shell: the broker's hidden bash
        /// adapter) are pure terminals — land on the Terminal tab instead
        /// of Chat. Set via init so the first render is already terminal
        /// (an onAppear flip would flash Chat first). Mounting the terminal
        /// here is safe w.r.t. the #294 crash: the shell session's detail
        /// view mounts a runloop tick after create (see `createSession`'s
        /// deferred select), not in the create commit itself.
        init(session: ProjectSession, chatOnly: Bool = false) {
            self.session = session
            self.chatOnly = chatOnly
            let isShell = session.assistant.lowercased() == "shell"
            _tab = State(initialValue: isShell ? .terminal : .chat)
            _terminalActivated = State(initialValue: isShell)
        }
        @State private var showInfo = false
        /// Diff review sheet, opened from the header "Changes" button (shown
        /// only when the session has changes to review).
        @State private var showDiff = false
        /// Rename sheet, reached from the title menu (fix 2). Fork is no
        /// longer reachable from the header — it is a full-screen flow that
        /// lives in Session Info.
        @State private var showRename = false
        /// Title-menu popover anchored to the header identity block.
        @State private var showTitleMenu = false
        /// Destructive End-session confirmation (title menu's red row).
        @State private var showEndConfirm = false

        /// A session whose agent has exited / been archived is read-only:
        /// there's no live WS to interact with, so we collapse the detail
        /// to the chat log alone — hide the Terminal/Chat/Browser tab strip
        /// and render `ChatView` with no composer (per the user's request:
        /// "clicking on archived session should just show me the chat log").
        /// Live sessions keep the full tab strip + interactive surfaces.
        private var isReadOnly: Bool { store.isReadOnly(sessionID: session.id) }

        /// Whether the session has changes worth reviewing — gates the header
        /// "Changes" affordance. Reuses the exact signal the Diff surface
        /// itself uses: a session-level `linesAdded`/`linesRemoved` rollup, or
        /// a parseable `kind == "diff"` item in the conversation log.
        private var hasChanges: Bool {
            if (session.linesAdded ?? 0) > 0 || (session.linesRemoved ?? 0) > 0 { return true }
            return ConduitUI.DiffReviewModel.hasInlineDiff(in: store.conversationLog[session.id] ?? [])
        }

        var body: some View {
            VStack(spacing: 0) {
                header
                if !isReadOnly && !chatOnly {
                    tabStrip
                }
                Divider().background(neon.border)
                content
            }
            // Pin the top chrome (header + tab strip + divider) against the
            // keyboard. Device feedback: when the composer/keyboard appeared
            // "the whole app goes up" — the header was pushed off-screen.
            // Root cause: the chat content opts out of keyboard avoidance and
            // lifts ONLY its composer manually (see ConduitChatView's
            // `keyboardInset`), but this PARENT VStack still participated in
            // SwiftUI's implicit bottom-safe-area reduction when the IME
            // showed, so the layout system shrank the available height and
            // shifted the entire stack — header included — upward. Ignoring
            // the `.keyboard` region here keeps the chrome fixed; the composer
            // is the only thing that tracks the keyboard (via its own inset),
            // exactly the intended behaviour. The chat tab can never leave
            // `.chat` (read-only collapses to the log), so this doesn't strand
            // a keyboard-tracking surface that needs the avoidance.
            .ignoresSafeArea(.keyboard, edges: .bottom)
            // Full-bleed neon canvas for the notch / home-indicator, but
            // scope to `.container` so it does NOT ignore the `.keyboard`
            // region — a default `.ignoresSafeArea()` (regions: .all)
            // here suppressed keyboard avoidance for the chat composer's
            // `.safeAreaInset(.bottom)`, leaving it hidden behind the soft
            // keyboard (device bug #19).
            .background(GlassAppBackground().ignoresSafeArea(.container, edges: .all))
            .navigationBarBackButtonHidden(true)
            .toolbar(.hidden, for: .navigationBar)
            // Round-3 §5: hiding the nav bar disables UIKit's edge-swipe
            // back; this zero-size hook re-arms the interactive pop
            // (full left edge, parallax, ~40% commit + light haptic).
            .background(ConduitUI.SwipeBackEnabler().frame(width: 0, height: 0))
            // Dismiss the keyboard on every tab switch. The Terminal tab's
            // WKWebView owns a custom inputAccessoryView (the terminal key
            // bar); without this, switching Terminal→Chat left that
            // keyboard up and the chat composer inherited the dirty state
            // and disappeared (device bug #31). A clean slate per tab.
            .onChange(of: tab) { _, newTab in
                dismissKeyboard()
                // First time the Terminal tab opens, allow the native terminal
                // to mount (and stay mounted thereafter). Deliberate, outside
                // the session-create CA commit.
                if newTab == .terminal { terminalActivated = true }
            }
            .sheet(isPresented: $showInfo) {
                ConduitUI.SessionInfoView(session: session)
            }
            .sheet(isPresented: $showDiff) {
                // Diff review for this session. Commit/PR CTAs stay default
                // no-ops — no backend action exists yet.
                ConduitUI.DiffReviewView(session: session)
                    .environment(store)
            }
            .sheet(isPresented: $showRename) {
                ConduitUI.RenameSessionSheet(
                    session: session,
                    initialDraft: store.displayName(for: session)
                )
            }
            // Centered `.alert` (not `.confirmationDialog`) for the same
            // reason as SessionInfoView: dialogs anchored to a popover
            // trigger mis-point on iPad; an alert always centers.
            .alert("End this session?", isPresented: $showEndConfirm) {
                Button("End session", role: .destructive) {
                    store.archive(sessionID: session.id)
                    if !chatOnly { dismiss() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The agent stops and the box is released. The transcript stays in History.")
            }
        }

        private func dismissKeyboard() {
            // Force-resign via `endEditing(true)` rather than the
            // `sendAction(resignFirstResponder)` broadcast: the Terminal
            // tab's WKWebView (and the native GhosttyRenderView, a
            // UIKeyInput) hold the keyboard with their own input views and
            // do NOT reliably honour the responder-chain broadcast, so
            // switching Terminal→Chat left their keyboard up and the chat
            // composer rendered behind it (device bug #31, round 2).
            // `endEditing(true)` walks the window and forces the current
            // first responder + descendants to resign — the documented
            // hammer for a stuck keyboard owned by a UIView.
            //
            // Device feedback v0.0.49 #3: a SINGLE synchronous pass loses a
            // race when leaving Terminal — the WKWebView/Ghostty input view
            // can re-assert (or finish resigning) on the next runloop,
            // leaving the keyboard up over the freshly-laid-out Chat
            // composer (which owns no first responder, so SwiftUI's
            // keyboard-avoidance never lifts it). Fire once now and again
            // on the next runloop so the late resign also lands.
            endAllEditing()
            DispatchQueue.main.async { endAllEditing() }
        }

        private func endAllEditing() {
            for scene in UIApplication.shared.connectedScenes {
                guard let windowScene = scene as? UIWindowScene else { continue }
                for window in windowScene.windows {
                    window.endEditing(true)
                }
            }
        }

        // MARK: Header (single row — fix 1)

        private var header: some View {
            HStack(spacing: 10) {
                // Tablet 3-pane centre (chatOnly): the sessions rail owns
                // navigation and the right pane owns Session Info, so the
                // back chevron and the ⓘ info button here are dead/redundant
                // — hide them. Phone keeps both (back pops the nav stack; ⓘ
                // is the only route to Session Info).
                if !chatOnly {
                    // Plain chevron, no circle (fix 1 — the circled back
                    // button crowded the row). Round-3 §4: the glyph stays
                    // 16pt but the tappable frame is ≥44×44 — the back
                    // button at the screen edge was the worst offender.
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(neon.text)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Back")
                }

                // Identity title block — THE menu trigger (fix 2). Avatar +
                // session name (+ caret) over a one-line mono status:
                // `● agent · repo · branch`. This folds the old full-width
                // path row into the identity; there is no separate path line.
                Button {
                    showTitleMenu = true
                } label: {
                    HStack(spacing: 9) {
                        avatarTile(size: 34, markSize: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 5) {
                                Text(store.displayName(for: session))
                                    .font(neon.sans(16).weight(.bold))
                                    .foregroundStyle(neon.text)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(neon.textFaint)
                            }
                            HStack(spacing: 5) {
                                Circle()
                                    .fill(statusColor)
                                    .frame(width: 5, height: 5)
                                    .neonGlowBox(neon.glow ? neon.glowBox?.tinted(statusColor) : nil)
                                Text(session.assistant.lowercased())
                                    .font(neon.mono(11).weight(.semibold))
                                    .foregroundStyle(agentTint)
                                if let context = repoContextLine {
                                    Text("·")
                                        .font(neon.mono(11))
                                        .foregroundStyle(neon.textFaint)
                                    Text(context)
                                        .font(neon.mono(11))
                                        .foregroundStyle(neon.textFaint)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                }
                            }
                        }
                    }
                    // Round-3 §4: the ENTIRE title block (avatar + name +
                    // caret + status line) is one ≥44pt-tall target.
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Session details")
                .popover(isPresented: $showTitleMenu, arrowEdge: .top) {
                    titleMenu
                        .presentationCompactAdaptation(.popover)
                }

                Spacer(minLength: 8)

                // ONE trailing ⓘ → Session Info (fix 1). Fork and Refresh are
                // deliberately NOT here: Fork is a full-screen flow inside
                // Session Info, Refresh lives in the title menu.
                if !chatOnly {
                    headerIcon("info.circle", tint: neon.textDim, label: "Session info") {
                        showInfo = true
                    }
                }
            }
            // Was 14 — the back/info frames grew by ~6–7pt per side for
            // their 44pt hit areas, so the edge padding shrinks to keep
            // the GLYPHS visually where they were (round-3 §4).
            .padding(.horizontal, 8)
            .padding(.top, 12)
            .padding(.bottom, 8)
        }

        /// Agent avatar tile: the daemon mark tinted to the agent color on a
        /// soft rounded-square (same treatment as SessionInfoView's identity
        /// hero, sized for the header / menu).
        private func avatarTile(size: CGFloat, markSize: CGFloat) -> some View {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .fill(agentTint.opacity(neon.dark ? 0.14 : 0.10))
                .frame(width: size, height: size)
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                        .stroke(agentTint.opacity(0.35), lineWidth: 1)
                )
                .overlay(ConduitUI.ConduitMark(size: markSize, color: agentTint, glow: neon.glow))
                .neonGlowBox(neon.glow ? neon.glowBox?.tinted(agentTint) : nil)
        }

        /// Circular neon icon button used in the header slots.
        private func headerIcon(
            _ systemName: String,
            weight: Font.Weight = .semibold,
            tint: Color,
            label: String,
            action: @escaping () -> Void
        ) -> some View {
            Button(action: action) {
                Image(systemName: systemName)
                    .font(.system(size: 14, weight: weight))
                    .foregroundStyle(tint)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(neon.surface))
                    .overlay(Circle().stroke(neon.borderStrong, lineWidth: 1))
                    .neonGlowBox(neon.glow ? neon.glowBox : nil)
                    // Round-3 §4: the 32pt circle stays as drawn; the
                    // tappable frame extends to ≥44×44 around it.
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
        }

        // MARK: Title menu (fix 2)

        /// Popover opened by the identity title block. Leads with a REAL
        /// identity header — agent avatar · agent name · model line, plus a
        /// mono `repo · branch` sub-line (no more "claude / claude") — then
        /// hairline-separated actions (Rename · Refresh · Export transcript)
        /// and a destructive End session row. Fork is deliberately absent:
        /// it is its own full-screen flow, reached from Session Info.
        private var titleMenu: some View {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        avatarTile(size: 40, markSize: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(agentDisplayName)
                                .font(neon.sans(15).weight(.bold))
                                .foregroundStyle(neon.text)
                            Text(modelDisplay)
                                .font(neon.mono(11.5))
                                .foregroundStyle(neon.textDim)
                        }
                    }
                    if let context = repoContextLine {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.triangle.branch")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(neon.textFaint)
                            Text(context)
                                .font(neon.mono(11))
                                .foregroundStyle(neon.textFaint)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 13)

                Divider().background(neon.border)

                menuRow("pencil", "Rename") {
                    showTitleMenu = false
                    showRename = true
                }
                menuRow("arrow.clockwise", "Refresh") {
                    showTitleMenu = false
                    store.reconnect()
                }
                ShareLink(item: ConduitUI.TranscriptExport.markdown(for: session, store: store)) {
                    menuRowBody("square.and.arrow.up", "Export transcript", tint: neon.text)
                }
                .buttonStyle(.plain)
                // Diff review keeps an entry point after losing its header
                // circle (fix 1 allows only back · identity · ⓘ up top).
                // Shown only when there's something to review.
                if !chatOnly && hasChanges {
                    menuRow("plus.forwardslash.minus", "View changes") {
                        showTitleMenu = false
                        showDiff = true
                    }
                }

                Divider().background(neon.border)

                menuRow("trash", "End session", tint: neon.red) {
                    showTitleMenu = false
                    showEndConfirm = true
                }
            }
            .frame(width: 264)
            .presentationBackground(neon.surfaceSolid)
        }

        private func menuRow(
            _ systemName: String,
            _ label: String,
            tint: Color? = nil,
            action: @escaping () -> Void
        ) -> some View {
            Button(action: action) {
                menuRowBody(systemName, label, tint: tint ?? neon.text)
            }
            .buttonStyle(.plain)
        }

        private func menuRowBody(_ systemName: String, _ label: String, tint: Color) -> some View {
            HStack(spacing: 11) {
                Image(systemName: systemName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(tint == neon.text ? neon.textDim : tint)
                    .frame(width: 20)
                Text(label)
                    .font(neon.sans(14.5).weight(.medium))
                    .foregroundStyle(tint)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }

        // MARK: Derived identity

        /// Live reasoning effort (status overrides the session's seed value).
        private var liveEffort: String? {
            store.statusBySession[session.id]?.reasoningEffort ?? session.reasoningEffort
        }

        /// Friendly agent name for the menu identity header.
        private var agentDisplayName: String {
            switch session.assistant.lowercased() {
            case "claude": return "Claude"
            case "codex":  return "Codex"
            default:        return session.assistant.capitalized
            }
        }

        /// Honest model line for the identity header. The broker doesn't
        /// report a live model string, so this shows the alias the session
        /// was actually created/forked with when the store recorded one,
        /// else "default model" (+ effort) — never the agent name repeated.
        private var modelDisplay: String {
            if let alias = store.modelBySession[session.id], !alias.isEmpty {
                return alias
            }
            if let effort = liveEffort, !effort.isEmpty {
                return "default model · \(effort)"
            }
            return "default model"
        }

        /// `repo · branch` — the repo is the last path component of the
        /// session's working directory (the old full-width path row, folded
        /// down to the bit that identifies the project). nil when neither
        /// exists so the status line gracefully shrinks to `● agent`.
        private var repoContextLine: String? {
            let cwd = store.statusBySession[session.id]?.cwd ?? session.cwd
            let repo = cwd.flatMap { path -> String? in
                let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
                let last = trimmed.split(separator: "/").last.map(String.init)
                return (last?.isEmpty == false) ? last : nil
            }
            let branch = session.branch?.trimmingCharacters(in: .whitespaces)
            let parts = [repo, (branch?.isEmpty == false) ? branch : nil].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }

        private var statusColor: Color {
            let phase = store.statusBySession[session.id]?.phase ?? ""
            switch phase.lowercased() {
            case "working", "thinking": return neon.yellow
            case "ready", "idle":       return neon.green
            default:                     return neon.textFaint
            }
        }

        private var agentTint: Color {
            neon.agentTint(forAgent: session.assistant)
        }

        // MARK: Tab strip — floating neon segmented pill

        private var tabStrip: some View {
            HStack {
                // Chat · Terminal · Browser order (the enum's declaration
                // order is terminal/chat/browser; the pill presents Chat
                // first as the default landing tab).
                NeonSegmentedPill(
                    segments: [ProjectTab.chat, .terminal, .browser].map {
                        NeonSegmentedPill<ProjectTab>.Segment(id: $0, label: $0.label, systemImage: $0.systemImage)
                    },
                    selection: $tab
                )
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 8)
        }

        @ViewBuilder
        private var content: some View {
            // Read-only (exited/archived): force the chat log, no composer.
            // The tab strip is hidden above, so `tab` can never leave
            // `.chat` here, but we branch on `isReadOnly` first so a
            // session that exits *while* the Terminal/Browser tab is open
            // collapses straight to the transcript.
            if isReadOnly {
                ConduitUI.ChatView(session: session, forceReadOnly: true)
            } else if chatOnly {
                // Tablet 3-pane centre: chat only; Terminal/Browser/Info
                // live in the right pane (ConduitUI.TabletRightPane).
                ConduitUI.ChatView(session: session, isActive: true)
            } else {
                liveContent
            }
        }

        @ViewBuilder
        private var liveContent: some View {
            ZStack {
                // Device feedback v0.0.50 #3: keep the chat view MOUNTED
                // across tab switches instead of rebuilding it via `switch`.
                // A freshly-created chat view missed SwiftUI keyboard
                // avoidance on the FIRST composer focus after Terminal→Chat —
                // the input stayed behind the keyboard until you dismissed and
                // reopened it. Staying mounted keeps its avoidance machinery +
                // scroll position warm, so the first focus lifts correctly.
                // `isActive` lets it release the keyboard while hidden.
                ConduitUI.ChatView(session: session, isActive: tab == .chat)
                    // Let the chat's command card jump to the Terminal tab
                    // ("Open in terminal"). Only the live tabbed pane wires
                    // this; read-only / tablet chat-only panes leave it nil.
                    .environment(\.openTerminalAction, { tab = .terminal })
                    .opacity(tab == .chat ? 1 : 0)
                    .allowsHitTesting(tab == .chat)
                    .accessibilityHidden(tab != .chat)
                    .zIndex(tab == .chat ? 1 : 0)

                // Device feedback v0.0.68: keep Terminal + Browser MOUNTED
                // too, rather than rebuilding them on every tab switch.
                // Rebuilding the native GhosttyTerminalView tore down and
                // recreated the libghostty surface each Terminal↔other switch;
                // a CoreAnimation commit landing mid-teardown drove a
                // stale-object access — the terminal-reopen crash (Sentry
                // APPLE-IOS-S `apprt.surface.Mailbox.push`, then APPLE-IOS-P/Q
                // `object.Object.getProperty` → `bounds` after the teardown
                // hardening) — and the recreated surface re-sized small + re-
                // initialized laggily. Mounting once keeps the surface warm;
                // `isActive` pauses its draw pump + marks it occluded while
                // hidden (no battery cost off-tab).
                // Lazy-mount: don't instantiate the terminal (and its
                // libghostty surface) until the Terminal tab is first opened,
                // so it never mounts inside the session-create CA commit. Once
                // activated it stays mounted (opacity), preserving #294's
                // no-rebuild-on-switch warmth.
                if terminalActivated {
                    terminalContent
                        .opacity(tab == .terminal ? 1 : 0)
                        .allowsHitTesting(tab == .terminal)
                        .accessibilityHidden(tab != .terminal)
                        .zIndex(tab == .terminal ? 1 : 0)
                    // Render surfaces must NOT participate in the ZStack's
                    // keyboard-avoidance negotiation. They're full-screen and
                    // carry their own input bar; left in the negotiation, their
                    // safe-area treatment skewed the shared ZStack layout so the
                    // Chat sibling's `.safeAreaInset(.bottom)` composer no longer
                    // lifted above the keyboard (composer-behind-keyboard bug,
                    // phone-only — tablet renders Chat without this ZStack and
                    // works). Ignoring `.keyboard` here leaves Chat to negotiate
                    // the keyboard alone, like the tablet path.
                    .ignoresSafeArea(.keyboard, edges: .bottom)
                }

                BrowserTab(session: session, mode: .preview)
                    .opacity(tab == .browser ? 1 : 0)
                    .allowsHitTesting(tab == .browser)
                    .accessibilityHidden(tab != .browser)
                    .zIndex(tab == .browser ? 1 : 0)
                    .ignoresSafeArea(.keyboard, edges: .bottom)
            }
        }

        @ViewBuilder
        private var terminalContent: some View {
            // The terminal is the native `GhosttyTerminalTab`, which drives
            // libghostty's own Metal renderer. `isActive` lets the view pause
            // its CADisplayLink draw pump + go occluded while the Terminal tab
            // isn't visible.
            GhosttyTerminalTab(session: session, isActive: tab == .terminal)
        }
    }
}
