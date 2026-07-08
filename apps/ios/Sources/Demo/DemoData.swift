import Foundation

// MARK: - DemoData
//
// Deterministic, in-process fake data powering the App Store reviewer demo mode.
// No network calls, no real broker needed. All timestamps are hardcoded ISO strings
// so output is byte-for-byte reproducible across launches.

enum DemoData {

    // MARK: - Box
    //
    // Fake paired-box name shown wherever the Start sheet / Flow wizard's
    // "Where" row needs a box in demo mode (no real `SavedServer` exists).

    static let boxName = "Demo Box"

    // MARK: - Terminal lines
    //
    // Canned faux-terminal output for DemoTerminalView. Each entry is a
    // (isPrompt: Bool, text: String) pair; prompts render in neon.green,
    // output in neon.textDim. Content matches the todo.py narrative so
    // Chat / Terminal / Browser all tell the same story.

    struct TerminalLine {
        let isPrompt: Bool
        let text: String
    }

    static let terminalLines: [TerminalLine] = [
        TerminalLine(isPrompt: true,  text: "python todo.py list"),
        TerminalLine(isPrompt: false, text: "1. [ ] Buy groceries"),
        TerminalLine(isPrompt: false, text: "2. [x] Ship the release"),
        TerminalLine(isPrompt: false, text: "3. [ ] Call the dentist"),
        TerminalLine(isPrompt: true,  text: "python todo.py add \"Review the PR\""),
        TerminalLine(isPrompt: false, text: "Added: Review the PR"),
        TerminalLine(isPrompt: true,  text: "python todo.py list"),
        TerminalLine(isPrompt: false, text: "1. [ ] Buy groceries"),
        TerminalLine(isPrompt: false, text: "2. [x] Ship the release"),
        TerminalLine(isPrompt: false, text: "3. [ ] Call the dentist"),
        TerminalLine(isPrompt: false, text: "4. [ ] Review the PR"),
        TerminalLine(isPrompt: true,  text: "pytest -q"),
        TerminalLine(isPrompt: false, text: "........  [100%]"),
        TerminalLine(isPrompt: false, text: "8 passed in 0.42s"),
        TerminalLine(isPrompt: true,  text: "python todo.py complete 2"),
        TerminalLine(isPrompt: false, text: "Completed: Ship the release"),
        TerminalLine(isPrompt: true,  text: "git add todo.py && git commit -m \"feat: add todo CLI\""),
        TerminalLine(isPrompt: false, text: "[main 4f2a1c3] feat: add todo CLI"),
        TerminalLine(isPrompt: false, text: " 1 file changed, 47 insertions(+)"),
    ]

    // MARK: - Sessions

    static let sessions: [ProjectSession] = [
        ProjectSession(
            id: "demo-session-1",
            name: "demo-session-1",
            assistant: "claude",
            branch: nil,
            preview: nil,
            reasoningEffort: nil,
            cwd: "/home/user/projects/todo",
            startedAt: "2026-06-25T10:00:00Z",
            lastActivityAt: "2026-06-25T10:03:30Z",
            displayName: "Build a to-do app",
            totalInputTokens: 120_000,
            totalOutputTokens: 18_000,
            totalCachedTokens: 90_000,
            totalCostUsd: 0.42,
            contextUsedTokens: 48_000,
            contextWindowTokens: 200_000
        ),
        ProjectSession(
            id: "demo-session-2",
            name: "demo-session-2",
            assistant: "claude",
            branch: nil,
            preview: nil,
            reasoningEffort: nil,
            cwd: "/home/user/projects/api",
            startedAt: "2026-06-25T09:30:00Z",
            lastActivityAt: "2026-06-25T09:35:00Z",
            displayName: "Fix authentication bug",
            totalInputTokens: 34_000,
            totalOutputTokens: 5_200,
            totalCachedTokens: 22_000,
            totalCostUsd: 0.11,
            contextUsedTokens: 12_000,
            contextWindowTokens: 200_000
        ),
    ]

    // MARK: - Canned SessionStatus for demo sessions
    //
    // Seeded into store.statusBySession by activateDemo() so Usage/Recap/Activity
    // screens light up. Values are consistent with the session usage fields above.

