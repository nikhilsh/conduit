import SwiftUI

// MARK: - ConduitApprovalsView
//
// Conduit redesign "Approvals inbox" surface (handoff SS.B.5, image 06).
// A dedicated queue of the sessions whose agent is currently BLOCKED on
// the user -- each row shows the agent + session name + branch, the exact
// pending prompt / command text, a risk chip (safe / writes files /
// destructive), and Approve / Deny / open-chat actions.
//
// DATA SOURCE -- real signal only, no fabrication. The queue is built from
// the SAME "awaiting input" signal the Home "needs-you" banner uses: a
// session whose LAST `ConversationItem` is a non-user item with
// `kind == "pending_input"` (Codex [A]pprove/[E]dit/[R]eject prompts,
// numbered menus, `request_user_input` -- classified in
// `core/src/conversation.rs`). We reuse `ConduitUI.HomeViewModel.isAwaitingInput`
// verbatim for that classification rather than re-deriving it differently,
// and never synthesize an approval item that isn't actually pending.
//
// APPROVE / DENY -- both actions call `POST /api/session/approval` on the
// broker (same transport AppDelegate uses for push-action resolves). This
// is uniform with the lock-screen buttons and avoids duplicating WS logic.
// The endpoint is resolved from the active SessionStore endpoint. A 200 ->
// "continuing..." visual; 404 -> nothing pending, fall back to opening
// chat; network error -> Telemetry.capture.
//
// PER-SESSION AUTO-APPROVE -- a local toggle on each card. While the app is
// foreground-connected and an approval arrives for a session with the toggle
// on, the resolve endpoint is called automatically with "approve" and a
// quiet audited line is shown. Persisted in-memory only (resets on restart,
// intentionally -- a blanket approval from a previous session shouldn't
// carry over).

extension ConduitUI {

    // MARK: Risk

    /// Honest, heuristic risk classification for a pending command. Derived
    /// from the command/prompt text -- clearly a best-effort guess, defaults
    /// to `.safe` when nothing risky is detected (never invents danger).
    enum ApprovalRisk: Equatable {
        /// Irreversible / data-losing (`rm -rf`, `git push --force`, `DROP
        /// TABLE`, etc.).
        case destructive
        /// Mutates the working tree / filesystem (writes, moves, installs).
        case writesFiles
        /// Nothing risky detected (or no command to inspect).
        case safe

        var label: String {
            switch self {
            case .destructive: return "destructive"
            case .writesFiles: return "writes files"
            case .safe:        return "safe"
            }
        }
    }

    /// One actionable item in the Approvals queue. Pure data so the queue +
    /// risk derivation are unit-testable without a view tree.
    struct ApprovalItem: Equatable, Identifiable {
        var id: String          // session id
        var title: String       // friendly session name
        var agent: String       // "claude" / "codex"
        var branch: String?
        /// The pending prompt / command text to show (the pending_input
        /// item's `command` when present, else its `content`).
        var prompt: String
        var risk: ApprovalRisk
        /// Non-empty for AskUserQuestion items (content contains the
        /// [[conduit:needs-input]] sentinel). Each entry is a tappable
        /// answer option. Empty for command-approval items.
        var pendingOptions: [String]
    }

    /// Pure helpers for the Approvals queue + risk classification. Lives off
    /// SwiftUI so XCTest / Swift Testing can pin the rules. Mirrors how the
    /// Home view-model stays a pure data layer.
    enum ApprovalsViewModel {

