import SwiftUI
import GhosttyVT

// MARK: - ConduitSettingsView
//
// Conduit redesign Settings screen (handoff §A.2, image 03). The shipped
// build had ~11 stacked sections with appearance shattered across six of
// them. This collapses the IA to exactly eight, top to bottom:
//
//   identity · Account · Usage & limits · Appearance · Terminal ·
//   Conversation · Servers · About
//
//   • identity      — a `>conduit` wordmark card (mono, the `>` cyan-
//                     tinted) + version/build line + a live/offline badge.
//   • Account       — pairing row + "Sign in to agent" (sheets unchanged).
//   • Usage & limits— account-wide, BOTH agents (claude + codex), each with
//                     a 5-hour AND a weekly window (bar / % / reset).
//   • Appearance    — ONE grouped card: Theme segmented, accent palette
//                     swatches, App font drill-in, Text size slider, Glow &
//                     scanlines toggle, + the `conduit --theme ice` chip.
//   • Terminal      — Color theme / Font as drill-in rows (picker sub-views).
//   • Conversation  — collapse-turns toggle.
//   • Servers       — saved servers + Add Server (swipe-to-forget).
//   • About         — version + licenses.
//
// Presentation + IA only: every store/AppearanceStore binding, sheet, and
// navigation path is preserved from the prior build.

extension ConduitUI {

    struct SettingsView: View {
        @Environment(SessionStore.self) private var store
        @Environment(AppearanceStore.self) private var appearance
        @Environment(\.neonTheme) private var neon
        @Environment(\.dismiss) private var dismiss
        @Environment(\.colorScheme) private var colorScheme

        /// When true the screen is hosted inline as a tablet section pane
        /// (not a sheet), so the "Done" affordance is dropped — there's
        /// nothing to dismiss.
        var embedded: Bool = false

        @State private var showAddServer = false
        @State private var showAgentLogin = false
        /// Saved-server pending deletion (drives the confirmation alert
        /// for the Settings → Servers swipe-to-delete affordance).
        @State private var pendingServerDelete: PendingServerDelete?

        var body: some View {
            @Bindable var appearance = appearance

            NavigationStack {
                ZStack {
                    GlassAppBackground()

                    ScrollView {
                        VStack(spacing: 18) {
                            identityCard
                            accountSection
                            usageLimitsSection
                            appearanceSection
                            terminalSection
                            conversationSection
                            serversSection
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
                            // Plain Button (no copper-tint overlay) per
                            // PLAN-CONDUIT-VISUAL-PARITY audit §A.3.5 — upstream
                            // uses a flat `.confirmationAction` link, not a
                            // tinted capsule. The surrounding NavigationStack
                            // `.tint(neon.accent)` still
                            // picks up the accent colour on the link itself,
                            // we just stop double-painting it.
                            Button("Done") { dismiss() }
                        }
                    }
                }
                .sheet(isPresented: $showAddServer) {
                    ConduitUI.AddServerSheet()
                }
                .sheet(isPresented: $showAgentLogin) {
                    ConduitUI.AgentLoginSheet()
                }
                .alert(
                    "Forget server?",
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
                    Text("Drops the saved pairing for \(target.name). Sessions already running on this server keep running until you delete them.")
                }
            }
            // Re-bind \.colorScheme to the AppearanceStore so a runtime
            // theme swap from Settings → Appearance updates THIS sheet
            // live, not just the underlying RootView (see
            // `AppearanceColorScheme.swift`).
            .appearanceColorScheme()
        }

        // MARK: identity

