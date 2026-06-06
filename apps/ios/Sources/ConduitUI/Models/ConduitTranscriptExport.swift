import Foundation

// MARK: - ConduitTranscriptExport
//
// Shared transcript → markdown builder. Lifted out of SessionInfoView so the
// title menu's "Export transcript" row (Round-2 fix 2) and the Session Info
// "Export" pill ship byte-identical exports from one implementation.

extension ConduitUI {

    enum TranscriptExport {

        /// The actual conversation transcript as markdown — the human /
        /// assistant message content, not session metadata. Tool and command
        /// items are folded in compactly so the export reads as the chat the
        /// user had. Empty log → header + "(no messages yet)".
        @MainActor
        static func markdown(for session: ProjectSession, store: SessionStore) -> String {
            let assistant = store.statusBySession[session.id]?.assistant ?? session.assistant
            return markdown(
                title: store.displayName(for: session),
                assistant: assistant,
                branch: session.branch,
                log: store.conversationLog[session.id] ?? []
            )
        }

        /// Pure builder — title/agent/branch + the conversation items.
        static func markdown(
            title: String,
            assistant: String,
            branch: String?,
            log: [ConversationItem]
        ) -> String {
            var lines: [String] = []
            lines.append("# \(title)")
            var meta = assistant.lowercased()
            if let branch, !branch.isEmpty { meta += " · \(branch)" }
            let userMsgs = log.filter { $0.role.lowercased() == "user" }.count
            let asstMsgs = log.filter { $0.role.lowercased() == "assistant" }.count
            let msgCount = userMsgs + asstMsgs
            meta += "   ·  \(msgCount) message\(msgCount == 1 ? "" : "s")"
            lines.append(meta)
            lines.append("")

            if log.isEmpty {
                lines.append("(no messages yet)")
                return lines.joined(separator: "\n")
            }

            for item in log {
                let role = item.role.lowercased()
                let content = item.content.trimmingCharacters(in: .whitespacesAndNewlines)
                // Command / tool items: render compactly so the transcript
                // keeps its shape without dumping raw tool noise.
                if let command = item.command, !command.isEmpty {
                    lines.append("$ \(command)")
                    if !content.isEmpty, content != command { lines.append(content) }
                    lines.append("")
                    continue
                }
                switch role {
                case "user":
                    lines.append("## You")
                    lines.append(content.isEmpty ? "(empty)" : content)
                case "assistant":
                    lines.append("## Assistant")
                    lines.append(content.isEmpty ? "(empty)" : content)
                default:
                    // System / other roles or tool items with no command —
                    // include the content only if there's something to show.
                    guard !content.isEmpty else { continue }
                    if let tool = item.toolName, !tool.isEmpty {
                        lines.append("`\(tool)` \(content)")
                    } else {
                        lines.append(content)
                    }
                }
                lines.append("")
            }
            return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
