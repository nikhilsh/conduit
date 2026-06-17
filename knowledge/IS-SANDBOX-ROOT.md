---
title: IS_SANDBOX=1 required for broker-exec of claude under root
tags: [broker, claude, root, sandbox, recap, CI]
scope: repo
source: recap-issandbox-root-bug
status: active
---

# IS_SANDBOX=1 required for broker-exec of claude under root

## The rule

Any broker one-shot exec of `claude --dangerously-skip-permissions` MUST include
`IS_SANDBOX=1` in the subprocess environment. Without it, the command is refused
when the broker runs as `root` (the standard bare-VPS deployment):

> cannot be used with root/sudo privileges

The live session spawn already sets this (in `lifecycle.go`). Any new exec path
— recap, batch one-shots, future automation — must mirror it.

## Why CI does not catch it

CI and local dev typically run as a non-root user, where
`--dangerously-skip-permissions` is accepted without `IS_SANDBOX=1`. The failure
is silent on prod: the exec returns an error and the code falls back to a
deterministic (non-agent) alternative. No crash, no obvious log line — just
missing output. This pattern makes the bug invisible until verified on the live
box.

## Context: the recap bug (v0.0.168)

The resume-recap feature (`broker/internal/session/recap.go`) had two compounding
issues, both fixed in v0.0.168:

1. **Speed.** `claudeRecap` used `--resume <id> --fork-session --print`, which
   re-ingests the full transcript and times out on large sessions. Fix: use
   `transcriptDigest` (tail ≤40 messages / 12 KB) + a fresh `claude --print`.

2. **IS_SANDBOX missing.** `recapEnv` did not set `IS_SANDBOX=1`, so on the live
   root-running broker every recap exec was refused and fell back to the
   deterministic note. The agent-authored recap never appeared in production.

**Verification method:** run `generateRecapLive` against a real large session on
the live box. Should return agent text in ~13 seconds. If it returns the
deterministic fallback immediately, the IS_SANDBOX env is missing.

Related: [UNIFFI-BINDINGS](UNIFFI-BINDINGS.md) (another "CI green, prod broken" pattern)
