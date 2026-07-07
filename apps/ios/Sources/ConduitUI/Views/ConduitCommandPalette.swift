import SwiftUI

// MARK: - ConduitCommandPalette
//
// Conduit redesign Command palette (⌘K) surface (handoff §B.12, image 14).
// A terminal-styled quick switcher: a mono, prompt-styled (`>`) search
// field that filters live as you type, three sections, and a keyboard
// hints footer.
//
//   • Actions          — New session… · Pair a box
//   • Jump to session  — the live `store.sessions`, agent-tinted, filtered
//                        by the typed query; selecting one opens it.
//   • Run on box       — a single row that starts a NEW session seeded with
//                        the typed text as its first message. HomeView wires
//                        `onRunOnBox` to stash the text and defer the agent-
//                        picker presentation until after the palette dismisses
//                        (avoids the iOS double-sheet race).
//
// HOW TO PRESENT (the caller wires this — this file only defines the view):
//   Present as a sheet from any host that already has the SessionStore in
//   its environment, e.g. on a ⌘K key command / a search affordance:
//
//       .sheet(isPresented: $showPalette) {
//           ConduitUI.CommandPaletteSheet(
//               onNewSession: { showAgentPicker = true },
//               onPairBox:    { showAddServer = true },
//               onOpenSession: { id in store.selectedSessionID = id },
//               onRunOnBox:    { command in /* stash + defer agent picker */ }
//           )
//           .environment(store)            // SessionStore from the host
//           .presentationDetents([.medium, .large])
//       }
//
//   The sheet pulls the SessionStore from the environment and reads only
//   `store.sessions` + `store.displayName(for:)` — it never fabricates
//   sessions. All callbacks default to no-ops so it compiles + previews
//   standalone. Uses `neon.*` tokens only (no hardcoded hex).

extension ConduitUI {

    struct CommandPaletteSheet: View {
        @Environment(SessionStore.self) private var store
        @Environment(\.neonTheme) private var neon
        @Environment(\.dismiss) private var dismiss

        /// "New session…" action. Default no-op so the sheet compiles
        /// standalone; the caller routes this to the agent picker.
        var onNewSession: () -> Void = {}
        /// "Pair a box" action. Default no-op; caller routes to add-server.
        var onPairBox: () -> Void = {}
        /// Open the session with this id. Default no-op; caller sets
        /// `store.selectedSessionID` / pushes the project view.
        var onOpenSession: (String) -> Void = { _ in }
        /// Run the typed command on the active box as a new session seeded
        /// with the typed text as its first message. The caller (HomeView)
        /// stashes the text in `voicePrompt` and sets `pendingRunOnBox = true`
        /// so the agent picker opens after the palette finishes dismissing,
        /// avoiding the iOS double-sheet race.
        var onRunOnBox: (String) -> Void = { _ in }
        /// "Fan out a task" action — caller presents the Fan-out surface
        /// (`ConduitUI.FanOutView`). Default no-op so the sheet compiles
        /// standalone.
        var onFanOut: () -> Void = {}
        /// "New pipeline" action — caller presents PipelineBuilderView.
        /// Default no-op so the sheet compiles standalone.
        var onNewPipeline: () -> Void = {}
        /// "Pipelines" action — caller presents `ConduitUI.PipelineListView`
        /// (the list of running/past pipelines). Default no-op; only shown
        /// when `store.pipelinesEnabled` is true (old brokers omit the flag).
        var onPipelines: () -> Void = {}

        @State private var query: String = ""
        @FocusState private var fieldFocused: Bool

        var body: some View {
            ZStack {
                GlassAppBackground()
                VStack(spacing: 0) {
                    searchField
                    Divider().overlay(neon.border)
                    ScrollView {
                        // Cap content width at 560pt and centre it so the
                        // palette doesn't stretch edge-to-edge on iPad.
                        // Phone widths are under 560pt so they are unchanged.
                        HStack(spacing: 0) {
                            Spacer(minLength: 0)
                            VStack(alignment: .leading, spacing: 16) {
                                actionsSection
                                jumpSection
                                runOnBoxSection
                            }
                            .frame(maxWidth: 560)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 14)
                            Spacer(minLength: 0)
                        }
                    }
                    Divider().overlay(neon.border)
                    hintsFooter
                }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .onAppear { fieldFocused = true }
        }

