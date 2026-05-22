import SwiftUI

/// Settings — Litter-style sectioned IA. Sentence-case bold section
/// headers (`SettingsSectionHeader`) replace the old uppercased mono
/// labels. New sections at the top mirror the Litter reference:
/// Support · Theme · Font · Conversation · Experimental. The
/// existing Saved Servers / Paired Harness / Pairing / Harness Status /
/// About sections continue to live below them unchanged (Stage C will
/// rework the server UI).
///
/// Note: the old "Pet" section housed a "Wake Pet" button that was
/// wired to a stub (`print("wake pet")`). The broker has no concept
/// of an idle / sleeping agent — PTY-backed assistants (Claude /
/// Codex) are persistent processes — so there was no real endpoint
/// to call. The section was removed rather than backed by a no-op.
struct SettingsSheet: View {
    @Environment(SessionStore.self) private var store
    @Environment(AppearanceStore.self) private var appearance
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State private var showAddServer = false
    @State private var showAppearance = false
    @State private var showExperimental = false
    @State private var showAgentLogin = false

    private let sponsorURL = URL(string: "https://github.com/sponsors/nikhilsh")!

    var body: some View {
        NavigationStack {
            ZStack {
                SweKittyTheme.backgroundGradient(for: colorScheme)
                    .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 22) {
                        supportSection
                        themeSection
                        fontSection
                        conversationSection
                        experimentalSection
                        agentAccountsSection
                        serversSection
                        harnessSection
                        aboutSection
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 18)
                }
                .scrollIndicators(.hidden)
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .tint(SweKittyTheme.accentStrong)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        Text("Done")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(SweKittyTheme.accentStrong)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(
                                Capsule()
                                    .fill(SweKittyTheme.accentStrong.opacity(0.18))
                            )
                            .overlay(
                                Capsule()
                                    .stroke(SweKittyTheme.accentStrong.opacity(0.55), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .sheet(isPresented: $showAddServer) {
                AddServerSheet()
                    .environment(store)
            }
            .sheet(isPresented: $showAppearance) {
                AppearanceSheet()
                    .environment(appearance)
                    .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showExperimental) {
                ExperimentalFeaturesSheet()
                    .environment(appearance)
                    .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showAgentLogin) {
                AgentLoginSheet()
                    .presentationDetents([.medium, .large])
            }
        }
    }

    // MARK: - Litter-style sections

    private var supportSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionHeader("Support")
            VStack(alignment: .leading, spacing: 10) {
                Link(destination: sponsorURL) {
                    SettingsLinkRowContent(
                        icon: "pawprint.fill",
                        title: "Tip the Kitty",
                        subtitle: nil
                    )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassRoundedRect()
        }
    }

    private var themeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionHeader("Theme")
            VStack(alignment: .leading, spacing: 10) {
                SettingsRow(
                    icon: "paintbrush.pointed.fill",
                    title: "Appearance",
                    subtitle: nil
                ) {
                    showAppearance = true
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassRoundedRect()
        }
    }

    private var fontSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionHeader("Font")
            VStack(alignment: .leading, spacing: 10) {
                @Bindable var bindable = appearance
                ForEach(Array(AppearanceStore.FontFamily.allCases.enumerated()), id: \.element.id) { idx, choice in
                    FontSampleRow(
                        family: choice,
                        isSelected: appearance.fontFamily == choice
                    ) {
                        bindable.fontFamily = choice
                    }
                    if idx < AppearanceStore.FontFamily.allCases.count - 1 {
                        Divider().background(SweKittyTheme.separator)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassRoundedRect()
        }
    }

    private var conversationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionHeader("Conversation")
            VStack(alignment: .leading, spacing: 10) {
                @Bindable var bindable = appearance
                SettingsToggleRow(
                    icon: "arrow.up.and.line.horizontal.and.arrow.down",
                    title: "Collapse Turns",
                    subtitle: "Collapse previous turns into cards",
                    isOn: $bindable.collapseTurns
                )
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassRoundedRect()
        }
    }

    /// Stage 0 of `docs/PLAN-AGENT-OAUTH.md` — a single entry that
    /// presents `AgentLoginSheet` for the ChatGPT (Codex) OAuth spike.
    /// The sheet stashes the resulting blob in Keychain and logs it to
    /// the console; no broker wiring yet (Stage 2+).
    private var agentAccountsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionHeader("Agent accounts")
            VStack(alignment: .leading, spacing: 10) {
                SettingsRow(
                    icon: "person.crop.circle.badge.checkmark",
                    title: "Sign in to agents",
                    subtitle: "Login with ChatGPT (Claude soon)"
                ) {
                    showAgentLogin = true
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassRoundedRect()
        }
    }

    private var experimentalSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionHeader("Experimental")
            VStack(alignment: .leading, spacing: 10) {
                SettingsRow(
                    icon: "flask.fill",
                    title: "Experimental Features",
                    subtitle: nil
                ) {
                    showExperimental = true
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassRoundedRect()
        }
    }

    // MARK: - Legacy sections (Stage C will rework)

    @ViewBuilder
    private var serversSection: some View {
        SettingsSection(title: "Servers") {
            if !store.savedServers.isEmpty {
                ForEach(Array(store.savedServers.enumerated()), id: \.element.id) { idx, server in
                    ServerListRow(server: server, store: store)
                    if idx < store.savedServers.count - 1 {
                        Divider().background(SweKittyTheme.separator)
                    }
                }
                Divider().background(SweKittyTheme.separator)
            }
            SettingsRow(
                icon: "plus.circle.fill",
                title: "Add server",
                subtitle: "QR · LAN discover · SSH · paste URL+token"
            ) {
                showAddServer = true
            }
        }
    }

    @ViewBuilder
    private var harnessSection: some View {
        if store.endpoint.isComplete {
            SettingsSection(title: "Harness") {
                HStack {
                    Image(systemName: "link")
                        .frame(width: 22)
                        .foregroundStyle(SweKittyTheme.accentStrong)
                    Text("Link")
                        .foregroundStyle(SweKittyTheme.textBody)
                    Spacer()
                    HarnessBadge(state: store.harness)
                }
                if let reason = store.harness.failureReason {
                    Divider().background(SweKittyTheme.separator)
                    Text(reason)
                        .font(.footnote)
                        .foregroundStyle(SweKittyTheme.danger)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if shouldShowReconnect {
                    Divider().background(SweKittyTheme.separator)
                    SettingsRow(
                        icon: "arrow.clockwise",
                        title: "Reconnect",
                        subtitle: nil
                    ) {
                        store.reconnect()
                    }
                }
                Divider().background(SweKittyTheme.separator)
                SettingsRow(
                    icon: "trash",
                    title: "Forget harness",
                    subtitle: store.endpoint.displayHost,
                    iconTint: SweKittyTheme.danger,
                    titleTint: SweKittyTheme.danger
                ) {
                    store.endpoint = .empty
                    store.disconnect()
                }
            }
        }
    }

    private var aboutSection: some View {
        SettingsSection(title: "About") {
            HStack {
                Image(systemName: "app.fill")
                    .frame(width: 22)
                    .foregroundStyle(SweKittyTheme.accentStrong)
                Text("App")
                    .foregroundStyle(SweKittyTheme.textBody)
                Spacer()
                Text("SweKitty")
                    .foregroundStyle(SweKittyTheme.textSecondary)
            }
            if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                Divider().background(SweKittyTheme.separator)
                HStack {
                    Image(systemName: "number")
                        .frame(width: 22)
                        .foregroundStyle(SweKittyTheme.accentStrong)
                    Text("Version")
                        .foregroundStyle(SweKittyTheme.textBody)
                    Spacer()
                    Text(version)
                        .foregroundStyle(SweKittyTheme.textSecondary)
                }
            }
        }
    }

    /// Only show the manual Reconnect affordance when the link
    /// actually needs intervention.
    private var shouldShowReconnect: Bool {
        guard store.endpoint.isComplete else { return false }
        switch store.harness {
        case .disconnected, .failed: return true
        default: return false
        }
    }
}

/// `swekitty://host[:port]?token=<bearer>` → (endpoint URL, token).
enum PairingURL {
    struct Parsed { let endpoint: String; let token: String }