    static let statusBySession: [String: SessionStatus] = [
        "demo-session-1": SessionStatus(
            session: "demo-session-1",
            assistant: "claude",
            phase: "idle",
            health: "green",
            rows: 40,
            cols: 120,
            yolo: false,
            preview: nil,
            sessionName: "demo-session-1",
            viewers: 1,
            reasoningEffort: nil,
            cwd: "/home/user/projects/todo",
            startedAt: "2026-06-25T10:00:00Z",
            lastActivityAt: "2026-06-25T10:03:30Z",
            displayName: "Build a to-do app",
            totalInputTokens: 120_000,
            totalOutputTokens: 18_000,
            totalCachedTokens: 90_000,
            totalCostUsd: 0.42,
            contextUsedTokens: 48_000,
            contextWindowTokens: 200_000
        ),
        "demo-session-2": SessionStatus(
            session: "demo-session-2",
            assistant: "claude",
            phase: "idle",
            health: "green",
            rows: 40,
            cols: 120,
            yolo: false,
            preview: nil,
            sessionName: "demo-session-2",
            viewers: 1,
            reasoningEffort: nil,
            cwd: "/home/user/projects/api",
            startedAt: "2026-06-25T09:30:00Z",
            lastActivityAt: "2026-06-25T09:35:00Z",
            displayName: "Fix authentication bug",
            totalInputTokens: 34_000,
            totalOutputTokens: 5_200,
            totalCachedTokens: 22_000,
            totalCostUsd: 0.11,
            contextUsedTokens: 12_000,
            contextWindowTokens: 200_000
        ),
    ]

    // MARK: - Conversations

    static let conversationBySession: [String: [ConversationItem]] = [
        "demo-session-1": session1Conversation,
        "demo-session-2": session2Conversation,
    ]

    // MARK: - Pipelines (Flow demo fixtures)
    //
    // Feeds the demo home FLOWS section (`ConduitUI.FlowCard`, real
    // component) and the Monitor's static-fixture seam
    // (`ConduitUI.PipelineMonitorView.isDemo` reads these via
    // `SessionStore.demoPipelineStatus(id:)`). No network -- these are
    // hand-built `PipelineSummary`/`PipelineStatus` values matching the
    // broker's real shapes (see `ConduitPipelineListView.swift` /
    // `ConduitPipelineMonitorView.swift`).

    static let pipelines: [ConduitUI.PipelineSummary] = [
        ConduitUI.PipelineSummary(
            id: "demo-flow-1",
            title: "Add rate limiter to broker",
            state: "awaiting_gate",
            current_step: 1,
            step_count: 3,
            created: "2026-06-25T10:00:00Z",
            steps: [
                ConduitUI.PipelineSummaryStep(agent: "claude", role: "research", status: "done", gate_after: false),
                ConduitUI.PipelineSummaryStep(agent: "claude", role: "design", status: "done", gate_after: true),
                ConduitUI.PipelineSummaryStep(agent: "codex", role: "build", status: "queued", gate_after: false),
            ],
            result: nil
        ),
        ConduitUI.PipelineSummary(
            id: "demo-flow-2",
            title: "Migrate settings to KV store",
            state: "running",
            current_step: 1,
            step_count: 3,
            created: "2026-06-25T09:30:00Z",
            steps: [
                ConduitUI.PipelineSummaryStep(agent: "claude", role: "research", status: "done", gate_after: false),
                ConduitUI.PipelineSummaryStep(agent: "codex", role: "build", status: "running", gate_after: false),
                ConduitUI.PipelineSummaryStep(agent: "codex", role: "verify", status: "queued", gate_after: false),
            ],
            result: nil
        ),
    ]

    /// Gate handoff excerpt shown in the Monitor's "Handoff preview" block
    /// for the gated demo fixture (`demo-flow-1`).
    private static let flow1GateHandoff = """
    ## Proposed design

    Token-bucket limiter keyed by bearer token:
    - 60 req/min steady, burst 20
    - 429 with Retry-After on exhaustion
    - Metrics counter per client

    Mounted as HTTP middleware ahead of /api/session routes.
    """

