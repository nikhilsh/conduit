import Foundation
import Observation

// MARK: - Git wire models (PLAN-REVIEW-SHIP §3)
//
// Decodable/Encodable shapes for the broker's structured diff + git-ops
// endpoints. Property names deliberately mirror the wire JSON verbatim
// (snake_case) -- the codebase convention elsewhere (see `LiveSessionInfo`'s
// `RemoteConversationPage` sibling structs) is either that or an explicit
// `CodingKeys` block; snake_case-as-written keeps these terse since every
// field name is already a valid Swift identifier.
//
// NOTE: distinct from the pre-existing `ConduitUI.DiffFile` / `DiffLine`
// (ConduitDiffReviewModel.swift) which scrape a diff out of the chat
// transcript for old brokers. These `GitDiff*` types are the new,
// structurally-parsed broker diff (review_ship capability) and intentionally
// do not share a name with the legacy scrape types.

extension ConduitUI {

    struct GitDiffLine: Decodable, Equatable {
        enum Kind: String, Codable, Equatable {
            case context, add, del
        }
        let kind: Kind
        let old: Int
        let new: Int
        let text: String
    }

    struct GitDiffHunk: Decodable, Equatable, Identifiable {
        let header: String
        let old_start: Int
        let old_lines: Int
        let new_start: Int
        let new_lines: Int
        let lines: [GitDiffLine]

        var id: String { "\(header)|\(old_start)|\(new_start)|\(new_lines)" }
    }

    struct GitDiffFile: Decodable, Equatable, Identifiable {
        let path: String
        let old_path: String?
        let status: String
        let staged: Bool
        let binary: Bool
        let additions: Int
        let deletions: Int
        let truncated: Bool
        let hunks: [GitDiffHunk]

        var id: String { path }
    }

    struct GitDiffStat: Decodable, Equatable {
        let files_changed: Int
        let additions: Int
        let deletions: Int
    }

    struct GitDiffResponse: Decodable, Equatable {
        let scope: String
        let default_branch: String
        let base: String?
        let files: [GitDiffFile]
        let diffstat: GitDiffStat
        let truncated: Bool
    }

    struct GitStatePR: Decodable, Equatable {
        let url: String
        let number: Int
        let state: String
    }

    /// `GET /api/session/{id}/git/state`. Every field but `is_git_repo` is
    /// optional -- the "not a repo" shape is `{"is_git_repo":false}` alone.
    struct GitState: Decodable, Equatable {
        let is_git_repo: Bool
        let branch: String?
        let detached: Bool?
        let default_branch: String?
        let upstream: String?
        let ahead: Int?
        let behind: Int?
        let staged: Int?
        let unstaged: Int?
        let untracked: Int?
        let dirty: Int?
        let has_gh: Bool?
        let pr: GitStatePR?
    }

    /// Shared `{"ok":bool,"stderr":string}` shape for stage/unstage.
    struct GitOpResult: Decodable, Equatable {
        let ok: Bool
        let stderr: String?
    }

    struct GitCommitResult: Decodable, Equatable {
        let ok: Bool
        let stdout: String?
        let stderr: String?
        let commit_sha: String?
    }

    struct GitPushResult: Decodable, Equatable {
        let ok: Bool
        let stdout: String?
        let stderr: String?
        let branch: String?
        let ahead: Int?
        let behind: Int?
        let set_upstream: Bool?
    }

    struct GitPRResult: Decodable, Equatable {
        let ok: Bool
        let pr_url: String?
        let stderr: String?
    }
}

// MARK: - Local annotation model (client-side only, no broker storage — v1 non-goal)

extension ConduitUI {

