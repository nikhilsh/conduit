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
// Header layout (upstream-faithful):
//   row 1: ← back · ● claude medium ▼ · ↻ refresh · ⓘ info
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
        @Environment(AppearanceStore.self) private var appearance
        @Environment(\.neonTheme) private var neon
        @Environment(\.dismiss) private var dismiss

        let session: ProjectSession
        /// Tablet 3-pane centre: render chat only (no tab strip) — the
        /// Terminal / Browser / Info surfaces live in the sibling right
        /// pane (`ConduitUI.TabletRightPane`). Phone / default = full tabs.
        var chatOnly: Bool = false

        @State private var tab: ProjectTab = .chat
        @State private var showInfo = false

        /// A session whose agent has exited / been archived is read-only:
        /// there's no live WS to interact with, so we collapse the detail
        /// to the chat log alone — hide the Terminal/Chat/Browser tab strip
        /// and render `ChatView` with no composer (per the user's request:
        /// "clicking on archived session should just show me the chat log").
        /// Live sessions keep the full tab strip + interactive surfaces.
        private var isReadOnly: Bool { store.isReadOnly(sessionID: session.id) }

        var body: some View {
            VStack(spacing: 0) {
                header
                if !isReadOnly && !chatOnly {
                    tabStrip
                }
                Divider().background(neon.border)
                content
            }
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
            .onChange(of: tab) { _, _ in dismissKeyboard() }
            .sheet(isPresented: $showInfo) {
                ConduitUI.SessionInfoView(session: session)
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

                // Centered title card: status dot + name + chevron, then
                // the agent + effort chips — neon card surface, glow on.
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
                    NeonAgentChip(label: session.assistant, tint: agentTint)
                    if let effort = session.reasoningEffort {
                        NeonAgentChip(label: effort, tint: neon.textDim)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                // Hug the content (dot · name · agent chip) instead of
                // stretching edge-to-edge — a full-width card left a large dead
                // gap between the chips and the refresh/info buttons (device
                // feedback: "empty space beside Claude at the top"). The trailing
                // Spacer below absorbs the slack and the name still truncates via
                // its own lineLimit when the row is tight (no fixedSize, which
                // would defeat that truncation).
                .neonCardSurface(neon, fill: neon.surface, cornerRadius: 13)

                Spacer(minLength: 8)

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
            // Default engine is the xterm.js terminal (shipping, proven).
            // The native `GhosttyTerminalTab` drives libghostty's own Metal
            // renderer and is gated behind `experimentalNativeTerminal`.
            // `isActive` lets the native view pause its CADisplayLink draw
            // pump + go occluded while the Terminal tab isn't visible.
            if appearance.experimentalNativeTerminal {
                GhosttyTerminalTab(session: session, isActive: tab == .terminal)
            } else {
                TerminalTabXterm(session: session)
            }
        }
    }
}