        /// `>conduit` wordmark card (BRAND.md §1: lowercase JetBrains Mono,
        /// the `>` tinted with the cyan accent) + the daemon mark, the
        /// version/build line, and a live/offline status badge.
        private var identityCard: some View {
            HStack(spacing: 12) {
                ConduitUI.ConduitMark(size: 30, glow: neon.glow)
                    .frame(width: 46, height: 46)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(neon.surface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(neon.border, lineWidth: 1)
                    )
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 0) {
                        Text(">")
                            .font(neon.mono(18).weight(.bold))
                            .foregroundStyle(neon.accent)
                            .neonTextGlow(neon.textGlow)
                        Text("conduit")
                            .font(neon.mono(18).weight(.bold))
                            .foregroundStyle(neon.text)
                            .tracking(1)
                    }
                    Text(aboutVersion)
                        .font(neon.mono(11))
                        .foregroundStyle(neon.textFaint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                identityBadge
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .neonCardSurface(neon, fill: neon.surface, cornerRadius: 14)
        }

        private var identityBadge: some View {
            let reachable = store.harness.isReachable
            let color = reachable ? neon.green : neon.textDim
            return HStack(spacing: 5) {
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
                    .neonGlowBox(neon.glow && reachable ? neon.glowBox?.tinted(color) : nil)
                Text(store.harness.badgeLabel)
                    .font(neon.mono(10.5).weight(.semibold))
                    .foregroundStyle(color)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(color.opacity(0.12))
                    .overlay(Capsule().strokeBorder(color.opacity(0.3), lineWidth: 1))
            )
        }

        // MARK: Account

        private var accountSection: some View {
            sectionCard(title: "Account") {
                VStack(spacing: 0) {
                    ConduitUI.navRow(
                        icon: "person.crop.circle.fill",
                        title: store.endpoint.isComplete ? store.endpoint.displayHost : "Not paired",
                        subtitle: harnessSubtitle
                    )
                    Divider()
                        .background(neon.border)
                        .padding(.leading, 46)
                    Button {
                        showAgentLogin = true
                    } label: {
                        ConduitUI.ListRow(
                            icon: "key.fill",
                            title: "Sign in to agent",
                            subtitle: "OAuth for Claude / ChatGPT (v2)",
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

        private var harnessSubtitle: String {
            store.harness.badgeLabel
        }

        // MARK: Usage & limits (account-wide, BOTH agents)

        /// Account-level plan limits for BOTH agents (claude + codex), each
        /// with its 5-hour AND weekly window (handoff §A.2 / data-model). The
        /// numbers are per-account, not per-session, so we read the freshest
        /// values off any session of that agent. When an agent has no data
        /// yet (no session, or never fetched) the card shows honest "—" /
        /// "tap refresh" rather than fabricating a percentage.
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

        // MARK: Appearance (one grouped card)

        /// ONE grouped Appearance card (handoff §A.2): Theme segmented control,
        /// accent-palette swatches, App font drill-in row, Text size slider,
        /// Glow & scanlines toggle — plus the live `conduit --theme <id>`
        /// preview chip beneath. Merges the old Theme + Neon + Font + Font
        /// Size + preview-chip sections.
        private var appearanceSection: some View {
            @Bindable var appearance = appearance
            return VStack(alignment: .leading, spacing: 10) {
                Text("Appearance")
                    .font(neon.mono(11).weight(.bold))
                    .foregroundStyle(neon.textFaint)
                    .textCase(.uppercase)
                    .padding(.horizontal, 4)

                VStack(alignment: .leading, spacing: 0) {
                    // Theme — segmented System / Light / Dark.
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Theme")
                            .font(.system(size: 15, weight: .semibold))
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
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(neon.text)
                            Spacer(minLength: 6)
                            Text(appearance.neonPalette.label)
                                .font(neon.mono(11.5))
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

                    // App font — drill-in row (current value + chevron).
                    NavigationLink {
                        AppFontPicker()
                    } label: {
                        ConduitUI.ListRow(
                            icon: "textformat",
                            title: "App font",
                            subtitle: nil,
                            iconTint: neon.accent
                        ) {
                            HStack(spacing: 6) {
                                Text(appearance.fontFamily.label)
                                    .font(neon.mono(12.5))
                                    .foregroundStyle(neon.textFaint)
                                Image(systemName: "chevron.right")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(neon.textFaint)
                            }
                        }
                    }
                    .buttonStyle(.plain)

                    Divider().background(neon.border).padding(.leading, 46)

                    // Text size — slider over the typography ramp base.
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 12) {
                            Image(systemName: "textformat.size")
                                .font(.body)
                                .frame(width: 20)
                                .foregroundStyle(neon.accent)
                            Text("Text size")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(neon.text)
                            Spacer(minLength: 6)
                            Text("\(Int(appearance.bodyPointSize))pt")
                                .font(neon.mono(12).weight(.semibold))
                                .foregroundStyle(neon.textFaint)
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

                // Live preview chip (terminal-styled `conduit --theme ice`).
                ConduitUI.NeonThemePreviewChip()
            }
        }

        // MARK: Terminal (drill-in rows)

        /// The two long radio lists (color theme, font) collapse to single
        /// drill-in rows that open a picker sub-view (handoff §A.2).
        private var terminalSection: some View {
            @Bindable var appearance = appearance
            return sectionCard(title: "Terminal") {
                VStack(spacing: 0) {
                    NavigationLink {
                        TerminalThemePicker()
                    } label: {
                        ConduitUI.ListRow(
                            icon: "paintpalette.fill",
                            title: "Color theme",
                            subtitle: nil,
                            iconTint: neon.accent
                        ) {
                            drillValue(appearance.terminalTheme.label)
                        }
                    }
                    .buttonStyle(.plain)

                    Divider().background(neon.border).padding(.leading, 46)

                    NavigationLink {
                        TerminalFontPicker()
                    } label: {
                        ConduitUI.ListRow(
                            icon: "textformat",
                            title: "Font",
                            subtitle: nil,
                            iconTint: neon.accent
                        ) {
                            drillValue(appearance.terminalFont.label)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }

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

        // MARK: Conversation

        private var conversationSection: some View {
            @Bindable var appearance = appearance
            return sectionCard(title: "Conversation") {
                ConduitUI.toggleRow(
                    icon: "arrow.up.arrow.down",
                    title: "Collapse Turns",
                    subtitle: "Hide reasoning blocks by default",
                    isOn: $appearance.collapseTurns
                )
            }
        }

        // MARK: Servers

        private var serversSection: some View {
            sectionCard(title: "Servers") {
                VStack(spacing: 0) {
                    // Saved-server rows live inside an embedded `List` so
                    // each carries `.swipeActions` for the Forget gesture —
                    // SwiftUI only honours trailing-swipe on List rows. The
                    // list takes a fixed height (row count × estimated row
                    // height) so the surrounding scroll view continues to
                    // own vertical layout; the inner list itself never
                    // scrolls. `listStyle(.plain)` + clear backgrounds keep
                    // the upstream glass-card look from the prior VStack.
                    if !store.savedServers.isEmpty {
                        List {
                            ForEach(store.savedServers) { server in
                                savedServerRow(server)
                                    .listRowBackground(Color.clear)
                                    .listRowSeparator(.hidden)
                                    .listRowInsets(EdgeInsets())
                                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                        Button(role: .destructive) {
                                            pendingServerDelete = PendingServerDelete(id: server.id, name: server.name)
                                        } label: {
                                            Label("Forget", systemImage: "trash")
                                        }
                                    }
                                    .contextMenu {
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
                        .frame(height: CGFloat(store.savedServers.count) * 56)
                        Divider()
                            .background(neon.border)
                            .padding(.leading, 46)
                    }
                    Button {
                        showAddServer = true
                    } label: {
                        ConduitUI.ListRow(
                            icon: "plus.circle.fill",
                            title: "Add Server",
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
            }
        }

        @ViewBuilder
        private func savedServerRow(_ server: SavedServer) -> some View {
            ConduitUI.ListRow(
                icon: "server.rack",
                title: server.name,
                subtitle: server.endpoint.displayHost,
                iconTint: neon.accent
            ) {
                if server.isDefault {
                    Text("Default")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(neon.accent.opacity(0.22)))
                        .overlay(Capsule().stroke(neon.accent.opacity(0.5), lineWidth: 1))
                }
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
            // Show the release tag the IPA was actually published under
            // (stamped into BuildInfo by release-ios.yml), not the static
            // MARKETING_VERSION — that was hardcoded "0.0.1", so Settings
            // never matched the release (device bug #7, v0.0.30). Dev/CI
            // builds aren't stamped, so fall back to the marketing version.
            BuildInfo.isStamped
                ? "\(BuildInfo.releaseTag) (\(BuildInfo.gitSHA))"
                : "\(BuildInfo.marketingVersion) (dev)"
        }

        // MARK: Layout helpers

        @ViewBuilder
        private func sectionCard<C: View>(title: String, @ViewBuilder content: () -> C) -> some View {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(neon.mono(11).weight(.bold))
                    .foregroundStyle(neon.textFaint)
                    .textCase(.uppercase)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 4)
                // Neon section surface: hairline border + glow (or light-
                // mode elevation) via the shared card-surface rule.
                content()
                    .neonCardSurface(neon, fill: neon.surface, cornerRadius: 14)
            }
        }
    }

    // MARK: - Usage & limits · per-agent window rows

    /// Account-wide plan limits for one agent (claude or codex): the 5-hour
    /// and weekly windows side by side, with a refresh affordance. Reads the
    /// freshest account-usage values off any session of `agent` (the numbers
    /// are per-account, not per-session, so any of that agent's sessions
    /// carries the latest fetched values). Shows honest "—"/"tap refresh"
    /// when no data has arrived — never a fabricated percentage.
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
            let barTint = ConduitUI.AccountUsageFormat.tint(pct ?? 0, neon)
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
        /// status frame preferred, session snapshot as fallback). Mirrors
        /// `SessionStore.accountUsage` but parameterised on the agent, so the
        /// Settings card can show both claude and codex rather than the
        /// Claude-only ambient strip.
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

    // MARK: - Drill-in pickers

    /// App font drill-in target — the chat/UI body font family, opened from
    /// the Appearance card's "App font" row. Same single-select semantics as
    /// the prior inline `fontSection`, just hosted on its own screen.
    struct AppFontPicker: View {
        @Environment(AppearanceStore.self) private var appearance
        @Environment(\.neonTheme) private var neon

        var body: some View {
            @Bindable var appearance = appearance
            return pickerList(title: "App font") {
                ForEach(AppearanceStore.FontFamily.allCases) { family in
                    Button {
                        appearance.fontFamily = family
                    } label: {
                        ConduitUI.ListRow(
                            icon: fontIcon(family),
                            title: family.label,
                            subtitle: "The quick brown fox",
                            iconTint: neon.accent
                        ) {
                            if appearance.fontFamily == family {
                                Image(systemName: "checkmark")
                                    .font(.footnote.weight(.bold))
                                    .foregroundStyle(neon.accent)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    pickerDivider(after: family, in: AppearanceStore.FontFamily.allCases, neon: neon)
                }
            }
        }

        private func fontIcon(_ family: AppearanceStore.FontFamily) -> String {
            switch family {
            case .serif:      return "textformat.alt"
            case .system:     return "textformat"
            case .monospaced: return "chevron.left.forwardslash.chevron.right"
            }
        }
    }

    /// Terminal color-theme drill-in target — the native (libghostty) terminal
    /// color theme. Applies live via `AppearanceStore.terminalTheme`.
    struct TerminalThemePicker: View {
        @Environment(AppearanceStore.self) private var appearance
        @Environment(\.neonTheme) private var neon

        var body: some View {
            @Bindable var appearance = appearance
            return pickerList(title: "Color theme") {
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

    /// Terminal font drill-in target — the native (libghostty) terminal font.
    struct TerminalFontPicker: View {
        @Environment(AppearanceStore.self) private var appearance
        @Environment(\.neonTheme) private var neon

        var body: some View {
            @Bindable var appearance = appearance
            return pickerList(title: "Font") {
                ForEach(GhosttyFont.allCases) { font in
                    Button {
                        appearance.terminalFont = font
                    } label: {
                        ConduitUI.ListRow(
                            icon: "textformat",
                            title: font.label,
                            subtitle: nil,
                            iconTint: neon.accent
                        ) {
                            if appearance.terminalFont == font {
                                Image(systemName: "checkmark")
                                    .font(.footnote.weight(.bold))
                                    .foregroundStyle(neon.accent)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    pickerDivider(after: font, in: GhosttyFont.allCases, neon: neon)
                }
            }
        }
    }
}

// MARK: - Shared picker chrome (free helpers, used by the drill-in screens)

/// A drill-in picker screen: the same neon-card list the Settings sections
/// use, hosted full-screen with a nav title. Kept as a free helper so the
/// three picker `struct`s above stay tiny.
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

/// Carrier for the Settings → Servers Forget confirmation alert. Same
/// `Identifiable` pattern as `PendingSessionDelete` in `ConduitHomeView`
/// — keys the alert presentation off the pending target and prevents a
/// stale id from leaking into the next prompt.
private struct PendingServerDelete: Identifiable, Equatable {
    let id: String
    let name: String
}
