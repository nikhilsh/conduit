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
                        onCreate: { cwd in
                            store.createSession(
                                assistant: kind,
                                startupCwd: cwd,
                                initialPrompt: initialPrompt
                            )
                            dismiss()
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
        /// Called with the absolute path to cd into, or nil to start with
        /// no working directory (skip).
        let onCreate: (String?) -> Void

        @Environment(SessionStore.self) private var store
        @Environment(\.neonTheme) private var neon

        @State private var listing: RemoteDirectoryListing?
        @State private var isLoading = false
        @State private var loadError: String?
        /// Path currently being browsed. nil = the harness default (home).
        @State private var currentPath: String?

        var body: some View {
            ZStack {
                GlassAppBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
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
            .safeAreaInset(edge: .bottom) { bottomBar }
            .task(id: currentPath) { await load() }
            .tint(neon.accent)
        }

        // MARK: Sections

        private var recentSection: some View {
            VStack(alignment: .leading, spacing: 8) {
                sectionLabel("Recent")
                VStack(spacing: 6) {
                    ForEach(store.recentDirectories, id: \.self) { path in
                        Button {
                            onCreate(path)
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
                    onCreate(listing?.path)
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
                    onCreate(nil)
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
            .background(neon.surfaceSolid.opacity(0.96))
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
