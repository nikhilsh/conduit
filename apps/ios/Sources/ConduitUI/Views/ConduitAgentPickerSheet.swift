import Foundation
import SwiftUI

// MARK: - ConduitAgentPickerSheet
//
// Native ConduitUI agent-picker sheet. Replaces the legacy
// `AgentPickerSheet`. Visual choices:
//   - small-caps "PAIRED WITH" / "INITIAL PROMPT" / "AGENT" section
//     labels (11pt mono, brand-tinted)
//   - neon card surfaces via `neonCardSurface(...)`
//   - per-agent accent on the avatar circle only; row text stays in
//     `textPrimary` so the buttons read as a list not a rainbow
//
// Used in two places:
//   - "+" button on `ConduitHomeView` (new session).
//   - Auto-presented after a deep-link pair so the user lands on
//     "pick Claude/Codex" instead of an empty session list.

extension ConduitUI {
    struct AgentPickerSheet: View {
        @Environment(SessionStore.self) private var store
        @Environment(\.neonTheme) private var neon
        @Environment(\.dismiss) private var dismiss

        /// Optional context label (e.g. host that was just paired) shown
        /// in the sheet header. nil hides it.
        var headerNote: String? = nil

        /// Optional pre-populated prompt (typically a voice transcript).
        /// When set, tapping an agent creates the session with this
        /// prompt seeded as its first chat message.
        var initialPrompt: String? = nil

        /// Agent the user tapped; pushes the directory picker. nil while
        /// on the agent-selection screen.
        @State private var pickedAgent: String?

        /// Box the session should run on (device feedback, round 3:
        /// "I can't choose where to start the session in"). nil =
        /// whatever box is currently connected; an explicit pick of a
        /// different box routes the create through
        /// `store.connectAndStart` (switch endpoint → connect → create).
        @State private var selectedServerID: String?

        /// The effective box pick: the explicit selection, else the
        /// saved server matching the live endpoint.
        private var resolvedServer: SavedServer? {
            if let id = selectedServerID,
               let picked = store.savedServers.first(where: { $0.id == id }) {
                return picked
            }
            return store.savedServers.first(where: { $0.endpoint == store.endpoint })
        }

        var body: some View {
            NavigationStack {
                ZStack {
                    GlassAppBackground()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            header
                            if let prompt = initialPrompt?.trimmingCharacters(in: .whitespacesAndNewlines),
                               !prompt.isEmpty {
                                promptPreview(prompt)
                            }
                            sectionLabel("Agent")
                            agentRow(
                                kind: "claude",
                                label: "Claude",
                                subtitle: "Powered by Anthropic"
                            )
                            agentRow(
                                kind: "codex",
                                label: "Codex",
                                subtitle: "Powered by OpenAI"
                            )
                            // Always show where the session will run — even
                            // with one box. Device feedback round 4: with the
                            // section gated on >1 servers, a single-box user
                            // "can't choose the box" and can't tell local vs
                            // server. One box = one checked row + footnote.
                            if !store.savedServers.isEmpty {
                                sectionLabel("Box")
                                boxSection
                            }
                            if !store.harness.canIssueCommands {
                                Text("Connect to a server first — open Settings to pair.")
                                    .font(neon.sans(13))
                                    .foregroundStyle(neon.textDim)
                                    .multilineTextAlignment(.center)
                                    .frame(maxWidth: .infinity, alignment: .center)
                                    .padding(.top, 4)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 18)
                    }
                    .scrollIndicators(.hidden)
                }
                .navigationTitle("New session")
                .navigationBarTitleDisplayMode(.inline)
                .navigationDestination(item: $pickedAgent) { kind in
                    DirectoryPicker(
                        agentKind: kind,
                        initialPrompt: initialPrompt,
                        onCreate: { cwd, model, effort, permissionMode in
                            if let target = resolvedServer, target.endpoint != store.endpoint {
                                // Session targeted at a different box:
                                // switch endpoint → connect → create.
                                store.connectAndStart(
                                    endpoint: target.endpoint,
                                    assistant: kind,
                                    cwd: cwd,
                                    reasoningEffort: effort,
                                    model: model,
                                    permissionMode: permissionMode,
                                    initialPrompt: initialPrompt
                                )
                            } else {
                                store.createSession(
                                    assistant: kind,
                                    startupCwd: cwd,
                                    reasoningEffort: effort,
                                    model: model,
                                    permissionMode: permissionMode,
                                    initialPrompt: initialPrompt
                                )
                            }
                            // Defer the dismiss one runloop tick. createSession
                            // mutates the store → the app tree rebuilds; tearing
                            // down this pushed DirectoryPicker (a representable
                            // subtree) in the SAME CoreAnimation transaction can
                            // message a freed CALayer →
                            // `-[NSIndirectTaggedPointerString bounds]` at CA
                            // commit (Sentry CONDUIT-IOS-N/M, the dominant 0.0.83
                            // crash). Letting the create commit first, then
                            // dismissing, avoids the collision. Best-effort —
                            // needs on-device verification.
                            DispatchQueue.main.async { dismiss() }
                        }
                    )
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
            }
            .presentationDetents([.medium, .large])
            .presentationCornerRadius(26)
            .tint(neon.accent)
            .appearanceColorScheme()
        }

