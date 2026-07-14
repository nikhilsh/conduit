import XCTest
@testable import Conduit

/// PLAN-REVIEW-SHIP -- pure-logic coverage for the iOS Changes surface:
/// the send-to-agent prompt composer (exact template), the re-anchor
/// matcher, structured-diff JSON decode, and the `BoxFeatures.reviewShip` /
/// `.hibernation` capability decode. No networking, no SwiftUI -- every
/// function under test here is `nonisolated`/pure precisely so it's testable
/// without a broker or MainActor ceremony.
final class ChangesModelTests: XCTestCase {

    // MARK: - Prompt composer

    func testComposePromptSingleAnchoredCommentWithContext() {
        let ann = ConduitUI.ChangeAnnotation(
            filePath: "src/x.ts",
            kind: .add,
            lineNumber: 12,
            lineText: "new()",
            contextBefore: ["a", "b"],
            contextAfter: ["c", "d"],
            comment: "fix this",
            anchored: true
        )
        let expected = """
        I reviewed the current changes and left 1 inline comment(s). Please address each one, then stop so I can re-review.

        ===== Comment 1 of 1 =====
        File: src/x.ts
        Location: add line 12
        Annotated line:
            new()
        Context:
            a
            b
        >>> new()
            c
            d
        Comment:
        fix this

        ===== End of comments =====
        Guidance: make only the changes these comments call for; keep the diff focused. When done, reply with a one-line summary per comment and wait for my re-review.
        """
        XCTAssertEqual(ConduitUI.ChangesModel.composePrompt([ann]), expected)
    }

    func testComposePromptOmitsContextForSingleLineHunk() {
        let ann = ConduitUI.ChangeAnnotation(
            filePath: "b.go",
            kind: .del,
            lineNumber: 5,
            lineText: "old()",
            contextBefore: [],
            contextAfter: [],
            comment: "remove",
            anchored: true
        )
        let expected = """
        I reviewed the current changes and left 1 inline comment(s). Please address each one, then stop so I can re-review.

        ===== Comment 1 of 1 =====
        File: b.go
        Location: del line 5
        Annotated line:
            old()
        Comment:
        remove

        ===== End of comments =====
        Guidance: make only the changes these comments call for; keep the diff focused. When done, reply with a one-line summary per comment and wait for my re-review.
        """
        XCTAssertEqual(ConduitUI.ChangesModel.composePrompt([ann]), expected)
    }

    func testComposePromptUnanchoredCommentOmitsLocationAndContext() {
        let ann = ConduitUI.ChangeAnnotation(
            filePath: "b.go",
            kind: .del,
            lineNumber: 5,
            lineText: "old()",
            contextBefore: ["would", "be"],
            contextAfter: ["dropped", "anyway"],
            comment: "remove",
            anchored: false
        )
        let expected = """
        I reviewed the current changes and left 1 inline comment(s). Please address each one, then stop so I can re-review.

        ===== Comment 1 of 1 =====
        File: b.go
        Location: (unanchored — line text no longer present)
        Annotated line:
            old()
        Comment:
        remove

        ===== End of comments =====
        Guidance: make only the changes these comments call for; keep the diff focused. When done, reply with a one-line summary per comment and wait for my re-review.
        """
        XCTAssertEqual(ConduitUI.ChangesModel.composePrompt([ann]), expected)
    }

    func testComposePromptNumbersMultipleComments() {
        let a = ConduitUI.ChangeAnnotation(
            filePath: "f1", kind: .context, lineNumber: 3, lineText: "ctx line",
            contextBefore: [], contextAfter: [], comment: "c1", anchored: true
        )
        let b = ConduitUI.ChangeAnnotation(
            filePath: "f2", kind: .add, lineNumber: 9, lineText: "add line",
            contextBefore: [], contextAfter: [], comment: "c2", anchored: true
        )
        let expected = """
        I reviewed the current changes and left 2 inline comment(s). Please address each one, then stop so I can re-review.

        ===== Comment 1 of 2 =====
        File: f1
        Location: context line 3
        Annotated line:
            ctx line
        Comment:
        c1

        ===== Comment 2 of 2 =====
        File: f2
        Location: add line 9
        Annotated line:
            add line
        Comment:
        c2

        ===== End of comments =====
        Guidance: make only the changes these comments call for; keep the diff focused. When done, reply with a one-line summary per comment and wait for my re-review.
        """
        XCTAssertEqual(ConduitUI.ChangesModel.composePrompt([a, b]), expected)
    }

    // MARK: - Re-anchor

    private func makeDiff(path: String, lines: [ConduitUI.GitDiffLine]) -> ConduitUI.GitDiffResponse {
        let hunk = ConduitUI.GitDiffHunk(
            header: "@@ -1,3 +1,3 @@", old_start: 1, old_lines: 3, new_start: 1, new_lines: 3, lines: lines
        )
        let file = ConduitUI.GitDiffFile(
            path: path, old_path: nil, status: "modified", staged: false, binary: false,
            additions: 1, deletions: 0, truncated: false, hunks: [hunk]
        )
        return ConduitUI.GitDiffResponse(
            scope: "uncommitted", default_branch: "main", base: nil, files: [file],
            diffstat: ConduitUI.GitDiffStat(files_changed: 1, additions: 1, deletions: 0), truncated: false
        )
    }

