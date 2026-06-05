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
// Header layout:
//   row 1: ← back · [● name ▼ identity-dropdown] · ↻ refresh · ⓘ info
//          (the dropdown holds agent · effort · model + Rename/Fork/Info;
//           device feedback: the old inline agent/effort chips wrapped +
//           crammed the header, so they moved into the dropdown)
//   row 2: path subtitle (truncated middle, mono)
//   row 3: Terminal | Chat | Browser segmented picker
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
        @State private var showInfo = false
        /// Diff review sheet, opened from the header "Changes" button (shown
        /// only when the session has changes to review).
        @State private var showDiff = false
        /// Rename / Fork sheets, reached from the header identity dropdown
        /// (device feedback: the inline agent/effort chips wrapped + crammed
        /// the header — they move into this dropdown alongside quick actions).
        @State private var showRename = false
        @State private var showFork = false

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
            .sheet(isPresented: $showFork) {
                ConduitUI.ForkSheet(
                    session: session,
                    currentEffort: store.statusBySession[session.id]?.reasoningEffort ?? session.reasoningEffort
                )
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

        // MARK: Header rows

        private var header: some View {
            VStack(alignment: .leading, spacing: 8) {
                row1
                row2
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)
        }

        private var row1: some View {
            HStack(spacing: 10) {
                // Tablet 3-pane centre (chatOnly): the sessions rail owns
                // navigation and the right pane owns Session Info, so the
                // back chevron and the ⓘ info button here are dead/redundant
                // — hide them. Phone keeps both (back pops the nav stack; ⓘ
                // is the only route to Session Info).
                if !chatOnly {
                    headerIcon("chevron.left", weight: .semibold, tint: neon.text, label: "Back") {
                        dismiss()
                    }
                }

                // Identity dropdown: a single tappable control showing
                // status dot · session name · chevron on the neon card
                // surface. Device feedback: the always-visible header crammed
                // a truncated name + an agent chip that WRAPPED to two lines +
                // an effort chip + 3 icons. The agent / effort / model metadata
                // now lives in the `Menu` below (never visible inline, so it
                // can't wrap), and the name is the only inline label — single
                // line, middle-truncated, never wraps.
                Menu {
                    identityMenu
                } label: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 8, height: 8)
                            .neonGlowBox(neon.glow ? neon.glowBox?.tinted(statusColor) : nil)
                        Text(store.displayName(for: session))
                            .font(neon.sans(15).weight(.semibold))
                            .foregroundStyle(neon.text)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(agentTint)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    // Hug the content (dot · name · chevron) instead of
                    // stretching edge-to-edge — a full-width card left a large
                    // dead gap before the refresh/info buttons (device
                    // feedback: "empty space beside Claude at the top"). The
                    // trailing Spacer below absorbs the slack and the name
                    // still truncates via its own lineLimit when the row is
                    // tight (no fixedSize, which would defeat that truncation).
                    .neonCardSurface(neon, fill: neon.surface, cornerRadius: 13)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .accessibilityLabel("Session details")

                Spacer(minLength: 8)

                // "Changes" affordance → Diff review. Shown only when there's
                // something to review (linesAdded/Removed > 0 or a parseable
                // diff item exists). Hidden in the tablet chat-only pane (the
                // right pane owns diff/info there).
                if !chatOnly && hasChanges {
                    headerIcon("arrow.triangle.branch", tint: neon.textDim, label: "Changes") {
                        showDiff = true
                    }
                }

                headerIcon("arrow.clockwise", tint: neon.textDim, label: "Refresh") {
                    store.reconnect()
                }
                if !chatOnly {
                    headerIcon("info.circle", tint: neon.textDim, label: "Session info") {
                        showInfo = true
                    }
                }
            }
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
            }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
        }

        /// Dropdown contents for the header identity control. The metadata
        /// that used to crowd the header inline (agent · reasoning effort ·
        /// model) lives here as a non-tappable info section, followed by the
        /// quick actions already wired elsewhere (Rename · Fork · Session
        /// info). `Menu` rows can't carry custom fonts, so we lean on
        /// `Section` + `Label`/`Text` for the native dropdown look.
        @ViewBuilder
        private var identityMenu: some View {
            // Metadata section — read-only "current settings" rows. The
            // broker doesn't report a model string, so the model line mirrors
            // SessionInfoView: agent (+ effort) is the honest stand-in.
            Section {
                Text("Agent: \(session.assistant)")
                if let effort = liveEffort, !effort.isEmpty {
                    Text("Effort: \(effort)")
                }
                Text("Model: \(modelLine)")
            }
            // Quick actions — reuse the exact store-driven flows the Session
            // Info screen exposes, so data flow is unchanged.
            Section {
                Button {
                    showRename = true
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                Button {
                    showFork = true
                } label: {
                    Label("Fork", systemImage: "arrow.triangle.branch")
                }
                if !chatOnly {
                    Button {
                        showInfo = true
                    } label: {
                        Label("Session info", systemImage: "info.circle")
                    }
                }
            }
        }

        /// Live reasoning effort (status overrides the session's seed value).
        private var liveEffort: String? {
            store.statusBySession[session.id]?.reasoningEffort ?? session.reasoningEffort
        }

        /// Honest model line: the broker doesn't report a model string, so
        /// show the agent (+ effort) — same stand-in SessionInfoView uses.
        private var modelLine: String {
            if let effort = liveEffort, !effort.isEmpty {
                return "\(session.assistant.lowercased()) · \(effort)"
            }
            return session.assistant.lowercased()
        }

        private var row2: some View {
            HStack {
                Text(session.cwd ?? "—")
                    .font(neon.mono(11))
                    .foregroundStyle(neon.textFaint)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
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