        // MARK: - Subviews

        @ViewBuilder
        private var header: some View {
            if let note = headerNote, !note.isEmpty {
                // PLAN-CONDUIT-VISUAL-PARITY audit §A.5 / PR 5
                // deferred — collapse the chunky tinted glass card
                // around the "Paired with <host>" note to an inline
                // caption. The agent buttons below are the action;
                // the header is metadata and shouldn't compete with
                // them for visual weight.
                HStack(spacing: 6) {
                    Text("PAIRED WITH")
                        .font(neon.mono(11).weight(.bold))
                        .tracking(0.6)
                        .foregroundStyle(neon.textFaint)
                    Text(note)
                        .font(neon.sans(13).weight(.semibold))
                        .foregroundStyle(neon.textDim)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
                .padding(.bottom, 2)
            }
        }

        private func promptPreview(_ prompt: String) -> some View {
            VStack(alignment: .leading, spacing: 6) {
                sectionLabel("Initial prompt")
                Text(prompt)
                    .font(neon.sans(13))
                    .foregroundStyle(neon.text)
                    .lineLimit(4)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .neonCardSurface(neon, fill: neon.surface, cornerRadius: 13)
            .accessibilityIdentifier("ConduitAgentPickerSheet.initialPrompt")
        }

        private func sectionLabel(_ text: String) -> some View {
            Text(text.uppercased())
                .font(neon.mono(11).weight(.bold))
                .tracking(0.6)
                .foregroundStyle(neon.textFaint)
        }

        /// One row per paired box; the session is created on the checked
        /// one. "This device" on the home Boxes list is display-only — a
        /// phone can't host the broker — so it is deliberately not a
        /// target here; the single-box footnote says so instead of
        /// offering a dead option.
        private var boxSection: some View {
            VStack(spacing: 6) {
                ForEach(store.savedServers) { server in
                    let isSelected = server.id == resolvedServer?.id
                    Button {
                        selectedServerID = server.id
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "server.rack")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(isSelected ? neon.accent : neon.textDim)
                                .frame(width: 30, height: 30)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(server.name)
                                    .font(neon.sans(13).weight(.semibold))
                                    .foregroundStyle(neon.text)
                                Text(server.endpoint.displayHost)
                                    .font(neon.mono(11))
                                    .foregroundStyle(neon.textDim)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(isSelected ? neon.accent : neon.textFaint)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .neonCardSurface(
                            neon,
                            fill: isSelected ? neon.accent.opacity(neon.dark ? 0.10 : 0.07) : neon.surface,
                            cornerRadius: 13,
                            border: isSelected ? neon.accent.opacity(0.5) : neon.border
                        )
                    }
                    .buttonStyle(.plain)
                }
                if store.savedServers.count == 1 {
                    Text("Sessions run on a paired box — this device can't host them. Pair another box in Settings.")
                        .font(neon.mono(10.5))
                        .foregroundStyle(neon.textFaint)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 2)
                }
            }
            .accessibilityIdentifier("ConduitAgentPickerSheet.boxSection")
        }