        // MARK: Search field (mono, prompt-styled `>`)

        private var searchField: some View {
            HStack(spacing: 8) {
                Text(">")
                    .font(neon.mono(16).weight(.bold))
                    .foregroundStyle(neon.glow ? neon.accent : neon.textDim)
                    .neonTextGlow(neon.glow ? neon.textGlow : nil)
                TextField("", text: $query, prompt: Text("Search actions, sessions, commands…")
                    .foregroundColor(neon.textFaint))
                    .font(neon.mono(15))
                    .foregroundStyle(neon.text)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .focused($fieldFocused)
                    .onSubmit(runPrimary)
                Spacer(minLength: 8)
                Text("ESC")
                    .font(neon.mono(10).weight(.semibold))
                    .foregroundStyle(neon.textFaint)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(neon.surface)
                            .overlay(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .strokeBorder(neon.border, lineWidth: 1)
                            )
                    )
                    .onTapGesture { dismiss() }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }

        // MARK: 1 · Actions

        @ViewBuilder
        private var actionsSection: some View {
            if !filteredActions.isEmpty {
                section("Actions") {
                    VStack(spacing: 6) {
                        ForEach(filteredActions, id: \.id) { action in
                            paletteRow(
                                systemImage: action.systemImage,
                                tint: neon.accent,
                                title: action.title,
                                trailing: action.shortcut
                            ) {
                                dismiss()
                                action.run()
                            }
                        }
                    }
                }
            }
        }

        private struct PaletteAction: Identifiable {
            let id: String
            let title: String
            let systemImage: String
            let shortcut: String?
            let run: () -> Void
        }

        private var allActions: [PaletteAction] {
            [
                PaletteAction(id: "new", title: "New session…", systemImage: "plus.square",
                              shortcut: "⌘N", run: onNewSession),
                PaletteAction(id: "pair", title: "Pair a box", systemImage: "antenna.radiowaves.left.and.right",
                              shortcut: nil, run: onPairBox),
                PaletteAction(id: "fanout", title: "Fan out a task", systemImage: "square.grid.2x2",
                              shortcut: nil, run: onFanOut),
                PaletteAction(id: "pipeline", title: "New flow", systemImage: "arrow.triangle.merge",
                              shortcut: nil, run: onNewPipeline),
            ] + (store.pipelinesEnabled ? [
                PaletteAction(id: "pipelines", title: "Flows", systemImage: "list.bullet.rectangle",
                              shortcut: nil, run: onPipelines),
            ] : [])
        }

        private var filteredActions: [PaletteAction] {
            let q = trimmedQuery
            guard !q.isEmpty else { return allActions }
            return allActions.filter { $0.title.lowercased().contains(q) }
        }

        // MARK: 2 · Jump to session (live store.sessions, filtered + tinted)

        @ViewBuilder
        private var jumpSection: some View {
            let matches = filteredSessions
            if !matches.isEmpty {
                section("Jump to session") {
                    VStack(spacing: 6) {
                        ForEach(matches, id: \.id) { session in
                            let tint = neon.agentTint(forAgent: session.assistant)
                            paletteRow(
                                systemImage: nil,
                                avatarTint: tint,
                                tint: tint,
                                title: store.displayName(for: session),
                                trailing: trailingLabel(for: session)
                            ) {
                                let id = session.id
                                dismiss()
                                onOpenSession(id)
                            }
                        }
                    }
                }
            }
        }

        /// Live sessions filtered by the typed query against the resolved
        /// display name (+ agent + branch). Never fabricates rows.
        private var filteredSessions: [ProjectSession] {
            let q = trimmedQuery
            guard !q.isEmpty else { return store.sessions }
            return store.sessions.filter { session in
                if store.displayName(for: session).lowercased().contains(q) { return true }
                if session.assistant.lowercased().contains(q) { return true }
                if let branch = session.branch, branch.lowercased().contains(q) { return true }
                return false
            }
        }

        private func trailingLabel(for session: ProjectSession) -> String {
            if let branch = session.branch, !branch.isEmpty { return branch }
            return session.assistant.lowercased()
        }

