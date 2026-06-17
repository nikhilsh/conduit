---
title: Stop/interrupt protocol for in-flight agent turns
tags: [broker, claude, codex, protocol, wire-format]
scope: repo
source: stop-turn-interrupt-protocol
status: active
---

# Stop/interrupt protocol for in-flight agent turns

Ground truth captured live on the box (claude-code 2.1.168, codex-cli 0.132.0
app-server v2). Both agents support graceful interrupt — no process kill needed.

## Claude (stream-json mode)

Write a `control_request` to the CLI's stdin:

```json
{"type":"control_request","request_id":"<id>","request":{"subtype":"interrupt"}}
```

The CLI responds:

```json
{"type":"control_response","response":{"subtype":"success","request_id":"<id>"}}
```

It then emits a user event `[Request interrupted by user]`, ends the turn with:

```json
{"type":"result","subtype":"error_during_execution","is_error":true}
```

The process stays alive for the next turn. The broker already runs this
bidirectional control channel for `AskUserQuestion`
(see [ASKUSERQUESTION-CONTROL-BRIDGE](ASKUSERQUESTION-CONTROL-BRIDGE.md)), so
the mechanism is wired and tested.

Note: some documentation claims `interrupt` on stdin is unsupported. That
refers to a bare `{"type":"interrupt"}` shape, not the `control_request`
subtype — the latter works and was verified live.

## Codex (app-server v2 JSON-RPC)

Method `turn/interrupt` with params:

```json
{"threadId":"<tid>","turnId":"<turnId>"}
```

Both fields are required. Returns an empty `{}` response.

The broker must latch `turnId` separately — `turn/start` RESPONSE and the
`turn/started` notification both carry it. As of the memory capture,
`codexappserver.go` tracked `threadID` and `turnActive` but not `turnId` — add
it before wiring the interrupt path.

## Discovery technique

To rediscover or extend the Codex protocol:
```sh
codex app-server generate-json-schema --out <dir>
```
This dumps every request and notification schema (v2/ directory contains
`TurnInterruptParams`, `TurnStartResponse`, `TurnCompletedNotification`, and
`turn/steer` for steering). `generate-ts` also exists.

For Claude: drive `claude -p --input-format stream-json --output-format
stream-json --include-partial-messages --verbose` with a long-running prompt,
then send the interrupt control_request after a few seconds.

## Composer Stop-button UX (all four surfaces)

Trailing button priority: draft non-empty → Send; agent working/streaming →
Stop; otherwise → voice/mic. `isAgentWorking` / `agentWorking` already exist
on both iOS and Android.

Related: [CLAUDE-OAUTH-GROUND-TRUTH](CLAUDE-OAUTH-GROUND-TRUTH.md),
[ASKUSERQUESTION-CONTROL-BRIDGE](ASKUSERQUESTION-CONTROL-BRIDGE.md)