        private func agentRow(kind: String, label: String, subtitle: String) -> some View {
            let canIssue = store.harness.canIssueCommands
            let tint = neon.agentTint(forAgent: kind)
            return Button {
                pickedAgent = kind
            } label: {
                HStack(spacing: 14) {
                    AgentAvatar(assistant: kind, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(label)
                            .font(neon.sans(13).weight(.semibold))
                            .foregroundStyle(neon.text)
                        Text(subtitle)
                            .font(neon.sans(11))
                            .foregroundStyle(neon.textDim)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(tint)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .neonCardSurface(
                    neon,
                    fill: tint.opacity(neon.dark ? 0.14 : 0.10),
                    cornerRadius: 13,
                    border: tint.opacity(0.5),
                    glowTint: tint
                )
            }
            .buttonStyle(.plain)
            .disabled(!canIssue)
            .opacity(canIssue ? 1.0 : 0.55)
        }
    }
}

// MARK: - DirectoryPicker
//
// Second step of the new-session flow (upstream parity, task #36). After
// the agent is chosen the user lands here to pick a working directory:
//   - "Recent" shortcut list (from `store.recentDirectories`, per-server)
//   - a live browser over `store.listDirectories(path:)` — tap a folder
//     to descend, breadcrumb / parent button to go back up
//   - "Use this folder" starts the session cd'd into the current path
//   - "Start without a folder" preserves today's behavior (no cwd)
//
// Style follows the ConduitUI palette + glass cards used by the agent
// step above so the two screens read as one sheet.

extension ConduitUI {
    struct DirectoryPicker: View {
        let agentKind: String
        var initialPrompt: String?
        /// Called with the absolute path to cd into (or nil to start with no
        /// working directory), the selected model alias (nil = inherit the
        /// agent's default model), the chosen reasoning effort (nil = the
        /// agent's default effort), and the agent mode (nil = Auto / full-auto
        /// default; "plan" = read-only planning).
        let onCreate: (String?, String?, String?, String?) -> Void

        @Environment(SessionStore.self) private var store
        @Environment(\.neonTheme) private var neon
        @Environment(\.dismiss) private var dismiss

        @State private var listing: RemoteDirectoryListing?
        @State private var isLoading = false
        @State private var loadError: String?
        /// Path currently being browsed. nil = the harness default (home).
        @State private var currentPath: String?
        /// Selected model option. `ForkOptions.inheritModel` (empty string)
        /// means "no override — use the agent's default model", which is the
        /// default and keeps the start path identical to before.
        @State private var model: String = ConduitUI.ForkOptions.inheritModel
        /// Selected reasoning effort. Defaults to the agent's sensible
        /// default ("medium" when offered) via `defaultEffort`, mirroring the
        /// Fork sheet — the new-session flow previously couldn't set effort.
        @State private var effort: String
        /// Selected agent mode. `ForkOptions.autoMode` (empty string) means
        /// the app's current full-auto default — sent as nil so the spawn
        /// carries no override, identical to before this picker existed.
        @State private var permissionMode: String = ConduitUI.ForkOptions.autoMode

        init(
            agentKind: String,
            initialPrompt: String? = nil,
            onCreate: @escaping (String?, String?, String?, String?) -> Void
        ) {
            self.agentKind = agentKind
            self.initialPrompt = initialPrompt
            self.onCreate = onCreate
            self._effort = State(initialValue: Self.defaultEffort(forAssistant: agentKind))
        }

        private static func defaultEffort(forAssistant assistant: String) -> String {
            let options = ConduitUI.ForkOptions.efforts(forAssistant: assistant)
            return options.contains("medium") ? "medium" : (options.first ?? "medium")
        }

        private var modelOptions: [String] {
            ConduitUI.ForkOptions.models(forAssistant: agentKind)
        }

        private var effortOptions: [String] {
            ConduitUI.ForkOptions.efforts(forAssistant: agentKind)
        }

        /// The model to hand to onCreate: the sentinel maps to nil.
        private var selectedModel: String? { model.isEmpty ? nil : model }

