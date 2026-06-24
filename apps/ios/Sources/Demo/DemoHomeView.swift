import SwiftUI

// MARK: - DemoHomeView
//
// Self-contained demo shell shown to App Store reviewers. Displays two fake
// sessions and a scripted conversation with no network calls and no real broker.
// Phone: NavigationStack + list. iPad: NavigationSplitView mirroring TabletShell.
//
// The "Exit Demo" button calls store.deactivateDemo(), which flips the
// isDemoMode flag back to false and returns the user to the normal onboarding.

extension ConduitUI {

    struct DemoHomeView: View {
        @Environment(SessionStore.self) private var store
        @Environment(\.horizontalSizeClass) private var horizontalSizeClass
        @Environment(\.neonTheme) private var neon

        var body: some View {
            if horizontalSizeClass == .regular {
                DemoTabletShell()
            } else {
                DemoPhoneShell()
            }
        }
    }
}

// MARK: - Phone shell

private struct DemoPhoneShell: View {
    @Environment(SessionStore.self) private var store
    @Environment(\.neonTheme) private var neon
    @State private var selectedSessionID: String?

    private var selectedSession: ProjectSession? {
        guard let id = selectedSessionID else { return nil }
        return DemoData.sessions.first { $0.id == id }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                GlassAppBackground()
                VStack(spacing: 0) {
                    demoBanner(neon: neon)
                    DemoSessionList(onSelect: { selectedSessionID = $0.id })
                        .padding(.top, 8)
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 8) {
                        ConduitUI.AnimatedBrandMark(size: 22)
                        (Text(">").foregroundStyle(neon.codex) + Text("conduit").foregroundStyle(neon.text))
                            .font(neon.mono(14).weight(.bold))
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        Telemetry.breadcrumb("demo", "exit_tapped")
                        store.deactivateDemo()
                    } label: {
                        Text("Exit Demo")
                            .font(neon.mono(12).weight(.bold))
                            .foregroundStyle(neon.codex)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                Capsule()
                                    .fill(neon.codex.opacity(0.12))
                                    .overlay(Capsule().strokeBorder(neon.codex.opacity(0.35), lineWidth: 1))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationDestination(isPresented: Binding(
                get: { selectedSessionID != nil },
                set: { if !$0 { selectedSessionID = nil } }
            )) {
                if let session = selectedSession {
                    DemoChatView(session: session)
                }
            }
        }
        .onAppear {
            Telemetry.breadcrumb("demo", "home_appeared")
        }
    }
}

// MARK: - Tablet shell

private struct DemoTabletShell: View {
    @Environment(SessionStore.self) private var store
    @Environment(\.neonTheme) private var neon
    @State private var selectedSession: ProjectSession? = DemoData.sessions.first

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                // Sidebar header
                HStack(spacing: 8) {
                    ConduitUI.AnimatedBrandMark(size: 22)
                    (Text(">").foregroundStyle(neon.codex) + Text("conduit").foregroundStyle(neon.text))
                        .font(neon.mono(14).weight(.bold))
                    Spacer()
                    Button {
                        Telemetry.breadcrumb("demo", "exit_tapped")
                        store.deactivateDemo()
                    } label: {
                        Text("Exit Demo")
                            .font(neon.mono(11).weight(.bold))
                            .foregroundStyle(neon.codex)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                demoBanner(neon: neon)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
                DemoSessionList(onSelect: { selectedSession = $0 })
            }
            .background(neon.appBg)
            .navigationSplitViewColumnWidth(min: 240, ideal: 272, max: 320)
            .toolbar(.hidden, for: .navigationBar)
        } detail: {
            if let session = selectedSession {
                DemoChatView(session: session)
                    .id(session.id)
            } else {
                ConduitUI.EmptyDetail()
            }
        }
        .onAppear {
            Telemetry.breadcrumb("demo", "home_appeared_tablet")
        }
    }
}

// MARK: - Demo banner

private func demoBanner(neon: NeonTheme) -> some View {
    HStack(spacing: 8) {
        Image(systemName: "sparkle")
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(neon.codex)
        Text("Demo Mode")
            .font(neon.mono(12).weight(.bold))
            .foregroundStyle(neon.codex)
        Text("--")
            .font(neon.mono(12))
            .foregroundStyle(neon.textFaint)
        Text("connect a real server to run AI agents")
            .font(neon.mono(11.5))
            .foregroundStyle(neon.textDim)
            .lineLimit(1)
        Spacer(minLength: 4)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 9)
    .background(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(neon.codex.opacity(0.08))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(neon.codex.opacity(0.25), lineWidth: 1))
    )
    .padding(.horizontal, 14)
    .padding(.top, 6)
}

// MARK: - Session list

