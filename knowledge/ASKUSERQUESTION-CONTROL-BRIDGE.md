---
title: AskUserQuestion control bridge
tags: [broker, claude, control-protocol, ios, android]
scope: repo
source: ask-user-question-control-bridge
status: active
---

# AskUserQuestion control bridge

Headless `claude -p` auto-denies `AskUserQuestion` tool calls. The broker
intercepts them via the `--permission-prompt-tool stdio` flag and implements the
`control_request`/`control_response` protocol, allowing the phone to answer.

## How it works

The broker launches claude with `--permission-prompt-tool stdio`
(`broker/internal/session/askcontrol.go`). When claude issues an AskUserQuestion
tool call, it emits a `control_request`; the broker:

1. Stashes the question on the session.
2. Pushes a notification to the phone (the "pending input" card).
3. Waits for the user's next `SendChat` message (or a 30-minute timeout).
4. Forwards the answer as a `control_response` with the user's text.
5. The agent resumes the SAME turn with the real answer.

For multiple questions, `SendChat` answers variant `1` (first pending); subsequent
messages answer further questions in order. Free-text answers are forwarded as
`updatedInput.response`.

30-minute timeout: if the user does not answer, the broker sends an allow-unchanged
response. Other `can_use_tool` requests (non-AskUserQuestion) are auto-allowed,
preserving bypass semantics.

## Multi-select encoding

Multi-select questions ride inside the card text with the marker
`" (select all that apply)"` appended by `askUserQuestionContent` in the broker.
iOS `parsePendingQuestions` strips the marker and sets `PendingQuestion.multiSelect`.
Android: `PendingQuestions.parse` (Kotlin mirror). This is deliberate — no UDL
or `ConversationItem` schema change was required.

## Chat resume continuity

PR #398: respawned/recovered claude chat agents `--resume` their persisted
conversation id (`claude_chat_session_id` in `meta.json`, latched from the
stream-json init line). Broker restarts no longer wipe agent memory.

PRs #399–#402 (v0.0.122): codex thread persists (`codex_thread_id`); pre-latch
sessions recover via `--continue`; stale-id guard; agent switch re-points the
chat backend; `Session.Close` no longer wipes agent-home (scrubs only materialized
credentials — the old `RemoveAll` was destroying resume files on every redeploy).

## Verification

The control protocol was verified live against CLI 2.1.168. Drive a session that
triggers AskUserQuestion, watch for the pending input card on the phone, tap to
answer, and confirm the agent continues the turn (not a new turn).

Related: [STOP-INTERRUPT-PROTOCOL](STOP-INTERRUPT-PROTOCOL.md),
[CLAUDE-OAUTH-GROUND-TRUTH](CLAUDE-OAUTH-GROUND-TRUTH.md)