        /// The agent mode to hand to onCreate: Auto (sentinel) maps to nil.
        private var selectedPermissionMode: String? { permissionMode.isEmpty ? nil : permissionMode }

        var body: some View {
            ZStack {
                GlassAppBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        modelSection
                        effortSection
                        modeSection
                        if !store.recentDirectories.isEmpty {
                            recentSection
                        }
                        browseSection
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 18)
                }
                .scrollIndicators(.hidden)
            }
            .navigationTitle("Working directory")
            .navigationBarTitleDisplayMode(.inline)
            // Replace iOS 26's default circular glass back button — its
            // translucent fill let the app's grid background show through
            // ("the back shows under the button", device feedback) and it
            // clashed with the plain-chevron back used everywhere else
            // (see ConduitProjectView's header). A flat chevron pops the
            // nav stack via the dismiss environment.
            .navigationBarBackButtonHidden(true)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(neon.text)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Back")
                }
            }
            .safeAreaInset(edge: .bottom) { bottomBar }
            .task(id: currentPath) { await load() }
            .tint(neon.accent)
        }

        // MARK: Sections

        private var modelSection: some View {
            VStack(alignment: .leading, spacing: 8) {
                sectionLabel("Model")
                Menu {
                    Picker("Model", selection: $model) {
                        ForEach(modelOptions, id: \.self) { option in
                            Text(ConduitUI.ForkOptions.modelLabel(option)).tag(option)
                        }
                    }
                } label: {
                    HStack {
                        Text(ConduitUI.ForkOptions.modelLabel(model))
                            .font(neon.sans(13).weight(.medium))
                            .foregroundStyle(neon.text)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(neon.textDim)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .neonCardSurface(neon, fill: neon.surface, cornerRadius: 13)
                }
                .tint(neon.accent)
            }
        }

        private var effortSection: some View {
            VStack(alignment: .leading, spacing: 8) {
                sectionLabel("Reasoning effort")
                Picker("Reasoning effort", selection: $effort) {
                    ForEach(effortOptions, id: \.self) { level in
                        Text(level.capitalized).tag(level)
                    }
                }
                .pickerStyle(.segmented)
                .tint(neon.accent)
            }
        }

        private var modeSection: some View {
            VStack(alignment: .leading, spacing: 8) {
                sectionLabel("Mode")
                Picker("Mode", selection: $permissionMode) {
                    ForEach(ConduitUI.ForkOptions.permissionModes, id: \.self) { mode in
                        Text(ConduitUI.ForkOptions.permissionModeLabel(mode)).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .tint(neon.accent)
                Text("Plan = read-only; agent explores and proposes without editing.")
                    .font(neon.mono(10.5))
                    .foregroundStyle(neon.textFaint)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }

        private var recentSection: some View {
            VStack(alignment: .leading, spacing: 8) {
                sectionLabel("Recent")
                VStack(spacing: 6) {
                    ForEach(store.recentDirectories, id: \.self) { path in
                        Button {
                            onCreate(path, selectedModel, effort, selectedPermissionMode)
                        } label: {
                            ConduitUI.ListRow(
                                icon: "clock.arrow.circlepath",
                                title: displayName(of: path),
                                subtitle: path,
                                iconTint: neon.accent
                            ) {
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(neon.accent)
                            }
                            .neonCardSurface(neon, fill: neon.surface, cornerRadius: 13)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .accessibilityIdentifier("ConduitDirectoryPicker.recent")
        }

        private var browseSection: some View {
            VStack(alignment: .leading, spacing: 8) {
                sectionLabel("Browse")
                breadcrumb
                // iOS-26.5 crash hardening (CONDUIT-IOS-N / -M). This subtree
                // must stay structurally STABLE. We previously swapped between
                // ProgressView / error Text / folderList with if·else·if; when
                // /api/fs/list returned and flipped @State, SwiftUI
                // restructured the tree *inside* the freshly-pushed picker's
                // CoreAnimation commit and corrupted the AttributeGraph →
                // crash in CA::Transaction::commit
                // (-[NSTaggedPointerString bounds]). Keeping all three
                // branches resident and toggling opacity means only opacity
                // changes; the view identity never moves.
                ZStack {
                    folderList
                        .opacity(isLoading || loadError != nil ? 0 : 1)
                    ProgressView()
                        .controlSize(.small)
                        .padding(.vertical, 24)
                        .opacity(isLoading ? 1 : 0)
                    Text(loadError ?? " ")
                        .font(neon.sans(13))
                        .foregroundStyle(neon.red)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 16)
                        .opacity(loadError != nil ? 1 : 0)
                        .accessibilityHidden(loadError == nil)
                }
                .frame(maxWidth: .infinity)
            }
        }

        private var breadcrumb: some View {
            HStack(spacing: 8) {
                Button {
                    if let parent = listing?.parent, !parent.isEmpty,
                       parent != listing?.path {
                        currentPath = parent
                    }
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(canGoUp ? neon.accent : neon.textFaint)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(neon.surface))
                        .overlay(Circle().stroke(neon.border, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(!canGoUp)

                Text(listing?.path ?? "…")
                    .font(neon.mono(12).weight(.medium))
                    .foregroundStyle(neon.textDim)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }

        private var folderList: some View {
            let folders = (listing?.entries ?? []).filter { $0.is_dir }
            // Stable container (no empty/non-empty if·else swap — see
            // browseSection note). The "No sub-folders" copy is an opacity
            // overlay so the subtree shape never changes when the listing
            // lands inside the picker's CoreAnimation commit.
            return VStack(spacing: 6) {
                ForEach(folders) { entry in
                    Button {
                        currentPath = entry.path
                    } label: {
                        ConduitUI.navRow(icon: "folder", title: entry.name, iconTint: neon.accent)
                            .neonCardSurface(neon, fill: neon.surface, cornerRadius: 13)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, minHeight: folders.isEmpty ? 44 : nil)
            .overlay {
                Text("No sub-folders here.")
                    .font(neon.sans(13))
                    .foregroundStyle(neon.textDim)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .opacity(folders.isEmpty ? 1 : 0)
                    .accessibilityHidden(!folders.isEmpty)
            }
        }

        private var bottomBar: some View {
            VStack(spacing: 10) {
                Button {
                    onCreate(listing?.path, selectedModel, effort, selectedPermissionMode)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                        Text("Use this folder")
                    }
                    .font(neon.sans(15).weight(.semibold))
                    .foregroundStyle(neon.accentText)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .fill(neon.accent)
                    )
                    .neonGlowBox(neon.glow ? neon.glowBox : nil)
                }
                .buttonStyle(.plain)
                .disabled(listing == nil)
                .opacity(listing == nil ? 0.5 : 1.0)

                Button {
                    onCreate(nil, selectedModel, effort, selectedPermissionMode)
                } label: {
                    Text("Start without a folder")
                        .font(neon.sans(13).weight(.medium))
                        .foregroundStyle(neon.textDim)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 12)
            // Fully opaque docked bar. At 0.96 the browse list scrolled
            // visibly THROUGH the bar ("you can see the options under
            // 'Use this folder'", device feedback) — there's no blur
            // behind a safe-area inset to hide it, so the bar must be
            // solid. A hairline on top keeps it visually separated from
            // the scrolling content above.
            .background(
                neon.surfaceSolid
                    .overlay(alignment: .top) {
                        Rectangle()
                            .fill(neon.border)
                            .frame(height: 1)
                    }
            )
        }

        // MARK: Helpers

        private var canGoUp: Bool {
            guard let listing else { return false }
            return !listing.parent.isEmpty && listing.parent != listing.path
        }

        private func sectionLabel(_ text: String) -> some View {
            Text(text.uppercased())
                .font(neon.mono(11).weight(.bold))
                .tracking(0.6)
                .foregroundStyle(neon.textFaint)
        }

        private func displayName(of path: String) -> String {
            let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
            let last = trimmed.split(separator: "/").last.map(String.init)
            return (last?.isEmpty == false ? last : nil) ?? trimmed
        }

        private func load() async {
            isLoading = true
            loadError = nil
            do {
                listing = try await store.listDirectories(path: currentPath)
            } catch {
                loadError = "Couldn't list this folder."
            }
            isLoading = false
        }
    }
}
