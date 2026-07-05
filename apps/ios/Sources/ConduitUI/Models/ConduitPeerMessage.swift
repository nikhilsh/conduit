import Foundation

/// Parses the framed peer-session message block broker emits from
/// `framePeerMessage` (broker/internal/session/peerchat.go). A peer message
/// always arrives as a **user-role** chat `view_event` whose `content` is:
///
///   [CONDUIT PEER MESSAGE -- from another agent session on this box, NOT from the human user]
///   From session: <uuid> ("<title>")      (title / whole line may be absent)
///   ...boilerplate (untrusted-data preamble, reply hint)...
///   ---
///   <body>
///   [END CONDUIT PEER MESSAGE]
///
/// `ConduitPeerMessage.parse` extracts the sender id/title and the body,
/// stripping the envelope boilerplate so the chat card never shows it.
enum ConduitPeerMessage {
    /// The exact leading marker gating detection. Callers must check
    /// `content.hasPrefix(marker)` on a **user-role** event before treating
    /// it as a peer message -- content-only sniffing mid-message classified
    /// unrelated messages incorrectly before (#699); this stays a strict,
    /// anchored prefix check.
    static let marker = "[CONDUIT PEER MESSAGE"

    private static let endMarker = "[END CONDUIT PEER MESSAGE]"
    private static let fromSessionPrefix = "From session: "

    struct Parsed: Equatable {
        /// Sender session id, or nil when unidentified / absent.
        var fromSessionID: String?
        /// Sender session title, or nil when absent (untitled or an
        /// external/unidentified caller).
        var fromTitle: String?
        /// The message body with the envelope boilerplate stripped.
        var body: String
    }

    /// Returns nil when `content` does not start with the exact marker.
    static func parse(_ content: String) -> Parsed? {
        guard content.hasPrefix(marker) else { return nil }
        let lines = content.components(separatedBy: "\n")

        var fromID: String?
        var fromTitle: String?
        // The "From session: ..." / "From: ..." line is always the second
        // line, but scan a short defensive window in case framing shifts.
        for line in lines.dropFirst().prefix(4) {
            guard let range = line.range(of: fromSessionPrefix) else { continue }
            let rest = line[range.upperBound...]
            if let parenIdx = rest.firstIndex(of: "(") {
                fromID = rest[rest.startIndex..<parenIdx].trimmingCharacters(in: .whitespaces)
                let afterParen = rest[parenIdx...]
                if let firstQuote = afterParen.firstIndex(of: "\""),
                   let lastQuote = afterParen.lastIndex(of: "\""),
                   firstQuote != lastQuote {
                    let inner = afterParen[afterParen.index(after: firstQuote)..<lastQuote]
                    fromTitle = String(inner)
                }
            } else {
                fromID = rest.trimmingCharacters(in: .whitespaces)
            }
            break
        }
        if fromID?.isEmpty == true { fromID = nil }
        if fromTitle?.isEmpty == true { fromTitle = nil }

        guard let sepIdx = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }),
              let endIdx = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == endMarker }),
              endIdx > sepIdx
        else {
            // Malformed frame (no separator / no end marker): fall back to
            // showing everything after the first (marker) line.
            let rest = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return Parsed(fromSessionID: fromID, fromTitle: fromTitle, body: rest)
        }
        let body = lines[(sepIdx + 1)..<endIdx]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Parsed(fromSessionID: fromID, fromTitle: fromTitle, body: body)
    }

    /// Header label: the sender title, else the first 8 chars of the
    /// session id, else a generic fallback.
    static func displayLabel(_ parsed: Parsed) -> String {
        if let title = parsed.fromTitle, !title.isEmpty { return title }
        if let id = parsed.fromSessionID, !id.isEmpty { return String(id.prefix(8)) }
        return "another session"
    }
}