    func testReanchorMovedLineUpdatesLineNumberAndStaysAnchored() {
        let ann = ConduitUI.ChangeAnnotation(
            filePath: "src/x.ts", kind: .add, lineNumber: 12, lineText: "foo()",
            contextBefore: [], contextAfter: [], comment: "x", anchored: true
        )
        // The line moved from new:12 to new:30 in the freshest diff.
        let diff = makeDiff(path: "src/x.ts", lines: [
            ConduitUI.GitDiffLine(kind: .context, old: 29, new: 29, text: "unrelated"),
            ConduitUI.GitDiffLine(kind: .add, old: 0, new: 30, text: "foo()"),
        ])
        let result = ConduitUI.ChangesModel.reanchor([ann], against: diff)
        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(result[0].anchored)
        XCTAssertEqual(result[0].lineNumber, 30)
    }

    func testReanchorVanishedLineMarksUnanchored() {
        let ann = ConduitUI.ChangeAnnotation(
            filePath: "src/x.ts", kind: .add, lineNumber: 12, lineText: "foo()",
            contextBefore: [], contextAfter: [], comment: "x", anchored: true
        )
        let diff = makeDiff(path: "src/x.ts", lines: [
            ConduitUI.GitDiffLine(kind: .context, old: 29, new: 29, text: "unrelated"),
        ])
        let result = ConduitUI.ChangesModel.reanchor([ann], against: diff)
        XCTAssertEqual(result.count, 1)
        XCTAssertFalse(result[0].anchored)
        // lineNumber/kind are left as last-known on an unanchored comment.
        XCTAssertEqual(result[0].lineNumber, 12)
    }

    func testReanchorFileNoLongerInDiffMarksUnanchored() {
        let ann = ConduitUI.ChangeAnnotation(
            filePath: "gone.ts", kind: .add, lineNumber: 1, lineText: "foo()",
            contextBefore: [], contextAfter: [], comment: "x", anchored: true
        )
        let diff = makeDiff(path: "src/x.ts", lines: [
            ConduitUI.GitDiffLine(kind: .add, old: 0, new: 1, text: "foo()"),
        ])
        let result = ConduitUI.ChangesModel.reanchor([ann], against: diff)
        XCTAssertFalse(result[0].anchored)
    }

    // MARK: - Diff JSON decode

    func testGitDiffResponseDecodesWireContractFixture() throws {
        let json = """
        {
          "scope": "uncommitted",
          "default_branch": "main",
          "files": [
            {
              "path": "broker/internal/ws/git.go",
              "old_path": "",
              "status": "modified",
              "staged": true,
              "binary": false,
              "additions": 12,
              "deletions": 3,
              "truncated": false,
              "hunks": [
                {
                  "header": "@@ -10,6 +10,8 @@ func serve() {",
                  "old_start": 10, "old_lines": 6,
                  "new_start": 10, "new_lines": 8,
                  "lines": [
                    {"kind":"context","old":10,"new":10,"text":"func serve() {"},
                    {"kind":"del","old":11,"new":0,"text":"  old()"},
                    {"kind":"add","old":0,"new":11,"text":"  new()"}
                  ]
                }
              ]
            }
          ],
          "diffstat": {"files_changed": 3, "additions": 47, "deletions": 12},
          "truncated": false
        }
        """
        let decoded = try JSONDecoder().decode(ConduitUI.GitDiffResponse.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.scope, "uncommitted")
        XCTAssertEqual(decoded.default_branch, "main")
        XCTAssertNil(decoded.base)
        XCTAssertEqual(decoded.files.count, 1)
        let file = decoded.files[0]
        XCTAssertEqual(file.path, "broker/internal/ws/git.go")
        XCTAssertEqual(file.status, "modified")
        XCTAssertTrue(file.staged)
        XCTAssertEqual(file.hunks.count, 1)
        let hunk = file.hunks[0]
        XCTAssertEqual(hunk.old_start, 10)
        XCTAssertEqual(hunk.new_lines, 8)
        XCTAssertEqual(hunk.lines.count, 3)
        XCTAssertEqual(hunk.lines[0].kind, .context)
        XCTAssertEqual(hunk.lines[1].kind, .del)
        XCTAssertEqual(hunk.lines[2].kind, .add)
        XCTAssertEqual(hunk.lines[2].text, "  new()")
        XCTAssertEqual(decoded.diffstat.files_changed, 3)
        XCTAssertFalse(decoded.truncated)
    }

    func testGitStateDecodesNotAGitRepoShape() throws {
        let decoded = try JSONDecoder().decode(ConduitUI.GitState.self, from: Data(#"{"is_git_repo": false}"#.utf8))
        XCTAssertFalse(decoded.is_git_repo)
        XCTAssertNil(decoded.branch)
        XCTAssertNil(decoded.has_gh)
    }

    // MARK: - BoxFeatures decode (review_ship / hibernation)

    func testDecodeBoxFeaturesWithNewKeysPresent() {
        let json = """
        {"features": {"host_metrics": true, "review_ship": true, "hibernation": true}}
        """
        let features = SessionStore.decodeBoxFeatures(Data(json.utf8))
        XCTAssertEqual(features?.hostMetrics, true)
        XCTAssertEqual(features?.reviewShip, true)
        XCTAssertEqual(features?.hibernation, true)
    }

    func testDecodeBoxFeaturesDefaultsFalseWhenKeysAbsent() {
        // Old-broker shape: no review_ship/hibernation keys at all.
        let json = """
        {"features": {"host_metrics": true, "shell_sessions": false}}
        """
        let features = SessionStore.decodeBoxFeatures(Data(json.utf8))
        XCTAssertEqual(features?.hostMetrics, true)
        XCTAssertEqual(features?.reviewShip, false)
        XCTAssertEqual(features?.hibernation, false)
    }

    func testDecodeBoxFeaturesDefaultsFalseWhenFeaturesBlockAbsent() {
        let features = SessionStore.decodeBoxFeatures(Data("{}".utf8))
        XCTAssertEqual(features?.reviewShip, false)
        XCTAssertEqual(features?.hibernation, false)
    }
}
