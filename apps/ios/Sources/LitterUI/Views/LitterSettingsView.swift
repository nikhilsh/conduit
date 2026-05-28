import SwiftUI

// MARK: - LitterSettingsView
//
// Litter-faithful sectioned Settings screen, presented as a sheet from
// the LitterHomeView. Section order mirrors litter:
//   Account · Theme · Font · Conversation · Servers · About
//
// Each section is a `LitterCard` wrapping `LitterListRow`s. Rows use
// the brand tint for the leading icon and a chevron / toggle / value
// trailing element. Sheet-style sub-screens stay legacy for now (they
// open the existing AddServerSheet etc.).

extension LitterUI {

    struct SettingsView: View {
        @Environment(SessionStore.self) private var store
        @Environment(AppearanceStore.self) private var appearance
        @Environment(\.dismiss) private var dismiss
        @Environment(\.colorScheme) private var colorScheme

        @State private var showAddServer = false
        @State private var showAgentLogin = false
        /// Saved-server pending deletion (drives the confirmation alert
        /// for the Settings → Servers swipe-to-delete affordance).
        @State private var pendingServerDelete: PendingServerDelete?

        var body: some View {
            @Bindable var appearance = appearance

            NavigationStack {
                ZStack {
                    LitterUI.Palette.surface.color.ignoresSafeArea()

                    ScrollView {
                        VStack(spacing: 18) {
                            accountSection
                            themeSection
                            fontSection
                            fontSizeSection
                            conversationSection
                            serversSection
                            experimentalSection
                            aboutSection
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 18)
                    }
                    .scrollIndicators(.hidden)
                }
                .navigationTitle("Settings")
                .navigationBarTitleDisplayMode(.inline)
                .tint(LitterUI.Palette.brand.color)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        // Plain Button (no copper-tint overlay) per
                        // PLAN-LITTER-VISUAL-PARITY audit §A.3.5 — litter
                        // uses a flat `.confirmationAction` link, not a
                        // tinted capsule. The surrounding NavigationStack
                        // `.tint(LitterUI.Palette.brand.color)` still
                        // picks up the accent colour on the link itself,
                        // we just stop double-painting it.
                        Button("Done") { dismiss() }
                    }
                }
                .sheet(isPresented: $showAddServer) {
                    LitterUI.AddServerSheet()
                }
                .sheet(isPresented: $showAgentLogin) {
                    LitterUI.AgentLoginSheet()
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

        // MARK: Sections

        private var accountSection: some View {
            sectionCard(title: "Account") {
                VStack(spacing: 0) {
                    LitterUI.navRow(
                        icon: "person.crop.circle.fill",
                        title: store.endpoint.isComplete ? store.endpoint.displayHost : "Not paired",
                        subtitle: harnessSubtitle
                    )
                    Divider()
                        .background(LitterUI.Palette.separator.color)
                        .padding(.leading, 46)
                    Button {
                        showAgentLogin = true
                    } label: {
                        LitterUI.ListRow(
                            icon: "key.fill",
                            title: "Sign in to agent",
                            subtitle: "OAuth for Claude / ChatGPT (v2, litter pattern)",
                            iconTint: LitterUI.Palette.brand.color
                        ) {
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(LitterUI.Palette.textMuted.color)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }

        private var harnessSubtitle: String {
            store.harness.badgeLabel
        }

        private var themeSection: some View {
            @Bindable var appearance = appearance
            return sectionCard(title: "Theme") {
                VStack(spacing: 0) {
                    ForEach(AppearanceStore.ThemeMode.allCases) { mode in
                        Button {
                            appearance.themeMode = mode
                        } label: {
                            LitterUI.ListRow(
                                icon: themeIcon(for: mode),
                                title: mode.label,
                                subtitle: nil,
                                iconTint: LitterUI.Palette.brand.color
                            ) {
                                if appearance.themeMode == mode {
                                    Image(systemName: "checkmark")
                                        .font(.footnote.weight(.bold))
                                        .foregroundStyle(LitterUI.Palette.brand.color)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        rowDivider(after: mode, in: AppearanceStore.ThemeMode.allCases)
                    }
                }
            }
        }

        private func themeIcon(for mode: AppearanceStore.ThemeMode) -> String {
            switch mode {
            case .system: return "iphone"
            case .light:  return "sun.max.fill"
            case .dark:   return "moon.fill"
            }
        }

        private var fontSection: some View {
            @Bindable var appearance = appearance
            return sectionCard(title: "Font") {
                VStack(spacing: 0) {
                    ForEach(AppearanceStore.FontFamily.allCases) { family in
                        Button {
                            appearance.fontFamily = family
                        } label: {
                            LitterUI.ListRow(
                                icon: fontIcon(for: family),
                                title: family.label,
                                subtitle: "The quick brown fox",
                                iconTint: LitterUI.Palette.brand.color
                            ) {
                                if appearance.fontFamily == family {
                                    Image(systemName: "checkmark")
                                        .font(.footnote.weight(.bold))
                                        .foregroundStyle(LitterUI.Palette.brand.color)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        rowDivider(after: family, in: AppearanceStore.FontFamily.allCases)
                    }
                }
            }
        }

        private func fontIcon(for family: AppearanceStore.FontFamily) -> String {
            switch family {
            case .serif:      return "textformat.alt"
            case .system:     return "textformat"
            case .monospaced: return "chevron.left.forwardslash.chevron.right"
            }
        }

        /// Body font size slider. Drives `AppearanceStore.bodyPointSize`
        /// (the base size the `SweKittyTypography` ramp scales off,
        /// landed in PR 1). Range / clamp lives in `AppearanceStore`;
        /// the slider just binds and previews the current size in the
        /// user's chosen family so they can read what they're choosing
        /// at the value they're choosing it at.
        private var fontSizeSection: some View {
            @Bindable var appearance = appearance
            return sectionCard(title: "Font Size") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        Image(systemName: "textformat.size")
                            .font(.body)
                            .frame(width: 20)
                            .foregroundStyle(LitterUI.Palette.brand.color)
                        Text("Body")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(LitterUI.Palette.textPrimary.color)
                        Spacer(minLength: 6)
                        Text("\(Int(appearance.bodyPointSize))pt")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(LitterUI.Palette.textMuted.color)
                    }
                    Slider(
                        value: $appearance.bodyPointSize,
                        in: AppearanceStore.bodyPointSizeRange,
                        step: 1
                    )
                    .tint(LitterUI.Palette.brand.color)
                    Text("The quick brown fox jumps over the lazy dog.")
                        .font(SweKittyTypography.body(appearance))
                        .foregroundStyle(LitterUI.Palette.textSecondary.color)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
        }

        private var conversationSection: some View {
            @Bindable var appearance = appearance
            return sectionCard(title: "Conversation") {
                LitterUI.toggleRow(
                    icon: "arrow.up.arrow.down",
                    title: "Collapse Turns",
                    subtitle: "Hide reasoning blocks by default",
                    isOn: $appearance.collapseTurns
                )
            }
        }

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
                    // the litter glass-card look from the prior VStack.
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
                            .background(LitterUI.Palette.separator.color)
                            .padding(.leading, 46)
                    }
                    Button {
                        showAddServer = true
                    } label: {
                        LitterUI.ListRow(
                            icon: "plus.circle.fill",
                            title: "Add Server",
                            subtitle: nil,
                            iconTint: LitterUI.Palette.brand.color
                        ) {
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(LitterUI.Palette.textMuted.color)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }

        @ViewBuilder
        private func savedServerRow(_ server: SavedServer) -> some View {
            LitterUI.ListRow(
                icon: "server.rack",
                title: server.name,
                subtitle: server.endpoint.displayHost,
                iconTint: LitterUI.Palette.brand.color
            ) {
                if server.isDefault {
                    Text("Default")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .litterGlassCapsule(tint: LitterUI.Palette.brand.color.opacity(0.22), config: .pill)
                }
            }
        }

        // Re-exposed in Stage 5: the native libghostty terminal now
        // drives its own Metal renderer (uiview attach + set_size +
        // ghostty_surface_draw loop), so the toggle is back for
        // on-device verification. Default OFF — flip it to try the
        // native terminal; if it misbehaves, flip back to xterm.js.
        private var experimentalSection: some View {
            @Bindable var appearance = appearance
            return sectionCard(title: "Experimental") {
                VStack(spacing: 0) {
                    LitterUI.toggleRow(
                        icon: "apple.terminal",
                        title: "Native Terminal (Ghostty)",
                        subtitle: "libghostty renderer — falls back to the web terminal if off",
                        isOn: $appearance.experimentalNativeTerminal
                    )
                    // Font-size + color-theme controls only matter for the
                    // native libghostty terminal, so they appear only when
                    // that path is enabled. xterm.js ignores them.
                    if appearance.experimentalNativeTerminal {
                        Divider()
                            .background(LitterUI.Palette.separator.color)
                            .padding(.leading, 46)
                        ghosttyFontSizeRow
                        Divider()
                            .background(LitterUI.Palette.separator.color)
                            .padding(.leading, 46)
                        ghosttyThemeRows
                    }
                }
            }
        }

        /// Native-terminal font-size slider. Drives
        /// `AppearanceStore.ghosttyFontSize` → libghostty's `font-size`
        /// config key. Range / clamp live in `AppearanceStore`.
        private var ghosttyFontSizeRow: some View {
            @Bindable var appearance = appearance
            return VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: "textformat.size")
                        .font(.body)
                        .frame(width: 20)
                        .foregroundStyle(LitterUI.Palette.brand.color)
                    Text("Terminal Font Size")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(LitterUI.Palette.textPrimary.color)
                    Spacer(minLength: 6)
                    Text("\(Int(appearance.ghosttyFontSize))pt")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(LitterUI.Palette.textMuted.color)
                }
                Slider(
                    value: $appearance.ghosttyFontSize,
                    in: AppearanceStore.ghosttyFontSizeRange,
                    step: 1
                )
                .tint(LitterUI.Palette.brand.color)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }

        /// Native-terminal color-theme picker. Drives
        /// `AppearanceStore.ghosttyTerminalTheme` → libghostty's
        /// foreground/background/cursor/palette config keys.
        private var ghosttyThemeRows: some View {
            @Bindable var appearance = appearance
            return VStack(spacing: 0) {
                ForEach(AppearanceStore.GhosttyTerminalTheme.allCases) { theme in
                    Button {
                        appearance.ghosttyTerminalTheme = theme
                    } label: {
                        LitterUI.ListRow(
                            icon: "paintpalette.fill",
                            title: theme.label,
                            subtitle: nil,
                            iconTint: LitterUI.Palette.brand.color
                        ) {
                            if appearance.ghosttyTerminalTheme == theme {
                                Image(systemName: "checkmark")
                                    .font(.footnote.weight(.bold))
                                    .foregroundStyle(LitterUI.Palette.brand.color)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    rowDivider(after: theme, in: AppearanceStore.GhosttyTerminalTheme.allCases)
                }
            }
        }

        private var aboutSection: some View {
            sectionCard(title: "About") {
                VStack(spacing: 0) {
                    LitterUI.valueRow(
                        icon: "info.circle.fill",
                        title: "SweKitty",
                        value: aboutVersion,
                        subtitle: nil
                    )
                    Divider()
                        .background(LitterUI.Palette.separator.color)
                        .padding(.leading, 46)
                    NavigationLink {
                        LitterUI.LicensesView()
                    } label: {
                        LitterUI.ListRow(
                            icon: "doc.text",
                            title: "Licenses",
                            subtitle: "Open source & trademark attribution",
                            iconTint: LitterUI.Palette.brand.color
                        ) {
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(LitterUI.Palette.textMuted.color)
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
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(LitterUI.Palette.textSecondary.color)
                    .textCase(.uppercase)
                    .padding(.horizontal, 4)
                // Corner radius left at the modifier default (now 14
                // post PR 2) so the whole sheet picks up the flatter
                // litter shape without per-call overrides.
                content()
                    .litterGlassRoundedRect(config: .card)
            }
        }

        @ViewBuilder
        private func rowDivider<T: Equatable>(after element: T, in collection: [T]) -> some View {
            if let idx = collection.firstIndex(of: element), idx < collection.count - 1 {
                Divider()
                    .background(LitterUI.Palette.separator.color)
                    .padding(.leading, 46)
            }
        }
    }
}

/// Carrier for the Settings → Servers Forget confirmation alert. Same
/// `Identifiable` pattern as `PendingSessionDelete` in `LitterHomeView`
/// — keys the alert presentation off the pending target and prevents a
/// stale id from leaking into the next prompt.
private struct PendingServerDelete: Identifiable, Equatable {
    let id: String
    let name: String
}