    /// A line-anchored review comment. Persisted client-side only, keyed by
    /// session id (`ChangesAnnotationStore`). `anchored:false` means the last
    /// re-anchor pass (`ChangesModel.reanchor`) couldn't find `lineText` in
    /// the freshest diff for `filePath` -- the comment moves to the
    /// "Unanchored comments" section but is NEVER dropped.
    struct ChangeAnnotation: Codable, Identifiable, Equatable {
        let id: UUID
        var filePath: String
        var kind: GitDiffLine.Kind
        /// `new` line number for add/context lines, `old` for del -- the
        /// exact convention the prompt composer's `Location:` line uses.
        var lineNumber: Int
        var lineText: String
        /// Up to 2 lines of same-hunk context each side. Empty on both
        /// sides for a single-line hunk (composer omits the Context block).
        var contextBefore: [String]
        var contextAfter: [String]
        var comment: String
        var createdAt: Date
        var anchored: Bool

        init(
            id: UUID = UUID(),
            filePath: String,
            kind: GitDiffLine.Kind,
            lineNumber: Int,
            lineText: String,
            contextBefore: [String],
            contextAfter: [String],
            comment: String,
            createdAt: Date = Date(),
            anchored: Bool = true
        ) {
            self.id = id
            self.filePath = filePath
            self.kind = kind
            self.lineNumber = lineNumber
            self.lineText = lineText
            self.contextBefore = contextBefore
            self.contextAfter = contextAfter
            self.comment = comment
            self.createdAt = createdAt
            self.anchored = anchored
        }
    }

    /// UserDefaults-backed persistence for annotations, keyed by session id
    /// (mirrors `SessionStore`'s `hiddenFoundSessions` persistence pattern).
    /// Client-side only per the plan's v1 non-goal (no broker annotation
    /// storage) -- comments live on-device and are re-anchored against
    /// whatever diff the broker returns next.
    enum ChangesAnnotationStore {
        private static let key = "conduit.changes.annotations"

        static func loadAll() -> [String: [ChangeAnnotation]] {
            guard let data = UserDefaults.standard.data(forKey: key),
                  let decoded = try? JSONDecoder().decode([String: [ChangeAnnotation]].self, from: data)
            else { return [:] }
            return decoded
        }

        static func persistAll(_ map: [String: [ChangeAnnotation]]) {
            guard let data = try? JSONEncoder().encode(map) else { return }
            UserDefaults.standard.set(data, forKey: key)
        }

        static func load(sessionID: String) -> [ChangeAnnotation] {
            loadAll()[sessionID] ?? []
        }

        static func save(sessionID: String, annotations: [ChangeAnnotation]) {
            var all = loadAll()
            if annotations.isEmpty {
                all.removeValue(forKey: sessionID)
            } else {
                all[sessionID] = annotations
            }
            persistAll(all)
        }
    }
}

// MARK: - ChangesModel
//
// Per-session orchestration for the Changes surface: diff + git/state fetch,
// the local annotation store, re-anchoring, and the send-to-agent prompt
// composer. Networking is delegated to `SessionStore`'s `fetchGitDiff` /
// `fetchGitState` / `gitStage` / `gitUnstage` / `gitCommit` / `gitPush` /
// `gitCreatePR` client methods -- this class holds no URLSession of its own.

extension ConduitUI {

    @Observable
    @MainActor
    final class ChangesModel {
        enum Scope: String, CaseIterable, Identifiable {
            case uncommitted
            case branch

            var id: String { rawValue }
            var label: String {
                switch self {
                case .uncommitted: return "Uncommitted"
                case .branch:      return "Branch"
                }
            }
        }

        let sessionID: String

        var scope: Scope = .uncommitted
        var diff: GitDiffResponse?
        var gitState: GitState?
        var isLoading = false
        /// Set on a diff/state fetch failure; cleared on the next successful
        /// load. Rendered as an honest error state, never silently retried
        /// forever.
        var loadError: String?

        var annotations: [ChangeAnnotation] = []
        var anchoredAnnotations: [ChangeAnnotation] { annotations.filter(\.anchored) }
        var unanchoredAnnotations: [ChangeAnnotation] { annotations.filter { !$0.anchored } }

        /// Paths with an in-flight stage/unstage POST -- disables that row's
        /// toggle so a double-tap can't race two requests.
        var stagingPaths: Set<String> = []

