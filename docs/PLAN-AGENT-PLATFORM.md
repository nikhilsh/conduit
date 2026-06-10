# PLAN: Agent Platform — protocol-keyed backends, manifest-driven adapters, descriptor-driven apps

Status: approved plan, 2026-06-10. Owner: Nikhil. Implementation: Claude subagents
(per-workstream model recommendation in each spec — `sonnet` = mechanical/well-mapped,
`opus` = protocol/design work).

## Goal

Make onboarding a NEW agent (gemini-cli, opencode, pi, …) cost **one TOML manifest +
at most one Go protocol package**, instead of edits to ~13 hardcoded `switch` sites in
the broker and ~82 name-switches in the apps. Codex becomes a first-class citizen
(today it lacks AI titles, quick replies, and AskUserQuestion). Push notifications are
specced separately in `docs/PLAN-PUSH.md`.

## Principles

1. **Backends are keyed by PROTOCOL, not agent name.** The field is converging on a
   few protocol families: claude's stream-json control protocol, codex's app-server
   JSON-RPC, plain exec-per-turn JSONL, and (later) ACP. A new agent speaking an
   existing protocol must cost zero Go.
2. **Per-agent string/flag differences live in the adapter TOML manifest**, not in Go
   switches. The manifest is the single source of truth for flags, paths, and
   capability declarations.
3. **Apps render from broker-served descriptors with static fallback** — the exact
   pattern shipped for the model catalog in PR #428 (`/api/capabilities` `models` map,
   `ForkOptions` static fallback). Old broker → apps behave as today.
4. **Behavior-preserving refactors ship with golden tests**: claude/codex argv and
   wire frames must be byte-identical before/after each phase.

## Ground truth: the coupling inventory

A full audit of agent special-casing was done 2026-06-10 (subagent af0f7ea9b38aa4b32).
Summary of the ~13 hardcoded broker switch points (see git history of this file for
the full table):

| # | Integration point | claude | codex | today |
|---|---|---|---|---|
| 1 | Spawn argv | `claudeStreamCommand` (claudechat.go:40) | `codex app-server` (codexappserver.go:158) / `codex exec` (codexchatproc.go:71) | HC |
| 2 | Event parsing | `parseClaudeStreamLine` (claudestream.go) | `codexNotificationToEvent` (codexappserverwire.go:331) / `parseCodexStreamLine` | HC |
| 3 | AskUserQuestion | stdio control bridge (askcontrol.go) | **none** | HC |
| 4 | Resume | `--resume`/`--continue` + init session_id | `thread/resume` / `exec resume` + thread id | HC |
| 5 | Conv-file discovery | `.claude/projects,sessions/*.jsonl` (recovery.go:60) | `.codex/...` | HC |
| 6 | Interrupt | `control_request{interrupt}` | `turn/interrupt` / proc kill | HC behind `chatBackend` |
| 7 | Effort/model flags | `--effort`/`--model` (override.go:126) | `-c model_reasoning_effort=` / RPC params | HC |
| 8 | Catalog probe | stream-json `initialize` (modelcatalog.go) | `model/list` RPC | HC, output normalized |
| 9 | Permission modes | `--permission-mode plan` (override.go:42) | `--sandbox read-only` / sandbox enum | HC |
| 10 | OAuth login | `claude auth login` (loopback **stub**) | `codex login` (loopback, works) | HC behind `oauth.Provider` |
| 11 | Cred paths/freshness | `.claude/.credentials.json` | `.codex/auth.json` | HC |
| 12 | Account usage | api.anthropic.com oauth/usage | chatgpt.com wham/usage | HC |
| 13 | AI titles/quick-replies | Anthropic Messages API, **claude sessions only** (manager.go:525, aigen.go) | **none** | HC |

The cleanest existing seam is `chatBackend` (chatbackend.go:8 — Send/Interrupt/Close/
TurnActive) and the `structuredChatBackend(chatMode)` router (chatbackend.go:37).
Memory/handoff hooks, switch_agent, restart budget, watchdog are already agnostic.

---

## Phase 0 — Parity debt (product-visible; do first; workstreams independent)

### WS-0.1 AI titles + quick replies for codex sessions — `opus`

**Why:** `startChatBackend` attaches `titleGenerator`/`quickReplyGenerator` only in the
`case "claude"` branch (manager.go:525-544); both call `anthropicMessages` (aigen.go:65,
hardcoded `claude-haiku-4-5`, Anthropic OAuth creds). Codex users get no AI titles and
no quick replies.