        /// Build the queue from per-session candidates. A candidate is
        /// included ONLY when it is genuinely awaiting input -- the same
        /// signal `HomeViewModel.isAwaitingInput` gates the needs-you banner
        /// on (last transcript item is a non-user `pending_input`). Input
        /// order is preserved. `command`/`content` come from that last item.
        static func queue(
            _ candidates: [(
                id: String,
                title: String,
                agent: String,
                branch: String?,
                lastItemRole: String?,
                lastItemKind: String?,
                command: String?,
                content: String
            )]
        ) -> [ApprovalItem] {
            candidates.compactMap { c in
                guard HomeViewModel.isAwaitingInput(
                    lastItemRole: c.lastItemRole,
                    lastItemKind: c.lastItemKind
                ) else { return nil }
                let prompt = promptText(command: c.command, content: c.content)
                // Detect AskUserQuestion items via the broker sentinel.
                // These must answer via sendChat, not the approval endpoint.
                let isPendingAsk = c.content.contains(ChatViewModel.pendingInputSentinel)
                let pendingOptions: [String]
                if isPendingAsk {
                    let questions = ChatViewModel.parsePendingQuestions(c.content)
                    pendingOptions = questions.flatMap { $0.options }
                } else {
                    pendingOptions = []
                }
                return ApprovalItem(
                    id: c.id,
                    title: c.title,
                    agent: c.agent,
                    branch: c.branch,
                    prompt: prompt,
                    risk: classifyRisk(command: c.command, content: c.content),
                    pendingOptions: pendingOptions
                )
            }
        }

        /// The text to surface for a pending item: the structured `command`
        /// when the classifier extracted one, else the raw prompt body. Both
        /// trimmed; never empty (falls back to a generic ask).
        static func promptText(command: String?, content: String) -> String {
            if let command, !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return command.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let body = content.trimmingCharacters(in: .whitespacesAndNewlines)
            return body.isEmpty ? "Agent is waiting for your input" : body
        }

        /// Heuristic risk from the command (preferred) or prompt body.
        /// Honest best-effort -- destructive patterns win, then file-writing
        /// patterns, else `.safe`. Case-insensitive.
        static func classifyRisk(command: String?, content: String) -> ApprovalRisk {
            let haystack = ((command ?? "") + " " + content).lowercased()
            if haystack.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .safe
            }
            for pattern in destructivePatterns where haystack.contains(pattern) {
                return .destructive
            }
            for pattern in writePatterns where haystack.contains(pattern) {
                return .writesFiles
            }
            return .safe
        }

        /// Irreversible / data-losing fragments. Substring match keeps it a
        /// transparent heuristic (not a shell parser).
        static let destructivePatterns: [String] = [
            "rm -rf", "rm -fr", "rm -r ", "git push --force", "git push -f",
            "push --force", "force-push", "force push",
            "drop table", "drop database", "truncate ", "mkfs", "dd if=",
            ":(){", "git reset --hard", "git clean -", "shutdown", "reboot",
            "> /dev/", "chmod -r 777", "kubectl delete", "terraform destroy",
        ]