    static func parse(_ raw: String) -> Parsed? {
        guard let components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased() else { return nil }
        let token = components.queryItems?.first(where: { $0.name.lowercased() == "token" })?.value ?? ""
        guard !token.isEmpty else { return nil }

        if scheme == "swekitty", let host = components.host {
            let port = components.port.map { ":\($0)" } ?? ""
            return Parsed(endpoint: "ws://\(host)\(port)", token: token)
        }

        if (scheme == "ws" || scheme == "wss"),
           let host = components.host {
            let port = components.port.map { ":\($0)" } ?? ""
            return Parsed(endpoint: "\(scheme)://\(host)\(port)", token: token)
        }
        return nil
    }
}

// MARK: - Building blocks

/// Litter-style section header: sentence-case, bold title3, left-aligned.
/// Used by the new top-of-settings sections in place of the old
/// uppercased monospaced caption2 labels.
struct SettingsSectionHeader: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.title3.weight(.bold))
            .foregroundStyle(SweKittyTheme.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
            .padding(.horizontal, 4)
    }
}

/// Legacy section: small uppercased mono label + a glass card. Still
/// used by Servers / Harness / About until Stage C reworks them.
struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(.caption2, design: .monospaced).weight(.semibold))
                .tracking(0.9)
                .foregroundStyle(SweKittyTheme.textSecondary)
                .padding(.horizontal, 4)

            VStack(alignment: .leading, spacing: 10) {
                content()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassRoundedRect()
        }
    }
}