        var commitMessage: String = ""
        var isCommitting = false
        var isPushing = false
        var isCreatingPR = false
        /// Verbatim stderr from the most recent commit/push/PR failure --
        /// never swallowed, per the plan's ship-card requirement.
        var opError: String?
        var lastCommitSha: String?
        var lastPRUrl: String?

        var isSendingToAgent = false

        // `nonisolated` so `ChangesView.init` (not itself @MainActor) can
        // construct this via `State(initialValue:)` without the compiler
        // requiring the whole View init to be MainActor-isolated. Only
        // touches `sessionID` + the nonisolated `ChangesAnnotationStore`.
        nonisolated init(sessionID: String) {
            self.sessionID = sessionID
            self.annotations = ChangesAnnotationStore.load(sessionID: sessionID)
        }

        // MARK: Load

        @MainActor
        func load(store: SessionStore) async {
            isLoading = true
            loadError = nil
            Telemetry.breadcrumb("changes", "diff_fetch start", data: [
                "session": sessionID, "scope": scope.rawValue,
            ])
            async let diffTask = store.fetchGitDiff(sessionID: sessionID, scope: scope.rawValue)
            async let stateTask = store.fetchGitState(sessionID: sessionID)
            let (newDiff, newState) = await (diffTask, stateTask)
            isLoading = false
            guard let newDiff else {
                loadError = "Could not load the diff. Pull to retry."
                Telemetry.capture(
                    error: NSError(domain: "ios.changes", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "diff fetch failed"]),
                    message: "changes diff_fetch failed",
                    tags: ["surface": "ios", "phase": "changes"],
                    extras: ["session": sessionID, "scope": scope.rawValue]
                )
                return
            }
            diff = newDiff
            gitState = newState
            annotations = Self.reanchor(annotations, against: newDiff)
            ChangesAnnotationStore.save(sessionID: sessionID, annotations: annotations)
            Telemetry.breadcrumb("changes", "diff_fetch finish", data: [
                "session": sessionID, "scope": scope.rawValue,
                "files": "\(newDiff.files.count)",
                "unanchored": "\(unanchoredAnnotations.count)",
            ])
        }

        @MainActor
        func setScope(_ newScope: Scope, store: SessionStore) async {
            guard newScope != scope else { return }
            scope = newScope
            await load(store: store)
        }

        // MARK: Annotate

        /// Up to-2-lines-each-side context window from the SAME hunk --
        /// never crosses a hunk boundary. Empty/empty for a single-line hunk.
        nonisolated static func contextWindow(hunk: GitDiffHunk, lineIndex: Int) -> (before: [String], after: [String]) {
            let lines = hunk.lines
            guard lines.indices.contains(lineIndex) else { return ([], []) }
            let beforeStart = max(0, lineIndex - 2)
            let before = lines[beforeStart..<lineIndex].map(\.text)
            let afterEnd = min(lines.count, lineIndex + 3)
            let after = lines[(lineIndex + 1)..<afterEnd].map(\.text)
            return (before, after)
        }

        func addAnnotation(
            filePath: String,
            hunk: GitDiffHunk,
            lineIndex: Int,
            comment: String
        ) {
            guard hunk.lines.indices.contains(lineIndex) else { return }
            let line = hunk.lines[lineIndex]
            let window = Self.contextWindow(hunk: hunk, lineIndex: lineIndex)
            let lineNumber = line.kind == .del ? line.old : line.new
            let annotation = ChangeAnnotation(
                filePath: filePath,
                kind: line.kind,
                lineNumber: lineNumber,
                lineText: line.text,
                contextBefore: window.before,
                contextAfter: window.after,
                comment: comment
            )
            annotations.append(annotation)
            ChangesAnnotationStore.save(sessionID: sessionID, annotations: annotations)
            Telemetry.breadcrumb("changes", "annotate_add", data: [
                "session": sessionID, "file": filePath, "kind": line.kind.rawValue,
                "line": "\(lineNumber)",
            ])
        }

