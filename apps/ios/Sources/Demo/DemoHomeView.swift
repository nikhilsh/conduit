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
        @Environment(AppearanceStore.self) private var appearance
        @Environment(\.horizontalSizeClass) private var horizontalSizeClass
        @Environment(\.neonTheme) private var neon

        /// Captured on `.onAppear`; restored on `.onDisappear` so any
        /// theme/font changes made in the demo do not persist after the
        /// reviewer exits demo mode.
        @State private var appearanceSnapshot: AppearanceStore.Snapshot?

        var body: some View {
            Group {
                if horizontalSizeClass == .regular {
                    DemoTabletShell()
                } else {
                    DemoPhoneShell()
                }
            }
            .onAppear {
                appearanceSnapshot = appearance.snapshot()
                Telemetry.breadcrumb("demo", "appearance_snapshot_captured")
            }
            .onDisappear {
                if let snap = appearanceSnapshot {
                    appearance.apply(snap)
                    Telemetry.breadcrumb("demo", "appearance_snapshot_restored")
                }
            }
        }
    }
}

// MARK: - Phone shell

private struct DemoPhoneShell: View {
    @Environment(SessionStore.self) private var store
    @Environment(AppearanceStore.self) private var appearance
    @Environment(\.neonTheme) private var neon
    @State private var selectedSessionID: String?
    @State private var showingAppearance = false

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
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        Telemetry.breadcrumb("demo", "appearance_opened")
                        showingAppearance = true
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(neon.textDim)
                    }
                    .buttonStyle(.plain)
                }
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
                    DemoProjectView(session: session)
                }
            }
            .sheet(isPresented: $showingAppearance) {
                ConduitUI.AppearanceSheet()
                    .environment(appearance)
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
    @Environment(AppearanceStore.self) private var appearance
    @Environment(\.neonTheme) private var neon
    @State private var selectedSession: ProjectSession? = DemoData.sessions.first
    @State private var showingAppearance = false

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
                        Telemetry.breadcrumb("demo", "appearance_opened")
                        showingAppearance = true
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(neon.textDim)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 8)
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
                DemoProjectView(session: session)
                    .id(session.id)
            } else {
                ConduitUI.EmptyDetail()
            }
        }
        .sheet(isPresented: $showingAppearance) {
            ConduitUI.AppearanceSheet()
                .environment(appearance)
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
                ForEach(DemoData.sessions, id: \.id) { session in
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
//
// Routes the transcript body through the REAL read-only ConduitUI.ChatView so
// the demo shows authentic chat rendering (code blocks, diff cards, handoff
// cards, pending-input cards, plan checklists, subagent cards) rather than the
// hand-rolled approximation that was here before.
// The shell chrome (nav title, Exit-Demo button) lives in the parent
// NavigationStack/DemoPhoneShell; only the transcript body is replaced.

struct DemoChatView: View {
    let session: ProjectSession

    var body: some View {
        ConduitUI.ChatView(
            session: session,
            readOnlyItems: DemoData.conversationBySession[session.id] ?? [],
            forceReadOnly: true
        )
        .navigationTitle(session.displayName ?? session.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            Telemetry.breadcrumb("demo", "chat_appeared", data: ["session": session.id])
        }
    }
}
