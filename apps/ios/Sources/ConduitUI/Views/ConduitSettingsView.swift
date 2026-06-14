import SwiftUI
import UIKit
import GhosttyVT

// MARK: - Donation URL
private let kSupportDonationURL = "https://buymeacoffee.com/conduitapp"

// MARK: - ConduitSettingsView
//
// Conduit redesign Settings screen (handoff Part A). The shipped build
// had eight stacked sections with the server appearing TWICE (Account +
// Servers) and Terminal floating on its own. This collapses the IA to
// five labelled groups, top to bottom:
//
//   Connection · Usage & limits · Appearance · Conversation · About
//
//   • Connection    — ONE home: active server row (tap → switch/manage),
//                     the agents on it (Claude / Codex), Add account, and
//                     Add server. Merges the old Account + Agent Accounts +
//                     Servers sections; the server has exactly one home now.
//   • Usage & limits— account-wide, BOTH agents (claude + codex), each with
//                     a 5-hour AND a weekly window (bar / % / reset).
//   • Appearance    — ONE grouped card with Terminal folded IN: Theme
//                     segmented, accent palette, the type-forward Chat font
//                     + Terminal font strips, Terminal colors, Text size,
//                     Glow & scanlines, + the `conduit --theme <id>` chip.
//   • Conversation  — collapse-turns toggle.
//   • About         — version + licenses.
//
// Presentation + IA only: every store/AppearanceStore binding, sheet, and
// navigation path is preserved from the prior build.

extension ConduitUI {

    struct SettingsView: View {
        @Environment(SessionStore.self) private var store
        @Environment(AppearanceStore.self) private var appearance
        @Environment(FeatureFlags.self) private var flags
        @Environment(\.neonTheme) private var neon
        @Environment(\.dismiss) private var dismiss
        @Environment(\.colorScheme) private var colorScheme
        @Environment(\.openURL) private var openURL

        /// When true the screen is hosted inline as a tablet section pane
        /// (not a sheet), so the "Done" affordance is dropped — there's
        /// nothing to dismiss.
        var embedded: Bool = false

        /// Called when the user taps "How it works" to re-open the onboarding
        /// guide. The caller dismisses the settings sheet then presents the guide.
        var onOpenOnboarding: (() -> Void)? = nil

        @State private var showAddServer = false
        @State private var showAgentLogin = false
        /// When non-nil, the next agent-login sheet open auto-starts OAuth
        /// for this provider (one-tap re-auth from the ⋯ menu).
        @State private var reAuthProvider: OAuthProvider? = nil
        /// Per-agent signed-in + plan snapshot for the Connection group.
        /// Refreshed on appear and whenever the login sheet closes.
        @State private var agentAccounts: [AgentAccountStatus] = []
        // Fix 1: onboarding entry intents from Settings.
        // Presented via .fullScreenCover(item:) so the entry binds atomically
        // and never snapshots a stale default (which routed already-paired
        // users straight to Done).
        @State private var onboardingEntry: OnboardingEntry?

        // WS-P.3: push notification settings state — observed from the
        // shared PushNotificationManager so the row updates live when the
        // token arrives or the user changes system settings.
        @State private var pushManager = PushNotificationManager.shared
        /// Feedback string shown after a "Send test notification" tap.
        @State private var testPushResult: String?
        @State private var testPushInFlight = false

        var body: some View {
            @Bindable var appearance = appearance

            NavigationStack {
                ZStack {
                    GlassAppBackground()

                    ScrollView {
                        VStack(spacing: 18) {
                            connectionSection
                            usageLimitsSection
                            appearanceSection
                            notificationsSection
                            conversationSection
                            agentsSection
                            labsSection
                            supportSection
                            aboutSection
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 18)
                    }
                    .scrollIndicators(.hidden)
                }
                .navigationTitle("Settings")
                .navigationBarTitleDisplayMode(.inline)
                .tint(neon.accent)
                .toolbar {
                    if !embedded {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { dismiss() }
                        }
                    }
                }
                .fullScreenCover(item: $onboardingEntry) { entry in
                    ConduitUI.OnboardingView(onFinish: { onboardingEntry = nil }, entry: entry)
                        .environment(store)
                        .environment(flags)
                }
                .sheet(isPresented: $showAddServer) {
                    ConduitUI.AddServerSheet()
                }
                .sheet(isPresented: $showAgentLogin, onDismiss: {
                    // Re-read the Keychain so a fresh sign-in flips the
                    // agent rows to `● signed in` immediately.
                    agentAccounts = AgentAccountStatus.current(descriptors: store.agentDescriptors)
                    reAuthProvider = nil
                }) {
                    ConduitUI.AgentLoginSheet(autoStartProvider: reAuthProvider)
                }
            }
            // Re-bind \.colorScheme to the AppearanceStore so a runtime
            // theme swap from Settings → Appearance updates THIS sheet
            // live, not just the underlying RootView.
            .appearanceColorScheme()
        }

        // MARK: Connection (server + agents + add, one home)