/// Tap-to-perform row: copper icon · title (+ optional subtitle) · chevron.
struct SettingsRow: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    var iconTint: Color = SweKittyTheme.accentStrong
    var titleTint: Color = SweKittyTheme.textPrimary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            SettingsLinkRowContent(
                icon: icon,
                title: title,
                subtitle: subtitle,
                iconTint: iconTint,
                titleTint: titleTint
            )
        }
        .buttonStyle(.plain)
    }
}

/// Shared row body so both `SettingsRow` (Button) and `Link` rows
/// render identically. Renders: icon · title (+ optional subtitle) ·
/// chevron-right.
struct SettingsLinkRowContent: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    var iconTint: Color = SweKittyTheme.accentStrong
    var titleTint: Color = SweKittyTheme.textPrimary

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.body)
                .frame(width: 22)
                .foregroundStyle(iconTint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(titleTint)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(SweKittyTheme.textMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(SweKittyTheme.textMuted)
        }
        .contentShape(Rectangle())
    }
}

/// Toggle row: copper icon · title/subtitle · trailing Switch.
struct SettingsToggleRow: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.body)
                .frame(width: 22)
                .foregroundStyle(SweKittyTheme.accentStrong)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(SweKittyTheme.textPrimary)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(SweKittyTheme.textMuted)
                }
            }
            Spacer()
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(SweKittyTheme.accentStrong)
        }
    }
}

/// Radio-style picker row used by the legacy `AppearanceSheet`'s Theme
/// section. (The new Font section uses `FontSampleRow` instead.)
struct SettingsPickerRow: View {
    let icon: String
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.body)
                    .frame(width: 22)
                    .foregroundStyle(SweKittyTheme.accentStrong)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(SweKittyTheme.textPrimary)
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.body)
                    .foregroundStyle(isSelected ? SweKittyTheme.accentStrong : SweKittyTheme.textMuted)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Font picker row used by the Litter-style Font section: bold family
/// label plus a secondary "The quick brown fox" sample rendered in the
/// matching face. Selected row gets a trailing orange checkmark.
struct FontSampleRow: View {
    let family: AppearanceStore.FontFamily
    let isSelected: Bool
    let action: () -> Void

    private static let sampleText = "The quick brown fox"

    private var sampleFont: Font {
        switch family {
        case .serif:      return .system(.body, design: .serif)
        case .system:     return .body
        case .monospaced: return .system(.body, design: .monospaced)
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(family.label)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(SweKittyTheme.textPrimary)
                    Text(Self.sampleText)
                        .font(sampleFont)
                        .foregroundStyle(SweKittyTheme.textSecondary)
                        .lineLimit(1)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(SweKittyTheme.accentStrong)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Experimental Features sheet — flagged features live here behind
/// per-feature toggles. Stage 0 of the terminal rewrite lands the
/// "Native Terminal (Ghostty)" toggle; the actual `GhosttyTerminalView`
/// is a placeholder until Stage 1 wires libghostty. See
/// `docs/PLAN-TERMINAL-REWRITE.md`.
private struct ExperimentalFeaturesSheet: View {
    @Environment(AppearanceStore.self) private var appearance
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        NavigationStack {
            ZStack {
                SweKittyTheme.backgroundGradient(for: colorScheme)
                    .ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        terminalSection
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 18)
                }
                .scrollIndicators(.hidden)
            }
            .navigationTitle("Experimental Features")
            .navigationBarTitleDisplayMode(.inline)
            .tint(SweKittyTheme.accentStrong)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var terminalSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionHeader("Terminal")
            VStack(alignment: .leading, spacing: 10) {
                @Bindable var bindable = appearance
                SettingsToggleRow(
                    icon: "terminal.fill",
                    title: "Native Terminal (Ghostty)",
                    subtitle: "Spike — placeholder view, not wired to PTY",
                    isOn: $bindable.experimentalNativeTerminal
                )
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassRoundedRect()
        }
    }
}

/// Single row in the Servers section: name, host, Default badge, Use,
/// trash. The previous implementation lived inline in `savedServersCard`.
private struct ServerListRow: View {
    let server: SavedServer
    let store: SessionStore

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "server.rack")
                .font(.body)
                .frame(width: 22)
                .foregroundStyle(SweKittyTheme.accentStrong)
            VStack(alignment: .leading, spacing: 2) {
                Text(server.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(SweKittyTheme.textPrimary)
                Text(server.endpoint.displayHost)
                    .font(.caption)
                    .foregroundStyle(SweKittyTheme.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if server.isDefault {
                Text("Default")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .glassCapsule(interactive: false, tint: SweKittyTheme.accentStrong.opacity(0.22))
            }
            Button("Use") {
                store.selectSavedServer(server.id, autoConnect: true)
            }
            .buttonStyle(.plain)
            .foregroundStyle(SweKittyTheme.accentStrong)
            Button(role: .destructive) {
                store.removeSavedServer(server.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
        }
    }
}