        func removeAnnotation(id: UUID) {
            annotations.removeAll { $0.id == id }
            ChangesAnnotationStore.save(sessionID: sessionID, annotations: annotations)
        }

        /// Re-locate every annotation against a freshly fetched diff by exact
        /// `(file, lineText)` match, preferring the same `kind`. A file no
        /// longer in the diff, or text no longer present anywhere in that
        /// file, marks the annotation `anchored:false` -- it moves to the
        /// Unanchored section, never dropped.
        nonisolated static func reanchor(_ annotations: [ChangeAnnotation], against diff: GitDiffResponse) -> [ChangeAnnotation] {
            annotations.map { original in
                var ann = original
                guard let file = diff.files.first(where: { $0.path == ann.filePath }) else {
                    ann.anchored = false
                    return ann
                }
                let candidates = file.hunks.flatMap(\.lines)
                let match = candidates.first { $0.text == ann.lineText && $0.kind == ann.kind }
                    ?? candidates.first { $0.text == ann.lineText }
                guard let match else {
                    ann.anchored = false
                    return ann
                }
                ann.kind = match.kind
                ann.lineNumber = match.kind == .del ? match.old : match.new
                ann.anchored = true
                return ann
            }
        }

        // MARK: Prompt composer (send-to-agent)

        /// Builds the exact batched review prompt (design doc §2). Pure
        /// function -- no I/O, unit-tested against a golden fixture.
        nonisolated static func composePrompt(_ annotations: [ChangeAnnotation]) -> String {
            let n = annotations.count
            var lines: [String] = []
            lines.append("I reviewed the current changes and left \(n) inline comment(s). Please address each one, then stop so I can re-review.")
            lines.append("")
            for (idx, ann) in annotations.enumerated() {
                let i = idx + 1
                lines.append("===== Comment \(i) of \(n) =====")
                lines.append("File: \(ann.filePath)")
                if ann.anchored {
                    lines.append("Location: \(ann.kind.rawValue) line \(ann.lineNumber)")
                } else {
                    lines.append("Location: (unanchored — line text no longer present)")
                }
                lines.append("Annotated line:")
                lines.append("    \(ann.lineText)")
                let hasContext = ann.anchored && !(ann.contextBefore.isEmpty && ann.contextAfter.isEmpty)
                if hasContext {
                    lines.append("Context:")
                    for c in ann.contextBefore { lines.append("    \(c)") }
                    lines.append(">>> \(ann.lineText)")
                    for c in ann.contextAfter { lines.append("    \(c)") }
                }
                lines.append("Comment:")
                lines.append(ann.comment)
                lines.append("")
            }
            lines.append("===== End of comments =====")
            lines.append("Guidance: make only the changes these comments call for; keep the diff focused. When done, reply with a one-line summary per comment and wait for my re-review.")
            return lines.joined(separator: "\n")
        }

        /// Compose the batched prompt and send it through the EXISTING
        /// durable chat-send path (client_msg_id dedup) -- no new endpoint.
        /// Annotations stay pinned afterward (re-review verification), per
        /// the plan.
        @MainActor
        func sendToAgent(store: SessionStore) {
            guard !anchoredAnnotations.isEmpty || !unanchoredAnnotations.isEmpty else { return }
            isSendingToAgent = true
            defer { isSendingToAgent = false }
            let prompt = Self.composePrompt(annotations)
            Telemetry.breadcrumb("changes", "send_to_agent", data: [
                "session": sessionID, "count": "\(annotations.count)",
                "unanchored": "\(unanchoredAnnotations.count)",
            ])
            store.sendChat(sessionID: sessionID, message: prompt)
        }

        // MARK: Stage / unstage