        /// Mutates the filesystem / working tree. Conservative: only flags
        /// clear write intents, leaving read-only commands `.safe`.
        static let writePatterns: [String] = [
            "git commit", "git add", "git push", "git merge", "git rebase",
            "git checkout", "git stash", "write_file", "writefile",
            "create file", "edit file", "apply patch", "applypatch",
            "npm install", "yarn add", "pnpm add", "pip install", "cargo add",
            "mkdir", "touch ", "mv ", "cp ", "tee ", ">>", "sed -i", "chmod",
        ]
    }

    // MARK: - Per-card approval state

    /// Per-session UI state for in-app approve/deny actions.
    enum ApprovalCardState: Equatable {
        /// Idle -- buttons live.
        case idle
        /// HTTP request in flight.
        case resolving
        /// Resolved successfully.
        case resolved(String)   // "continuing..." / "denied"
        /// 404 -- nothing pending; open chat.
        case notPending
        /// Network / server error.
        case failed(String)
    }

    // MARK: View

    struct ApprovalsView: View {
        @Environment(SessionStore.self) private var store
        @Environment(\.neonTheme) private var neon
        @Environment(\.dismiss) private var dismiss

        /// Opens the given session's chat.
        var onOpenSession: (String) -> Void = { _ in }

        /// Hosted inline (e.g. tablet right pane) -> drop the NavigationStack
        /// chrome and the close affordance.
        var embedded: Bool = false

        /// Per-session approve/deny state.
        @State private var cardState: [String: ApprovalCardState] = [:]
        /// Per-session auto-approve toggle (in-memory, resets on restart).
        @State private var autoApprove: Set<String> = []

        var body: some View {
            if embedded {
                content
            } else {
                NavigationStack {
                    content
                        .navigationTitle("Approvals")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .principal) {
                                HStack(spacing: 8) {
                                    Text("Approvals")
                                        .font(neon.sans(16).weight(.semibold))
                                        .foregroundStyle(neon.text)
                                    countBadge
                                }
                            }
                            ToolbarItem(placement: .confirmationAction) {
                                Button {
                                    dismiss()
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 13, weight: .semibold))
                                }
                                .accessibilityLabel("Close")
                            }
                        }
                        .tint(neon.accent)
                }
                .appearanceColorScheme()
            }
        }

        /// The live queue, resolved from the store the same way the Home
        /// banner is: each session's last transcript item's role + kind feed
        /// the shared `isAwaitingInput` gate; the same item's command /
        /// content feed the prompt + risk.
        private var queue: [ConduitUI.ApprovalItem] {
            let candidates = store.sessions.map { s -> (
                id: String, title: String, agent: String, branch: String?,
                lastItemRole: String?, lastItemKind: String?,
                command: String?, content: String
            ) in
                let last = store.conversationLog[s.id]?.last
                return (
                    id: s.id,
                    title: store.displayName(for: s),
                    agent: s.assistant,
                    branch: s.branch,
                    lastItemRole: last?.role,
                    lastItemKind: last?.kind,
                    command: last?.command,
                    content: last?.content ?? ""
                )
            }
            return ConduitUI.ApprovalsViewModel.queue(candidates)
        }

        /// Header count badge -- a small filled gold pill showing the queue
        /// size, mirroring the Android header badge (`ApprovalsScreen.kt`).
        /// Only shown when there is something waiting.
        @ViewBuilder private var countBadge: some View {
            let count = queue.count
            if count > 0 {
                Text("\(count)")
                    .font(neon.mono(12).weight(.bold))
                    .foregroundStyle(neon.yellow)
                    .frame(minWidth: 22, minHeight: 22)
                    .padding(.horizontal, 3)
                    .background(
                        Circle()
                            .fill(neon.yellow.opacity(0.16))
                            .overlay(Circle().strokeBorder(neon.yellow.opacity(0.4), lineWidth: 1))
                    )
                    .accessibilityLabel("\(count) waiting")
            }
        }

        private var content: some View {
            ZStack {
                GlassAppBackground()
                let items = queue
                if items.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(items) { item in
                                card(item)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 18)
                        .frame(maxWidth: embedded ? .infinity : 640)
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            // Auto-approve: when a new item arrives and the toggle is on,
            // fire the resolve immediately. The queue is derived from live
            // store state so it updates when pending_input items appear.
            .onChange(of: queue) { _, newQueue in
                for item in newQueue {
                    guard autoApprove.contains(item.id),
                          cardState[item.id] == nil || cardState[item.id] == .idle
                    else { continue }
                    Telemetry.breadcrumb("approvals", "auto-approve triggered",
                        data: ["session": item.id])
                    resolve(sessionID: item.id, decision: "approve", autoApproved: true)
                }
            }
        }

        // MARK: Empty

        private var emptyState: some View {
            VStack(spacing: 12) {
                Image(systemName: "checkmark.seal")
                    .font(.system(size: 40, weight: .regular))
                    .foregroundStyle(neon.green)
                    .neonGlowBox(neon.glow ? neon.glowBox?.tinted(neon.green) : nil)
                Text("Nothing waiting on you")
                    .font(neon.sans(16).weight(.semibold))
                    .foregroundStyle(neon.text)
                Text("When an agent pauses for a command, file write, or a choice, it shows up here.")
                    .font(neon.mono(11.5))
                    .foregroundStyle(neon.textDim)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 36)
            }
            .frame(maxWidth: .infinity)
        }

        // MARK: Card

        private func card(_ item: ConduitUI.ApprovalItem) -> some View {
            let tint = neon.agentTint(forAgent: item.agent)
            let state = cardState[item.id] ?? .idle
            let isAutoApprove = autoApprove.contains(item.id)
            return VStack(alignment: .leading, spacing: 12) {
                // Header: avatar · name · agent/branch · risk chip
                HStack(spacing: 11) {
                    avatarTile(tint)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title)
                            .font(neon.sans(15).weight(.bold))
                            .foregroundStyle(neon.text)
                            .neonTextGlow(neon.textGlow)
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            Text(item.agent.lowercased())
                                .font(neon.mono(11).weight(.semibold))
                                .foregroundStyle(tint)
                            if let branch = item.branch, !branch.isEmpty {
                                Text("·").font(neon.mono(11)).foregroundStyle(neon.textFaint)
                                Text(branch)
                                    .font(neon.mono(11))
                                    .foregroundStyle(neon.textDim)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                    Spacer(minLength: 8)
                    riskChip(item.risk)
                }

                // Auto-approve toggle (per-session, in-memory).
                Toggle(isOn: Binding(
                    get: { isAutoApprove },
                    set: { on in
                        if on { autoApprove.insert(item.id) }
                        else  { autoApprove.remove(item.id) }
                        Telemetry.breadcrumb("approvals", "auto-approve toggled",
                            data: ["session": item.id, "on": "\(on)"])
                    }
                )) {
                    HStack(spacing: 5) {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 10, weight: .bold))
                        Text("Auto-approve this session")
                            .font(neon.mono(11).weight(.semibold))
                    }
                    .foregroundStyle(isAutoApprove ? neon.green : neon.textFaint)
                }
                .tint(neon.green)

                // "wants to <ask>" + the exact command/prompt in a code tile.
                VStack(alignment: .leading, spacing: 8) {
                    Text("wants to \(item.pendingOptions.isEmpty ? intentPhrase(item.risk) : "ask you something")")
                        .font(neon.sans(12.5))
                        .foregroundStyle(neon.textDim)
                    Text(item.prompt)
                        .font(neon.mono(12))
                        .foregroundStyle(neon.codeText)
                        .lineLimit(4)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(neon.codeBg)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .strokeBorder(neon.border, lineWidth: 1)
                                )
                        )
                }

                // State-aware action area.
                switch state {
                case .idle:
                    actionRow(item: item, tint: tint)
                case .resolving:
                    HStack {
                        ProgressView()
                            .tint(neon.accent)
                            .scaleEffect(0.9)
                        Text("Sending...")
                            .font(neon.mono(12))
                            .foregroundStyle(neon.textDim)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
                case .resolved(let msg):
                    Text(msg)
                        .font(neon.mono(12).weight(.semibold))
                        .foregroundStyle(neon.green)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                case .notPending:
                    // 404: nothing pending -- offer to open chat.
                    HStack(spacing: 8) {
                        Text("Nothing pending -- open chat?")
                            .font(neon.mono(11))
                            .foregroundStyle(neon.textDim)
                        Spacer(minLength: 4)
                        Button {
                            onOpenSession(item.id)
                        } label: {
                            Image(systemName: "bubble.left")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(neon.accent)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 6)
                case .failed(let msg):
                    Text(msg)
                        .font(neon.mono(11))
                        .foregroundStyle(neon.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .neonCardSurface(neon, fill: neon.surface, cornerRadius: neon.radius - 4)
        }

        @ViewBuilder
        private func actionRow(item: ConduitUI.ApprovalItem, tint: Color) -> some View {
            if item.pendingOptions.isEmpty {
                // Command-approval: standard Approve / Deny row.
                HStack(spacing: 9) {
                    actionButton(
                        label: "Approve",
                        systemImage: "checkmark",
                        tint: neon.green,
                        filled: true
                    ) {
                        Telemetry.breadcrumb("approvals", "in-app approve tapped",
                            data: ["session": item.id, "risk": item.risk.label])
                        resolve(sessionID: item.id, decision: "approve", autoApproved: false)
                    }
                    actionButton(
                        label: "Deny",
                        systemImage: "xmark",
                        tint: neon.textDim,
                        filled: false
                    ) {
                        Telemetry.breadcrumb("approvals", "in-app deny tapped",
                            data: ["session": item.id, "risk": item.risk.label])
                        resolve(sessionID: item.id, decision: "deny", autoApproved: false)
                    }
                    Button {
                        onOpenSession(item.id)
                    } label: {
                        Image(systemName: "bubble.left")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(neon.accent)
                            .frame(width: 44, height: 38)
                            .neonCardSurface(
                                neon,
                                fill: neon.surface,
                                cornerRadius: 11,
                                border: neon.border
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open chat")
                }
            } else {
                // AskUserQuestion: tappable option buttons + chat bubble.
                HStack(alignment: .top, spacing: 9) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(item.pendingOptions, id: \.self) { option in
                            Button {
                                Telemetry.breadcrumb("approvals", "pending-ask option tapped",
                                    data: ["session": item.id, "option": option])
                                answerPendingAsk(sessionID: item.id, answer: option)
                            } label: {
                                Text(option)
                                    .font(neon.sans(13).weight(.semibold))
                                    .foregroundStyle(neon.accentText)
                                    .lineLimit(2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 11)
                                    .padding(.horizontal, 14)
                                    .background(
                                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                                            .fill(neon.accent)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                                    .strokeBorder(neon.accent.opacity(0), lineWidth: 1)
                                            )
                                    )
                                    .neonGlowBox(neon.glow ? neon.glowBox?.tinted(neon.accent) : nil)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Button {
                        onOpenSession(item.id)
                    } label: {
                        Image(systemName: "bubble.left")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(neon.accent)
                            .frame(width: 44, height: 38)
                            .neonCardSurface(
                                neon,
                                fill: neon.surface,
                                cornerRadius: 11,
                                border: neon.border
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open chat")
                }
            }
        }

        /// Answer an AskUserQuestion by sending the chosen option as a chat
        /// message. The broker routes any chat message to the pending ask, so
        /// no approval endpoint is needed.
        private func answerPendingAsk(sessionID: String, answer: String) {
            cardState[sessionID] = .resolving
            store.sendChat(sessionID: sessionID, message: answer)
            store.resolvePendingInput(sessionID: sessionID)
            cardState[sessionID] = .resolved("Sent: \(answer)")
        }

        // MARK: - HTTP resolve

        /// POST to `POST /api/session/approval` with the given decision.
        /// Updates `cardState` for the session's card. On 404 falls back to
        /// opening chat. On success shows a brief "continuing..." / "denied".
        private func resolve(sessionID: String, decision: String, autoApproved: Bool) {
            cardState[sessionID] = .resolving

            let endpoint = store.endpoint
            guard endpoint.isComplete, let base = endpoint.httpBaseURL else {
                cardState[sessionID] = .failed("No active endpoint")
                return
            }
            var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
            components?.path = "/api/session/approval"
            guard let url = components?.url else {
                cardState[sessionID] = .failed("Bad URL")
                return
            }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.timeoutInterval = 20
            req.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            struct ApprovalBody: Encodable {
                let session_id: String
                let decision: String
            }
            guard let body = try? JSONEncoder().encode(
                ApprovalBody(session_id: sessionID, decision: decision)
            ) else {
                cardState[sessionID] = .failed("Encoding error")
                return
            }
            req.httpBody = body

            Telemetry.breadcrumb("approvals", "resolve POST start",
                data: ["session": sessionID, "decision": decision,
                       "auto": "\(autoApproved)", "host": endpoint.displayHost])

            Task { @MainActor in
                do {
                    let (_, resp) = try await URLSession.shared.data(for: req)
                    if let http = resp as? HTTPURLResponse {
                        switch http.statusCode {
                        case 200..<300:
                            let msg = decision == "approve" ? "continuing..." : "denied"
                            Telemetry.breadcrumb("approvals", "resolve: resolved",
                                data: ["session": sessionID, "decision": decision,
                                       "auto": "\(autoApproved)"])
                            store.resolvePendingInput(sessionID: sessionID)
                            cardState[sessionID] = .resolved(msg)
                        case 404:
                            Telemetry.breadcrumb("approvals", "resolve: 404 nothing pending",
                                data: ["session": sessionID])
                            if autoApproved {
                                // Auto-approve on an already-resolved item: clear quietly.
                                cardState[sessionID] = .idle
                            } else {
                                cardState[sessionID] = .notPending
                                onOpenSession(sessionID)
                            }
                        default:
                            let msg = "HTTP \(http.statusCode)"
                            Telemetry.capture(
                                error: NSError(domain: "ios.approvals", code: 1,
                                    userInfo: [NSLocalizedDescriptionKey: "approval resolve HTTP error"]),
                                message: "in-app approval resolve failed",
                                tags: ["surface": "ios", "phase": "approvals"],
                                extras: ["session": sessionID, "decision": decision,
                                         "status": "\(http.statusCode)"]
                            )
                            cardState[sessionID] = .failed(msg)
                        }
                    }
                } catch {
                    Telemetry.capture(
                        error: error,
                        message: "in-app approval resolve network error",
                        tags: ["surface": "ios", "phase": "approvals"],
                        extras: ["session": sessionID, "decision": decision,
                                 "detail": error.localizedDescription]
                    )
                    cardState[sessionID] = .failed("Network error")
                }
            }
        }

        private func avatarTile(_ tint: Color) -> some View {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(tint.opacity(neon.dark ? 0.14 : 0.10))
                .frame(width: 38, height: 38)
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(tint.opacity(0.35), lineWidth: 1)
                )
                .overlay(ConduitUI.ConduitMark(size: 22, color: tint, glow: neon.glow))
                .neonGlowBox(neon.glow ? neon.glowBox?.tinted(tint) : nil)
        }

        private func riskChip(_ risk: ConduitUI.ApprovalRisk) -> some View {
            let color = riskColor(risk)
            return HStack(spacing: 5) {
                Image(systemName: riskSymbol(risk))
                    .font(.system(size: 9, weight: .bold))
                Text(risk.label)
                    .font(neon.mono(10).weight(.semibold))
            }
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(color.opacity(0.12))
                    .overlay(Capsule().strokeBorder(color.opacity(0.3), lineWidth: 1))
            )
        }

        private func actionButton(
            label: String,
            systemImage: String,
            tint: Color,
            filled: Bool,
            action: @escaping () -> Void
        ) -> some View {
            Button(action: action) {
                HStack(spacing: 6) {
                    Image(systemName: systemImage)
                        .font(.system(size: 12, weight: .bold))
                    Text(label)
                        .font(neon.sans(13).weight(.semibold))
                }
                .foregroundStyle(filled ? neon.accentText : tint)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(filled ? tint : tint.opacity(0.12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .strokeBorder(tint.opacity(filled ? 0 : 0.3), lineWidth: 1)
                        )
                )
                .neonGlowBox(filled && neon.glow ? neon.glowBox?.tinted(tint) : nil)
            }
            .buttonStyle(.plain)
        }

        // MARK: Risk styling

        private func riskColor(_ risk: ConduitUI.ApprovalRisk) -> Color {
            switch risk {
            case .destructive: return neon.red
            case .writesFiles: return neon.blue
            case .safe:        return neon.green
            }
        }

        private func riskSymbol(_ risk: ConduitUI.ApprovalRisk) -> String {
            switch risk {
            case .destructive: return "exclamationmark.triangle.fill"
            case .writesFiles: return "square.and.pencil"
            case .safe:        return "checkmark.shield"
            }
        }

        private func intentPhrase(_ risk: ConduitUI.ApprovalRisk) -> String {
            switch risk {
            case .destructive: return "run a destructive command"
            case .writesFiles: return "write files"
            case .safe:        return "run a command"
            }
        }
    }
}