    /// Full per-step detail for the Monitor, keyed by `pipelines` id. Mirrors
    /// `GET /api/pipeline/{id}` (`ConduitUI.PipelineStatus`).
    static func pipelineStatus(id: String) -> ConduitUI.PipelineStatus? {
        switch id {
        case "demo-flow-1":
            return ConduitUI.PipelineStatus(
                id: "demo-flow-1",
                title: "Add rate limiter to broker",
                task: "Add rate limiting middleware to the broker's HTTP API to prevent abuse.",
                cwd: "/home/user/projects/broker",
                base: "main",
                state: "awaiting_gate",
                current_step: 1,
                steps: [
                    ConduitUI.PipelineStepStatus(
                        index: 0, agent_type: "claude", role: "research",
                        prompt_template: "", input_from_prev: "", gate_after: false,
                        session_id: "demo-flow-1-step-0", phase: "exited(0)",
                        started: "2026-06-25T10:00:00Z", ended: "2026-06-25T10:04:12Z",
                        retries: nil, prev_session_ids: nil, fanout: nil, kind: nil,
                        spliced_from: nil, loop: nil,
                        output: "Reviewed the broker's HTTP middleware chain and existing rate-limit precedent in sibling services. Recommending a token-bucket limiter keyed by client token, mounted ahead of the session routes."
                    ),
                    ConduitUI.PipelineStepStatus(
                        index: 1, agent_type: "claude", role: "design",
                        prompt_template: "", input_from_prev: "", gate_after: true,
                        session_id: "demo-flow-1-step-1", phase: "exited(0)",
                        started: "2026-06-25T10:04:12Z", ended: "2026-06-25T10:09:47Z",
                        retries: nil, prev_session_ids: nil, fanout: nil, kind: nil,
                        spliced_from: nil, loop: nil,
                        output: flow1GateHandoff
                    ),
                    ConduitUI.PipelineStepStatus(
                        index: 2, agent_type: "codex", role: "build",
                        prompt_template: "", input_from_prev: "", gate_after: false,
                        session_id: nil, phase: nil,
                        started: nil, ended: nil,
                        retries: nil, prev_session_ids: nil, fanout: nil, kind: nil,
                        spliced_from: nil, loop: nil,
                        output: nil
                    ),
                ],
                gate: ConduitUI.PipelineGate(step: 1, prev: flow1GateHandoff, output: flow1GateHandoff),
                result: nil
            )
        case "demo-flow-2":
            return ConduitUI.PipelineStatus(
                id: "demo-flow-2",
                title: "Migrate settings to KV store",
                task: "Move the app's local settings storage to a KV store backend for durability across reinstalls.",
                cwd: "/home/user/projects/api",
                base: "main",
                state: "running",
                current_step: 1,
                steps: [
                    ConduitUI.PipelineStepStatus(
                        index: 0, agent_type: "claude", role: "research",
                        prompt_template: "", input_from_prev: "", gate_after: false,
                        session_id: "demo-flow-2-step-0", phase: "exited(0)",
                        started: "2026-06-25T09:30:00Z", ended: "2026-06-25T09:34:20Z",
                        retries: nil, prev_session_ids: nil, fanout: nil, kind: nil,
                        spliced_from: nil, loop: nil,
                        output: "Audited current settings storage across Settings screens; found 12 keys touching 3 stores. KV store candidate: a boltdb-backed key namespace under ~/.conduit/kv."
                    ),
                    ConduitUI.PipelineStepStatus(
                        index: 1, agent_type: "codex", role: "build",
                        prompt_template: "", input_from_prev: "", gate_after: false,
                        session_id: "demo-flow-2-step-1", phase: "running",
                        started: "2026-06-25T09:34:20Z", ended: nil,
                        retries: nil, prev_session_ids: nil, fanout: nil, kind: nil,
                        spliced_from: nil, loop: nil,
                        output: nil
                    ),
                    ConduitUI.PipelineStepStatus(
                        index: 2, agent_type: "codex", role: "verify",
                        prompt_template: "", input_from_prev: "", gate_after: false,
                        session_id: nil, phase: nil,
                        started: nil, ended: nil,
                        retries: nil, prev_session_ids: nil, fanout: nil, kind: nil,
                        spliced_from: nil, loop: nil,
                        output: nil
                    ),
                ],
                gate: nil,
                result: nil
            )
        default:
            return nil
        }
    }

    // MARK: Session 1: Build a to-do app