        @MainActor
        func toggleStaged(file: GitDiffFile, store: SessionStore) async {
            guard !stagingPaths.contains(file.path) else { return }
            stagingPaths.insert(file.path)
            defer { stagingPaths.remove(file.path) }
            Telemetry.breadcrumb("changes", file.staged ? "unstage start" : "stage start", data: [
                "session": sessionID, "path": file.path,
            ])
            let result = file.staged
                ? await store.gitUnstage(sessionID: sessionID, paths: [file.path])
                : await store.gitStage(sessionID: sessionID, paths: [file.path])
            guard let result, result.ok else {
                opError = result?.stderr ?? "Stage/unstage failed"
                Telemetry.capture(
                    error: NSError(domain: "ios.changes", code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "stage toggle failed"]),
                    message: "changes stage toggle failed",
                    tags: ["surface": "ios", "phase": "changes"],
                    extras: ["session": sessionID, "path": file.path, "stderr": result?.stderr ?? ""]
                )
                return
            }
            await load(store: store)
        }

        // MARK: Ship (commit / push / PR)

        @MainActor
        func commit(all: Bool, store: SessionStore) async {
            let msg = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !msg.isEmpty, !isCommitting else { return }
            isCommitting = true
            opError = nil
            defer { isCommitting = false }
            Telemetry.breadcrumb("changes", "commit_start", data: ["session": sessionID, "all": "\(all)"])
            let response = await store.gitCommit(sessionID: sessionID, message: msg, all: all)
            guard let result = response, result.ok else {
                let detail = response?.stderr ?? "Commit failed"
                opError = detail
                Telemetry.capture(
                    error: NSError(domain: "ios.changes", code: 3,
                        userInfo: [NSLocalizedDescriptionKey: "commit failed"]),
                    message: "changes commit_fail",
                    tags: ["surface": "ios", "phase": "changes"],
                    extras: ["session": sessionID, "stderr": detail]
                )
                return
            }
            lastCommitSha = result.commit_sha
            commitMessage = ""
            Telemetry.breadcrumb("changes", "commit_finish", data: [
                "session": sessionID, "sha": result.commit_sha ?? "",
            ])
            await load(store: store)
        }

        @MainActor
        func push(store: SessionStore) async {
            guard !isPushing else { return }
            isPushing = true
            opError = nil
            defer { isPushing = false }
            Telemetry.breadcrumb("changes", "push_start", data: ["session": sessionID])
            let response = await store.gitPush(sessionID: sessionID)
            guard let result = response, result.ok else {
                let detail = response?.stderr ?? "Push failed"
                opError = detail
                Telemetry.capture(
                    error: NSError(domain: "ios.changes", code: 4,
                        userInfo: [NSLocalizedDescriptionKey: "push failed"]),
                    message: "changes push_fail",
                    tags: ["surface": "ios", "phase": "changes"],
                    extras: ["session": sessionID, "stderr": detail]
                )
                return
            }
            Telemetry.breadcrumb("changes", "push_finish", data: [
                "session": sessionID, "branch": result.branch ?? "",
            ])
            await load(store: store)
        }

        @MainActor
        func createPR(title: String, body: String, store: SessionStore) async {
            let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, !isCreatingPR else { return }
            isCreatingPR = true
            opError = nil
            defer { isCreatingPR = false }
            Telemetry.breadcrumb("changes", "pr_start", data: ["session": sessionID])
            let response = await store.gitCreatePR(sessionID: sessionID, title: t, body: body)
            guard let result = response, result.ok, let url = result.pr_url else {
                let detail = response?.stderr ?? "Could not open the pull request"
                opError = detail
                Telemetry.capture(
                    error: NSError(domain: "ios.changes", code: 5,
                        userInfo: [NSLocalizedDescriptionKey: "PR create failed"]),
                    message: "changes pr_fail",
                    tags: ["surface": "ios", "phase": "changes"],
                    extras: ["session": sessionID, "stderr": detail]
                )
                return
            }
            lastPRUrl = url
            Telemetry.breadcrumb("changes", "pr_finish", data: ["session": sessionID, "url": url])
            await load(store: store)
        }
    }
}
