import SwiftUI

// MARK: - ConduitUI.ChangesView  (PLAN-REVIEW-SHIP — Review & Ship from phone)
//
// The structured-diff Changes surface: scope toggle (Uncommitted | Branch),
// file list with status glyph + ±counts + a per-file staged toggle, an
// inline expandable file diff (DiffHunkView / DiffLineRow), line-anchored
// annotations batched into one send-to-agent prompt, an Unanchored-comments
// section, and a Ship card (stage-aware commit / push / Create PR).
//
// Gated end to end on `BoxFeatures.reviewShip` by the caller
// (`ConduitProjectView`, `ConduitUI.TabletRightPane`) — this view assumes
// the broker supports the endpoints it calls.

extension ConduitUI {

    struct ChangesView: View {
        @Environment(SessionStore.self) private var store
        @Environment(\.neonTheme) private var neon
        @Environment(\.dismiss) private var dismiss

        let session: ProjectSession
        /// Hosted inline (tablet right pane) rather than as a sheet — drop
        /// the close button, matching `DiffReviewView`'s `embedded` convention.
        var embedded: Bool = false

        @State private var model: ChangesModel
        @State private var expandedPaths: Set<String> = []
        @State private var annotateTarget: AnnotateTarget?
        @State private var showPRSheet = false
        @State private var prTitle = ""
        @State private var prBody = ""

        init(session: ProjectSession, embedded: Bool = false) {
            self.session = session
            self.embedded = embedded
            _model = State(initialValue: ChangesModel(sessionID: session.id))
        }

