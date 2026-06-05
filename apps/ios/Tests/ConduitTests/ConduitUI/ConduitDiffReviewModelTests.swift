import Testing
import Foundation
@testable import Conduit

@Suite("ConduitUI.DiffReviewModel")
struct ConduitDiffReviewModelTests {

    // A minimal `ConversationItem` factory — only the fields the model reads.
    private func diffItem(_ content: String, id: String = "d1") -> ConversationItem {
        ConversationItem(
            id: id, role: "tool", kind: "diff", status: "done",
            content: content, ts: "2026-06-05T00:00:00Z",
            files: [], toolName: nil, command: nil, exitCode: nil,
            durationMs: nil, diffSummary: nil, pendingOptions: [],
            sourceAgent: nil, targetAgent: nil, taskText: nil,
            resultSummary: nil, planSteps: []
        )
    }

    private func session(added: UInt32? = nil, removed: UInt32? = nil) -> ProjectSession {
        ProjectSession(
            id: "s1", name: "s", assistant: "claude", branch: "fix/auth",
            preview: nil, reasoningEffort: nil, cwd: nil, startedAt: nil,
            lastActivityAt: nil, displayName: nil,
            totalInputTokens: nil, totalOutputTokens: nil, totalCachedTokens: nil,
            totalCostUsd: nil, contextUsedTokens: nil, contextWindowTokens: nil,
            linesAdded: added, linesRemoved: removed, commits: nil,
            prNumber: nil, prState: nil,
            account5hPct: nil, account5hResetsAt: nil,
            account7dPct: nil, account7dResetsAt: nil
        )
    }

    @Test func parsesGitHeaderPathAndCounts() {
        let patch = """
        diff --git a/src/auth/refresh.ts b/src/auth/refresh.ts
        index 1111111..2222222 100644
        --- a/src/auth/refresh.ts
        +++ b/src/auth/refresh.ts
        @@ -1,3 +1,4 @@
         async function refresh(token) {
        -  const r = await fetch(url);
        -  return r.json();
        +  const r = await backoff(() => fetch(url));
        +  if (!r.ok) throw new AuthError(r.status);
        +  return r.json();
         }
        """
        let files = ConduitUI.DiffReviewModel.parsePatch(patch)
        #expect(files.count == 1)
        #expect(files[0].path == "src/auth/refresh.ts")
        #expect(files[0].added == 3)
        #expect(files[0].removed == 2)
    }

    @Test func parsesMultipleFiles() {
        let patch = """
        diff --git a/a.ts b/a.ts
        @@ -1 +1 @@
        -x
        +y
        diff --git a/b.ts b/b.ts
        @@ -0,0 +1,2 @@
        +line1
        +line2
        """
        let files = ConduitUI.DiffReviewModel.parsePatch(patch)
        #expect(files.map(\.path) == ["a.ts", "b.ts"])
        #expect(files[0].added == 1)
        #expect(files[0].removed == 1)
        #expect(files[1].added == 2)
        #expect(files[1].removed == 0)
    }

    @Test func tripleHeaderWithoutGitLineStartsFile() {
        let patch = """
        --- a/only.ts
        +++ b/only.ts
        @@ -1 +1 @@
        -old
        +new
        """
        let files = ConduitUI.DiffReviewModel.parsePatch(patch)
        #expect(files.count == 1)
        #expect(files[0].path == "only.ts")
        #expect(files[0].added == 1)
        #expect(files[0].removed == 1)
    }

    @Test func filePlusPlusPlusMarkersNotCountedAsAdds() {
        // `+++`/`---` are file markers, not body lines.
        let patch = """
        diff --git a/x.ts b/x.ts
        --- a/x.ts
        +++ b/x.ts
        @@ -1 +1 @@
        +real add
        """
        let files = ConduitUI.DiffReviewModel.parsePatch(patch)
        #expect(files[0].added == 1)
        #expect(files[0].removed == 0)
    }

    @Test func summaryPrefersParsedTotals() {
        let log = [diffItem("""
        diff --git a/a.ts b/a.ts
        @@ -1 +1 @@
        -x
        +y
        +z
        """)]
        let files = ConduitUI.DiffReviewModel.files(from: log)
        let summary = ConduitUI.DiffReviewModel.summary(session: session(added: 999, removed: 999), files: files, log: log)
        #expect(summary.fileCount == 1)
        #expect(summary.added == 2)
        #expect(summary.removed == 1)
        #expect(summary.deltaLabel == "+2 −1")
        #expect(summary.fileCountLabel == "1 file")
    }

    @Test func summaryFallsBackToSessionRollupWhenNoDiffItem() {
        let summary = ConduitUI.DiffReviewModel.summary(session: session(added: 162, removed: 39), files: [], log: [])
        #expect(summary.added == 162)
        #expect(summary.removed == 39)
        #expect(summary.fileCount == 0)
        #expect(summary.fileCountLabel == "0 files")
    }

    @Test func addedFractionClampsAndNeutralizes() {
        #expect(ConduitUI.DiffSummary(fileCount: 0, added: 0, removed: 0).addedFraction == 0.5)
        #expect(ConduitUI.DiffSummary(fileCount: 1, added: 3, removed: 1).addedFraction == 0.75)
        #expect(ConduitUI.DiffSummary(fileCount: 1, added: 1, removed: 0).addedFraction == 1.0)
    }

    @Test func filesPicksMostRecentDiffItem() {
        let log = [
            diffItem("diff --git a/old.ts b/old.ts\n@@ -1 +1 @@\n+a", id: "1"),
            diffItem("diff --git a/new.ts b/new.ts\n@@ -1 +1 @@\n+b\n+c", id: "2"),
        ]
        let files = ConduitUI.DiffReviewModel.files(from: log)
        #expect(files.map(\.path) == ["new.ts"])
        #expect(files[0].added == 2)
    }

    @Test func hasInlineDiffReflectsPresence() {
        #expect(ConduitUI.DiffReviewModel.hasInlineDiff(in: []) == false)
        #expect(ConduitUI.DiffReviewModel.hasInlineDiff(in: [diffItem("diff --git a/x b/x\n+y")]) == true)
    }

    @Test func lineKindsClassified() {
        let patch = """
        diff --git a/x.ts b/x.ts
        @@ -1,2 +1,2 @@
         context
        -gone
        +added
        """
        let files = ConduitUI.DiffReviewModel.parsePatch(patch)
        let kinds = files[0].lines.map(\.kind)
        #expect(kinds.contains(.hunk))
        #expect(kinds.contains(.context))
        #expect(kinds.contains(.removed))
        #expect(kinds.contains(.added))
    }
}