    private static let session1Conversation: [ConversationItem] = [
        ConversationItem(
            id: "demo-1-1",
            role: "user",
            kind: "message",
            status: "done",
            content: "Build me a simple to-do list app in Python",
            ts: "2026-06-25T10:00:00Z",
            files: [],
            toolName: nil,
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
        ),
        ConversationItem(
            id: "demo-1-2",
            role: "assistant",
            kind: "message",
            status: "done",
            content: "I'll create a clean command-line to-do app. Let me start by creating the file.",
            ts: "2026-06-25T10:00:05Z",
            files: [],
            toolName: nil,
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
        ),
        ConversationItem(
            id: "demo-1-3",
            role: "tool",
            kind: "tool",
            status: "done",
            content: "",
            ts: "2026-06-25T10:00:10Z",
            files: [],
            toolName: "bash",
            command: "python3 -c \"open('todo.py','w').write('...')\"",
            exitCode: 0,
            durationMs: 350,
            diffSummary: nil,
            pendingOptions: [],
            sourceAgent: nil,
            targetAgent: nil,
            taskText: nil,
            resultSummary: nil,
            planSteps: []
        ),
        ConversationItem(
            id: "demo-1-4",
            role: "tool",
            kind: "tool",
            status: "done",
            content: "",
            ts: "2026-06-25T10:00:15Z",
            files: [],
            toolName: "str_replace_based_edit_tool",
            command: "Write todo.py",
            exitCode: 0,
            durationMs: 120,
            diffSummary: nil,
            pendingOptions: [],
            sourceAgent: nil,
            targetAgent: nil,
            taskText: nil,
            resultSummary: nil,
            planSteps: []
        ),
        ConversationItem(
            id: "demo-1-5",
            role: "assistant",
            kind: "message",
            status: "done",
            content: "Done! I've created `todo.py` with `add`, `list`, `complete`, and `delete` commands. Try it with:\n\n```\npython todo.py add 'Buy groceries'\npython todo.py list\n```",
            ts: "2026-06-25T10:00:20Z",
            files: [],
            toolName: nil,
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
        ),
        // PLAN: roadmap the agent lays out after scaffolding the core
        ConversationItem(
            id: "demo-1-plan",
            role: "assistant",
            kind: "plan",
            status: "done",
            content: "Here's the roadmap I'm working through:",
            ts: "2026-06-25T10:00:26Z",
            files: [],
            toolName: nil,
            command: nil,
            exitCode: nil,
            durationMs: nil,
            diffSummary: nil,
            pendingOptions: [],
            sourceAgent: nil,
            targetAgent: nil,
            taskText: nil,
            resultSummary: nil,
            planSteps: [
                PlanStep(text: "scaffold todo.py with a JSON store", state: "done"),
                PlanStep(text: "add / list / complete / delete commands", state: "done"),
                PlanStep(text: "colored output with colorama", state: "todo"),
                PlanStep(text: "unit tests for the CLI commands", state: "todo"),
            ]
        ),
        ConversationItem(
            id: "demo-1-6",
            role: "user",
            kind: "message",
            status: "done",
            content: "Can you add colored output?",
            ts: "2026-06-25T10:02:00Z",
            files: [],
            toolName: nil,
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
        ),
        ConversationItem(
            id: "demo-1-7",
            role: "assistant",
            kind: "message",
            status: "done",
            content: "Sure, I'll use `colorama` for cross-platform color support.",
            ts: "2026-06-25T10:02:05Z",
            files: [],
            toolName: nil,
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
        ),
        ConversationItem(
            id: "demo-1-8",
            role: "tool",
            kind: "tool",
            status: "done",
            content: "Collecting colorama\n  Downloading colorama-0.4.6-py2.py3-none-any.whl (25 kB)\nSuccessfully installed colorama-0.4.6",
            ts: "2026-06-25T10:02:10Z",
            files: [],
            toolName: "bash",
            command: "pip install colorama",
            exitCode: 0,
            durationMs: 1200,
            diffSummary: nil,
            pendingOptions: [],
            sourceAgent: nil,
            targetAgent: nil,
            taskText: nil,
            resultSummary: nil,
            planSteps: []
        ),
        ConversationItem(
            id: "demo-1-9",
            role: "tool",
            kind: "tool",
            status: "done",
            content: "",
            ts: "2026-06-25T10:02:15Z",
            files: [],
            toolName: "str_replace_based_edit_tool",
            command: "Update todo.py with colorama",
            exitCode: 0,
            durationMs: 90,
            diffSummary: nil,
            pendingOptions: [],
            sourceAgent: nil,
            targetAgent: nil,
            taskText: nil,
            resultSummary: nil,
            planSteps: []
        ),
        ConversationItem(
            id: "demo-1-10",
            role: "assistant",
            kind: "message",
            status: "done",
            content: "Updated! Pending tasks now show in yellow, completed ones in green. Run `python todo.py list` to see it.",
            ts: "2026-06-25T10:02:20Z",
            files: [],
            toolName: nil,
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
        ),
        // CODE: assistant message with a python fenced block
        ConversationItem(
            id: "demo-1-11",
            role: "assistant",
            kind: "message",
            status: "done",
            content: "Here is the key section of `todo.py` that handles color output:\n\n```python\nfrom colorama import Fore, Style, init\ninit(autoreset=True)\n\ndef list_tasks(tasks):\n    for i, task in enumerate(tasks, 1):\n        if task['done']:\n            print(f\"{Fore.GREEN}{i}. [x] {task['text']}{Style.RESET_ALL}\")\n        else:\n            print(f\"{Fore.YELLOW}{i}. [ ] {task['text']}{Style.RESET_ALL}\")\n```",
            ts: "2026-06-25T10:02:30Z",
            files: [],
            toolName: nil,
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
        ),
        // DIFF: unified diff of the colorama edit
        ConversationItem(
            id: "demo-1-12",
            role: "tool",
            kind: "diff",
            status: "done",
            content: "--- a/todo.py\n+++ b/todo.py\n@@ -1,5 +1,11 @@\n+from colorama import Fore, Style, init\n+init(autoreset=True)\n+\n import json, sys\n \n def list_tasks(tasks):\n-    for i, task in enumerate(tasks, 1):\n-        print(f\"{i}. {'[x]' if task['done'] else '[ ]'} {task['text']}\")\n+    for i, task in enumerate(tasks, 1):\n+        if task['done']:\n+            print(f\"{Fore.GREEN}{i}. [x] {task['text']}{Style.RESET_ALL}\")\n+        else:\n+            print(f\"{Fore.YELLOW}{i}. [ ] {task['text']}{Style.RESET_ALL}\")",
            ts: "2026-06-25T10:02:35Z",
            files: [],
            toolName: "str_replace_based_edit_tool",
            command: nil,
            exitCode: 0,
            durationMs: 90,
            diffSummary: "1 file · +6 -1",
            pendingOptions: [],
            sourceAgent: nil,
            targetAgent: nil,
            taskText: nil,
            resultSummary: nil,
            planSteps: []
        ),
        // SUBAGENT: audit of the CLI commands
        ConversationItem(
            id: "demo-1-subagent",
            role: "system",
            kind: "subagent",
            status: "done",
            content: "subagent: audited the CLI commands for edge cases\nChecked add / list / complete / delete; added empty-list and duplicate-title handling, and guarded delete against out-of-range indexes.",
            ts: "2026-06-25T10:02:45Z",
            files: [],
            toolName: nil,
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
        ),
        // HANDOFF: claude -> codex to port the CLI to mobile
        ConversationItem(
            id: "demo-1-handoff",
            role: "assistant",
            kind: "handoff",
            status: "done",
            content: "Core CLI is done, colored, and edge-cases are guarded. Handing the mobile packaging + port to codex.",
            ts: "2026-06-25T10:02:52Z",
            files: [],
            toolName: nil,
            command: nil,
            exitCode: nil,
            durationMs: nil,
            diffSummary: nil,
            pendingOptions: [],
            sourceAgent: "claude",
            targetAgent: "codex",
            taskText: "Package the to-do CLI and port it to the mobile app",
            resultSummary: "Core CLI is done, colored, and edge-cases are guarded. Handing the mobile packaging + port to codex.",
            planSteps: []
        ),
        // PENDING-INPUT: assistant asking if user wants unit tests
        ConversationItem(
            id: "demo-1-13",
            role: "assistant",
            kind: "pending_input",
            status: "pending",
            content: "Want me to add unit tests for the CLI commands?",
            ts: "2026-06-25T10:03:00Z",
            files: [],
            toolName: nil,
            command: nil,
            exitCode: nil,
            durationMs: nil,
            diffSummary: nil,
            pendingOptions: ["Add tests", "Not now"],
            sourceAgent: nil,
            targetAgent: nil,
            taskText: nil,
            resultSummary: nil,
            planSteps: []
        ),
    ]

