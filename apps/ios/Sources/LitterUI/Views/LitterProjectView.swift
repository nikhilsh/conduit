import SwiftUI
import UIKit

// MARK: - LitterProjectView
//
// Session detail in the LitterUI tree. Litter's reference has a single
// chat surface per session; we keep our Terminal / Chat / Browser
// trio (per the user's direction in the brief) but collapse the tab
// strip into a slim segmented control directly under the title so it
// reads as sub-nav rather than chrome.
//
// Header layout (litter-faithful):
//   row 1: ← back · ● claude medium ▼ · ↻ refresh · ⓘ info
//   row 2: path subtitle (truncated middle, mono)
//   row 3: Terminal | Chat | Browser segmented picker
// Below: tab content (LitterChatView for the chat tab, legacy
// TerminalTabXterm + BrowserTab for the others — the LitterUI rebuild
// scope was the conversation + nav, not the terminal/browser
// renderers).

extension LitterUI {

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
                if !isReadOnly {
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
                LitterUI.SessionInfoView(session: session)
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
                headerIcon("chevron.left", weight: .semibold, tint: neon.text, label: "Back") {
                    dismiss()
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
                .frame(maxWidth: .infinity, alignment: .leading)
                .neonCardSurface(neon, fill: neon.surface, cornerRadius: 13)

                headerIcon("arrow.clockwise", tint: neon.textDim, label: "Refresh") {
                    store.reconnect()
                }
                headerIcon("info.circle", tint: neon.textDim, label: "Session info") {
                    showInfo = true
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
                LitterUI.ChatView(session: session, forceReadOnly: true)
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
                LitterUI.ChatView(session: session, isActive: tab == .chat)
                    .opacity(tab == .chat ? 1 : 0)
                    .allowsHitTesting(tab == .chat)
                    .accessibilityHidden(tab != .chat)
                    .zIndex(tab == .chat ? 1 : 0)

                liveSecondaryContent
            }
        }

        @ViewBuilder
        private var liveSecondaryContent: some View {
            switch tab {
            case .chat:
                EmptyView()
            case .terminal:
                // Default engine is the xterm.js terminal (shipping,
                // proven). Stage 5 wires the native `GhosttyTerminalTab`
                // to libghostty's *own* Metal renderer — we pass our
                // UIView via `ghostty_platform_ios_s.uiview`, push the
                // real pixel size, and drive `ghostty_surface_draw` from
                // a CADisplayLink (the Stage-4 skeleton fed bytes but
                // never sized the surface or asked it to paint, hence the
                // blank screen). It's gated behind the
                // `experimentalNativeTerminal` flag for on-device
                // verification; default users stay on xterm.js until the
                // native path is confirmed painting on real hardware.
                if appearance.experimentalNativeTerminal {
                    GhosttyTerminalTab(session: session)
                } else {
                    TerminalTabXterm(session: session)
                }
            case .browser:
                BrowserTab(session: session, mode: .preview)
            }
        }
    }
}