        var body: some View {
            ZStack {
                GlassAppBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        header
                        scopeToggle
                        if let error = model.loadError {
                            errorCard(error)
                        }
                        if let diff = model.diff {
                            diffStatCard(diff)
                            fileSection(diff)
                        } else if model.isLoading {
                            ProgressView().tint(neon.accent)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 32)
                        }
                        if !model.unanchoredAnnotations.isEmpty {
                            unanchoredSection
                        }
                        shipCard
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 90)
                    .frame(maxWidth: embedded ? .infinity : 760)
                    .frame(maxWidth: .infinity)
                }
                .refreshable { await model.load(store: store) }
            }
            .safeAreaInset(edge: .bottom) {
                if !model.annotations.isEmpty { reviewBar }
            }
            .navigationTitle("Changes")
            .navigationBarTitleDisplayMode(.inline)
            .task(id: session.id) {
                Telemetry.breadcrumb("changes", "changes_open", data: ["session": session.id])
                await model.load(store: store)
            }
            .sheet(item: $annotateTarget) { target in
                annotateSheet(target)
            }
            .sheet(isPresented: $showPRSheet) {
                prInputSheet
            }
        }

        // MARK: Header

        private var header: some View {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Changes")
                        .font(neon.sans(20).weight(.bold))
                        .foregroundStyle(neon.text)
                        .neonTextGlow(neon.textGlow)
                    if let branch = model.gitState?.branch {
                        Text(branch)
                            .font(neon.mono(11.5))
                            .foregroundStyle(neon.textDim)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if !embedded {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(neon.textDim)
                            .frame(width: 32, height: 32)
                            .conduitGlassCircle()
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close")
                }
            }
        }

        private var scopeToggle: some View {
            NeonSegmentedPill(
                segments: ChangesModel.Scope.allCases.map {
                    NeonSegmentedPill<ChangesModel.Scope>.Segment(id: $0, label: $0.label)
                },
                selection: Binding(
                    get: { model.scope },
                    set: { newValue in
                        Task { await model.setScope(newValue, store: store) }
                    }
                )
            )
        }

        private func errorCard(_ message: String) -> some View {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(neon.red)
                Text(message)
                    .font(neon.sans(13))
                    .foregroundStyle(neon.text)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .neonCardSurface(neon, fill: neon.surface, cornerRadius: 12, failed: true)
        }

        private func diffStatCard(_ diff: GitDiffResponse) -> some View {
            HStack(spacing: 18) {
                ConduitUI.StatTile(value: "\(diff.diffstat.files_changed)", label: "files")
                ConduitUI.StatTile(value: "+\(diff.diffstat.additions)", label: "added", tint: neon.green)
                ConduitUI.StatTile(value: "−\(diff.diffstat.deletions)", label: "removed", tint: neon.red)
            }
        }

        // MARK: File list

        private func fileSection(_ diff: GitDiffResponse) -> some View {
            VStack(alignment: .leading, spacing: 8) {
                if diff.files.isEmpty {
                    Text("No changes.")
                        .font(neon.sans(13))
                        .foregroundStyle(neon.textDim)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .neonCardSurface(neon, fill: neon.surface, cornerRadius: 12)
                } else {
                    ForEach(diff.files) { file in
                        fileCard(file)
                    }
                }
            }
        }

        private func fileCard(_ file: GitDiffFile) -> some View {
            let isOpen = expandedPaths.contains(file.path)
            // NOTE: the staged toggle is a real `Button`, so the row-tap
            // disclosure below is deliberately `.onTapGesture` (not a
            // wrapping `Button`) -- nesting a `Button` inside another
            // `Button`'s label is ambiguous gesture territory in SwiftUI.
            return VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: statusGlyph(file.status))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(statusTint(file.status))
                    Text(file.path)
                        .font(neon.mono(12).weight(.medium))
                        .foregroundStyle(neon.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    if !file.binary {
                        Text("+\(file.additions)")
                            .font(neon.mono(11).weight(.semibold))
                            .foregroundStyle(neon.green)
                        Text("−\(file.deletions)")
                            .font(neon.mono(11).weight(.semibold))
                            .foregroundStyle(neon.red)
                    }
                    stagedToggle(file)
                    if !file.hunks.isEmpty {
                        Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(neon.textFaint)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
                .contentShape(Rectangle())
                .onTapGesture {
                    guard !file.hunks.isEmpty else { return }
                    withAnimation(.easeOut(duration: 0.16)) {
                        if isOpen { expandedPaths.remove(file.path) } else { expandedPaths.insert(file.path) }
                    }
                }

                if isOpen, !file.hunks.isEmpty {
                    Divider().background(neon.border)
                    VStack(spacing: 6) {
                        ForEach(file.hunks) { hunk in
                            DiffHunkView(
                                filePath: file.path,
                                hunk: hunk,
                                annotatedLineIndices: annotatedIndices(filePath: file.path, hunk: hunk),
                                onTapLine: { hunk, index in
                                    annotateTarget = AnnotateTarget(filePath: file.path, hunk: hunk, lineIndex: index)
                                }
                            )
                        }
                    }
                    .padding(10)
                }
            }
            .neonCardSurface(neon, fill: neon.surface, cornerRadius: 12)
        }

        private func stagedToggle(_ file: GitDiffFile) -> some View {
            let inFlight = model.stagingPaths.contains(file.path)
            return Button {
                Task { await model.toggleStaged(file: file, store: store) }
            } label: {
                if inFlight {
                    ProgressView().scaleEffect(0.6).tint(neon.accent)
                        .frame(width: 22, height: 22)
                } else {
                    Image(systemName: file.staged ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(file.staged ? neon.green : neon.textFaint)
                        .frame(width: 22, height: 22)
                }
            }
            .buttonStyle(.plain)
            .disabled(inFlight)
            .accessibilityLabel(file.staged ? "Staged" : "Not staged")
        }

        private func annotatedIndices(filePath: String, hunk: GitDiffHunk) -> Set<Int> {
            let texts = Set(
                model.annotations
                    .filter { $0.anchored && $0.filePath == filePath }
                    .map(\.lineText)
            )
            guard !texts.isEmpty else { return [] }
            var result: Set<Int> = []
            for (index, line) in hunk.lines.enumerated() where texts.contains(line.text) {
                result.insert(index)
            }
            return result
        }

        private func statusGlyph(_ status: String) -> String {
            switch status {
            case "added":     return "plus.circle"
            case "deleted":   return "minus.circle"
            case "renamed":   return "arrow.triangle.swap"
            case "copied":    return "doc.on.doc"
            case "untracked": return "questionmark.circle"
            default:          return "pencil.circle"
            }
        }

        private func statusTint(_ status: String) -> Color {
            switch status {
            case "added":     return neon.green
            case "deleted":   return neon.red
            case "renamed", "copied": return neon.blue
            case "untracked": return neon.textDim
            default:          return neon.yellow
            }
        }

        // MARK: Annotate sheet

        private struct AnnotateTarget: Identifiable {
            let id = UUID()
            let filePath: String
            let hunk: GitDiffHunk
            let lineIndex: Int
            var line: GitDiffLine { hunk.lines[lineIndex] }
        }

        @ViewBuilder
        private func annotateSheet(_ target: AnnotateTarget) -> some View {
            AnnotateSheetView(
                filePath: target.filePath,
                line: target.line
            ) { commentText in
                model.addAnnotation(
                    filePath: target.filePath,
                    hunk: target.hunk,
                    lineIndex: target.lineIndex,
                    comment: commentText
                )
                annotateTarget = nil
            }
            .environment(\.neonTheme, neon)
        }

        // MARK: Unanchored comments

        private var unanchoredSection: some View {
            VStack(alignment: .leading, spacing: 8) {
                Text("Unanchored comments")
                    .font(neon.mono(11).weight(.bold))
                    .foregroundStyle(neon.yellow)
                    .textCase(.uppercase)
                ForEach(model.unanchoredAnnotations) { ann in
                    unanchoredRow(ann)
                }
            }
        }

        private func unanchoredRow(_ ann: ChangeAnnotation) -> some View {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(neon.yellow)
                    Text(ann.filePath)
                        .font(neon.mono(11).weight(.semibold))
                        .foregroundStyle(neon.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    Button {
                        model.removeAnnotation(id: ann.id)
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(neon.red)
                    }
                    .buttonStyle(.plain)
                }
                Text(ann.lineText)
                    .font(neon.mono(10.5))
                    .foregroundStyle(neon.textFaint)
                    .lineLimit(1)
                Text(ann.comment)
                    .font(neon.sans(12.5))
                    .foregroundStyle(neon.textDim)
                    .lineLimit(3)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .neonCardSurface(neon, fill: neon.surface, cornerRadius: 10, border: neon.yellow.opacity(0.35))
        }

        // MARK: Review bar (send-to-agent)

        private var reviewBar: some View {
            Button {
                model.sendToAgent(store: store)
            } label: {
                HStack(spacing: 8) {
                    if model.isSendingToAgent {
                        ProgressView().progressViewStyle(.circular).tint(neon.accentText).scaleEffect(0.7)
                    } else {
                        Image(systemName: "paperplane.fill")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    Text("\(model.annotations.count) comment\(model.annotations.count == 1 ? "" : "s") · Send to agent")
                        .font(neon.mono(13).weight(.semibold))
                }
                .foregroundStyle(neon.accentText)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Capsule().fill(neon.accent))
                .neonGlowBox(neon.glow ? neon.glowBox?.tinted(neon.accent) : nil)
            }
            .buttonStyle(.plain)
            .disabled(model.isSendingToAgent)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)
            .overlay(alignment: .top) { Divider().background(neon.border) }
        }

        // MARK: Ship card

        private var shipCard: some View {
            VStack(alignment: .leading, spacing: 10) {
                Text("Ship")
                    .font(neon.mono(11).weight(.bold))
                    .foregroundStyle(neon.textDim)
                    .textCase(.uppercase)

                if let opError = model.opError {
                    errorCard(opError)
                }
                if let sha = model.lastCommitSha {
                    Text("Committed \(sha)")
                        .font(neon.mono(11))
                        .foregroundStyle(neon.green)
                }
                if let prURLString = model.lastPRUrl, let prURL = URL(string: prURLString) {
                    Link(prURLString, destination: prURL)
                        .font(neon.mono(11))
                        .foregroundStyle(neon.blue)
                }

                TextField("Commit message", text: Binding(
                    get: { model.commitMessage },
                    set: { model.commitMessage = $0 }
                ), axis: .vertical)
                    .font(neon.sans(14))
                    .foregroundStyle(neon.text)
                    .lineLimit(1...3)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(neon.surface2)
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(neon.border, lineWidth: 1))
                    )

                let canCommit = !model.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && !model.isCommitting

                HStack(spacing: 10) {
                    ConduitUI.ActionButton("Commit staged", variant: .secondary, tint: neon.green) {
                        Task { await model.commit(all: false, store: store) }
                    }
                    .disabled(!canCommit)

                    ConduitUI.ActionButton("Commit all", variant: .primary, tint: neon.green) {
                        Task { await model.commit(all: true, store: store) }
                    }
                    .disabled(!canCommit)
                }

                HStack(spacing: 10) {
                    ConduitUI.ActionButton("Push", variant: .secondary, tint: neon.accent) {
                        Task { await model.push(store: store) }
                    }
                    .disabled(model.isPushing)

                    if model.gitState?.has_gh == true {
                        ConduitUI.ActionButton("Create PR", variant: .secondary, tint: neon.blue) {
                            prTitle = ""
                            prBody = ""
                            showPRSheet = true
                        }
                        .disabled(model.isCreatingPR)
                    }
                }
            }
            .padding(14)
            .neonCardSurface(neon, fill: neon.surface, cornerRadius: 14)
        }

        private var prInputSheet: some View {
            NavigationStack {
                ZStack {
                    GlassAppBackground()
                    VStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("PR Title")
                                .font(neon.mono(11).weight(.semibold))
                                .foregroundStyle(neon.textDim)
                                .textCase(.uppercase)
                            TextField("Title (required)", text: $prTitle)
                                .font(neon.sans(14))
                                .foregroundStyle(neon.text)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(neon.surface2)
                                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(neon.border, lineWidth: 1))
                                )
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Description (optional)")
                                .font(neon.mono(11).weight(.semibold))
                                .foregroundStyle(neon.textDim)
                                .textCase(.uppercase)
                            TextField("Body", text: $prBody, axis: .vertical)
                                .font(neon.sans(14))
                                .foregroundStyle(neon.text)
                                .lineLimit(4...8)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(neon.surface2)
                                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(neon.border, lineWidth: 1))
                                )
                        }
                        Spacer()
                    }
                    .padding(16)
                }
                .navigationTitle("Open Pull Request")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showPRSheet = false }
                            .foregroundStyle(neon.textDim)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Open PR") {
                            showPRSheet = false
                            Task { await model.createPR(title: prTitle, body: prBody, store: store) }
                        }
                        .font(neon.sans(14).weight(.semibold))
                        .foregroundStyle(neon.accent)
                        .disabled(prTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .environment(\.neonTheme, neon)
        }
    }
}

