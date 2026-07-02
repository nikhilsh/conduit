import SwiftUI
import WebKit

// MARK: - DemoProjectView
//
// Phase-2 demo shell: wraps the existing read-only chat with a
// NeonSegmentedPill tab switcher (Chat / Terminal / Browser). Replaces
// the direct DemoChatView navigation in DemoPhoneShell / DemoTabletShell.
//
// No broker, no real sessions. Terminal is a static faux output; Browser
// loads a bundled preview.html from the app bundle (file:// URL, offline).

struct DemoProjectView: View {
    let session: ProjectSession
    @Environment(\.neonTheme) private var neon
    @State private var tab: DemoTab = .chat

    enum DemoTab: String, Hashable {
        case chat, terminal, browser

        var label: String {
            switch self {
            case .chat:     return "Chat"
            case .terminal: return "Terminal"
            case .browser:  return "Browser"
            }
        }
        var systemImage: String {
            switch self {
            case .chat:     return "bubble.left.and.bubble.right"
            case .terminal: return "terminal"
            case .browser:  return "globe"
            }
        }
    }

    private static let allTabs: [DemoTab] = [.chat, .terminal, .browser]

    var body: some View {
        VStack(spacing: 0) {
            // Tab switcher pill — centred above the content, matching
            // the real ProjectView's NeonSegmentedPill placement.
            HStack {
                Spacer()
                NeonSegmentedPill(
                    segments: Self.allTabs.map {
                        NeonSegmentedPill<DemoTab>.Segment(id: $0, label: $0.label, systemImage: $0.systemImage)
                    },
                    selection: $tab
                )
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(neon.surfaceSolid)

            Divider().background(neon.border)

            // Tab bodies — use ZStack so the ChatView stays warm in
            // memory (avoids re-render jank on switch back).
            ZStack {
                // Chat tab: existing read-only ChatView.
                ConduitUI.ChatView(
                    session: session,
                    readOnlyItems: DemoData.conversationBySession[session.id] ?? [],
                    forceReadOnly: true
                )
                .opacity(tab == .chat ? 1 : 0)
                .allowsHitTesting(tab == .chat)

                // Terminal tab: static faux shell.
                DemoTerminalView()
                    .opacity(tab == .terminal ? 1 : 0)
                    .allowsHitTesting(tab == .terminal)

                // Browser tab: bundled preview.html.
                DemoBrowserView()
                    .opacity(tab == .browser ? 1 : 0)
                    .allowsHitTesting(tab == .browser)
            }
        }
        .navigationTitle(session.displayName ?? session.name)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: tab) { _, newTab in
            Telemetry.breadcrumb("demo", "tab_switched", data: [
                "tab": newTab.rawValue,
                "session": session.id,
            ])
        }
        .onAppear {
            Telemetry.breadcrumb("demo", "project_appeared", data: ["session": session.id])
        }
    }
}

// MARK: - DemoTerminalView
//
// Static faux-terminal rendering DemoData.terminalLines. No PTY, no
// libghostty — just a ScrollView of styled Text rows. Scrolled to the
// bottom on appear (most recent output visible first).

private struct DemoTerminalView: View {
    @Environment(\.neonTheme) private var neon

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(DemoData.terminalLines.enumerated()), id: \.offset) { index, line in
                        HStack(alignment: .top, spacing: 0) {
                            if line.isPrompt {
                                Text("$ ")
                                    .font(neon.mono(13).weight(.semibold))
                                    .foregroundStyle(neon.green)
                                Text(line.text)
                                    .font(neon.mono(13).weight(.semibold))
                                    .foregroundStyle(neon.green)
                            } else {
                                Text("  \(line.text)")
                                    .font(neon.mono(13))
                                    .foregroundStyle(neon.textDim)
                            }
                            Spacer(minLength: 0)
                        }
                        .id(index)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .background(neon.codeBg)
            .onAppear {
                proxy.scrollTo(DemoData.terminalLines.count - 1, anchor: .bottom)
                Telemetry.breadcrumb("demo", "terminal_appeared")
            }
        }
    }
}

// MARK: - DemoBrowserView
//
// Loads the bundled preview.html from the app bundle via WKWebView
// using a file:// URL. Shows the neon chrome bar (globe + URL pill)
// matching BrowserTab's chrome, but with a static display URL.

private struct DemoBrowserView: View {
    @Environment(\.neonTheme) private var neon

    private static let displayURL = "https://todo.demo.local"

    var body: some View {
        VStack(spacing: 0) {
            // Chrome bar matching BrowserTab.chromeBar(url:)
            HStack(spacing: 8) {
                Image(systemName: "globe")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(neon.accent)
                Text(Self.displayURL)
                    .font(neon.mono(12))
                    .foregroundStyle(neon.codeText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 99, style: .continuous).fill(neon.codeBg)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 99, style: .continuous)
                            .stroke(neon.border, lineWidth: 1)
                    )
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider().background(neon.border)

            DemoBundledWebView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(neon.surfaceSolid)
        .onAppear {
            Telemetry.breadcrumb("demo", "browser_appeared")
        }
    }
}

// MARK: WKWebView wrapper loading preview.html from the bundle

private struct DemoBundledWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView()
        if let url = Bundle.main.url(forResource: "preview", withExtension: "html") {
            // allowingReadAccessTo: the parent directory so the WebView can
            // resolve any relative assets (inline CSS only here, so moot).
            view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            // Fallback: show an error page if the resource is not bundled.
            Telemetry.capture(
                error: NSError(domain: "demo.browser", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "preview.html not found in bundle"]),
                message: "demo browser: preview.html not bundled"
            )
            let html = "<body style=\"background:#05090f;color:#d6e6ff;font-family:monospace;padding:24px\">" +
                       "<p>preview.html not bundled.</p></body>"
            view.loadHTMLString(html, baseURL: nil)
        }
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}
}