**Design:** introduce a small `aiGen` provider abstraction in the session package:
- `type aiGenProvider interface { Complete(ctx, system, user string, maxTokens int) (string, error) }`
- `anthropicGen` — current implementation, used when anthropic creds are materialized
  for the identity (today's behavior, unchanged).
- `codexGen` — one-shot `codex exec --json --model gpt-5.4-mini -c model_reasoning_effort=low`
  with the prompt on stdin, parse the final agent message. Use the smallest model from
  the discovered catalog (`modelcatalog.go`) rather than hardcoding when available.
- Selection: per-session — prefer the session's own agent's provider; fall back to the
  other if creds for the primary are missing. Attach generators in BOTH backend
  branches.

**Files:** `broker/internal/session/aigen.go`, `manager.go` (startChatBackend),
new `aigen_codex.go` + tests with a stub `codex` script binary (pattern:
`modelcatalog_test.go` writeStubBinary).

**Acceptance:** codex session with fake transcript gets a generated title + quick
replies via the stub binary; claude path byte-identical (existing aigen tests pass);
no generation attempted when neither provider has creds (graceful skip, breadcrumb).

**Gates:** `cd broker && gofmt -l . && go vet ./... && go test ./...`.

### WS-0.2 Approval cards (AskUserQuestion-equivalent) for codex — `opus`

**Why:** claude gets native tappable choice cards via the stdio control bridge
(askcontrol.go, `--permission-prompt-tool stdio`); codex has nothing — yet the
app-server protocol enumerates elicitation/approval methods (seen live 2026-06-10:
`thread/increment_elicitation`, `thread/approveGuardianDeniedAction`, and server→client
approval requests under `approvalPolicy: on-request`).

**Design (two stages, stage 1 is the deliverable):**
1. **Protocol capture**: on the box (codex installed + signed in), run
   `codex app-server`, start a thread with `approvalPolicy: "on-request"`, send a turn
   that triggers a command needing approval, and capture the server→client request
   JSON (id-bearing request, expects a response). Document the exact frames in
   `docs/CODEX-APPSERVER-PROTOCOL.md` (extend it; capture technique in
   `~/.claude` memory: codex-app-server-backend).
2. **Implement**: map the captured approval request → the existing approval-card
   `view_event` shape the apps already render for claude (askcontrol.go's card pump);
   user's tap → JSON-RPC response. Wire codex "plan/on-request" permission mode to
   actually use `on-request` instead of `never` so approvals flow.

**Files:** `broker/internal/session/codexappserver.go` (handleNotification → also
handle server→client *requests*), `codexappserverwire.go`, askcontrol card-shape reuse;
tests with canned frames.

**Acceptance:** canned approval-request frame produces the same card view_event shape
the iOS/Android approval UI consumes; response frame is well-formed (table test).
Live verify on the box against real codex. Flag "needs on-device verification" for the
tap path.

### WS-0.3 Validate claude login code-paste fallback — `opus`

**Why:** `claudeProvider` (oauth/login_session.go:178) is a Stage-2 stub: no loopback,
URL match only, `Forward` rejects port-0. If claude's `auth login` flow changed, app
sign-in for claude may be broken on fresh boxes.

**Design:** sandboxed login probe (technique in memory: claude-oauth-ground-truth —
isolated $HOME, run `claude auth login`, capture URL + expected callback/paste flow,
grep the Bun bundle for endpoints if needed). Then either wire the loopback path
(if the CLI now serves one) or implement the code-paste relay: app captures the code
from the browser redirect page, sends it via the existing `agent_login_callback` WS
message, broker pastes it to the CLI's stdin.

**Acceptance:** end-to-end login on the box into a throwaway $HOME using the real CLI,
documented frame-by-frame; unit tests for the new provider parsing. Update
`docs/archive/PLAN-AGENT-OAUTH.md` stage-2 section.

### WS-0.4 Invoke the `on_start` hook — `sonnet`

**Why:** `hooks.on_start` is parsed (registry.go:16) and configured in both TOMLs but
has **no call site** — on_exit (manager.go:1040) and on_swap (lifecycle.go:576) do.
The memory render that's supposed to seed `.conduit/HANDOFF.html` for fresh sessions
never runs.

**Design:** call `s.runHook(s.hooks.OnStart, …)` in the spawn path (lifecycle.go,
after PTY/backend start, before the session is exposed) with the same env as on_swap;
non-fatal on error (breadcrumb + log, never block the spawn). Render the handoff HTML
for fresh sessions the way switchToAdapter does (lifecycle.go:676).

**Acceptance:** new test: session spawn with an on_start hook that touches a sentinel
file → file exists; hook failure doesn't fail the spawn. Existing suite green.

---

## Phase 1 — Manifest extraction (mechanical; map = inventory above) — `sonnet`

### WS-1.1 Extend the adapter TOML schema

Add to `agents.Adapter` (registry.go), all optional with defaults equal to today's
hardcoded claude/codex values (resolved by adapter NAME for back-compat when absent):

```toml
# agents/claude.toml (new fields — illustrative values)
protocol            = "stream-json"        # routing key for Phase 2 (alias of chat_mode)
config_dir          = ".claude"            # recovery.go conv-file discovery
cred_files          = [".claude/.credentials.json", ".claude.json"]
resume_args         = ["--resume", "{session_id}"]
continue_args       = ["--continue"]
model_args          = ["--model", "{model}"]
effort_args         = ["--effort", "{effort}"]
login_provider      = "anthropic"
[permission_modes.plan]
drop_args = ["--dangerously-skip-permissions"]
add_args  = ["--permission-mode", "plan"]
```

```toml
# agents/codex.toml (new fields)
protocol            = "codex-app-server"
config_dir          = ".codex"
cred_files          = [".codex/auth.json", ".codex/config.toml"]
resume_args         = []                    # app-server resumes via thread/resume
model_args          = ["--model", "{model}"]
effort_args         = ["-c", "model_reasoning_effort={effort}"]
login_provider      = "openai"
[permission_modes.plan]
drop_args = ["--dangerously-bypass-approvals-and-sandbox"]
add_args  = ["--sandbox", "read-only"]
```

Update both checked-in TOMLs AND the embedded copies
(`cmd/conduit-broker/embedded-agents/`). `{placeholders}` use simple string
substitution.

### WS-1.2 Convert the switch sites to read the manifest

- `override.go`: `extraArgsFor` / `effectiveEffort` / `applyClaudePermissionMode` /
  `applyCodexPermissionMode` → generic functions taking the Adapter manifest.
- `recovery.go:60`: `chatConversationOnDisk(dir, adapter.ConfigDir)`.
- `credentials` materialization + freshness paths (store.go:203-206, credfresh.go):
  resolve target paths from `cred_files` / `login_provider`.
- `lifecycle.go:156` `providerForAssistant` → `adapter.LoginProvider`.
- `lifecycle.go:173` `allCredentialProviders` → derived from the registry's adapters.

**Acceptance (critical):** golden argv tests — for every (assistant × override ×
permission-mode × resume) combination, the produced argv is **byte-identical** to the
pre-refactor output (capture the goldens FIRST in a standalone commit). Full broker
suite green. No app or wire-protocol changes in this phase.

---

## Phase 2 — Protocol backends — `opus`

### WS-2.1 `AgentBackend` interface + protocol registry

Formalize and extend the `chatBackend` seam (chatbackend.go):

```go
// protocol implementations registered by key, selected by adapter.Protocol
type AgentBackend interface {
    // Spawn starts the backend for a session (argv/RPC details internal).
    Spawn(ctx context.Context, sess *Session, adapter agents.Adapter, ov SpawnOverride, resume ResumeRef) (chatBackend, error)
    // CatalogProbe returns the live model catalog (modelcatalog.go probes move here).
    CatalogProbe(ctx context.Context, bin string) ([]ModelInfo, error)
    // Usage fetches account usage windows ("" ok = unsupported).
    Usage(ctx context.Context, homeDir string) (*AccountUsage, error)
    // Capabilities declares what the protocol supports (compact, askUserQuestion,
    // interrupt, resume, effort) — feeds the Phase-2.3 descriptors.
    Capabilities() BackendCapabilities
}
```

- Implementations: `streamjson` (claude today), `codexappserver`, `codexexec`
  (fallback), each in its own file set — mostly moves, not rewrites.
- `startChatBackend` (manager.go:515) routes via `registry[adapter.Protocol]`;
  the `structuredChatBackend` name-mapping shim is deleted.
- `modelcatalog.go`'s `catalogProbeFor` switch → backend method.
  `RefreshAccountUsage`'s switch (accountusage.go:119) → backend method.

**Acceptance:** golden wire tests: claude stream-json frames and codex RPC frames
produced for a scripted session are byte-identical pre/post (extend existing
codexappserver_test.go / claudechat tests). Behavior parity for interrupt, resume,
compact. Full suite green.

### WS-2.2 OAuth provider registry — `sonnet`

`oauth.ProviderFor` (login_session.go:207) keyed by `adapter.LoginProvider` from the
registry instead of a hardcoded switch; providers register themselves. No behavior
change; tests as today.

### WS-2.3 Per-assistant descriptors in capabilities — `sonnet`

Extend `/api/capabilities`:

```json
"agents": {
  "claude": {
    "display_name": "Claude",
    "login_provider": "anthropic",
    "supports": {"compact": true, "ask_user_question": true, "effort": true,
                  "plan_mode": true, "usage": true},
    "models": [ … existing ModelInfo … ]
  },
  "codex": { … }
}
```

Keep the existing top-level `models` map for one release (deprecate after apps ship).
Supports flags come from `BackendCapabilities` + manifest. Extend
`TestCapabilitiesEndpoint`.

---

## Phase 3 — Descriptor-driven apps — `sonnet` (one workstream per platform)

### WS-3.1 iOS / WS-3.2 Android

- Decode `agents` descriptors in SessionStore (pattern: `modelCatalog` from PR #428 —
  fetch on picker open, keep across failures, static fallback).
- Drive from descriptors: slash-command availability (`claudeOnly` flag in
  `SlashCommandRegistry.swift:40` → `supports.compact`), login UI provider mapping,
  picker copy, effort-section visibility (`supports.effort`), usage-card presence.
- Unknown agents render generically: existing monogram avatar fallback
  (AgentAvatar), neutral tint, name from descriptor. Brand colors/marks stay
  client-side keyed by name (decorative only — unknown names get the generic look).
- Unit tests mirror ForkOptions catalog tests: descriptor present vs absent fallback.

**Acceptance:** CI green; with descriptors absent (old broker) behavior is pixel-
identical to today. Flag "needs on-device verification" for the rendering.

---

## Phase 4 — Pilot agent: **opencode** — `opus`

Chosen over pi: opencode has a server mode (`opencode serve`, used by litter), a
models command for the catalog, an active ecosystem, and litter's integration as a
reference. pi remains a candidate after.

### WS-4.1 Protocol capture (do first, read-only)

Install opencode on the box (user-space). Capture, against the real binary:
- headless one-shot: `opencode run` JSON output shape; exit codes
- server mode: `opencode serve` HTTP/WS API (litter launches `<bin> serve --port=`)
  — enumerate endpoints (session create/list, message send, event stream, interrupt)
- model listing (CLI or API) for the catalog probe
- session persistence/resume story (on-disk session files? ids?)
- auth story (`opencode auth login` providers)
Document in `docs/OPENCODE-PROTOCOL.md` with verbatim frames (same rigor as
docs/CODEX-APPSERVER-PROTOCOL.md).

### WS-4.2 Implement

- `agents/opencode.toml` manifest (+ embedded copy) with `protocol = "opencode-server"`.
- New backend package implementing `AgentBackend` over the captured API.
- Catalog probe from its model listing; usage = unsupported (Capabilities flag).
- Apps: ZERO required changes if Phase 3 landed (generic rendering); optional
  brand tint/mark as a follow-up.

**Acceptance:** on the box: create session, send turn, see structured chat, interrupt,
resume after broker restart, model picker shows opencode's models. Broker suite green
with stub-binary tests. **The success metric of the whole plan: count the files
touched outside `agents/opencode.toml` + the new backend package — target ≤ 3.**

---

## Sequencing & dependencies

```
WS-0.1  WS-0.2  WS-0.3  WS-0.4     (independent, start immediately)
            ↓
WS-1.1 → WS-1.2                     (goldens first)
            ↓
WS-2.1 → WS-2.2, WS-2.3             (2.2/2.3 parallel after 2.1)
            ↓
WS-3.1 ∥ WS-3.2                     (parallel)
            ↓
WS-4.1 → WS-4.2
```

Push (PLAN-PUSH.md) is independent of all phases and can run in parallel.

## Subagent operating rules (every workstream)

- Work in an isolated worktree branched off fresh `origin/main`; one PR per
  workstream; commit style: single tight subject line.
- Run the broker gates locally (`gofmt -l . && go vet ./... && go test ./...`);
  mobile is CI-compile-only — push and watch CI; UI changes get "needs on-device
  verification" in the PR body.
- Sentry breadcrumbs on every new failure path (CLAUDE.md standing order).
- Refactor phases (1, 2) MUST land goldens in a separate first commit.
- Never touch the live broker; redeploy is a human-gated release step.