// MARK: - AnnotateSheetView

/// Markdown comment sheet opened on a line tap. `.sheet(item:)`-hosted (not
/// `isPresented:`) so a new target while one sheet is already up correctly
/// re-identifies the view instead of reusing stale identity.
private struct AnnotateSheetView: View {
    let filePath: String
    let line: ConduitUI.GitDiffLine
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.neonTheme) private var neon
    @State private var comment: String = ""

    var body: some View {
        NavigationStack {
            ZStack {
                GlassAppBackground()
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(filePath)
                            .font(neon.mono(11).weight(.semibold))
                            .foregroundStyle(neon.textDim)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(line.text)
                            .font(neon.mono(12))
                            .foregroundStyle(neon.text)
                            .lineLimit(3)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 8).fill(neon.surface2))
                    }

                    TextEditor(text: $comment)
                        .font(neon.sans(14))
                        .foregroundStyle(neon.text)
                        .scrollContentBackground(.hidden)
                        .background(neon.surface2)
                        .frame(height: 160)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(neon.borderStrong, lineWidth: 1)
                        )

                    Spacer()
                }
                .padding(16)
            }
            .navigationTitle("Comment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(neon.textDim)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        onSave(comment.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                    .font(neon.sans(14).weight(.semibold))
                    .foregroundStyle(neon.accent)
                    .disabled(comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .environment(\.neonTheme, neon)
    }
}
