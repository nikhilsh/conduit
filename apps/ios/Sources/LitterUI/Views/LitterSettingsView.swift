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
                        Button("Done") { dismiss() }
                            .foregroundStyle(LitterUI.Palette.brand.color)
                    }
                }
                .sheet(isPresented: $showAddServer) {
                    LitterUI.AddServerSheet()
                }
                .sheet(isPresented: $showAgentLogin) {
                    LitterUI.AgentLoginSheet()
                }
            }
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
                    ForEach(store.savedServers) { server in
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
                        rowDivider(after: server, in: store.savedServers)
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

        private var experimentalSection: some View {
            @Bindable var appearance = appearance
            return sectionCard(title: "Experimental") {
                LitterUI.toggleRow(
                    icon: "rectangle.dashed",
                    title: "Native terminal (Ghostty)",
                    subtitle: "Render the terminal tab with libghostty instead of xterm.js",
                    isOn: $appearance.experimentalNativeTerminal
                )
            }
        }

        private var aboutSection: some View {
            sectionCard(title: "About") {
                LitterUI.valueRow(
                    icon: "info.circle.fill",
                    title: "SweKitty",
                    value: aboutVersion,
                    subtitle: nil
                )
            }
        }

        private var aboutVersion: String {
            let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
            return v
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
                content()
                    .litterGlassRoundedRect(cornerRadius: 16, config: .card)
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