        /// The big de-dupe (handoff §A.1, render 01): one card holding the
        /// active server row, the agents on it, and the two add affordances.
        /// Removes the standalone Account row + Servers section — the server
        /// has exactly one home now.
        private var connectionSection: some View {
            VStack(alignment: .leading, spacing: 8) {
                Text("Connection")
                    .font(neon.mono(11.5).weight(.bold))
                    .foregroundStyle(neon.textFaint)
                    .tracking(1.6)
                    .textCase(.uppercase)
                    .padding(.horizontal, 4)

                VStack(spacing: 0) {
                    activeServerRow

                    Divider().background(neon.border)

                    Text("AGENTS ON THIS SERVER")
                        .font(neon.mono(11).weight(.bold))
                        .tracking(1.2)
                        .foregroundStyle(neon.textFaint)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.top, 11)
                        .padding(.bottom, 2)

                    ForEach(agentAccounts) { account in
                        agentAccountRow(account)
                        Divider().background(neon.border).padding(.leading, 60)
                    }

                    addAccountRow

                    Divider().background(neon.border)

                    Button {
                        showAddServer = true
                    } label: {
                        ConduitUI.ListRow(
                            icon: "externaldrive.connected.to.line.below",
                            title: "Add server",
                            subtitle: nil,
                            iconTint: neon.accent
                        ) {
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(neon.textFaint)
                        }
                    }
                    .buttonStyle(.plain)

                    Divider().background(neon.border)

                    // Fix 1: replay / add-machine onboarding intents.
                    Button {
                        Telemetry.breadcrumb("onboarding", "settings: replay walkthrough tapped")
                        onboardingEntry = .replay
                    } label: {
                        ConduitUI.ListRow(
                            icon: "arrow.counterclockwise",
                            title: "Replay walkthrough",
                            subtitle: "Run the setup flow again from Welcome",
                            iconTint: neon.accent
                        ) {
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(neon.textFaint)
                        }
                    }
                    .buttonStyle(.plain)

                    Divider().background(neon.border)

                    Button {
                        Telemetry.breadcrumb("onboarding", "settings: add a machine tapped")
                        onboardingEntry = .addMachine
                    } label: {
                        ConduitUI.ListRow(
                            icon: "plus.rectangle.on.rectangle",
                            title: "Add a machine",
                            subtitle: "Pair another box starting from Install",
                            iconTint: neon.accent
                        ) {
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(neon.textFaint)
                        }
                    }
                    .buttonStyle(.plain)
                }
                .neonCardSurface(neon, fill: neon.surface, cornerRadius: 14)
            }
            .onAppear {
                agentAccounts = AgentAccountStatus.current(descriptors: store.agentDescriptors)
                // Fix 3 breadcrumb: log inferred installed state from brokerReadiness.
                // Source: readiness.agents[key].cliPresent from /api/capabilities.
                // nil = old broker or fetch not yet completed (no nag shown).
                if let r = store.brokerReadiness {
                    let summary = r.agents.map { "\($0.key)=\($0.value.cliPresent ? "installed" : "MISSING")" }
                        .sorted().joined(separator: ",")
                    Telemetry.breadcrumb("settings", "agent installed state (from readiness)",
                        data: ["agents": summary])
                }
            }
        }

        /// Active server row — shows the real box identity (SavedServer.name
        /// or ssh username@host) as the primary line, NOT the raw endpoint
        /// which can be a loopback 127.0.0.1 for SSH-tunneled boxes.
        private var activeServerRow: some View {
            NavigationLink {
                ServerSwitcherView()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.body)
                        .frame(width: 20)
                        .foregroundStyle(neon.accent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(activeServerPrimaryLabel)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(neon.text)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(activeServerSubtitle)
                            .font(neon.mono(12.5))
                            .foregroundStyle(neon.textDim)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Text("Switch")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(neon.textDim)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(neon.textFaint)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }

        /// The real box identity for the primary Connection row. For SSH-tunneled
        /// boxes, returns SavedServer.name (e.g. "root@185.201.8.184") — NOT the
        /// loopback tunnel address. For token-paired boxes, falls back to the
        /// endpoint host (already the real address).
        private var activeServerPrimaryLabel: String {
            guard store.endpoint.isComplete else { return "Not paired" }
            if let matched = store.savedServers.first(where: { $0.endpoint == store.endpoint }) {
                return matched.name
            }
            return store.endpoint.displayHost
        }

        /// "Live · default server" / "<state> · server" — honest about
        /// reachability and whether the active endpoint is the default.
        private var activeServerSubtitle: String {
            let state = store.harness.isReachable ? "Live" : store.harness.badgeLabel
            let isDefault = store.savedServers.first(where: { $0.isDefault })?.endpoint == store.endpoint
            return "\(state) · \(isDefault ? "default server" : "server")"
        }

        /// "Manage" row — opens the agent accounts sheet (full list + sign-in).
        private var addAccountRow: some View {
            Button {
                reAuthProvider = nil
                showAgentLogin = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "person.2")
                        .font(.body)
                        .frame(width: 20)
                        .foregroundStyle(neon.textDim)
                    Text("Manage")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(neon.textDim)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }

        /// One agent's account row (Stage-2 two-line design): tinted avatar,
        /// name + plan badge, LINE 1 phone (device-local) sign-in status, LINE 2
        /// connected-box readiness, and a trailing ... menu (re-authenticate /
        /// remove from phone / remove pushed credential from this box).
        /// Uses brokerReadiness.agents[agent] for the box line; cliPresent ==
        /// false surfaces "not installed on this box" on line 2.
        private func agentAccountRow(_ account: AgentAccountStatus) -> some View {
            let tint = neon.agentTint(forAgent: account.agent)
            // Per-agent readiness from the broker block. nil = old broker or not
            // yet fetched; treat as unknown (don't nag, hide line 2).
            let agentReadiness = store.brokerReadiness?.agents[account.agent]
            let notInstalled = agentReadiness?.cliPresent == false
            // LINE 1 -- phone (device-local Keychain) status.
            let (phoneText, phoneColor): (String, Color) =
                account.expired ? ("Signed in - expired", neon.yellow)
                : account.signedIn ? ("Signed in", neon.green)
                : ("Not signed in", neon.textFaint)
            // LINE 2 -- connected-box readiness. "Not installed" pre-empts it.
            let boxLine = notInstalled
                ? nil
                : AgentBoxStatus.make(
                    agent: account.agent,
                    boxName: store.connectedBoxName,
                    signedIn: agentReadiness?.signedIn
                )
            return HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(tint.opacity(neon.dark ? 0.14 : 0.10))
                    .frame(width: 38, height: 38)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(tint.opacity(0.35), lineWidth: 1)
                    )
                    .overlay(ConduitUI.ConduitMark(size: 22, color: tint, glow: neon.glow))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(account.displayName)
                            .font(neon.sans(15).weight(.bold))
                            .foregroundStyle(neon.text)
                        if let plan = account.planLabel, !notInstalled {
                            Text(plan)
                                .font(neon.mono(9).weight(.bold))
                                .tracking(0.6)
                                .foregroundStyle(tint)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(tint.opacity(0.14)))
                                .overlay(Capsule().strokeBorder(tint.opacity(0.4), lineWidth: 1))
                        }
                    }
                    // LINE 1 -- phone status
                    HStack(spacing: 5) {
                        Circle()
                            .fill(phoneColor)
                            .frame(width: 5, height: 5)
                        Text(phoneText)
                            .font(neon.mono(10.5))
                            .foregroundStyle(phoneColor)
                    }
                    // LINE 2 -- connected-box readiness (or "not installed")
                    if notInstalled {
                        Text("Not installed on this box")
                            .font(neon.mono(10))
                            .foregroundStyle(neon.yellow)
                    } else if let boxLine {
                        Text(boxLine.text)
                            .font(neon.mono(10))
                            .foregroundStyle(boxLine.tone == .ready ? neon.green : neon.textFaint)
                    }
                }
                Spacer(minLength: 8)
                agentAccountMenu(account)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }

        /// Trailing ... menu for a Settings agent row -- replaces the old
        /// "Manage" speech-bubble confirmationDialog. Re-authenticate directly
        /// launches OAuth for the provider (one tap, no double-hop); the two
        /// destructive removes are scoped phone vs box.
        @ViewBuilder
        private func agentAccountMenu(_ account: AgentAccountStatus) -> some View {
            Menu {
                Button {
                    Telemetry.breadcrumb("agent_reauth", "re-auth triggered from settings menu",
                        data: ["provider": account.provider.rawValue])
                    reAuthProvider = account.provider
                    showAgentLogin = true
                } label: {
                    Label(account.signedIn ? "Re-authenticate" : "Sign in", systemImage: "arrow.clockwise")
                }
                if account.signedIn {
                    Button(role: .destructive) {
                        OAuthCredentialStore.clear(provider: account.provider)
                        agentAccounts = AgentAccountStatus.current(descriptors: store.agentDescriptors)
                        Telemetry.breadcrumb("agent_creds", "removed from phone",
                            data: ["provider": account.provider.rawValue])
                    } label: {
                        Label("Remove from phone", systemImage: "iphone.slash")
                    }
                }
                // Only when a connected box exists. Removes the app-pushed
                // credential from the broker store, NOT the box owner's shell
                // login.
                if store.connectedBoxName != nil {
                    Button(role: .destructive) {
                        let provider = account.provider
                        let endpoint = store.endpoint
                        Task {
                            await store.clearAgentCredential(provider: provider, on: endpoint)
                            await store.refreshModelCatalog()
                        }
                    } label: {
                        Label("Remove pushed credential from this box", systemImage: "externaldrive.badge.minus")
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(neon.textDim)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("\(account.displayName) account options")
        }

        // MARK: Usage & limits (account-wide, BOTH agents)

        /// Account-level plan limits for BOTH agents (claude + codex), each
        /// with its 5-hour AND weekly window (handoff §A.2). Reads the
        /// freshest account-usage values off any session of that agent.
        private var usageLimitsSection: some View {
            sectionCard(title: "Usage & limits") {
                VStack(spacing: 0) {
                    AgentUsageRows(agent: "claude", tint: neon.claude)
                    Divider()
                        .background(neon.border)
                        .padding(.horizontal, 14)
                    AgentUsageRows(agent: "codex", tint: neon.codex)
                }
                .padding(.vertical, 4)
            }
        }

        // MARK: Appearance (one grouped card, Terminal folded in)

        /// ONE grouped Appearance card (handoff §A.3, renders 03/04): Theme
        /// segmented, accent-palette swatches, the type-forward Chat font +
        /// Terminal font strips, the Terminal colors row, Text size slider,
        /// and Glow & scanlines — plus the live `conduit --theme <id>` chip.
        private var appearanceSection: some View {
            @Bindable var appearance = appearance
            return VStack(alignment: .leading, spacing: 10) {
                Text("Appearance")
                    .font(neon.mono(11.5).weight(.bold))
                    .foregroundStyle(neon.textFaint)
                    .tracking(1.6)
                    .textCase(.uppercase)
                    .padding(.horizontal, 4)

                VStack(alignment: .leading, spacing: 0) {
                    // Theme — segmented System / Light / Dark.
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Theme")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(neon.text)
                        Picker("Theme", selection: $appearance.themeMode) {
                            ForEach(AppearanceStore.ThemeMode.allCases) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 13)

                    Divider().background(neon.border)

                    // Accent palette — Ice / Synth / Matrix / Amber swatches.
                    VStack(alignment: .leading, spacing: 11) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Accent palette")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(neon.text)
                            Spacer(minLength: 6)
                            Text(appearance.neonPalette.label)
                                .font(neon.mono(13))
                                .foregroundStyle(neon.accent)
                        }
                        HStack(spacing: 9) {
                            ForEach(AppearanceStore.NeonPaletteChoice.allCases) { palette in
                                ConduitUI.NeonPaletteSwatch(palette: palette)
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 13)

                    Divider().background(neon.border)

                    // Chat font — type-forward preview-card strip.
                    chatFontRow

                    // Terminal font — type-forward preview-card strip.
                    terminalFontRow

                    Divider().background(neon.border)

                    // Terminal colors — drill-in to the libghostty theme picker.
                    NavigationLink {
                        TerminalThemePicker()
                    } label: {
                        ConduitUI.ListRow(
                            icon: "paintpalette.fill",
                            title: "Terminal colors",
                            subtitle: nil,
                            iconTint: neon.accent
                        ) {
                            drillValue(appearance.terminalTheme.label)
                        }
                    }
                    .buttonStyle(.plain)

                    Divider().background(neon.border)

                    // Text size — slider over the typography ramp base.
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 12) {
                            Image(systemName: "textformat.size")
                                .font(.body)
                                .frame(width: 20)
                                .foregroundStyle(neon.accent)
                            Text("Text size")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(neon.text)
                            Spacer(minLength: 6)
                            Text("\(Int(appearance.bodyPointSize))pt")
                                .font(neon.mono(14.5).weight(.bold))
                                .foregroundStyle(neon.accent)
                        }
                        Slider(
                            value: $appearance.bodyPointSize,
                            in: AppearanceStore.bodyPointSizeRange,
                            step: 1
                        )
                        .tint(neon.accent)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 13)

                    Divider().background(neon.border)

                    // Glow & scanlines.
                    ConduitUI.toggleRow(
                        icon: "sparkles",
                        title: "Glow & scanlines",
                        subtitle: neon.dark ? "neon halos · on dark" : "neon halos · dimmed in light",
                        isOn: $appearance.neonGlow
                    )
                }
                .neonCardSurface(neon, fill: neon.surface, cornerRadius: 14)

                // Live preview chip (terminal-styled `conduit --theme <id>`).
                ConduitUI.NeonThemePreviewChip()
            }
        }

        /// Chat-font row (handoff §4): header (title + current pairing's face
        /// names) over a horizontal strip of live pairing cards. Each card
        /// shows the PROSE "Ag" and a MONO `$>` token so the prose-vs-mono
        /// split is honest at a glance.
        private var chatFontRow: some View {
            VStack(alignment: .leading, spacing: 11) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Chat font")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(neon.text)
                    Spacer(minLength: 6)
                    Text(appearance.fontFamily.note)
                        .font(neon.mono(11))
                        .foregroundStyle(neon.textFaint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                fontStripScroll {
                    ForEach(AppearanceStore.FontFamily.allCases) { family in
                        Button {
                            appearance.fontFamily = family
                        } label: {
                            pairingFontCard(
                                family: family,
                                selected: appearance.fontFamily == family
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 6)
        }

        /// One pairing card: PROSE "Ag" big + a MONO `$>` token beneath, then
        /// the pairing name. Renders in the pairing's own faces so the strip
        /// is a live specimen. Selected card gets the accent border + glow.
        private func pairingFontCard(family: AppearanceStore.FontFamily, selected: Bool) -> some View {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Ag")
                        .font(family.proseFont(size: 30))
                        .foregroundStyle(neon.text)
                        .lineLimit(1)
                    Text("$>")
                        .font(family.monoFont(size: 18))
                        .foregroundStyle(neon.accent)
                        .lineLimit(1)
                }
                .frame(height: 34, alignment: .center)
                Text(family.label)
                    .font(neon.mono(11).weight(selected ? .bold : .regular))
                    .foregroundStyle(selected ? neon.accent : neon.textFaint)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(width: 128, alignment: .leading)
            .padding(EdgeInsets(top: 13, leading: 13, bottom: 11, trailing: 13))
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(selected ? neon.accent.opacity(0.08) : neon.surface2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(selected ? neon.accent : neon.border, lineWidth: selected ? 1.6 : 1)
            )
            .neonGlowBox(selected && neon.glow ? neon.glowBox?.tinted(neon.accent) : nil)
            .contentShape(Rectangle())
        }

        /// Terminal-font row: same type-forward strip, each card a mono `x>`
        /// sample in the terminal face. The terminal fonts are left as-is.
        private var terminalFontRow: some View {
            VStack(alignment: .leading, spacing: 11) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Terminal font")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(neon.text)
                    Spacer(minLength: 6)
                    Text(appearance.terminalFont.label)
                        .font(neon.mono(13))
                        .foregroundStyle(neon.textFaint)
                }
                fontStripScroll {
                    ForEach(GhosttyFont.allCases) { font in
                        Button {
                            appearance.terminalFont = font
                        } label: {
                            fontCard(
                                sample: "x>",
                                name: font.label,
                                selected: appearance.terminalFont == font,
                                sampleFont: terminalSampleFont(font, size: 26)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .padding(.bottom, 14)
        }

        /// SwiftUI font that renders a terminal face for the preview card,
        /// falling back to the system monospaced face for `system` / any
        /// unregistered family.
        private func terminalSampleFont(_ font: GhosttyFont, size: CGFloat) -> Font {
            if let name = font.previewFontName, !UIFont.fontNames(forFamilyName: name).isEmpty {
                return .custom(name, fixedSize: size)
            }
            return .system(size: size, weight: .regular, design: .monospaced)
        }

        /// One preview card in a font strip: a big glyph sample in the face,
        /// the name beneath. Selected card gets the accent border + glow.
        private func fontCard(sample: String, name: String, selected: Bool, sampleFont: Font) -> some View {
            VStack(alignment: .leading, spacing: 9) {
                Text(sample)
                    .font(sampleFont)
                    .foregroundStyle(neon.text)
                    .lineLimit(1)
                    .frame(height: 34, alignment: .center)
                Text(name)
                    .font(neon.mono(11).weight(selected ? .bold : .regular))
                    .foregroundStyle(selected ? neon.accent : neon.textFaint)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(width: 128, alignment: .leading)
            .padding(EdgeInsets(top: 13, leading: 13, bottom: 11, trailing: 13))
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(selected ? neon.accent.opacity(0.08) : neon.surface2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(selected ? neon.accent : neon.border, lineWidth: selected ? 1.6 : 1)
            )
            .neonGlowBox(selected && neon.glow ? neon.glowBox?.tinted(neon.accent) : nil)
            .contentShape(Rectangle())
        }

        /// Horizontal strip with a soft right-edge fade hinting it scrolls.
        @ViewBuilder
        private func fontStripScroll<C: View>(@ViewBuilder _ content: () -> C) -> some View {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 11) {
                    content()
                }
                .padding(.vertical, 3)
                .padding(.trailing, 8)
            }
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: 0.9),
                        .init(color: .clear, location: 1.0),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
        }

        // MARK: Notifications (WS-P.3)

        /// Push notification settings: honest-state row showing
        ///   · "box doesn't support push" — old broker, no relay wired
        ///   · "disabled in Settings" — system permission denied
        ///   · "authorized · registered with box" — all good
        ///   · "authorized · not registered" — token pending or reg failed
        ///   · "not set up" — not yet determined
        /// Plus a "Send test notification" button to end-to-end verify.
        private var notificationsSection: some View {
            sectionCard(title: "Notifications") {
                VStack(spacing: 0) {
                    pushStateRow
                    if pushManager.settingsState.auth == .authorized
                        && pushManager.settingsState.brokerSupported {
                        Divider()
                            .background(neon.border)
                            .padding(.leading, 46)
                        testPushRow
                    }
                }
                .onAppear {
                    // Refresh both auth and capabilities when this section
                    // appears (e.g. user returns from iOS Settings).
                    pushManager.refreshAuthStatus()
                    let ep = store.endpoint
                    Task { await PushNotificationManager.shared.probeCapabilities(endpoint: ep) }
                }
            }
        }

        private var pushStateRow: some View {
            let state = pushManager.settingsState
            let (icon, iconTint, subtitle): (String, Color, String) = {
                if !state.brokerSupported {
                    return ("bell.slash", neon.textFaint, "box doesn't support push")
                }
                switch state.auth {
                case .notDetermined:
                    return ("bell", neon.textDim, "not set up")
                case .denied:
                    return ("bell.slash.fill", neon.yellow, "disabled in iOS Settings")
                case .pending:
                    return ("bell.badge", neon.accent, "waiting for system token…")
                case .authorized:
                    return state.registered
                        ? ("bell.badge.fill", neon.green, "authorized · registered with box")
                        : ("bell.badge", neon.accent, "authorized · not registered")
                }
            }()
            return ConduitUI.ListRow(
                icon: icon,
                title: "Push notifications",
                subtitle: subtitle,
                iconTint: iconTint
            ) {
                // Broker supports push but permission has not been asked yet.
                // Users who already had sessions at launch never saw the 0->1
                // prompt, so give them an explicit affordance here.
                if state.brokerSupported && state.auth == .notDetermined {
                    Button("Enable") {
                        Telemetry.breadcrumb("push", "settings notDetermined enable tapped")
                        PushNotificationManager.shared.requestAuthorizationIfNeeded()
                    }
                    .font(neon.sans(13).weight(.semibold))
                    .foregroundStyle(neon.accent)
                }
                // If permission is denied, offer a shortcut to Settings.
                if state.auth == .denied {
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                    .font(neon.sans(13).weight(.semibold))
                    .foregroundStyle(neon.accent)
                }
            }
        }

        private var testPushRow: some View {
            HStack(spacing: 12) {
                Image(systemName: "arrow.up.message")
                    .font(.body)
                    .frame(width: 20)
                    .foregroundStyle(neon.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Send test notification")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(neon.text)
                    if let result = testPushResult {
                        Text(result)
                            .font(neon.mono(11.5))
                            .foregroundStyle(result.hasPrefix("Sent") ? neon.green : neon.yellow)
                    }
                }
                Spacer(minLength: 8)
                if testPushInFlight {
                    ProgressView()
                        .tint(neon.accent)
                        .scaleEffect(0.8)
                } else {
                    Button("Send") {
                        sendTestPush()
                    }
                    .font(neon.sans(13).weight(.semibold))
                    .foregroundStyle(neon.accent)
                    .disabled(testPushInFlight)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }

        private func sendTestPush() {
            testPushInFlight = true
            testPushResult = nil
            let ep = store.endpoint
            Task {
                let err = await PushNotificationManager.shared.sendTestPush(
                    endpoint: ep,
                    title: "Conduit test",
                    body: "Push notifications are working"
                )
                testPushInFlight = false
                testPushResult = err == nil ? "Sent — check your device" : "Error: \(err!)"
                // Clear the result after a few seconds
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                testPushResult = nil
            }
        }

        // MARK: Conversation

        private var conversationSection: some View {
            @Bindable var appearance = appearance
            @Bindable var flags = flags
            return sectionCard(title: "Conversation") {
                VStack(spacing: 0) {
                    ConduitUI.toggleRow(
                        icon: "arrow.up.arrow.down",
                        title: "Collapse Turns",
                        subtitle: "Start command cards collapsed by default",
                        isOn: $appearance.collapseTurns
                    )
                    Divider()
                        .background(neon.border)
                        .padding(.leading, 46)
                    ConduitUI.toggleRow(
                        icon: "hand.tap",
                        title: "Reply Haptics",
                        subtitle: "Tap when a reply starts and finishes",
                        isOn: $flags.replyHaptics
                    )
                }
            }
        }

        // MARK: Agents (new-session picker toggles)

        /// Which agents are offered in the new-session picker. Matches
        /// `FeatureFlags.enabledAgents`. One toggle per known agent (claude,
        /// codex, gemini, opencode); defaults claude+codex on. Prevents
        /// disabling the last enabled agent -- the picker must always have at
        /// least one choice.
        private var agentsSection: some View {
            @Bindable var flags = flags
            let knownAgents: [(id: String, label: String, icon: String)] = [
                ("claude",   "Claude",   "cpu"),
                ("codex",    "Codex",    "curlybraces"),
                ("gemini",   "Gemini",   "sparkle"),
                ("opencode", "Opencode", "chevron.left.forwardslash.chevron.right"),
            ]
            return sectionCard(title: "Agents") {
                VStack(spacing: 0) {
                    ForEach(Array(knownAgents.enumerated()), id: \.element.id) { idx, agent in
                        let enabled = flags.enabledAgents.contains(agent.id)
                        let isLast = flags.enabledAgents.count == 1 && enabled
                        let tint = neon.agentTint(forAgent: agent.id)
                        ConduitUI.ListRow(
                            icon: agent.icon,
                            title: agent.label,
                            subtitle: nil,
                            iconTint: tint
                        ) {
                            Toggle("", isOn: Binding(
                                get: { enabled },
                                set: { on in
                                    var next = flags.enabledAgents
                                    if on {
                                        if !next.contains(agent.id) { next.append(agent.id) }
                                    } else if !isLast {
                                        next.removeAll { $0 == agent.id }
                                    }
                                    flags.enabledAgents = next
                                    Telemetry.breadcrumb("settings", "agent toggle",
                                        data: ["agent": agent.id, "on": "\(on)"])
                                }
                            ))
                            .labelsHidden()
                            .tint(tint)
                            .disabled(isLast)
                        }
                        if idx < knownAgents.count - 1 {
                            Divider()
                                .background(neon.border)
                                .padding(.leading, 46)
                        }
                    }
                }
            }
        }

        // MARK: Labs (handoff §2 — chat A/B + Debug)

        /// Settings › Labs (`01-ab`): the user-facing "Conversation style"
        /// A/B/Auto control, plus a drill-in to the staff Debug menu. The
        /// segments override the chat shell locally; `Auto` defers to the
        /// assigned experiment bucket without changing the logged bucket.
        private var labsSection: some View {
            @Bindable var flags = flags
            return sectionCard(title: "Labs") {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Conversation style")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(neon.text)
                            Spacer(minLength: 6)
                            Text(flags.resolvedChatArm.label)
                                .font(neon.mono(11))
                                .foregroundStyle(neon.textFaint)
                        }
                        Picker("Conversation style", selection: $flags.chatStylePreference) {
                            ForEach(FeatureFlags.ChatStylePreference.allCases) { pref in
                                Text(pref.label).tag(pref)
                            }
                        }
                        .pickerStyle(.segmented)
                        .tint(neon.accent)
                        Text("A = Breathe · B = Signature · Auto follows your assigned bucket.")
                            .font(neon.mono(10.5))
                            .foregroundStyle(neon.textFaint)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)

                    Divider()
                        .background(neon.border)
                        .padding(.leading, 14)

                    NavigationLink {
                        ConduitUI.DebugMenuView()
                    } label: {
                        ConduitUI.ListRow(
                            icon: "ladybug",
                            title: "Debug menu",
                            subtitle: "Experiment buckets & feature flags",
                            iconTint: neon.accent
                        ) {
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(neon.textFaint)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }

        // MARK: Support / Buy me a coffee

        /// External donation link (not an IAP — Apple explicitly permits
        /// genuine tip-jar links that open outside the app).
        private var supportSection: some View {
            sectionCard(title: "Support") {
                Button {
                    Telemetry.breadcrumb("settings", "buy-me-a-coffee tapped")
                    if let url = URL(string: kSupportDonationURL) {
                        openURL(url)
                    }
                } label: {
                    ConduitUI.ListRow(
                        icon: "cup.and.saucer.fill",
                        title: "Buy me a coffee",
                        subtitle: "Support Conduit development",
                        iconTint: neon.accent
                    ) {
                        Image(systemName: "arrow.up.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(neon.textFaint)
                    }
                }
                .buttonStyle(.plain)
            }
        }

        // MARK: About

        private var aboutSection: some View {
            sectionCard(title: "About") {
                VStack(spacing: 0) {
                    ConduitUI.valueRow(
                        icon: "info.circle.fill",
                        title: "Conduit",
                        value: aboutVersion,
                        subtitle: nil
                    )
                    Divider()
                        .background(neon.border)
                        .padding(.leading, 46)
                    // "How it works" row — re-opens the onboarding guide.
                    if let openOnboarding = onOpenOnboarding {
                        Button {
                            Telemetry.breadcrumb("settings", "how_it_works_tapped")
                            openOnboarding()
                        } label: {
                            ConduitUI.ListRow(
                                icon: "sparkles",
                                title: "How it works",
                                subtitle: "Add a box, run agents, work from anywhere",
                                iconTint: neon.accent
                            ) {
                                Image(systemName: "chevron.right")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(neon.textFaint)
                            }
                        }
                        .buttonStyle(.plain)
                        Divider()
                            .background(neon.border)
                            .padding(.leading, 46)
                    }
                    NavigationLink {
                        ConduitUI.LicensesView()
                    } label: {
                        ConduitUI.ListRow(
                            icon: "doc.text",
                            title: "Licenses",
                            subtitle: "Open source & trademark attribution",
                            iconTint: neon.accent
                        ) {
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(neon.textFaint)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }

        private var aboutVersion: String {
            BuildInfo.isStamped
                ? "\(BuildInfo.releaseTag) (\(BuildInfo.gitSHA))"
                : "\(BuildInfo.marketingVersion) (dev)"
        }

        // MARK: Layout helpers

        private func drillValue(_ value: String) -> some View {
            HStack(spacing: 6) {
                Text(value)
                    .font(neon.mono(12.5))
                    .foregroundStyle(neon.textFaint)
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(neon.textFaint)
            }
        }

        @ViewBuilder
        private func sectionCard<C: View>(title: String, @ViewBuilder content: () -> C) -> some View {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(neon.mono(11.5).weight(.bold))
                    .foregroundStyle(neon.textFaint)
                    .tracking(1.6)
                    .textCase(.uppercase)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 4)
                content()
                    .neonCardSurface(neon, fill: neon.surface, cornerRadius: 14)
            }
        }
    }

    // MARK: - Usage & limits · per-agent window rows

    /// Account-wide plan limits for one agent (claude or codex): the 5-hour
    /// and weekly windows, with a refresh affordance. Reads the freshest
    /// account-usage values off any session of `agent` (the numbers are
    /// per-account, not per-session). Shows honest "—"/"tap refresh" when no
    /// data has arrived — never a fabricated percentage.
    struct AgentUsageRows: View {
        let agent: String
        let tint: Color
        @Environment(SessionStore.self) private var store
        @Environment(\.neonTheme) private var neon
        private let now = Date()

        var body: some View {
            let snap = agentUsage()
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Circle().fill(tint).frame(width: 6, height: 6)
                    Text(agent)
                        .font(neon.mono(11.5).weight(.semibold))
                        .foregroundStyle(tint)
                    Spacer(minLength: 6)
                    Button {
                        if let id = snap.sourceSessionID {
                            store.refreshAccountUsage(sessionID: id)
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(snap.sourceSessionID == nil ? neon.textFaint : neon.accent)
                            .frame(width: 26, height: 26)
                            .background(Circle().fill(neon.surface))
                            .overlay(Circle().stroke(neon.border, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .disabled(snap.sourceSessionID == nil)
                    .accessibilityLabel("Refresh \(agent) usage")
                }
                if snap.sourceSessionID == nil {
                    Text("no \(agent) session — start one to see limits")
                        .font(neon.mono(10.5))
                        .foregroundStyle(neon.textFaint)
                } else {
                    window(label: "5-hour", pct: snap.fivePct, resetsAt: snap.fiveResetsAt)
                    window(label: "Weekly", pct: snap.weekPct, resetsAt: snap.weekResetsAt)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }

        @ViewBuilder
        private func window(label: String, pct: Double?, resetsAt: String?) -> some View {
            let frac = CGFloat(max(0, min(1, (pct ?? 0) / 100)))
            let barTint = tint
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(label.uppercased())
                        .font(neon.mono(10).weight(.semibold))
                        .foregroundStyle(neon.textFaint)
                        .tracking(1.2)
                    Spacer(minLength: 6)
                    Text(pct.map { "\(Int($0.rounded()))%" } ?? "—")
                        .font(neon.mono(13).weight(.bold))
                        .foregroundStyle(pct == nil ? neon.textFaint : neon.text)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(neon.border)
                        Capsule().fill(barTint)
                            .frame(width: max(0, geo.size.width * frac))
                            .neonGlowBox(neon.glow ? neon.glowBox?.tinted(barTint) : nil)
                    }
                }
                .frame(height: 8)
                Text(ConduitUI.AccountUsageFormat.resetCaption(resetsAt, now: now))
                    .font(neon.mono(10.5))
                    .foregroundStyle(neon.textDim)
            }
        }

        /// Freshest account-usage values across this agent's sessions (live
        /// status frame preferred, session snapshot as fallback).
        private func agentUsage() -> SessionStore.AccountUsageSnapshot {
            for s in store.sessions where s.assistant == agent {
                let st = store.statusBySession[s.id]
                let five = st?.account5hPct ?? s.account5hPct
                let week = st?.account7dPct ?? s.account7dPct
                if five != nil || week != nil {
                    return SessionStore.AccountUsageSnapshot(
                        fivePct: five,
                        fiveResetsAt: st?.account5hResetsAt ?? s.account5hResetsAt,
                        weekPct: week,
                        weekResetsAt: st?.account7dResetsAt ?? s.account7dResetsAt,
                        sourceSessionID: s.id
                    )
                }
            }
            return SessionStore.AccountUsageSnapshot(
                sourceSessionID: store.sessions.first(where: { $0.assistant == agent })?.id
            )
        }
    }

    // MARK: - Server switcher (drill-in from the active server row)

    /// Saved-server list reached from Connection's active-server row. Tap a
    /// row to switch the active server (and dial in); swipe to forget.
    /// Carries the Add Server affordance too so every server action lives in
    /// one place.
    struct ServerSwitcherView: View {
        @Environment(SessionStore.self) private var store
        @Environment(\.neonTheme) private var neon
        @State private var showAddServer = false
        @State private var pendingServerDelete: PendingServerDelete?
        // Rename flow: hold the server being renamed + the editable name.
        @State private var pendingRename: SavedServer?
        @State private var renameText: String = ""
        // Async reachability probe for inactive boxes: nil=unknown, true=up, false=down.
        @State private var boxReachability: [String: Bool?] = [:]

        var body: some View {
            ZStack {
                GlassAppBackground()
                ScrollView {
                    VStack(spacing: 0) {
                        if !store.savedServers.isEmpty {
                            List {
                                ForEach(store.savedServers) { server in
                                    boxRow(server)
                                        .listRowBackground(Color.clear)
                                        .listRowSeparator(.hidden)
                                        .listRowInsets(EdgeInsets())
                                        .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                            Button {
                                                pendingRename = server
                                                renameText = server.name
                                            } label: {
                                                Label("Rename", systemImage: "pencil")
                                            }
                                            .tint(neon.accent)
                                        }
                                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                            Button(role: .destructive) {
                                                pendingServerDelete = PendingServerDelete(id: server.id, name: server.name)
                                            } label: {
                                                Label("Forget", systemImage: "trash")
                                            }
                                        }
                                        .contextMenu {
                                            Button {
                                                pendingRename = server
                                                renameText = server.name
                                            } label: {
                                                Label("Rename", systemImage: "pencil")
                                            }
                                            Button(role: .destructive) {
                                                pendingServerDelete = PendingServerDelete(id: server.id, name: server.name)
                                            } label: {
                                                Label("Forget", systemImage: "trash")
                                            }
                                        }
                                }
                            }
                            .listStyle(.plain)
                            .scrollContentBackground(.hidden)
                            .scrollDisabled(true)
                            .frame(height: CGFloat(store.savedServers.count) * 64)

                            Divider().background(neon.border).padding(.leading, 46)
                        }

                        Button {
                            showAddServer = true
                        } label: {
                            ConduitUI.ListRow(
                                icon: "plus.circle.fill",
                                title: "Add Box",
                                subtitle: nil,
                                iconTint: neon.accent
                            ) {
                                Image(systemName: "chevron.right")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(neon.textFaint)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .neonCardSurface(neon, fill: neon.surface, cornerRadius: 14)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 18)
                }
                .scrollIndicators(.hidden)
            }
            .navigationTitle("Boxes")
            .navigationBarTitleDisplayMode(.inline)
            .tint(neon.accent)
            .appearanceColorScheme()
            .sheet(isPresented: $showAddServer) {
                ConduitUI.AddServerSheet()
            }
            .alert(
                "Rename box",
                isPresented: Binding(
                    get: { pendingRename != nil },
                    set: { if !$0 { pendingRename = nil } }
                ),
                presenting: pendingRename
            ) { target in
                TextField("Name", text: $renameText)
                    .autocorrectionDisabled(true)
                Button("Save") {
                    store.renameServer(target.id, to: renameText)
                    pendingRename = nil
                }
                Button("Cancel", role: .cancel) {
                    pendingRename = nil
                }
            } message: { target in
                Text("Enter a new name for \(target.name).")
            }
            .alert(
                "Forget box?",
                isPresented: Binding(
                    get: { pendingServerDelete != nil },
                    set: { if !$0 { pendingServerDelete = nil } }
                ),
                presenting: pendingServerDelete
            ) { target in
                Button("Forget", role: .destructive) {
                    store.forgetServer(target.id)
                    pendingServerDelete = nil
                }
                Button("Cancel", role: .cancel) {
                    pendingServerDelete = nil
                }
            } message: { target in
                Text("Drops the saved pairing for \(target.name). Sessions already running on this box keep running until you delete them.")
            }
            .task {
                // Probe reachability for inactive boxes once on appear.
                await probeInactiveBoxes()
            }
        }

        // MARK: - Row

        @ViewBuilder
        private func boxRow(_ server: SavedServer) -> some View {
            let isActive = server.endpoint == store.endpoint
            // boxReachability[id] is Bool?? (outer = key presence, inner = probed value)
            let probed: Bool? = boxReachability[server.id] ?? nil
            // SSH/tunneled boxes can't be probed at rest (loopback endpoint) --
            // show a neutral hint instead of a misleading "offline".
            let isLoopback = isLoopbackEndpoint(server.endpoint)
            let dotColor: Color = isActive ? neon.green : (probed == true ? neon.green : neon.textFaint)
            let statusText: String = isActive ? "connected"
                : (probed == true ? "reachable"
                    : (probed == false ? "offline"
                        : (isLoopback ? "SSH - tap Connect" : "")))
            Button {
                if !isActive {
                    Telemetry.breadcrumb("boxes", "switch box", data: ["id": server.id, "name": server.name])
                    store.selectSavedServer(server.id, autoConnect: true)
                }
            } label: {
                HStack(spacing: 12) {
                    // Status dot
                    Circle()
                        .fill(isActive ? neon.green : (probed == true ? neon.green.opacity(0.7) : neon.border))
                        .frame(width: 8, height: 8)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(server.name)
                                .font(neon.sans(14).weight(.semibold))
                                .foregroundStyle(neon.text)
                            if server.isDefault {
                                Text("PRIMARY")
                                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                                    .tracking(0.5)
                                    .foregroundStyle(neon.green)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(neon.green.opacity(0.15)))
                                    .overlay(Capsule().stroke(neon.green.opacity(0.4), lineWidth: 1))
                            }
                        }
                        HStack(spacing: 5) {
                            if !statusText.isEmpty {
                                Text(statusText)
                                    .font(neon.mono(10.5).weight(.medium))
                                    .foregroundStyle(dotColor)
                            }
                            if !statusText.isEmpty && !boxDisplayHost(server).isEmpty {
                                Text("·").font(neon.mono(10)).foregroundStyle(neon.textFaint)
                            }
                            Text(boxDisplayHost(server))
                                .font(neon.mono(10.5))
                                .foregroundStyle(neon.textDim)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }

                    Spacer(minLength: 4)

                    if isActive {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(neon.green)
                    } else {
                        Text("Connect")
                            .font(neon.mono(11).weight(.bold))
                            .foregroundStyle(neon.accent)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .disabled(isActive)
        }

        // MARK: - Reachability probe

        /// True when the endpoint points at the local loopback (an SSH tunnel's
        /// 127.0.0.1:<ephemeral port>). Such an endpoint only listens while the
        /// tunnel is connected, so it can't be probed for reachability at rest.
        private func isLoopbackEndpoint(_ endpoint: StoredEndpoint) -> Bool {
            let host = URLComponents(string: endpoint.url)?.host?.lowercased()
            return host == "127.0.0.1" || host == "localhost" || host == "::1"
        }

        /// Subtitle host for a box row: prefer the real SSH host:port when the
        /// stored endpoint is a loopback tunnel address (so the row shows the
        /// machine, not 127.0.0.1:<ephemeral port>).
        private func boxDisplayHost(_ server: SavedServer) -> String {
            if isLoopbackEndpoint(server.endpoint), let ssh = server.ssh, !ssh.host.isEmpty {
                return "\(ssh.host):\(ssh.port)"
            }
            return server.endpoint.displayHost
        }

        private func probeInactiveBoxes() async {
            for server in store.savedServers {
                let isActive = server.endpoint == store.endpoint
                guard !isActive else {
                    await MainActor.run { boxReachability[server.id] = .some(true) }
                    continue
                }
                let serverID = server.id
                // SSH/tunneled boxes expose a 127.0.0.1:<ephemeral port>
                // endpoint that only listens while the tunnel is up, so an
                // HTTP probe always fails at rest -> a misleading "offline".
                // Leave reachability UNKNOWN (nil) for these; the row shows a
                // neutral "SSH - tap Connect" instead.
                if isLoopbackEndpoint(server.endpoint) {
                    Telemetry.breadcrumb("boxes", "probe skipped: loopback/tunnel endpoint",
                        data: ["id": serverID, "name": server.name])
                    // Mark the key present but the probed value unknown (nil)
                    // so the row treats it as neutral, never "offline".
                    // updateValue stores a present key with a nil value;
                    // `dict[key] = nil` would instead REMOVE the key.
                    await MainActor.run { boxReachability.updateValue(nil, forKey: serverID) }
                    continue
                }
                guard let base = server.endpoint.httpBaseURL,
                      let url = URL(string: "/api/capabilities", relativeTo: base) else {
                    await MainActor.run { boxReachability[serverID] = .some(false) }
                    continue
                }
                do {
                    var req = URLRequest(url: url)
                    req.timeoutInterval = 5
                    req.httpMethod = "GET"
                    let (_, resp) = try await URLSession.shared.data(for: req)
                    let up = (resp as? HTTPURLResponse).map { $0.statusCode < 500 } ?? false
                    await MainActor.run { boxReachability[serverID] = .some(up) }
                } catch {
                    await MainActor.run { boxReachability[serverID] = .some(false) }
                }
            }
        }
    }

    // MARK: - Drill-in pickers

    /// Terminal color-theme drill-in target — the native (libghostty) terminal
    /// color theme. Applies live via `AppearanceStore.terminalTheme`.
    struct TerminalThemePicker: View {
        @Environment(AppearanceStore.self) private var appearance
        @Environment(\.neonTheme) private var neon

        var body: some View {
            @Bindable var appearance = appearance
            return pickerList(title: "Terminal colors") {
                ForEach(GhosttyTheme.allCases) { theme in
                    Button {
                        appearance.terminalTheme = theme
                    } label: {
                        ConduitUI.ListRow(
                            icon: "paintpalette.fill",
                            title: theme.label,
                            subtitle: nil,
                            iconTint: neon.accent
                        ) {
                            if appearance.terminalTheme == theme {
                                Image(systemName: "checkmark")
                                    .font(.footnote.weight(.bold))
                                    .foregroundStyle(neon.accent)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    pickerDivider(after: theme, in: GhosttyTheme.allCases, neon: neon)
                }
            }
        }
    }
}

// MARK: - Shared picker chrome (free helpers, used by the drill-in screens)

/// A drill-in picker screen: the same neon-card list the Settings sections
/// use, hosted full-screen with a nav title.
@ViewBuilder
private func pickerList<C: View>(title: String, @ViewBuilder content: @escaping () -> C) -> some View {
    PickerListShell(title: title, content: content)
}

private struct PickerListShell<C: View>: View {
    let title: String
    @ViewBuilder var content: () -> C
    @Environment(\.neonTheme) private var neon

    var body: some View {
        ZStack {
            GlassAppBackground()
            ScrollView {
                VStack(spacing: 0) {
                    content()
                }
                .neonCardSurface(neon, fill: neon.surface, cornerRadius: 14)
                .padding(.horizontal, 16)
                .padding(.vertical, 18)
            }
            .scrollIndicators(.hidden)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .tint(neon.accent)
        .appearanceColorScheme()
    }
}

/// Hairline between picker rows, skipped after the last element.
@ViewBuilder
private func pickerDivider<T: Equatable>(after element: T, in collection: [T], neon: NeonTheme) -> some View {
    if let idx = collection.firstIndex(of: element), idx < collection.count - 1 {
        Divider()
            .background(neon.border)
            .padding(.leading, 46)
    }
}

/// Carrier for the Servers Forget confirmation alert.
private struct PendingServerDelete: Identifiable, Equatable {
    let id: String
    let name: String
}