private struct DemoSessionList: View {
    @Environment(\.neonTheme) private var neon
    var onSelect: (ProjectSession) -> Void

    var body: some View {
        List {
            Section {
                Text("ACTIVE SESSIONS")
                    .font(neon.mono(12).weight(.semibold))
                    .tracking(2)
                    .foregroundStyle(neon.codex)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 6, leading: 14, bottom: 2, trailing: 14))
                ForEach(DemoData.sessions) { session in
                    DemoSessionRow(session: session)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 4, leading: 14, bottom: 4, trailing: 14))
                        .onTapGesture { onSelect(session) }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }
}

// MARK: - Session row

private struct DemoSessionRow: View {
    @Environment(\.neonTheme) private var neon
    let session: ProjectSession

    private var displayTitle: String {
        session.displayName ?? session.name
    }

    private var lastMessage: String? {
        DemoData.conversationBySession[session.id]?
            .last(where: { $0.role.lowercased() != "user" })
            .map { item in
                if item.role == "tool" {
                    return item.toolName.map { "[\($0)]" } ?? "[tool]"
                }
                let c = item.content
                return c.count > 60 ? String(c.prefix(60)) + "..." : c
            }
    }

    var body: some View {
        HStack(spacing: 12) {
            // Status dot
            Circle()
                .fill(neon.green)
                .frame(width: 8, height: 8)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(displayTitle)
                        .font(neon.sans(14).weight(.semibold))
                        .foregroundStyle(neon.text)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    // Agent badge
                    Text(session.assistant.lowercased())
                        .font(neon.mono(10).weight(.bold))
                        .foregroundStyle(neon.claude)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(neon.claude.opacity(0.12))
                                .overlay(Capsule().strokeBorder(neon.claude.opacity(0.3), lineWidth: 0.5))
                        )
                }
                if let preview = lastMessage {
                    Text(preview)
                        .font(neon.mono(11.5))
                        .foregroundStyle(neon.textDim)
                        .lineLimit(1)
                }
                if let cwd = session.cwd {
                    Text(cwd)
                        .font(neon.mono(10.5))
                        .foregroundStyle(neon.textFaint)
                        .lineLimit(1)
                }
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(neon.textFaint)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(neon.surface)
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(neon.border, lineWidth: 1))
        )
    }
}

// MARK: - Demo chat view

struct DemoChatView: View {
    @Environment(\.neonTheme) private var neon
    let session: ProjectSession

    private var items: [ConversationItem] {
        DemoData.conversationBySession[session.id] ?? []
    }

    private var displayTitle: String {
        session.displayName ?? session.name
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(items) { item in
                        DemoChatRow(item: item)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                    }
                }
                .padding(.bottom, 8)
            }
            disabledComposer
        }
        .background(neon.appBg)
        .navigationTitle(displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            Telemetry.breadcrumb("demo", "chat_appeared", data: ["session": session.id])
        }
    }

    private var disabledComposer: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(neon.textFaint)
            Text("Connect a real server to start a session")
                .font(neon.sans(14))
                .foregroundStyle(neon.textFaint)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(neon.surface)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(neon.border)
                .frame(height: 1)
        }
    }
}

// MARK: - Demo chat row

private struct DemoChatRow: View {
    @Environment(\.neonTheme) private var neon
    let item: ConversationItem

    var body: some View {
        switch item.role.lowercased() {
        case "user":
            userRow
        case "tool":
            toolRow
        default:
            assistantRow
        }
    }

    private var userRow: some View {
        HStack {
            Spacer(minLength: 60)
            Text(item.content)
                .font(neon.sans(14))
                .foregroundStyle(neon.text)
                .multilineTextAlignment(.trailing)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(neon.codex.opacity(0.12))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(neon.codex.opacity(0.25), lineWidth: 1))
                )
        }
    }

    private var assistantRow: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(neon.claude.opacity(0.18))
                .frame(width: 22, height: 22)
                .overlay(
                    Text("C")
                        .font(neon.mono(10).weight(.bold))
                        .foregroundStyle(neon.claude)
                )
                .padding(.top, 2)
            Text(item.content)
                .font(neon.sans(14))
                .foregroundStyle(neon.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }

    private var toolRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(neon.green)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                if let toolName = item.toolName {
                    Text(toolName)
                        .font(neon.mono(11).weight(.bold))
                        .foregroundStyle(neon.green)
                }
                if let cmd = item.command {
                    Text(cmd)
                        .font(neon.mono(11))
                        .foregroundStyle(neon.textDim)
                        .lineLimit(2)
                }
                if let code = item.exitCode {
                    Text("exit \(code)")
                        .font(neon.mono(10))
                        .foregroundStyle(code == 0 ? neon.green : neon.accent)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(neon.codeBg)
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(neon.border, lineWidth: 1))
        )
    }
}
