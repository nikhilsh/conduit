import Testing
import Foundation
@testable import Conduit

/// Pins the attachment-display helpers (#6): parsing `[attached …]`
/// reference lines back into chips, stripping them from the visible
/// bubble text, and dropping the broker's duplicate "uploaded …" tool card.
@Suite("ConduitUI.ChatAttachments")
struct ConduitChatAttachmentTests {

    private func toolItem(toolName: String?, content: String) -> ConversationItem {
        ConversationItem(
            id: UUID().uuidString,
            role: "tool",
            kind: "tool",
            status: "done",
            content: content,
            ts: "2026-06-05T10:00:00Z",
            files: [],
            toolName: toolName,
            command: nil,
            exitCode: nil,
            durationMs: nil,
            diffSummary: nil,
            pendingOptions: [],
            sourceAgent: nil,
            targetAgent: nil,
            taskText: nil,
            resultSummary: nil,
            planSteps: []
        )
    }

    // MARK: parse + split

    @Test func parsesImageReferenceLine() {
        let line = "[attached image: pic.png — uploads/sess-42/pic.png]"
        let ref = ConduitUI.parseAttachmentReferenceLine(line)
        #expect(ref == ConduitUI.AttachmentRef(kind: .image, filename: "pic.png", sessionID: "sess-42"))
    }

    @Test func parsesFileReferenceLine() {
        let line = "[attached file: report.pdf — uploads/abc/report.pdf]"
        let ref = ConduitUI.parseAttachmentReferenceLine(line)
        #expect(ref?.kind == .file)
        #expect(ref?.filename == "report.pdf")
        #expect(ref?.sessionID == "abc")
    }

    @Test func rejectsNonReferenceLines() {
        #expect(ConduitUI.parseAttachmentReferenceLine("just text") == nil)
        #expect(ConduitUI.parseAttachmentReferenceLine("[attached image: ]") == nil)
        #expect(ConduitUI.parseAttachmentReferenceLine("[attached other: x — uploads/s/x]") == nil)
    }

    @Test func splitSeparatesTextFromAttachments() {
        // composeOutgoingMessage joins draft + refs with blank lines.
        let content = ConduitUI.composeOutgoingMessage(
            draft: "look at this",
            pendingAttachments: [
                .init(kind: .image, filename: "a.png", mimeType: "image/png", bytes: Data([1])),
                .init(kind: .file, filename: "b.pdf", mimeType: "application/pdf", bytes: Data([2])),
            ],
            sessionID: "s1"
        )
        let parsed = ConduitUI.splitAttachmentReferences(content)
        #expect(parsed.text == "look at this")
        #expect(parsed.attachments.count == 2)
        #expect(parsed.attachments[0] == ConduitUI.AttachmentRef(kind: .image, filename: "a.png", sessionID: "s1"))
        #expect(parsed.attachments[1] == ConduitUI.AttachmentRef(kind: .file, filename: "b.pdf", sessionID: "s1"))
    }

    @Test func splitAttachmentOnlyMessageHasEmptyText() {
        let content = ConduitUI.composeOutgoingMessage(
            draft: "",
            pendingAttachments: [.init(kind: .image, filename: "a.png", mimeType: "image/png", bytes: Data([1]))],
            sessionID: "s1"
        )
        let parsed = ConduitUI.splitAttachmentReferences(content)
        #expect(parsed.text.isEmpty)
        #expect(parsed.attachments.count == 1)
    }

    // MARK: upload tool-card filter

    @Test func uploadToolEventDetectedByToolName() {
        #expect(ConduitUI.ChatViewModel.isUploadToolEvent(
            toolItem(toolName: "file_upload", content: "uploaded /x/a.png (image/png, 10 bytes)")
        ))
    }

    @Test func uploadToolEventDetectedByContentFallback() {
        // PTY-scraped chatlog carries no toolName.
        #expect(ConduitUI.ChatViewModel.isUploadToolEvent(
            toolItem(toolName: nil, content: "uploaded /x/a.png (image/png, 10 bytes)")
        ))
    }

    @Test func ordinaryToolEventNotTreatedAsUpload() {
        #expect(!ConduitUI.ChatViewModel.isUploadToolEvent(
            toolItem(toolName: "Bash", content: "$ ls -la")
        ))
    }

    @Test func mergedEventsDropsUploadCards() {
        let upload = toolItem(toolName: "file_upload", content: "uploaded /x/a.png (image/png, 10 bytes)")
        let bash = toolItem(toolName: "Bash", content: "$ ls")
        let merged = ConduitUI.ChatViewModel.mergedEvents(conversation: [upload, bash], chatLog: [])
        #expect(merged.count == 1)
        #expect(merged.first?.toolName == "Bash")
    }
}
