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
                Divider().background(LitterUI.Palette.separator.color)
                content
            }
            // Full-bleed background for the notch / home-indicator, but
            // scope to `.container` so it does NOT ignore the `.keyboard`
            // region — a default `.ignoresSafeArea()` (regions: .all)
            // here suppressed keyboard avoidance for the chat composer's
            // `.safeAreaInset(.bottom)`, leaving it hidden behind the soft
            // keyboard (device bug #19).
            .background(LitterUI.Palette.surface.color.ignoresSafeArea(.container, edges: .all))
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
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(LitterUI.Palette.textPrimary.color)
                        .frame(width: 32, height: 32)
                        .litterGlassCircle(tint: LitterUI.Palette.surfaceLight.color, config: .floating)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")

                HStack(spacing: 6) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                    Text(store.displayName(for: session))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(LitterUI.Palette.textPrimary.color)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    LitterUI.Chip(label: session.assistant, tint: agentTint)
                    if let effort = session.reasoningEffort {
                        LitterUI.Chip(label: effort)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    store.reconnect()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(LitterUI.Palette.textSecondary.color)
                        .frame(width: 32, height: 32)
                        .litterGlassCircle(tint: LitterUI.Palette.surfaceLight.color, config: .floating)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Refresh")

                Button {
                    showInfo = true
                } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(LitterUI.Palette.textSecondary.color)
                        .frame(width: 32, height: 32)
                        .litterGlassCircle(tint: LitterUI.Palette.surfaceLight.color, config: .floating)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Session info")
            }
        }

        private var row2: some View {
            HStack {
                Text(session.cwd ?? "—")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(LitterUI.Palette.textMuted.color)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }

        private var statusColor: Color {
            let phase = store.statusBySession[session.id]?.phase ?? ""
            switch phase.lowercased() {
            case "working", "thinking": return LitterUI.Palette.warning.color
            case "ready", "idle":       return LitterUI.Palette.success.color
            default:                     return LitterUI.Palette.textMuted.color
            }
        }

        private var agentTint: Color {
            SweKittyTheme.accent(forAgent: session.assistant)
        }

        // MARK: Tab strip — slim segmented control

        private var tabStrip: some View {
            HStack(spacing: 4) {
                ForEach(ProjectTab.allCases) { t in
                    Button {
                        withAnimation(.easeOut(duration: 0.18)) { tab = t }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: t.systemImage)
                                .font(.system(size: 10, weight: .semibold))
                            Text(t.label)
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .foregroundStyle(tab == t ? LitterUI.Palette.textOnAccent.color : LitterUI.Palette.textSecondary.color)
                        .litterGlassCapsule(tint: tab == t ? LitterUI.Palette.brand.color : nil, config: .pill)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
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
            switch tab {
            case .chat:
                LitterUI.ChatView(session: session)
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