        // MARK: 3 · Run on box

        @ViewBuilder
        private var runOnBoxSection: some View {
            let q = trimmedQuery
            if !q.isEmpty {
                // Name the connected box in the header when we have one
                // (`Run on <host>`); fall back to the generic label otherwise.
                let header = store.endpoint.isComplete
                    ? "Run on \(store.endpoint.displayHost)"
                    : "Run on box"
                section(header) {
                    paletteRow(
                        systemImage: "terminal",
                        tint: neon.green,
                        title: trimmedQueryRaw,
                        titleMono: true,
                        trailing: "↵"
                    ) {
                        let command = trimmedQueryRaw
                        dismiss()
                        onRunOnBox(command)
                    }
                }
            }
        }

        // MARK: Footer

        private var hintsFooter: some View {
            HStack(spacing: 10) {
                hint("↑↓", "navigate")
                hint("⏎", "open")
                hint("⌘K", "toggle")
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }

        private func hint(_ key: String, _ label: String) -> some View {
            HStack(spacing: 5) {
                Text(key)
                    .font(neon.mono(11).weight(.semibold))
                    .foregroundStyle(neon.textDim)
                Text(label)
                    .font(neon.mono(11))
                    .foregroundStyle(neon.textFaint)
            }
        }

        // MARK: Row + section chrome

        private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(neon.mono(10.5).weight(.bold))
                    .foregroundStyle(neon.textFaint)
                    .textCase(.uppercase)
                    .tracking(1.4)
                content()
            }
        }

        /// A single palette row: a leading glyph (SF Symbol) OR an
        /// agent-tinted ConduitMark avatar, a title (sans or mono), and an
        /// optional trailing mono hint. Wrapped in a hairline neon card.
        private func paletteRow(
            systemImage: String?,
            avatarTint: Color? = nil,
            tint: Color,
            title: String,
            titleMono: Bool = false,
            trailing: String?,
            action: @escaping () -> Void
        ) -> some View {
            Button(action: action) {
                HStack(spacing: 11) {
                    leadingGlyph(systemImage: systemImage, avatarTint: avatarTint, tint: tint)
                    Text(title)
                        .font(titleMono ? neon.mono(13) : neon.sans(14).weight(.medium))
                        .foregroundStyle(neon.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 8)
                    if let trailing, !trailing.isEmpty {
                        Text(trailing)
                            .font(neon.mono(11))
                            .foregroundStyle(neon.textFaint)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .neonCardSurface(neon, fill: neon.surface, cornerRadius: 11)
            }
            .buttonStyle(.plain)
        }

        @ViewBuilder
        private func leadingGlyph(systemImage: String?, avatarTint: Color?, tint: Color) -> some View {
            if let avatarTint {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(avatarTint.opacity(neon.dark ? 0.14 : 0.10))
                    .frame(width: 30, height: 30)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(avatarTint.opacity(0.35), lineWidth: 1)
                    )
                    .overlay(ConduitUI.ConduitMark(size: 18, color: avatarTint, glow: neon.glow))
            } else {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(tint.opacity(0.12))
                    .frame(width: 30, height: 30)
                    .overlay(
                        Image(systemName: systemImage ?? "circle")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(tint)
                    )
            }
        }

        // MARK: Helpers

        /// The query trimmed of surrounding whitespace, preserving case for
        /// the run-on-box command text.
        private var trimmedQueryRaw: String {
            query.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        /// Lowercased trimmed query for case-insensitive filtering.
        private var trimmedQuery: String { trimmedQueryRaw.lowercased() }

        /// ⏎ behaviour: open the first matching session if any, else (when a
        /// query is present) treat the line as a run-on-box command, else
        /// fall through to "New session…". Mirrors the design's single
        /// "primary" intent for the highlighted top match.
        private func runPrimary() {
            if let first = filteredSessions.first {
                let id = first.id
                dismiss()
                onOpenSession(id)
                return
            }
            let q = trimmedQueryRaw
            if !q.isEmpty {
                dismiss()
                onRunOnBox(q)
                return
            }
            dismiss()
            onNewSession()
        }
    }
}