    // MARK: Session 2: Fix authentication bug

    private static let session2Conversation: [ConversationItem] = [
        ConversationItem(
            id: "demo-2-1",
            role: "user",
            kind: "message",
            status: "done",
            content: "My login endpoint returns 401 even with correct credentials",
            ts: "2026-06-25T09:30:00Z",
            files: [],
            toolName: nil,
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
        ),
        ConversationItem(
            id: "demo-2-2",
            role: "assistant",
            kind: "message",
            status: "done",
            content: "Let me look at the auth code.",
            ts: "2026-06-25T09:30:05Z",
            files: [],
            toolName: nil,
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
        ),
        ConversationItem(
            id: "demo-2-3",
            role: "tool",
            kind: "tool",
            status: "done",
            content: "src/auth.py:47:    if token.expires_at >= now:",
            ts: "2026-06-25T09:30:10Z",
            files: [],
            toolName: "bash",
            command: "grep -r 'expired_at\\|token' src/auth.py",
            exitCode: 0,
            durationMs: 180,
            diffSummary: nil,
            pendingOptions: [],
            sourceAgent: nil,
            targetAgent: nil,
            taskText: nil,
            resultSummary: nil,
            planSteps: []
        ),
        ConversationItem(
            id: "demo-2-4",
            role: "assistant",
            kind: "message",
            status: "done",
            content: "Found it -- line 47 uses `>=` instead of `>`, so tokens are rejected exactly at their stated expiry rather than after. Let me fix it.",
            ts: "2026-06-25T09:30:15Z",
            files: [],
            toolName: nil,
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
        ),
        ConversationItem(
            id: "demo-2-5",
            role: "tool",
            kind: "tool",
            status: "done",
            content: "",
            ts: "2026-06-25T09:30:20Z",
            files: [],
            toolName: "str_replace_based_edit_tool",
            command: "Fix auth.py:47 >= to >",
            exitCode: 0,
            durationMs: 80,
            diffSummary: nil,
            pendingOptions: [],
            sourceAgent: nil,
            targetAgent: nil,
            taskText: nil,
            resultSummary: nil,
            planSteps: []
        ),
        ConversationItem(
            id: "demo-2-6",
            role: "assistant",
            kind: "message",
            status: "done",
            content: "Fixed. The comparison is now `> expires_at` instead of `>= expires_at`. Tokens will now be accepted up to and including their expiry second.",
            ts: "2026-06-25T09:30:25Z",
            files: [],
            toolName: nil,
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
        ),
        // PLAN: checklist for the full fix
        ConversationItem(
            id: "demo-2-7",
            role: "assistant",
            kind: "plan",
            status: "done",
            content: "Here is the plan for the full token-refresh fix:",
            ts: "2026-06-25T09:30:30Z",
            files: [],
            toolName: nil,
            command: nil,
            exitCode: nil,
            durationMs: nil,
            diffSummary: nil,
            pendingOptions: [],
            sourceAgent: nil,
            targetAgent: nil,
            taskText: nil,
            resultSummary: nil,
            planSteps: [
                PlanStep(text: "reproduce the 401 loop", state: "done"),
                PlanStep(text: "add backoff on refresh", state: "done"),
                PlanStep(text: "add a regression test", state: "todo"),
            ]
        ),
        // SUBAGENT: audit of refreshToken callers
        ConversationItem(
            id: "demo-2-8",
            role: "system",
            kind: "subagent",
            status: "done",
            content: "subagent: audited callers of refreshToken()\nFound 3 call sites; 2 guarded, 1 missing the 401 backoff.",
            ts: "2026-06-25T09:31:00Z",
            files: [],
            toolName: nil,
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
        ),
        // HANDOFF: claude -> codex to port fix to mobile
        ConversationItem(
            id: "demo-2-9",
            role: "assistant",
            kind: "handoff",
            status: "done",
            content: "Refresh loop fixed; 401s now back off. Handing the mobile port to codex.",
            ts: "2026-06-25T09:31:30Z",
            files: [],
            toolName: nil,
            command: nil,
            exitCode: nil,
            durationMs: nil,
            diffSummary: nil,
            pendingOptions: [],
            sourceAgent: "claude",
            targetAgent: "codex",
            taskText: "Port the token-refresh fix to the mobile client",
            resultSummary: "Refresh loop fixed; 401s now back off. Handing the mobile port to codex.",
            planSteps: []
        ),
    ]
}
