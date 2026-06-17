---
title: Claude OAuth ground truth — extract from the CLI binary
tags: [oauth, claude, ios, android, auth]
scope: repo
source: claude-oauth-ground-truth
status: active
---

# Claude OAuth ground truth — extract from the CLI binary

Anthropic's OAuth endpoints are format-strict and undocumented. Guessing burns
device-test cycles. When you need the exact request shape, extract it from the
real `claude` binary on the broker host — do not reverse-engineer from docs or
memory.

## Two extraction techniques

**1. Live URL probe (zero impact on operator credentials):**
```sh
tmp=$(mktemp -d)
CLAUDE_CONFIG_DIR=$tmp timeout 12 claude auth login --claudeai </dev/null
```
This prints the exact authorize URL to stdout. The sandboxed config dir ensures
the operator's real `~/.claude/.credentials.json` is untouched.

**2. Bundle grep (for request body shapes):**
`/root/.local/bin/claude` resolves to a Bun-compiled ELF at
`/root/.local/share/claude/versions/<ver>`. The JS is embedded as strings.
```sh
grep -aoP '.{200}grant_type:"authorization_code".{500}' <binary>
```
Also search around `buildAuthUrl`, `code_challenge`, `claudeAiOauth` to recover
the full request shapes.

## Ground truth (CLI 2.1.165)

- **Authorize:** `https://claude.com/cai/oauth/authorize` (302s to claude.ai,
  normalizes query).
- **Param order:** `code=true, client_id, response_type, redirect_uri, scope,
  code_challenge, code_challenge_method, state`.
- **Encoding:** URLSearchParams (space → `+`).
- **State and verifier:** both `base64url(randomBytes(32))` = 43 characters.
- **Token exchange:** POST to `https://platform.claude.com/v1/oauth/token` with
  a **JSON body** (not form-encoded): `{grant_type, code, redirect_uri,
  client_id, code_verifier, state}`.
- **Codex/OpenAI:** stays RFC 6749 form body — the JSON body is Claude-specific.

Note: the token endpoint rate-limits from the broker IP. `curl` to claude.ai
gets Cloudflare-403'd. The binary is the reliable oracle.

## When to re-run

When Anthropic rotates the flow (client_id, params, body shape): re-run both
extraction steps against the current CLI version and diff against the above.

Related: [ASKUSERQUESTION-CONTROL-BRIDGE](ASKUSERQUESTION-CONTROL-BRIDGE.md),
[STOP-INTERRUPT-PROTOCOL](STOP-INTERRUPT-PROTOCOL.md)
